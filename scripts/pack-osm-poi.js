#!/usr/bin/env node
/**
 * Rider Services — pack OpenStreetMap POIs into small grid-chunked JSON.
 *
 * Reads a GeoJSON sequence (RS-delimited, from `osmium export -f geojsonseq`)
 * of pre-filtered POI features and emits normalized, gzip-compressed chunks
 * plus a manifest. The browser fetches only the chunks that intersect the
 * current viewport / route corridor — never the whole province at once.
 *
 * Categories (OSM tags):
 *   fuel       — amenity=fuel
 *   lodging    — tourism=hotel|motel|hostel|guest_house|chalet
 *   campground — tourism=camp_site|caravan_site
 *   liquor     — shop=alcohol  (ONLY; no bars/pubs/breweries/wineries)
 *
 * Normalized POI shape (matches app expectation):
 *   { id, category, subtype, name, lat, lon, address, brand,
 *     openingHours, phone, website,
 *     source: "openstreetmap", sourceId, sourceUpdatedAt }
 *
 * Usage:
 *   node scripts/pack-osm-poi.js <input.geojsonseq> [outDir] [sourceUrl]
 *
 * Env:
 *   POI_CHUNK_DEG   grid chunk size in degrees (default 0.5)
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const inputPath = process.argv[2];
const outDir = process.argv[3] || path.join(__dirname, "..", "app", "data", "poi");
const sourceUrl =
  process.argv[4] ||
  "https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf";
const CHUNK_DEG = Number(process.env.POI_CHUNK_DEG || 0.5);
const CHUNK_DIR = "chunks";
const REGION_LABEL = process.env.POI_REGION_LABEL || "Nova Scotia";
const SOURCES_FILE = process.env.POI_SOURCES_FILE || "";

if (!inputPath) {
  console.error("Usage: node scripts/pack-osm-poi.js <input.geojsonseq> [outDir] [sourceUrl]");
  process.exit(1);
}

const LODGING = new Set(["hotel", "motel", "hostel", "guest_house", "chalet"]);
const CAMPGROUND = new Set(["camp_site", "caravan_site"]);

function categorize(p) {
  if (p.amenity === "fuel") return { category: "fuel", subtype: "fuel" };
  // Liquor is shop=alcohol ONLY. Bars, pubs, restaurants, breweries, wineries
  // and generic beverage shops are intentionally excluded.
  if (p.shop === "alcohol") return { category: "liquor", subtype: "alcohol" };
  const t = p.tourism;
  if (LODGING.has(t)) return { category: "lodging", subtype: t };
  if (CAMPGROUND.has(t)) return { category: "campground", subtype: t };
  return null;
}

function representativePoint(geom) {
  if (!geom) return null;
  if (geom.type === "Point") return geom.coordinates;
  if (geom.type === "LineString") return averageCoords(geom.coordinates);
  if (geom.type === "Polygon") return averageCoords(geom.coordinates[0] || []);
  if (geom.type === "MultiPolygon") {
    let best = null;
    let bestLen = -1;
    for (const poly of geom.coordinates) {
      const ring = poly[0] || [];
      if (ring.length > bestLen) {
        bestLen = ring.length;
        best = ring;
      }
    }
    return averageCoords(best || []);
  }
  if (geom.type === "MultiLineString") {
    return averageCoords(geom.coordinates.flat());
  }
  return null;
}

function averageCoords(coords) {
  if (!coords.length) return null;
  let sx = 0;
  let sy = 0;
  let n = 0;
  for (const c of coords) {
    if (!Array.isArray(c) || !Number.isFinite(c[0]) || !Number.isFinite(c[1])) continue;
    sx += c[0];
    sy += c[1];
    n++;
  }
  if (!n) return null;
  return [sx / n, sy / n];
}

function round6(v) {
  return Math.round(v * 1e6) / 1e6;
}

function composeAddress(p) {
  const line1 = [p["addr:housenumber"], p["addr:street"]].filter(Boolean).join(" ");
  const parts = [line1, p["addr:city"], p["addr:province"] || p["addr:state"], p["addr:postcode"]]
    .map((s) => (s || "").trim())
    .filter(Boolean);
  return parts.length ? parts.join(", ") : null;
}

function clean(v) {
  if (v == null) return null;
  const s = String(v).trim();
  return s ? s : null;
}

function readSeq(text) {
  // geojsonseq records are separated by RS (0x1E) and/or newlines.
  return text
    .split(/\x1e/)
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      try {
        return JSON.parse(s);
      } catch (_) {
        return null;
      }
    })
    .filter(Boolean);
}

const raw = fs.readFileSync(inputPath, "utf8");
const features = readSeq(raw);

const chunks = new Map(); // key -> { id, bbox, pois:[] }
const counts = { fuel: 0, lodging: 0, campground: 0, liquor: 0 };
let kept = 0;
let skipped = 0;

for (const f of features) {
  const p = f.properties || {};
  const cat = categorize(p);
  if (!cat) {
    skipped++;
    continue;
  }
  const pt = representativePoint(f.geometry);
  if (!pt) {
    skipped++;
    continue;
  }
  const lon = round6(pt[0]);
  const lat = round6(pt[1]);
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
    skipped++;
    continue;
  }

  const rawId = String(f.id || p["@id"] || "");
  const numericId = rawId.replace(/^[nwr]/, "");
  const ts = p["@timestamp"];
  const sourceUpdatedAt = Number.isFinite(ts)
    ? new Date(ts * 1000).toISOString()
    : clean(p["@timestamp"]);

  const poi = {
    id: "osm:" + (rawId || cat.category + ":" + numericId),
    category: cat.category,
    subtype: cat.subtype,
    name: clean(p.name) || clean(p.brand) || clean(p.operator),
    lat,
    lon,
    address: composeAddress(p),
    brand: clean(p.brand) || clean(p.operator),
    openingHours: clean(p.opening_hours),
    phone: clean(p.phone) || clean(p["contact:phone"]),
    website: clean(p.website) || clean(p["contact:website"]),
    source: "openstreetmap",
    sourceId: numericId || rawId,
    sourceUpdatedAt: sourceUpdatedAt || null
  };

  const cx = Math.floor(lon / CHUNK_DEG);
  const cy = Math.floor(lat / CHUNK_DEG);
  const key = cx + "_" + cy;
  let chunk = chunks.get(key);
  if (!chunk) {
    chunk = {
      id: key,
      cx,
      cy,
      bbox: [cx * CHUNK_DEG, cy * CHUNK_DEG, (cx + 1) * CHUNK_DEG, (cy + 1) * CHUNK_DEG],
      pois: []
    };
    chunks.set(key, chunk);
  }
  chunk.pois.push(poi);
  counts[cat.category]++;
  kept++;
}

const chunkDir = path.join(outDir, CHUNK_DIR);
fs.rmSync(chunkDir, { recursive: true, force: true });
fs.mkdirSync(chunkDir, { recursive: true });

const manifestChunks = [];
let totalGz = 0;
for (const chunk of [...chunks.values()].sort((a, b) => a.id.localeCompare(b.id))) {
  // Tighten the bbox to the actual POIs so viewport intersection is precise.
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const poi of chunk.pois) {
    if (poi.lon < minX) minX = poi.lon;
    if (poi.lat < minY) minY = poi.lat;
    if (poi.lon > maxX) maxX = poi.lon;
    if (poi.lat > maxY) maxY = poi.lat;
  }
  const bbox = [round6(minX), round6(minY), round6(maxX), round6(maxY)];
  const file = chunk.id + ".json.gz";
  const payload = JSON.stringify({ id: chunk.id, bbox, pois: chunk.pois });
  const gz = zlib.gzipSync(Buffer.from(payload), { level: 9 });
  fs.writeFileSync(path.join(chunkDir, file), gz);
  totalGz += gz.length;
  manifestChunks.push({ id: chunk.id, file, bbox, count: chunk.pois.length });
}

const manifest = {
  generatedAt: new Date().toISOString(),
  schemaVersion: "poi-1",
  dataset: "Rider Services POIs",
  source: sourceUrl,
  sources: SOURCES_FILE && fs.existsSync(SOURCES_FILE)
    ? JSON.parse(fs.readFileSync(SOURCES_FILE, "utf8"))
    : [{ slug: "nova-scotia", url: sourceUrl }],
  license: "OpenStreetMap contributors (ODbL)",
  attribution: "© OpenStreetMap contributors",
  region: REGION_LABEL,
  chunkDeg: CHUNK_DEG,
  chunkDir: CHUNK_DIR,
  categories: {
    fuel: { tags: "amenity=fuel" },
    lodging: { tags: "tourism=hotel|motel|hostel|guest_house|chalet" },
    campground: { tags: "tourism=camp_site|caravan_site" },
    liquor: { tags: "shop=alcohol" }
  },
  counts,
  featureCount: kept,
  skipped,
  gzBytes: totalGz,
  chunks: manifestChunks
};

fs.writeFileSync(
  path.join(outDir, "poi.manifest.json"),
  JSON.stringify(manifest, null, 2) + "\n"
);

console.log("POI pack complete");
console.log("  kept:      " + kept + "  skipped: " + skipped);
console.log("  categories:", counts);
console.log("  chunks:    " + manifestChunks.length + " (" + CHUNK_DEG + "deg grid)");
console.log("  gz total:  " + (totalGz / 1024).toFixed(1) + " KB");
console.log("  out:       " + outDir);
