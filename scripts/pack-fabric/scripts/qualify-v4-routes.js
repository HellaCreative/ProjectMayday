#!/usr/bin/env node
"use strict";

// Serial native-engine qualification. Raw receipts remain available on failure;
// no failed route is converted into a successful connectivity assertion.
const fs = require("node:fs"), path = require("node:path"), os = require("node:os");
const { spawn } = require("node:child_process");
const { hashFile } = require("./prepare-common-source-lock");
const { readTopologySealMetaSync } = require("./topology-meta");
const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
const save = (file, value) => {
  fs.writeFileSync(file + ".tmp", JSON.stringify(value, null, 2) + "\n");
  fs.renameSync(file + ".tmp", file);
};

function distance(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== 2 || b.length !== 2 ||
      [...a, ...b].some(v => !Number.isFinite(v))) return Infinity;
  const rad = Math.PI / 180;
  const h = Math.sin((b[1] - a[1]) * rad / 2) ** 2 +
    Math.cos(a[1] * rad) * Math.cos(b[1] * rad) * Math.sin((b[0] - a[0]) * rad / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.min(1, Math.sqrt(h)));
}

function processMeasurements(text) {
  const number = pattern => {
    const value = Number(text.match(pattern)?.[1]);
    return Number.isFinite(value) && value >= 0 ? value : null;
  };
  return {
    rssBytes: number(/(\d+)\s+maximum resident set size/),
    peakFootprintBytes: number(/(\d+)\s+peak memory footprint/),
    processSeconds: number(/([\d.]+)\s+real\s+[\d.]+\s+user/)
  };
}

function audit(result, request, rssBytes) {
  const failures = [];
  if (result.status !== "complete" || result.limit) failures.push(`incomplete: ${result.error || result.limit || result.status}`);
  for (const key of ["style", "wander", "seed", "allowUnknown", "avoidFerries", "avoidHighways", "avoidCities"]) {
    if (result[key] !== request[key]) failures.push(`settings mismatch: ${key}`);
  }
  if (JSON.stringify(result.requestedStart) !== JSON.stringify(request.from) ||
      JSON.stringify(result.requestedEnd) !== JSON.stringify(request.to)) failures.push("requested pins changed");
  for (const [key, point] of [["matchedStart", request.from], ["matchedEnd", request.to]]) {
    if (distance(result[key], point) > 250) failures.push(`${key} outside matching radius`);
  }
  if (!Number.isFinite(result.seconds) || result.seconds < 0 || result.seconds > request.maxSeconds) failures.push("elapsed-time ceiling");
  if (!Number.isFinite(rssBytes) || rssBytes <= 0 || rssBytes > request.maxRSSBytes) failures.push("resident-memory ceiling");
  if (!Array.isArray(result.segments) || result.segments.length === 0) failures.push("missing road receipts");
  if (!Number.isFinite(result.distanceMeters) || result.distanceMeters <= 0 ||
      Math.abs((result.segments || []).reduce((sum, s) => sum + s.meters, 0) - result.distanceMeters) > 1)
    failures.push("reported distance differs from ridden roads");
  let previous = null, unknownRun = 0, longestUnknown = 0, maxGap = 0, ferries = 0;
  for (const segment of result.segments || []) {
    if (!Number.isFinite(segment.meters) || segment.meters < 0) failures.push("invalid road distance");
    if (![0, 1, 3, 4].includes(segment.access)) failures.push("prohibited/closed road");
    if (!Array.isArray(segment.geometry) || segment.geometry.length < 2) { failures.push("missing road shape"); continue; }
    if (segment.geometry.some(point => !Array.isArray(point) || point.length !== 2 ||
        !point.every(Number.isFinite) || Math.abs(point[0]) > 180 || Math.abs(point[1]) > 90))
      failures.push("invalid road coordinates");
    if (previous) maxGap = Math.max(maxGap, distance(previous, segment.geometry[0]));
    previous = segment.geometry.at(-1);
    if (segment.access === 1) unknownRun += segment.meters;
    else if (segment.meters > 0) unknownRun = 0;
    longestUnknown = Math.max(longestUnknown, unknownRun);
    if (segment.structure === "ferry") ferries++;
  }
  if (distance(result.segments?.[0]?.geometry?.[0], result.matchedStart) > 2 ||
      distance(result.segments?.at(-1)?.geometry?.at(-1), result.matchedEnd) > 2)
    failures.push("road shape does not reach matched endpoints");
  if (maxGap > 2) failures.push(`discontinuous geometry: ${maxGap} m`);
  if (!request.allowUnknown && longestUnknown > (request.style === "cleanest" ? 0 : 100.01)) failures.push("unknown connector too long");
  if (request.avoidFerries && ferries) failures.push("ferry despite avoidance");
  if (request.requireFerry && !ferries) failures.push("required ferry not exercised");
  if (request.requireWay && !(result.segments || []).some(s => s.edgeID.split(":")[0].replace(/^w/, "") === String(request.requireWay))) failures.push("required bridge/road not exercised");
  if (!Number.isFinite(result.reriddenMeters) || result.reriddenMeters > request.maxRepeatMeters) failures.push("repeated-road ceiling");
  return { failures: [...new Set(failures)], maxGap, longestUnknown, ferries };
}

