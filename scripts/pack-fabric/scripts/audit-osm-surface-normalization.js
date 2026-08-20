#!/usr/bin/env node
"use strict";

/**
 * Audit OSM surface normalization against the raw tags that produced a pack.
 *
 * The OPL input should contain the included highway ways only:
 *   osmium tags-filter -R -f opl source.osm.pbf \
 *     w/highway=motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,road,service,track,path,cycleway \
 *     -o roads.opl -O
 *
 * Usage:
 *   node --max-old-space-size=4096 scripts/audit-osm-surface-normalization.js \
 *     --opl /tmp/roads.opl --pack routing/data/regions/bc/graph.v1.json.gz
 */
const fs = require("fs");
const readline = require("readline");
const zlib = require("zlib");
const { classify } = require("../routing/adapters/osm-roads");

function arg(name) {
  const at = process.argv.indexOf(name);
  return at >= 0 ? process.argv[at + 1] : null;
}

function decodeOpl(value) {
  // OPL escapes bytes as `%HH%` (unlike URL encoding's `%HH`).
  return value.replace(/%([0-9a-f]{2})%/gi, (_, hex) =>
    String.fromCharCode(Number.parseInt(hex, 16))
  );
}

function parseOplWay(line) {
  if (!line || line[0] !== "w") return null;
  const idEnd = line.indexOf(" ");
  if (idEnd < 2) return null;
  const tagStart = line.indexOf(" T");
  if (tagStart < 0) return null;
  const tagEnd = line.indexOf(" ", tagStart + 2);
  const encoded = line.slice(tagStart + 2, tagEnd < 0 ? line.length : tagEnd);
  const props = {};
  if (encoded) {
    for (const item of encoded.split(",")) {
      const eq = item.indexOf("=");
      if (eq < 0) continue;
      props[decodeOpl(item.slice(0, eq))] = decodeOpl(item.slice(eq + 1));
    }
  }
  return { id: line.slice(1, idEnd), props };
}

function bump(obj, key, value = 1) {
  obj[key] = (obj[key] || 0) + value;
}

function sorted(obj) {
  return Object.fromEntries(
    Object.entries(obj).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
  );
}

function pct(part, whole) {
  return whole ? Number((100 * part / whole).toFixed(2)) : 0;
}

async function loadRawWays(oplPath) {
  const ways = new Map();
  const highway = {};
  const surfaces = {};
  const surfaceByHighway = {};
  const inferredByHighway = {};
  const missingTracktypeByHighway = {};
  const missingServiceType = {};
  const accessTags = {};
  const motorVehicleTags = {};
  const motorcycleTags = {};
  const accessPrecedenceConflicts = {};
  const explicitNormalized = {};
  const unknownExplicit = {};
  let included = 0;
  let excluded = 0;
  let missingSurface = 0;

  const rl = readline.createInterface({
    input: fs.createReadStream(oplPath, { encoding: "utf8" }),
    crlfDelay: Infinity
  });
  for await (const line of rl) {
    const way = parseOplWay(line);
    if (!way) continue;
    const result = classify(way.props);
    if (!result.ok) {
      excluded += 1;
      continue;
    }
    included += 1;
    const hw = String(way.props.highway || "missing").toLowerCase();
    const surface = String(way.props.surface || "").toLowerCase().trim();
    const access = String(way.props.access || "").toLowerCase().trim();
    const motorVehicle = String(way.props.motor_vehicle || "").toLowerCase().trim();
    const motorcycle = String(way.props.motorcycle || "").toLowerCase().trim();
    const vehicle = String(way.props.vehicle || "").toLowerCase().trim();
    if (access) bump(accessTags, access);
    if (motorVehicle) bump(motorVehicleTags, motorVehicle);
    if (motorcycle) bump(motorcycleTags, motorcycle);
    if (motorcycle && motorVehicle && motorcycle !== motorVehicle) {
      bump(accessPrecedenceConflicts, `motorcycle=${motorcycle}|motor_vehicle=${motorVehicle}`);
    }
    if (motorcycle && access && motorcycle !== access) {
      bump(accessPrecedenceConflicts, `motorcycle=${motorcycle}|access=${access}`);
    }
    if (motorVehicle && vehicle && motorVehicle !== vehicle) {
      bump(accessPrecedenceConflicts, `motor_vehicle=${motorVehicle}|vehicle=${vehicle}`);
    }
    bump(highway, hw);
    if (surface) {
      bump(surfaces, surface);
      bump(surfaceByHighway, `${hw}|${surface}`);
      bump(explicitNormalized, `${surface}->${result.surfaceClass}`);
      if (result.surfaceClass === "unknown") bump(unknownExplicit, surface);
    } else {
      missingSurface += 1;
      bump(inferredByHighway, `${hw}->${result.surfaceClass}`);
      bump(missingTracktypeByHighway, `${hw}|tracktype=${String(way.props.tracktype || "missing").toLowerCase()}`);
      if (hw === "service") {
        bump(missingServiceType, String(way.props.service || "missing").toLowerCase());
      }
    }
    ways.set(way.id, {
      highway: hw,
      surface: surface || null,
      tracktype: String(way.props.tracktype || "").toLowerCase().trim() || null,
      service: String(way.props.service || "").toLowerCase().trim() || null,
      name: way.props.name || way.props.ref || null,
      normalized: result.surfaceClass,
      roadClass: result.roadTrackClass
    });
  }
  return {
    ways,
    summary: {
      includedWays: included,
      excludedWays: excluded,
      missingSurfaceWays: missingSurface,
      missingSurfacePct: pct(missingSurface, included),
      highway: sorted(highway),
      explicitSurface: sorted(surfaces),
      explicitSurfaceNormalization: sorted(explicitNormalized),
      unrecognizedExplicitSurface: sorted(unknownExplicit),
      inferredMissingSurface: sorted(inferredByHighway),
      missingSurfaceTracktype: sorted(missingTracktypeByHighway),
      untaggedServiceType: sorted(missingServiceType),
      accessTags: sorted(accessTags),
      motorVehicleTags: sorted(motorVehicleTags),
      motorcycleTags: sorted(motorcycleTags),
      accessPrecedenceConflicts: sorted(accessPrecedenceConflicts),
      surfaceByHighway: sorted(surfaceByHighway)
    }
  };
}

