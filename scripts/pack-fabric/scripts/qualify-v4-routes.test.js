"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs"), os = require("node:os"), path = require("node:path");
const { audit, validateCoverage, verifyQualification } = require("./qualify-v4-routes");
const { hashFile } = require("./prepare-common-source-lock");
const request = { id: "a", regions: ["ns"], from: [-63, 45], to: [-63, 45.001],
  style: "dirt", wander: .5, seed: 1, allowUnknown: false, avoidFerries: true,
  avoidHighways: true, avoidCities: true, maxSeconds: 60, windowSeconds: 20,
  maxRSSBytes: 1e9, maxRepeatMeters: 100 };
function result(c = request) { return { status: "complete", style: c.style, wander: c.wander,
  seed: c.seed, allowUnknown: c.allowUnknown, avoidFerries: c.avoidFerries,
  avoidHighways: c.avoidHighways, avoidCities: c.avoidCities, seconds: 1,
  requestedStart: c.from, requestedEnd: c.to, distanceMeters: 112,
  matchedStart: c.from, matchedEnd: c.to, reriddenMeters: 0,
  packIdentities: [{ region: "ns", graph: "graph-hash", geometry: "geometry-hash" }],
  segments: [{ edgeID: "1:2:3", access: 0, meters: 112, geometry: [c.from, c.to], structure: "" }] }; }
test("native receipt audit rejects legality, continuity, settings and resource failures", () => {
  assert.deepEqual(audit(result(), request, 1e6).failures, []);
  for (const access of [2, 5]) {
    const r = result(); r.segments[0].access = access;
    assert.ok(audit(r, request, 1e6).failures.includes("prohibited/closed road"));
  }
  const r = result(); r.segments[0].access = 1;
  assert.ok(audit(r, request, 1e6).failures.includes("unknown connector too long"));
  r.segments[0].access = 0; r.segments[0].structure = "ferry";
  assert.ok(audit(r, request, 1e6).failures.includes("ferry despite avoidance"));
  r.segments.push({ ...r.segments[0], geometry: [[-65, 45], request.to] });
  assert.ok(audit(r, request, 1e6).failures.some(f => f.startsWith("discontinuous")));
  assert.ok(audit({ ...result(), wander: 1, seconds: 61, reriddenMeters: 1000 }, request, 2e9).failures.length === 4);
  assert.ok(audit({ status: "failed", error: "time" }, request, 0).failures.length > 0);
});
test("coverage requires internal rides in every style and both crossing directions", () => {
  const cases = ["ns", "nb"].flatMap(id => ["dirt", "balanced", "cleanest"].map(style => ({ ...request, id: id+style, regions: [id], style })));
  const pairs = [{ left: "ns", right: "nb" }];
  assert.equal(validateCoverage({ cases }, ["ns", "nb"], pairs).length, 6);
  for (const crossing of [["ns", "nb"], ["nb", "ns"]]) for (const style of ["dirt", "balanced", "cleanest"]) {
    cases.push({ ...request, id: crossing.join("-")+style, style, regions: crossing, crossing });
  }
  assert.deepEqual(validateCoverage({ cases }, ["ns", "nb"], pairs), []);
  cases.push(cases[0]);
  assert.ok(validateCoverage({ cases }, ["ns", "nb"], pairs).includes("missing/duplicate request ID"));
});
test("publication rejects stale, missing and tampered route evidence", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-qualification-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const out = path.join(root, "qualification"); fs.mkdirSync(out);
  fs.mkdirSync(path.join(root, "packs", "ns"), { recursive: true });
  const save = (file, doc) => fs.writeFileSync(file, JSON.stringify(doc, null, 2));
  save(path.join(root, "release.json"), { regions: [{ id: "ns" }] });
  save(path.join(root, "cross-pack-topology.v2.json"), { schemaVersion: 2, regions: { ns: {} }, pairs: [] });
  save(path.join(root, "packs/ns/pack-manifest.v2.json"), { graph: { sha256: "graph-hash" }, geometry: { sha256: "geometry-hash" } });
  const cases = ["dirt", "balanced", "cleanest"].map(style => ({ ...request, style, id: style }));
  save(path.join(out, "plan.json"), { cases });
  const summary = { schema: "dirt-route-qualification.v1", releaseSHA256: hashFile(path.join(root, "release.json")),
    planSHA256: hashFile(path.join(out, "plan.json")), probeSHA256: "binary-hash", hardware: "test", status: "passed",
    results: cases.map(c => {
      const file = c.id+".json"; save(path.join(out, file), result(c));
      return { id: c.id, file, sha256: hashFile(path.join(out, file)), rssBytes: 1e6, failures: [] };
    }) };
  assert.throws(() => verifyQualification(root, out));
  save(path.join(out, "qualification.json"), summary);
  assert.equal(verifyQualification(root, out).status, "passed");
  fs.appendFileSync(path.join(out, "dirt.json"), " ");
  assert.throws(() => verifyQualification(root, out), /receipt changed/);
  save(path.join(out, "dirt.json"), result(cases[0]));
  summary.releaseSHA256 = "old"; save(path.join(out, "qualification.json"), summary);
  assert.throws(() => verifyQualification(root, out), /different pack bytes/);
});