function validateCoverage(plan, regionIds, pairs) {
  const failures = [], styles = ["dirt", "balanced", "cleanest"];
  const ids = new Set();
  for (const c of plan.cases || []) {
    if (!c.id || ids.has(c.id)) failures.push("missing/duplicate request ID");
    ids.add(c.id);
    if (!styles.includes(c.style) || !c.regions?.length || c.regions.some(id => !regionIds.includes(id))) failures.push(`${c.id}: invalid style/regions`);
    if (![c.maxSeconds, c.windowSeconds, c.maxRSSBytes].every(v => Number.isFinite(v) && v > 0) ||
        !Number.isFinite(c.maxRepeatMeters) || c.maxRepeatMeters < 0) failures.push(`${c.id}: missing resource/shape limits`);
  }
  for (const id of regionIds) for (const style of styles) {
    if (!plan.cases.some(c => c.style === style && c.regions.length === 1 && c.regions[0] === id)) failures.push(`${id}/${style}: missing internal journey`);
  }
  // A landing may need an intermediate pack. The declared crossing names the
  // journey under test, not a claim that only those two files are sufficient.
  for (const pair of pairs) for (const [a, b] of [[pair.left, pair.right], [pair.right, pair.left]]) {
    for (const style of styles) {
      if (!plan.cases.some(c => c.style === style && c.crossing?.[0] === a && c.crossing?.[1] === b)) failures.push(`${a}>${b}/${style}: missing crossing journey`);
    }
  }
  return failures;
}

function verifyQualification(root, directory) {
  const summary = read(path.join(directory, "qualification.json"));
  const release = read(path.join(root, "release.json"));
  if (summary.schema !== "dirt-route-qualification.v1" || summary.releaseSHA256 !== hashFile(path.join(root, "release.json"))) throw new Error("route qualification is for different pack bytes/release");
  const planFile = path.join(directory, "plan.json");
  if (hashFile(planFile) !== summary.planSHA256) throw new Error("route qualification plan changed");
  const plan = read(planFile);
  const topology = readTopologySealMetaSync(path.join(root, "cross-pack-topology.v2.json"));
  const coverage = validateCoverage(plan, release.regions.map(r => r.id), topology.pairs);
  if (coverage.length) throw new Error(`route qualification coverage incomplete: ${coverage.join("; ")}`);
  if (!summary.hardware || !summary.probeSHA256 || summary.status !== "passed" || summary.results.length !== plan.cases.length) throw new Error("route qualification incomplete/failed");
  for (const request of plan.cases) {
    const row = summary.results.find(r => r.id === request.id);
    if (!row || row.failures.length) throw new Error(`${request.id}: no passing route receipt`);
    const resultFile = path.join(directory, row.file);
    if (hashFile(resultFile) !== row.sha256) throw new Error(`${request.id}: route receipt changed`);
    if (row.measurement) {
      const timeFile = path.join(directory, row.measurement.file);
      if (hashFile(timeFile) !== row.measurement.sha256) throw new Error(`${request.id}: process measurement changed`);
      const measured = processMeasurements(fs.readFileSync(timeFile, "utf8"));
      for (const key of ["rssBytes", "peakFootprintBytes", "processSeconds"])
        if (row[key] !== measured[key]) throw new Error(`${request.id}: process measurement differs: ${key}`);
    }
    const result = read(resultFile);
    if (audit(result, request, row.rssBytes).failures.length) throw new Error(`${request.id}: route receipt fails audit`);
    if (JSON.stringify((result.packIdentities || []).map(p => p.region).sort()) !== JSON.stringify([...request.regions].sort())) throw new Error(`${request.id}: tested region set differs`);
    for (const identity of result.packIdentities) {
      const manifest = read(path.join(root, "packs", identity.region, "pack-manifest.v2.json"));
      if (identity.graph !== manifest.graph.sha256 || identity.geometry !== manifest.geometry.sha256) throw new Error(`${request.id}: stale tested pack`);
    }
  }
  return summary;
}

