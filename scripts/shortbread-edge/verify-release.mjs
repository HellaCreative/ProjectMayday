import assert from "node:assert/strict";

const baseURL = (
  process.argv[2] ?? "https://dirt-shortbread-tiles.dirt-shortbread-edge.workers.dev"
).replace(/\/$/, "");

async function fetchOK(url, label, options = {}) {
  const response = await fetch(url, options);
  assert.equal(response.status, 200, `${label} returned HTTP ${response.status}`);
  return response;
}

const manifestResponse = await fetchOK(
  `${baseURL}/shortbread/v1/manifest.json`,
  "manifest",
  { headers: { Accept: "application/json" } },
);
const manifest = await manifestResponse.json();
assert.equal(manifest.contract, "dirt.shortbread-manifest.v1");
assert.equal(manifest.cacheNamespace, "shortbread-v1");
assert.match(manifest.shortbreadSchema, /^1(?:\.|$)/);
assert.equal(manifest.maxZoom, 14);
assert.match(manifest.attribution, /OpenStreetMap/i);
assert.ok(manifest.tileTemplate.includes("{z}/{x}/{y}.mvt"));

const healthResponse = await fetchOK(
  `${baseURL}/shortbread/v1/health`,
  "health",
);
const health = await healthResponse.json();
assert.equal(health.ok, true);
assert.equal(health.releaseID, manifest.releaseID);
assert.ok(health.archiveBytes > 0);
assert.ok(health.sampleBytes > 0);

const sampleResponse = await fetchOK(manifest.sampleTile, "R2 sample tile", {
  headers: { Accept: "application/vnd.mapbox-vector-tile" },
});
assert.match(sampleResponse.headers.get("content-type") ?? "", /mapbox-vector-tile/i);
assert.equal(sampleResponse.headers.get("access-control-allow-origin"), "*");
assert.equal(sampleResponse.headers.get("x-dirt-shortbread-release"), manifest.releaseID);
assert.equal(sampleResponse.headers.get("x-dirt-shortbread-source"), "r2");
assert.match(sampleResponse.headers.get("cache-control") ?? "", /immutable/i);
assert.ok((await sampleResponse.arrayBuffer()).byteLength > 0);

const fallbackURL = manifest.tileTemplate
  .replace("{z}", "10")
  .replace("{x}", "162")
  .replace("{y}", "351");
const fallbackResponse = await fetchOK(fallbackURL, "outside-archive fallback tile");
assert.equal(fallbackResponse.headers.get("x-dirt-shortbread-source"), "public-fallback");
assert.ok((await fallbackResponse.arrayBuffer()).byteLength > 0);

console.log(
  `verified ${manifest.releaseID}: manifest, R2 tile, immutable cache, attribution, CORS, and public fallback`,
);
