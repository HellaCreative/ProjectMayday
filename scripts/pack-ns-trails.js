#!/usr/bin/env node
/**
 * Pack osmium geojsonseq → classified DIRT trail FeatureCollection.
 * Usage: node scripts/pack-ns-trails.js <input.geojsonseq> <outDir>
 */
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const zlib = require('zlib');

const inputPath = process.argv[2];
const outDir = process.argv[3] || path.join(__dirname, '..', 'app', 'data');

if (!inputPath) {
  console.error('Usage: node scripts/pack-ns-trails.js <input.geojsonseq> [outDir]');
  process.exit(1);
}

function classify(tags) {
  const hw = tags.highway || '';
  if (hw === 'path' || hw === 'bridleway') return 'single';
  if (hw === 'track') {
    const tt = tags.tracktype || '';
    if (tt === 'grade1' || tt === 'grade2') return 'g2';
    if (tt === 'grade3') return 'g3';
    if (tt === 'grade4') return 'g4';
    if (tt === 'grade5') return 'g5';
    return 'unknown';
  }
  return null;
}

function legalAccess(tags) {
  const keys = ['motor_vehicle', 'motorcycle', 'vehicle', 'access'];
  let value = null;
  for (const k of keys) {
    if (tags[k] != null && tags[k] !== '') {
      value = tags[k];
      break;
    }
  }
  if (!value) return { status: 'unknown', detail: 'use judgment' };
  if (['yes', 'permissive', 'designated'].includes(value)) return { status: 'allowed', detail: value };
  if (['no', 'private', 'delivery', 'agricultural', 'forestry'].includes(value)) {
    return { status: 'restricted', detail: value };
  }
  return { status: 'unknown', detail: value };
}

function keepPath(tags) {
  const hw = tags.highway || '';
  if (hw === 'track' || hw === 'bridleway') return true;
  if (hw !== 'path') return false;
  const surface = (tags.surface || '').toLowerCase();
  if (/dirt|ground|earth|gravel|unpaved|fine_gravel|compacted|sand|grass/.test(surface)) return true;
  if (tags.motorcycle) return true;
  return false;
}

function roundCoord(c) {
  return [Math.round(c[0] * 1e5) / 1e5, Math.round(c[1] * 1e5) / 1e5];
}

function roundGeom(g) {
  if (g.type === 'LineString') {
    return { type: 'LineString', coordinates: g.coordinates.map(roundCoord) };
  }
  if (g.type === 'MultiLineString') {
    return {
      type: 'MultiLineString',
      coordinates: g.coordinates.map((line) => line.map(roundCoord))
    };
  }
  return g;
}

async function main() {
  const rl = readline.createInterface({
    input: fs.createReadStream(inputPath),
    crlfDelay: Infinity
  });

  const features = [];
  let kept = 0;
  let skipped = 0;

  for await (const raw of rl) {
    const line = raw.replace(/^\x1e/, '').trim();
    if (!line) continue;
    let f;
    try {
      f = JSON.parse(line);
    } catch {
      skipped += 1;
      continue;
    }
    if (
      !f.geometry ||
      (f.geometry.type !== 'LineString' && f.geometry.type !== 'MultiLineString')
    ) {
      skipped += 1;
      continue;
    }
    const tags = f.properties || {};
    if (!keepPath(tags)) {
      skipped += 1;
      continue;
    }
    const grade = classify(tags);
    if (!grade) {
      skipped += 1;
      continue;
    }
    const access = legalAccess(tags);
    const id = tags['@id'] || f.id || kept;
    const properties = {
      id,
      grade,
      highway: tags.highway || '',
      accessStatus: access.status,
      accessDetail: access.detail
    };
    if (tags.tracktype) properties.tracktype = tags.tracktype;
    if (tags.surface) properties.surface = tags.surface;
    if (tags.name) properties.name = tags.name;

    features.push({
      type: 'Feature',
      properties,
      geometry: roundGeom(f.geometry)
    });
    kept += 1;
  }

  fs.mkdirSync(outDir, { recursive: true });
  const fc = { type: 'FeatureCollection', features };
  const json = JSON.stringify(fc);
  const geoPath = path.join(outDir, 'ns-trails.geojson');
  const gzPath = path.join(outDir, 'ns-trails.geojson.gz');
  const metaPath = path.join(outDir, 'ns-trails.meta.json');

  fs.writeFileSync(geoPath, json);
  fs.writeFileSync(gzPath, zlib.gzipSync(Buffer.from(json), { level: 9 }));

  const meta = {
    generatedAt: new Date().toISOString(),
    source: 'https://download.geofabrik.de/north-america/canada/nova-scotia-latest.osm.pbf',
    featureCount: features.length,
    bytes: Buffer.byteLength(json),
    gzBytes: fs.statSync(gzPath).size,
    grades: features.reduce((a, f) => {
      a[f.properties.grade] = (a[f.properties.grade] || 0) + 1;
      return a;
    }, {})
  };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  console.log(JSON.stringify({ kept, skipped, ...meta }, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
