"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  BARE_PACK_REJECTION,
  assertPublicationCommand,
  assertSourceMatchesRelease,
  liveDeployArgs,
  mergePromotedRegionsIntoCatalog,
  parseArgs,
  parseRemoteCatalogJson,
  planStablePublication,
  publishStablePack
} = require("./ship-routing");

const NS_02_FILES = [
  {
    name: "graph.v2.bin",
    bytes: 13562309,
    sha256: "a9c5cb27eba2dc298344d9c80298881e1e0cfc0d40435d17cd9c4e210d1bef51"
  },
  {
    name: "geometry.v1.bin",
    bytes: 23395024,
    sha256: "01e2741006ae4ee2e4324e2254ca21d6e5ced7cdc2f3c16d0c07688cc09decc6"
  },
  {
    name: "fuel.v1.json",
    bytes: 143384,
    sha256: "999e1cbd5901b2bb28f7c09d7578abe2e7c69ad3e68c25b0b776c0172305fdd2"
  }
];

const NS_20_FILES = [
  {
    name: "graph.v2.bin",
    bytes: 13535078,
    sha256: "20d1c4b79fbbc63ca164ffe683c3e057813c3ddad9f8b3a33d6b4a479c3bf555"
  },
  {
    name: "geometry.v1.bin",
    bytes: 23394912,
    sha256: "41659ed9374ea0f399bfff285a41dd3a5e3f5a9153dcae97fd1146dbffd66a63"
  },
  {
    name: "fuel.v1.json",
    bytes: 143384,
    sha256: "fab91d4030cb3098a9ff2c846abde1444f2496c25fc24ec12bc3a2f1dc866b3f"
  }
];

function remoteCatalog() {
  return {
    schemaVersion: "pack-manifest.v1",
    packFormat: "graph.v2",
    geometryFormat: "geometry.v1",
    version: "v1",
    generatedAt: "2026-08-21T14:26:33.708Z",
    basePath: "/app/data/packs/v1",
    marker: "keep-top-level",
    regions: [
      {
        id: "ab",
        keep: "ab-extra",
        files: [
          { name: "graph.v2.bin", bytes: 1, sha256: "ab-graph" },
          { name: "geometry.v1.bin", bytes: 2, sha256: "ab-geom" }
        ]
      },
      {
        id: "nb",
        keep: "nb-extra",
        files: [
          { name: "graph.v2.bin", bytes: 3, sha256: "nb-graph" },
          { name: "geometry.v1.bin", bytes: 4, sha256: "nb-geom" },
          { name: "fuel.v1.json", bytes: 5, sha256: "nb-fuel" }
        ]
      },
      {
        id: "ns",
        keep: "ns-extra",
        files: NS_20_FILES.map((file) => ({ ...file }))
      },
      {
        id: "pe",
        keep: "pe-extra",
        files: [
          { name: "graph.v2.bin", bytes: 6, sha256: "pe-graph" },
          { name: "geometry.v1.bin", bytes: 7, sha256: "pe-geom" }
        ]
      }
    ]
  };
}

function releaseRecord() {
  return {
    schemaVersion: "dirt-pack-release.v1",
    releaseId: "ns-osm-20260821-02",
    status: "live-candidate",
    regions: [{ id: "ns", files: NS_02_FILES.map((file) => ({ ...file })) }]
  };
}

test("promoting NS preserves all unrelated remote regions at JSON-field level", () => {
  const remote = remoteCatalog();
  const nbBefore = JSON.stringify(remote.regions[1]);
  const peBefore = JSON.stringify(remote.regions[3]);
  const abBefore = JSON.stringify(remote.regions[0]);
  const merged = mergePromotedRegionsIntoCatalog(remote, releaseRecord().regions, {
    generatedAt: "2026-08-22T23:20:12.000Z"
  });
  assert.equal(merged.regions.length, 4);
  assert.equal(merged.regions[1], remote.regions[1]);
  assert.equal(merged.regions[3], remote.regions[3]);
  assert.equal(merged.regions[0], remote.regions[0]);
  assert.equal(JSON.stringify(merged.regions[1]), nbBefore);
  assert.equal(JSON.stringify(merged.regions[3]), peBefore);
  assert.equal(JSON.stringify(merged.regions[0]), abBefore);
  assert.equal(merged.schemaVersion, "pack-manifest.v1");
  assert.equal(merged.marker, "keep-top-level");
  assert.equal(merged.version, "v1");
});

test("promoting NS writes exact release-record graph, geometry, and fuel metadata", () => {
  const remote = remoteCatalog();
  const merged = mergePromotedRegionsIntoCatalog(remote, releaseRecord().regions, {
    generatedAt: "2026-08-22T23:20:12.000Z"
  });
  const ns = merged.regions.find((region) => region.id === "ns");
  assert.equal(ns.keep, "ns-extra");
  assert.deepEqual(ns.files, NS_02_FILES);
  assert.notDeepEqual(ns.files, NS_20_FILES);
  assert.equal(merged.generatedAt, "2026-08-22T23:20:12.000Z");
});

