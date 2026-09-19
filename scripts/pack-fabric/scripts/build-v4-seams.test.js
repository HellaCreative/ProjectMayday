"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { writeRegionSidecars, selectProofs, parseArgs, uniquePairs } = require("./build-v4-seams");
const { validatePackManifestV2 } = require("../routing/lib/pack-manifest-v2");

test("road connectivity metadata distinguishes bridges from timed ferries with missing leaves", () => {
  const { isRoadConnection } = require("./build-v4-seams");
  const edge = { accessForward: 0, accessReverse: 0, structureLeaf: "bridge", crossingSeconds: 0 };
  assert.equal(isRoadConnection({ edge }), true);
  assert.equal(isRoadConnection({ edge: { ...edge, structureLeaf: "ferry" } }), false);
  assert.equal(isRoadConnection({ edge: { ...edge, structureLeaf: null, crossingSeconds: 3600 } }), false);
  assert.equal(isRoadConnection({ edge: { ...edge, accessForward: 2, accessReverse: 2 } }), false);
});

test("identically labelled shared roads cannot seal with differing length or geometry", () => {
  const { assertSharedRoadGeometry } = require("./build-v4-seams");
  const road = () => ({ manifest: { regionId: "ns" }, pack: {
    edgeCount: 1, osmWayIds: ["10"], osmNodeIds: ["1", "2"], edgeFrom: [0], edgeTo: [1], edgeMeters: [100]
  }, geometry: { polyline: () => [[-63, 45], [-63.001, 45]] } });
  const a = road(), b = road();
  b.manifest.regionId = "nb";
  assert.equal(assertSharedRoadGeometry(a, b), 1);
  b.pack.edgeMeters[0] = 101;
  assert.throws(() => assertSharedRoadGeometry(a, b), /geometry mismatch ns\/nb/);
  b.pack.edgeMeters[0] = 100;
  b.geometry.polyline = () => [[-63, 45], [-63.002, 45]];
  assert.throws(() => assertSharedRoadGeometry(a, b), /geometry mismatch/);
});

function stagedManifest(regionId) {
  return {
    schema: "pack-manifest.v2",
    fabricReleaseId: "fabric-v4-20260907-01",
    regionId,
    capabilities: ["legal-topology.v1"],
    graph: { name: "graph.v4.bin", bytes: 1, sha256: "a".repeat(64) },
    geometry: { name: "geometry.v1.bin", bytes: 1, sha256: "b".repeat(64) },
    fuel: { name: "fuel.v1.json", bytes: 1, sha256: "c".repeat(64) },
    sourceEpoch: "locked-fixture-epoch",
    timezone: "America/Halifax"
  };
}

test("explicit canary includes every connection inside its selected regions", () => {
  const { regions } = parseArgs(["--regions", "ns,nb,pe,nl"]);
  assert.deepEqual(uniquePairs(regions), [["nb", "ns"], ["nb", "pe"], ["nl", "ns"], ["ns", "pe"]]);
  assert.ok(uniquePairs().length > uniquePairs(regions).length);
  assert.throws(() => parseArgs(["--regions", "ns,typo"]));
  assert.throws(() => parseArgs(["--regions", "ns"]));
});

test("seam sealing writes a sidecar and binds its identity into every region manifest", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-v4-seams-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const id of ["ns", "nb"]) {
    fs.mkdirSync(path.join(root, id), { recursive: true });
    fs.writeFileSync(
      path.join(root, id, "pack-manifest.v2.json"),
      JSON.stringify(stagedManifest(id))
    );
  }
  const proof = {
    coordinate: [-64.25, 45.85], gapMeters: 0, osmWayId: "100",
    localEdgeId: "100:1:2", remoteEdgeId: "100:1:2"
  };
  const doc = {
    sourceEpoch: "locked-fixture-epoch",
    regions: {
      ns: { neighbors: { nb: [proof] } },
      nb: { neighbors: { ns: [proof] } }
    }
  };
  writeRegionSidecars(root, doc);
  assert.equal(doc.fabricReleaseId, "fabric-v4-20260907-01");
  for (const id of ["ns", "nb"]) {
    const manifest = JSON.parse(fs.readFileSync(path.join(root, id, "pack-manifest.v2.json")));
    assert.equal(validatePackManifestV2(manifest, { requireSeams: true }), true);
    const sidecar = JSON.parse(fs.readFileSync(path.join(root, id, "cross-pack-seams.v2.json")));
    assert.equal(sidecar.regionId, id);
    assert.equal(sidecar.sourceEpoch, doc.sourceEpoch);
  }
});

