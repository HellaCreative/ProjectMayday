const test = require("node:test");
const assert = require("node:assert/strict");

const OfflineTiles = require("../lib/offline-tiles.js");

function key(z, x, y) {
  return `${z}/${x}/${y}`;
}

test("covers route overview through Shortbread native road detail", () => {
  const coords = [
    [-63.58, 44.65],
    [-63.2, 44.85],
    [-62.75, 45.05]
  ];
  const result = OfflineTiles.collectRouteTiles(coords, {
    viewport: { width: 390, height: 844 },
    maxNativeZoom: 14,
    maxTiles: 1200
  });

  assert.ok(result.fitZoom < 12, "Nova Scotia route should include overview zooms");
  assert.equal(result.minZoom, result.fitZoom);
  assert.equal(result.maxZoom, 14);
  assert.ok(result.tiles.some((tile) => tile.z === result.fitZoom));
  assert.ok(result.tiles.some((tile) => tile.z === 14));
  assert.ok(result.tiles.every((tile) => tile.z >= result.fitZoom && tile.z <= 14));
});

test("retains route endpoints at every zoom while respecting the phone-safe cap", () => {
  const coords = [
    [-66.2, 43.5],
    [-63.6, 45.0],
    [-60.0, 46.8]
  ];
  const result = OfflineTiles.collectRouteTiles(coords, {
    viewport: { width: 390, height: 844 },
    maxNativeZoom: 14,
    maxTiles: 240
  });

  assert.ok(result.tiles.length <= 240);
  for (let z = result.fitZoom; z <= 14; z += 1) {
    const first = OfflineTiles.coordToTile(coords[0], z);
    const last = OfflineTiles.coordToTile(coords[coords.length - 1], z);
    const keys = new Set(result.tiles.filter((tile) => tile.z === z).map((tile) => key(tile.z, tile.x, tile.y)));
    assert.ok(keys.has(key(z, first.x, first.y)), `missing first route tile at z${z}`);
    assert.ok(keys.has(key(z, last.x, last.y)), `missing last route tile at z${z}`);
  }
});

test("includes every road-level route tile for a typical NS day ride", () => {
  const coords = [
    [-63.58, 44.65],
    [-63.35, 44.78],
    [-63.1, 44.92]
  ];
  const result = OfflineTiles.collectRouteTiles(coords, {
    viewport: { width: 390, height: 844 },
    maxNativeZoom: 14,
    maxTiles: 1200
  });
  const expected = OfflineTiles.traceRouteTileKeys(coords, 14);
  const actual = new Set(result.tiles.filter((tile) => tile.z === 14).map((tile) => key(tile.z, tile.x, tile.y)));

  for (const routeKey of expected) assert.ok(actual.has(routeKey), `missing ${routeKey}`);
  assert.equal(result.truncated, false);
});