test("checksum mismatch aborts before any upload", () => {
  const puts = [];
  assert.throws(
    () =>
      publishStablePack({
        remoteCatalogText: JSON.stringify(remoteCatalog()),
        releaseRecord: releaseRecord(),
        regionIds: ["ns"],
        sourceRegions: [{ id: "ns", files: NS_20_FILES }],
        putObject: (item) => puts.push(item)
      }),
    /ns-osm-20260821-02\/ns\/graph\.v2\.bin no longer matches the tested candidate/
  );
  assert.deepEqual(puts, []);
});

test("bare --pack publication is rejected without reinterpretation", () => {
  const opts = parseArgs(["--pack", "ns"]);
  assert.equal(opts.pack, true);
  assert.equal(opts.promote, null);
  assert.equal(opts.candidate, null);
  assert.deepEqual(opts.ids, ["ns"]);
  assert.throws(() => assertPublicationCommand(opts), new RegExp(BARE_PACK_REJECTION.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.throws(() => assertPublicationCommand(parseArgs(["--pack", "bc"])), /bare --pack is rejected/);
  assert.doesNotThrow(() =>
    assertPublicationCommand(parseArgs(["--promote", "ns-osm-20260821-02", "--pack", "ns"]))
  );
  assert.doesNotThrow(() =>
    assertPublicationCommand(parseArgs(["--candidate", "ns-osm-20260821-02", "--pack", "ns"]))
  );
});

test("malformed or unavailable remote catalog aborts safely", () => {
  assert.throws(() => parseRemoteCatalogJson(null), /remote catalog unavailable/);
  assert.throws(() => parseRemoteCatalogJson(""), /remote catalog unavailable/);
  assert.throws(() => parseRemoteCatalogJson("   "), /remote catalog unavailable/);
  assert.throws(() => parseRemoteCatalogJson("not-json"), /malformed remote catalog/);
  assert.throws(() => parseRemoteCatalogJson("[]"), /remote catalog is missing or not an object/);
  assert.throws(() => parseRemoteCatalogJson("{}"), /remote catalog has no regions array/);
  assert.throws(() => parseRemoteCatalogJson('{"regions":null}'), /remote catalog has no regions array/);
  assert.throws(
    () =>
      planStablePublication({
        remoteCatalogText: null,
        releaseRecord: releaseRecord(),
        regionIds: ["ns"],
        sourceRegions: [{ id: "ns", files: NS_02_FILES }]
      }),
    /remote catalog unavailable/
  );
});

test("matching local bytes plan a catalog merge without touching unrelated regions", () => {
  const remote = remoteCatalog();
  const planned = planStablePublication({
    remoteCatalogText: JSON.stringify(remote),
    releaseRecord: releaseRecord(),
    regionIds: ["ns"],
    sourceRegions: [{ id: "ns", files: NS_02_FILES }],
    generatedAt: "2026-08-22T23:20:12.000Z"
  });
  assert.deepEqual(planned.promoted[0].files, NS_02_FILES);
  const puts = [];
  publishStablePack({
    remoteCatalogText: JSON.stringify(remote),
    releaseRecord: releaseRecord(),
    regionIds: ["ns"],
    sourceRegions: [{ id: "ns", files: NS_02_FILES }],
    generatedAt: "2026-08-22T23:20:12.000Z",
    putObject: (item) => puts.push(item)
  });
  assert.equal(puts.filter((item) => item.kind === "pack").length, 3);
  assert.equal(puts[0].regionId, "ns");
  assert.equal(puts[0].fileName, "graph.v2.bin");
  assert.equal(puts[0].sha256, NS_02_FILES[0].sha256);
  const manifest = puts.find((item) => item.kind === "manifest");
  assert.ok(manifest);
  assert.deepEqual(
    manifest.catalog.regions.find((region) => region.id === "ns").files,
    NS_02_FILES
  );
  assert.deepEqual(
    manifest.catalog.regions.find((region) => region.id === "nb"),
    remote.regions[1]
  );
});

test("assertSourceMatchesRelease fails closed on size or hash drift", () => {
  assert.doesNotThrow(() => assertSourceMatchesRelease(NS_02_FILES, NS_02_FILES, "ns-osm-20260821-02/ns"));
  assert.throws(
    () => assertSourceMatchesRelease(NS_20_FILES, NS_02_FILES, "ns-osm-20260821-02/ns"),
    /no longer matches the tested candidate/
  );
});

test("live deployment carries the exact committed source identity", () => {
  assert.deepEqual(liveDeployArgs(null, "dc22053"), [
    "vercel", "--prod", "--yes", "--env", "SOURCE_VERSION=dc22053"
  ]);
  assert.throws(() => liveDeployArgs(null, "local-uncommitted"), /committed Git source identity/);
});