function crossing(node, way, lat, accessForward = 0, accessReverse = 0) {
  return {
    osmNodeId: String(node), osmWayId: String(way), coordinate: [-74, lat],
    edge: { osmWayId: String(way), fromOsmNodeId: String(node),
      toOsmNodeId: String(node + 1), accessForward, accessReverse,
      layer: 0, structureLeaf: null }
  };
}

test("topology retains a northern main-network crossing beyond 128 southern proofs", () => {
  const southern = Array.from({ length: 128 }, (_, i) => crossing(i + 1, i + 1, 45));
  const mainNetwork = crossing(900, 900, 46);
  const result = selectProofs([...southern, mainNetwork]);
  assert.equal(result.length, 129);
  assert.ok(result.includes(mainNetwork));
  assert.deepEqual(selectProofs([mainNetwork, ...southern].reverse()), result);
});

test("distinct nodes on one OSM way remain available; duplicate proofs and denied directions do not", () => {
  const a = crossing(1, 10, 45);
  const b = crossing(2, 10, 46);
  const unknown = crossing(3, 11, 47, 1, 2);
  const denied = crossing(4, 12, 48, 2, 2);
  const destinationOnly = crossing(5, 13, 49, 4, 4);
  assert.deepEqual(selectProofs([a, b, { ...a }, unknown, denied, destinationOnly]), [a, b, unknown]);
});


test("topology checkpoint streams past JSON.stringify string limits", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-v4-seams-stream-"));
  const file = path.join(root, "cross-pack-topology.v2.json.partial");
  // ~2k proofs is enough to prove we never build one giant string of the whole doc;
  // the production failure was JSON.stringify(doc) on CA-scale arrays.
  const proof = {
    coordinate: [-119.5, 36.1],
    gapMeters: 0,
    osmNodeId: "1",
    osmWayId: "2",
    localEdgeId: "2:1:3",
    remoteEdgeId: "2:1:3",
    proof: { kind: "shared-node" },
    edge: {
      osmWayId: "2",
      fromOsmNodeId: "1",
      toOsmNodeId: "3",
      accessForward: 0,
      accessReverse: 0,
      layer: 0,
      structureLeaf: null
    },
    barrierDecision: "open",
    restrictions: []
  };
  const rows = Array.from({ length: 2500 }, (_, i) => ({
    ...proof,
    osmNodeId: String(i + 1),
    coordinate: [-119.5, 36 + (i % 1000) / 1000]
  }));
  const doc = {
    schemaVersion: "dirt-cross-pack-topology.v2",
    generatedAt: "2026-09-18T08:00:00.000Z",
    sourceEpoch: "locked-fixture-epoch",
    regions: {
      "ca-n": { neighbors: { "ca-s": rows } },
      "ca-s": { neighbors: { "ca-n": rows } }
    },
    pairs: [{ left: "ca-n", right: "ca-s", proofs: rows.length }]
  };
  const { writeTopologyDocument, writeCheckpoint } = require("./build-v4-seams");
  writeCheckpoint(path.join(root, "cross-pack-topology.v2.json"), doc);
  assert.equal(fs.existsSync(file), true);
  const roundTrip = JSON.parse(fs.readFileSync(file, "utf8"));
  assert.equal(roundTrip.pairs[0].proofs, 2500);
  assert.equal(roundTrip.regions["ca-n"].neighbors["ca-s"].length, 2500);
  assert.equal(roundTrip.regions["ca-s"].neighbors["ca-n"].length, 2500);
  writeTopologyDocument(path.join(root, "cross-pack-topology.v2.json"), doc);
  const finalDoc = JSON.parse(fs.readFileSync(path.join(root, "cross-pack-topology.v2.json"), "utf8"));
  assert.equal(finalDoc.regions["ca-n"].neighbors["ca-s"].length, 2500);
  fs.rmSync(root, { recursive: true, force: true });
});

test("national coverage permits declared isolated packs but not missing required neighbors", () => {
  const {assertNeighborCoverage, uniquePairs} = require("./build-v4-seams");
  const {REGION_NEIGHBOURS} = require("../routing/regional/merge");
  const ids=Object.keys(REGION_NEIGHBOURS).filter(id=>id.length===2);
  assert.doesNotThrow(()=>assertNeighborCoverage(ids,uniquePairs()));
  assert.doesNotThrow(()=>assertNeighborCoverage(["hi","nu"],[]));
  assert.throws(()=>assertNeighborCoverage(["ns","qc"],[]),/must have a neighbor/);
  assert.throws(()=>assertNeighborCoverage(["zz"],[]),/unknown region/);
});