function measuredRun(args, env, timeout) {
  return new Promise(resolve => {
    const child = spawn("/usr/bin/time", args, { env, detached: true });
    let stdout = "", stderr = "", error = null;
    const stop = message => {
      error = message;
      try { process.kill(-child.pid, "SIGKILL"); } catch (_) { /* already exited */ }
    };
    const timer = setTimeout(() => stop("wall-clock ceiling"), timeout);
    child.stdout.on("data", data => { stdout += data; if (stdout.length > 128 * 1024 * 1024) stop("receipt too large"); });
    child.stderr.on("data", data => { stderr += data; });
    child.on("error", e => { error = String(e); });
    child.on("close", status => { clearTimeout(timer); resolve({ stdout, stderr, status, error }); });
  });
}

async function main(args = process.argv.slice(2)) {
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!["--root", "--plan", "--probe", "--out"].includes(args[i]) || !args[i + 1]) throw new Error("require --root candidate --plan requests.json --probe executable --out evidence-directory");
    options[args[i].slice(2)] = path.resolve(args[i + 1]);
  }
  if (!["root", "plan", "probe", "out"].every(k => options[k])) throw new Error("missing qualification argument");
  const plan = read(options.plan), releaseFile = path.join(options.root, "release.json");
  const identity = { releaseSHA256: hashFile(releaseFile), planSHA256: hashFile(options.plan), probeSHA256: hashFile(options.probe) };
  fs.mkdirSync(options.out, { recursive: true });
  const summaryFile = path.join(options.out, "qualification.json");
  let summary = fs.existsSync(summaryFile) ? read(summaryFile) : {
    schema: "dirt-route-qualification.v1", ...identity, started: new Date().toISOString(),
    hardware: { platform: os.platform(), architecture: os.arch(), cpus: os.cpus()[0].model, memoryBytes: os.totalmem() }, results: []
  };
  if (Object.keys(identity).some(k => summary[k] !== identity[k])) throw new Error("resume identity changed; use a new evidence directory");
  fs.copyFileSync(options.plan, path.join(options.out, "plan.json"));
  for (let i = 0; i < plan.cases.length; i++) {
    const c = plan.cases[i];
    const existing = summary.results.find(r => r.id === c.id);
    if (existing) {
      if (hashFile(path.join(options.out, existing.file)) !== existing.sha256) throw new Error(`${c.id}: resume receipt changed`);
      continue;
    }
    const stem = String(i).padStart(4, "0"), file = `${stem}.json`;
    const env = { ...process.env, DIRT_WANDER: String(c.wander), DIRT_ALLOW_UNKNOWN: c.allowUnknown ? "1" : "0",
      DIRT_AVOID_FERRIES: c.avoidFerries ? "1" : "0", DIRT_AVOID_HIGHWAYS: c.avoidHighways ? "1" : "0",
      DIRT_NO_CITY_WALL: c.avoidCities ? "0" : "1", DIRT_PROBE_COMPACT: "0" };
    for (const key of ["DIRT_MAX_LABELS", "DIRT_ARRIVAL_EDGE", "DIRT_PRIOR_EDGES", "DIRT_LOOP_METERS", "DIRT_DIRT_PAVEMENT_AWAY"]) delete env[key];
    const run = await measuredRun(["-l", options.probe, path.join(options.root, "packs"), c.regions.join(","),
      ...c.from.map(String), ...c.to.map(String), c.style, String(c.windowSeconds), String(c.seed), "12.5"],
      env, c.maxSeconds * 1000 + 5000);
    const timeFile = path.join(options.out, `${stem}.time`);
    fs.writeFileSync(timeFile, run.stderr || "");
    let result;
    try { result = JSON.parse(run.stdout); } catch { result = { status: "failed", error: String(run.error || run.stderr) }; }
    save(path.join(options.out, file), result);
    const measurements = processMeasurements(run.stderr || "");
    const assessment = audit(result, c, measurements.rssBytes);
    if (run.status !== 0) assessment.failures.push(`process status ${run.status}`);
    summary.results.push({ id: c.id, file, sha256: hashFile(path.join(options.out, file)), ...measurements,
      measurement: { file: `${stem}.time`, sha256: hashFile(timeFile) },
      seconds: result.seconds, repeatMeters: result.reriddenMeters, ...assessment });
    summary.status = "running"; save(summaryFile, summary);
    console.log(`[${i + 1}/${plan.cases.length}] ${c.id}: ${assessment.failures.length ? assessment.failures.join("; ") : "pass"} (${result.seconds?.toFixed(2)}s)`);
  }
  const release = read(releaseFile), topology = readTopologySealMetaSync(path.join(options.root, "cross-pack-topology.v2.json"));
  summary.coverageFailures = validateCoverage(plan, release.regions.map(r => r.id), topology.pairs);
  summary.status = summary.coverageFailures.length || summary.results.some(r => r.failures.length) ? "failed" : "passed";
  summary.finished = new Date().toISOString(); save(summaryFile, summary);
  if (summary.status !== "passed") process.exitCode = 1;
}
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { audit, distance, processMeasurements, validateCoverage, verifyQualification, main };
