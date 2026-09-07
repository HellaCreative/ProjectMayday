"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { writeRegionSidecars } = require("./build-v4-seams");
const { validatePackManifestV2 } = require("../routing/lib/pack-manifest-v2");

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