async function auditPack(packPath, rawWays) {
  const surfaceName = ["paved", "gravel", "access", "track", "unknown"];
  const byRuleMeters = {};
  const byRuleEdges = {};
  const byPackedSurfaceMeters = {};
  const byPackedSurfaceRoadClassMeters = {};
  const samples = {};
  const contradictions = {};
  let matchedEdges = 0;
  let unmatchedEdges = 0;
  let matchedMeters = 0;

  let packGeneratedAt = null;
  function processEdge(edge) {
    if (!/openstreetmap/i.test(String(edge.src || ""))) return;
    const raw = rawWays.get(String(edge.rid || ""));
    if (!raw) {
      unmatchedEdges += 1;
      return;
    }
    matchedEdges += 1;
    const meters = Number(edge.m) || 0;
    matchedMeters += meters;
    const packed = surfaceName[edge.s] || "unknown";
    bump(byPackedSurfaceMeters, packed, meters);
    bump(byPackedSurfaceRoadClassMeters, `${packed}|${edge.rt || "unknown"}`, meters);
    const key = raw.surface
      ? `explicit:${raw.surface}->${packed}`
      : `inferred:${raw.highway}->${packed}`;
    bump(byRuleEdges, key);
    bump(byRuleMeters, key, meters);
    if (!samples[key]) samples[key] = [];
    if (samples[key].length < 5) {
      samples[key].push({
        osmWay: raw ? String(edge.rid) : null,
        name: raw.name,
        highway: raw.highway,
        surface: raw.surface,
        tracktype: raw.tracktype,
        service: raw.service,
        packed,
        meters
      });
    }
    // Explicit tags must survive normalization. These labels flag known semantic
    // contradictions rather than merely comparing the adapter with itself.
    if (raw.surface === "chipseal" && packed !== "paved") {
      bump(contradictions, "chipseal_not_paved_m", meters);
    }
    if (!raw.surface && raw.highway === "service" && packed !== "unknown") {
      bump(contradictions, "untagged_service_invented_surface_m", meters);
    }
    if (!raw.surface && raw.highway === "track" && packed !== "unknown") {
      bump(contradictions, "untagged_track_invented_surface_m", meters);
    }
    if (!raw.surface && (raw.highway === "path" || raw.highway === "cycleway") && packed !== "unknown") {
      bump(contradictions, "untagged_path_cycleway_invented_surface_m", meters);
    }
  }

  const source = fs.createReadStream(packPath).pipe(zlib.createGunzip());
  source.setEncoding("utf8");
  const marker = '"edges":[';
  let searching = true;
  let searchBuffer = "";
  let edgeBuffer = "";
  let depth = 0;
  let inString = false;
  let escaped = false;
  let done = false;
  for await (const chunk of source) {
    let text = chunk;
    if (searching) {
      searchBuffer += text;
      const at = searchBuffer.indexOf(marker);
      if (at < 0) {
        if (searchBuffer.length > marker.length + 512) {
          const generated = searchBuffer.match(/"generatedAt":"([^"]+)"/);
          if (generated) packGeneratedAt = generated[1];
          searchBuffer = searchBuffer.slice(-(marker.length + 512));
        }
        continue;
      }
      const generated = searchBuffer.slice(0, at).match(/"generatedAt":"([^"]+)"/);
      if (generated) packGeneratedAt = generated[1];
      text = searchBuffer.slice(at + marker.length);
      searchBuffer = "";
      searching = false;
    }
    for (let i = 0; i < text.length; i += 1) {
      const ch = text[i];
      if (depth === 0) {
        if (ch === "]") { done = true; break; }
        if (ch !== "{") continue;
        edgeBuffer = "{";
        depth = 1;
        inString = false;
        escaped = false;
        continue;
      }
      edgeBuffer += ch;
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') { inString = true; continue; }
      if (ch === "{" || ch === "[") depth += 1;
      else if (ch === "}" || ch === "]") depth -= 1;
      if (depth === 0) {
        processEdge(JSON.parse(edgeBuffer));
        edgeBuffer = "";
      }
    }
    if (done) break;
  }

  return {
    pack: packPath,
    packGeneratedAt,
    matchedOsmEdges: matchedEdges,
    unmatchedOsmEdges: unmatchedEdges,
    matchedKm: Number((matchedMeters / 1000).toFixed(1)),
    packedSurfaceKm: Object.fromEntries(
      Object.entries(byPackedSurfaceMeters)
        .map(([key, meters]) => [key, Number((meters / 1000).toFixed(1))])
        .sort((a, b) => b[1] - a[1])
    ),
    packedSurfaceRoadClassKm: Object.fromEntries(
      Object.entries(byPackedSurfaceRoadClassMeters)
        .map(([key, meters]) => [key, Number((meters / 1000).toFixed(1))])
        .sort((a, b) => b[1] - a[1])
    ),
    byNormalizationRuleEdges: sorted(byRuleEdges),
    byNormalizationRuleKm: Object.fromEntries(
      Object.entries(byRuleMeters)
        .map(([key, meters]) => [key, Number((meters / 1000).toFixed(1))])
        .sort((a, b) => b[1] - a[1])
    ),
    semanticContradictionsKm: Object.fromEntries(
      Object.entries(contradictions).map(([key, meters]) => [key, Number((meters / 1000).toFixed(1))])
    ),
    samples
  };
}

async function main() {
  const oplPath = arg("--opl");
  const packPath = arg("--pack");
  const outPath = arg("--out");
  if (!oplPath) throw new Error("Usage: audit-osm-surface-normalization.js --opl <roads.opl> [--pack <graph.v1.json.gz>]");
  const raw = await loadRawWays(oplPath);
  const report = {
    generatedAt: new Date().toISOString(),
    rawOsm: raw.summary,
    packedGraph: packPath ? await auditPack(packPath, raw.ways) : null
  };
  const json = JSON.stringify(report, null, 2) + "\n";
  if (outPath) {
    fs.mkdirSync(require("path").dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, json);
    const contradictions =
      report.packedGraph && report.packedGraph.semanticContradictionsKm
        ? report.packedGraph.semanticContradictionsKm
        : {};
    process.stdout.write(
      JSON.stringify({
        out: outPath,
        includedWays: report.rawOsm.includedWays,
        matchedOsmEdges: report.packedGraph && report.packedGraph.matchedOsmEdges,
        unmatchedOsmEdges: report.packedGraph && report.packedGraph.unmatchedOsmEdges,
        semanticContradictionsKm: contradictions
      }, null, 2) + "\n"
    );
  } else {
    process.stdout.write(json);
  }
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
