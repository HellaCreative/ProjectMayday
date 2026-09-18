#!/usr/bin/env node
"use strict";

/**
 * Thin per-region cross-pack-seams.v2.json sidecars for subregion pairs.
 *
 * Full topology (tens of thousands of proofs) is retained in
 * cross-pack-topology.v2.json. Phone/runtime sidecars only need a diversified
 * handover shortlist — Swift JSONDecoder on a 36MB seam file can exhaust the
 * route wall clock before search starts.
 *
 * National topology can exceed Node's ~512MB string limit (same class of bug as
 * streaming checkpoints in build-v4-seams). Prefer pack sidecars written by the
 * seams run; they already hold the pair rows and stay under the string limit.
 *
 * Usage:
 *   node scripts/pack-fabric/scripts/thin-subregion-seams.js \
 *     --topology scripts/pack-fabric/routing/candidates/fabric-v4-YYYYMMDD-NN/cross-pack-topology.v2.json \
 *     --root scripts/pack-fabric/routing/candidates/fabric-v4-YYYYMMDD-NN/packs \
 *     --pair on-s,on-n \
 *     [--max 600]
 */

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

function parseArgs(argv) {
  const opts = { topology: null, root: null, pair: null, max: 600 };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--topology") opts.topology = path.resolve(argv[++i]);
    else if (a === "--root") opts.root = path.resolve(argv[++i]);
    else if (a === "--pair") opts.pair = argv[++i];
    else if (a === "--max") opts.max = Number(argv[++i]);
    else throw new Error(`unknown argument ${a}`);
  }
  if (!opts.topology || !opts.root || !opts.pair) {
    throw new Error("Usage: thin-subregion-seams.js --topology <file> --root <packs> --pair on-s,on-n [--max 600]");
  }
  const parts = opts.pair.split(",").map((s) => s.trim()).filter(Boolean);
  if (parts.length !== 2) throw new Error("--pair needs exactly two region ids");
  if (!Number.isFinite(opts.max) || opts.max < 50) throw new Error("--max must be >= 50");
  opts.left = parts[0];
  opts.right = parts[1];
  return opts;
}

function usable(rows) {
  const filtered = rows.filter((r) => {
    const e = r.edge || {};
    return e.accessForward === 0 || e.accessForward === 1 || e.accessReverse === 0 || e.accessReverse === 1;
  });
  return filtered.length ? filtered : rows;
}

function shortlist(rows, maxKeep) {
  const pool = usable(rows);
  const grid = new Map();
  for (const row of pool) {
    const [lon, lat] = row.coordinate;
    if (lat >= 45.6 && lat <= 46.4) {
      const key = `${(Math.round(lon * 40) / 40).toFixed(3)}|${(Math.round(lat * 40) / 40).toFixed(3)}`;
      if (!grid.has(key)) grid.set(key, row);
    }
  }
  for (const row of pool) {
    const [lon, lat] = row.coordinate;
    const key = `${(Math.round(lon * 10) / 10).toFixed(1)}|${(Math.round(lat * 10) / 10).toFixed(1)}`;
    if (!grid.has(key)) grid.set(key, row);
  }
  let picked = [...grid.values()];
  if (picked.length > maxKeep) {
    picked.sort((a, b) => a.coordinate[1] - b.coordinate[1] || a.coordinate[0] - b.coordinate[0]);
    const step = picked.length / maxKeep;
    picked = Array.from({ length: maxKeep }, (_, i) => picked[Math.floor(i * step)]);
  }
  return picked;
}

function readJSONFile(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function loadPairFromSidecars(root, left, right) {
  const leftPath = path.join(root, left, "cross-pack-seams.v2.json");
  const rightPath = path.join(root, right, "cross-pack-seams.v2.json");
  if (!fs.existsSync(leftPath) || !fs.existsSync(rightPath)) return null;
  const leftDoc = readJSONFile(leftPath);
  const rightDoc = readJSONFile(rightPath);
  const leftRows = leftDoc.neighbors?.[right];
  const rightRows = rightDoc.neighbors?.[left];
  if (!Array.isArray(leftRows) || !Array.isArray(rightRows)) return null;
  return {
    leftRows,
    rightRows,
    leftDoc,
    rightDoc,
    meta: {
      fabricReleaseId: leftDoc.fabricReleaseId || rightDoc.fabricReleaseId || null,
      sourceEpoch: leftDoc.sourceEpoch || rightDoc.sourceEpoch || null
    }
  };
}

function loadPairFromTopology(topologyPath, left, right) {
  let topology;
  try {
    topology = readJSONFile(topologyPath);
  } catch (err) {
    if (err && (err.code === "ERR_STRING_TOO_LONG" || /string longer than/i.test(String(err.message)))) {
      throw new Error(
        `topology ${topologyPath} exceeds Node string limits; pack sidecars required for thinning`
      );
    }
    throw err;
  }
  const leftRows = topology.regions?.[left]?.neighbors?.[right];
  const rightRows = topology.regions?.[right]?.neighbors?.[left];
  if (!Array.isArray(leftRows) || !Array.isArray(rightRows)) {
    throw new Error(`topology missing pair ${left}/${right}`);
  }
  return {
    leftRows,
    rightRows,
    leftDoc: null,
    rightDoc: null,
    meta: {
      fabricReleaseId: topology.fabricReleaseId || null,
      sourceEpoch: topology.sourceEpoch || null
    }
  };
}

function loadPair(opts) {
  const fromSidecars = loadPairFromSidecars(opts.root, opts.left, opts.right);
  if (fromSidecars) return { ...fromSidecars, source: "sidecars" };
  return { ...loadPairFromTopology(opts.topology, opts.left, opts.right), source: "topology" };
}

function writeSidecar(root, meta, existingDoc, regionId, neighborId, rows) {
  const seamPath = path.join(root, regionId, "cross-pack-seams.v2.json");
  const existing = existingDoc || (fs.existsSync(seamPath) ? readJSONFile(seamPath) : null);
  const neighbors = {
    ...((existing && existing.neighbors) || {}),
    [neighborId]: rows
  };
  const doc = {
    schemaVersion: "dirt-cross-pack-seams.v2",
    fabricReleaseId: (existing && existing.fabricReleaseId) || meta.fabricReleaseId,
    sourceEpoch: (existing && existing.sourceEpoch) || meta.sourceEpoch,
    regionId,
    neighbors
  };
  const raw = `${JSON.stringify(doc, null, 2)}\n`;
  fs.writeFileSync(seamPath, raw);
  const sha256 = crypto.createHash("sha256").update(raw).digest("hex");
  const manifestPath = path.join(root, regionId, "pack-manifest.v2.json");
  const manifest = readJSONFile(manifestPath);
  manifest.seams = {
    name: "cross-pack-seams.v2.json",
    bytes: Buffer.byteLength(raw),
    sha256
  };
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return { regionId, proofs: rows.length, bytes: Buffer.byteLength(raw), sha256 };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(opts.topology)) {
    throw new Error(`topology missing: ${opts.topology}`);
  }
  const loaded = loadPair(opts);
  const left = writeSidecar(
    opts.root,
    loaded.meta,
    loaded.leftDoc,
    opts.left,
    opts.right,
    shortlist(loaded.leftRows, opts.max)
  );
  const right = writeSidecar(
    opts.root,
    loaded.meta,
    loaded.rightDoc,
    opts.right,
    opts.left,
    shortlist(loaded.rightRows, opts.max)
  );
  console.log(JSON.stringify({ pair: [opts.left, opts.right], source: loaded.source, left, right }, null, 2));
}

if (require.main === module) main();

module.exports = { shortlist, parseArgs, loadPairFromSidecars, loadPairFromTopology, loadPair };
