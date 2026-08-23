#!/usr/bin/env node
"use strict";

/**
 * Audit OSM surface normalization against the raw tags that produced a pack.
 *
 * Phase A — leaf length audit (no pack / schema change):
 *   node --max-old-space-size=4096 scripts/pack-fabric/scripts/audit-osm-surface-normalization.js \
 *     --geojsonseq scripts/pack-fabric/data-raw/osm-roads/nova-scotia/roads.geojsonseq
 *
 * Phase A follow-up — ATV / motor_vehicle access audit (measure only):
 *   node --max-old-space-size=4096 scripts/pack-fabric/scripts/audit-osm-surface-normalization.js \
 *     --geojsonseq scripts/pack-fabric/data-raw/osm-roads/nova-scotia/roads.geojsonseq \
 *     --atv-audit
 *
 * Phase A follow-up — positive atv= but access_restricted (soft vs hard deny):
 *   node --max-old-space-size=4096 scripts/pack-fabric/scripts/audit-osm-surface-normalization.js \
 *     --geojsonseq scripts/pack-fabric/data-raw/osm-roads/nova-scotia/roads.geojsonseq \
 *     --atv-excluded-audit
 *
 * Legacy OPL + optional pack comparison:
 *   osmium tags-filter -R -f opl source.osm.pbf \
 *     w/highway=motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,road,service,track,path,cycleway \
 *     -o roads.opl -O
 *   node --max-old-space-size=4096 scripts/pack-fabric/scripts/audit-osm-surface-normalization.js \
 *     --opl /tmp/roads.opl --pack routing/data/regions/bc/graph.v1.json.gz
 *
 * Does NOT modify osm-roads.js normalization — measure only.
 */
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const zlib = require("zlib");
const { classify, explicitSurfaceClass, effectiveMotorcycleAccess } = require("../routing/adapters/osm-roads");

const LEAF_TAGS = [
  "surface",
  "highway",
  "tracktype",
  "smoothness",
  "layer",
  "bridge",
  "tunnel",
  "ford"
];

const OFFROAD_HIGHWAYS = ["track", "path", "cycleway"];
const ATV_VALUE_BUCKETS = ["yes", "designated", "permissive", "no", "conditional", "other", "(missing)"];
const POSITIVE_ATV = new Set(["yes", "designated", "permissive"]);
const POSITIVE_MOTOR_VEHICLE = new Set(["yes", "designated"]);

const UINT8_MAX = 255;
const CARDINALITY_WARN = 200;

function hasFlag(name) {
  return process.argv.includes(name);
}

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

function haversineMeters(a, b) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const r = 6371000;
  const dLat = toRad(b[1] - a[1]);
  const dLng = toRad(b[0] - a[0]);
  const lat1 = toRad(a[1]);
  const lat2 = toRad(b[1]);
  const x =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

function lineMeters(coords) {
  let total = 0;
  for (let i = 1; i < coords.length; i += 1) {
    const a = coords[i - 1];
    const b = coords[i];
    if (!Array.isArray(a) || !Array.isArray(b) || a.length < 2 || b.length < 2) continue;
    total += haversineMeters(a, b);
  }
  return total;
}

function geometryMeters(geom) {
  if (!geom) return 0;
  if (geom.type === "LineString") return lineMeters(geom.coordinates || []);
  if (geom.type === "MultiLineString") {
    let total = 0;
    for (const part of geom.coordinates || []) total += lineMeters(part || []);
    return total;
  }
  return 0;
}

function rawTag(props, key) {
  const v = props[key];
  if (v == null || v === "") return "";
  return String(v).trim();
}

function isCompound(value) {
  return /[;,]/.test(value);
}

/**
 * Current coarse mapping as osm-roads.js classify / explicitSurfaceClass apply it.
 * Measurement only — does not change adapter behavior.
 */
function coarseMappingToday(tag, leaf) {
  if (!leaf) {
    if (tag === "surface") {
      return "MISSING → inferred paved if highway∈motorway|trunk|primary|secondary|tertiary(+links); else unknown";
    }
    if (tag === "highway") return "MISSING → way excluded (no highway)";
    if (tag === "bridge" || tag === "tunnel") return "MISSING → structureType=none";
    if (tag === "tracktype" || tag === "smoothness" || tag === "layer" || tag === "ford") {
      return "MISSING → unused (not packed)";
    }
    return "MISSING";
  }

  if (tag === "surface") {
    const family = explicitSurfaceClass(leaf.toLowerCase());
    if (family == null) return "→ unknown (empty after tokenize)";
    return `→ surfaceClass=${family}`;
  }

  if (tag === "highway") {
    const result = classify({ highway: leaf.toLowerCase() });
    if (!result.ok) return `→ EXCLUDED (${result.reason})`;
    return `→ roadTrackClass=${result.roadTrackClass}`;
  }

  if (tag === "bridge") {
    if (leaf.toLowerCase() === "yes") return "→ structureType=bridge";
    return `→ ignored (adapter only treats bridge=yes; raw="${leaf}")`;
  }

  if (tag === "tunnel") {
    if (leaf.toLowerCase() === "yes") return "→ structureType=tunnel";
    return `→ ignored (adapter only treats tunnel=yes; raw="${leaf}")`;
  }

  if (tag === "tracktype") {
    return "→ discarded (stashed in meta.tracktype at parse; meta not serialized to .bin)";
  }

  if (tag === "smoothness") {
    return "→ unused (not read by osm-roads.js)";
  }

  if (tag === "layer") {
    return "→ discarded from edge record (meta.layer; grade-bucket may use at package time)";
  }

  if (tag === "ford") {
    return "→ unused (not read by osm-roads.js classify for structure)";
  }

  return "→ (no mapping defined)";
}

function emptyTagBuckets() {
  const out = {};
  for (const tag of LEAF_TAGS) {
    out[tag] = {
      byLeafMeters: {},
      missingMeters: 0,
      compoundMeters: 0,
      compoundByLeafMeters: {},
      ways: 0
    };
  }
  return out;
}

function accumulateLeaf(buckets, props, meters) {
  for (const tag of LEAF_TAGS) {
    const bucket = buckets[tag];
    bucket.ways += 1;
    const raw = rawTag(props, tag);
    if (!raw) {
      bucket.missingMeters += meters;
      bump(bucket.byLeafMeters, "(missing)", meters);
      continue;
    }
    // Preserve original leaf spelling for dictionary sizing; normalize case for grouping.
    const leaf = raw.toLowerCase();
    bump(bucket.byLeafMeters, leaf, meters);
    if (isCompound(leaf)) {
      bucket.compoundMeters += meters;
      bump(bucket.compoundByLeafMeters, leaf, meters);
    }
  }
}

function summarizeTag(tag, bucket, totalMeters) {
  const entries = Object.entries(bucket.byLeafMeters).sort(
    (a, b) => b[1] - a[1] || a[0].localeCompare(b[0])
  );
  const taggedLeaves = entries.filter(([leaf]) => leaf !== "(missing)").map(([leaf]) => leaf);
  const cardinality = taggedLeaves.length;
  const rows = entries.map(([leaf, meters]) => {
    const km = meters / 1000;
    return {
      leaf,
      km: Number(km.toFixed(3)),
      pct: pct(meters, totalMeters),
      coarseToday: coarseMappingToday(tag, leaf === "(missing)" ? "" : leaf)
    };
  });
  const compoundRows = Object.entries(bucket.compoundByLeafMeters)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([leaf, meters]) => ({
      leaf,
      km: Number((meters / 1000).toFixed(3)),
      pct: pct(meters, totalMeters),
      coarseToday: coarseMappingToday(tag, leaf)
    }));

  return {
    tag,
    totalKm: Number((totalMeters / 1000).toFixed(3)),
    missingKm: Number((bucket.missingMeters / 1000).toFixed(3)),
    missingPct: pct(bucket.missingMeters, totalMeters),
    compoundKm: Number((bucket.compoundMeters / 1000).toFixed(3)),
    compoundPct: pct(bucket.compoundMeters, totalMeters),
    compoundDistinct: compoundRows.length,
    dictionaryCardinality: cardinality,
    uint8Fits: cardinality <= UINT8_MAX,
    uint8Headroom: UINT8_MAX - cardinality,
    approachingUint8Limit: cardinality >= CARDINALITY_WARN,
    rows,
    compounds: compoundRows
  };
}

function pad(s, n) {
  const t = String(s);
  return t.length >= n ? t.slice(0, n) : t + " ".repeat(n - t.length);
}

function printTagTable(summary) {
  const lines = [];
  lines.push("");
  lines.push(`## ${summary.tag}=`);
  lines.push(
    `dictionary cardinality (distinct tagged leaves): ${summary.dictionaryCardinality}` +
      `  |  Uint8 fit: ${summary.uint8Fits ? "YES" : "NO"}` +
      `  |  headroom: ${summary.uint8Headroom}` +
      (summary.approachingUint8Limit ? "  |  ⚠ APPROACHING 255" : "")
  );
  lines.push(
    `missing/untagged: ${summary.missingKm.toFixed(1)} km (${summary.missingPct}%)`
  );
  lines.push(
    `compound values (;/,): ${summary.compoundKm.toFixed(1)} km (${summary.compoundPct}%)` +
      ` across ${summary.compoundDistinct} distinct compound leaves`
  );
  lines.push("");
  lines.push(
    `${pad("leaf", 36)} ${pad("km", 12)} ${pad("%", 8)} coarse family today (osm-roads.js)`
  );
  lines.push("-".repeat(120));
  for (const row of summary.rows) {
    lines.push(
      `${pad(row.leaf, 36)} ${pad(row.km.toFixed(1), 12)} ${pad(String(row.pct), 8)} ${row.coarseToday}`
    );
  }
  if (summary.compounds.length) {
    lines.push("");
    lines.push("compound detail:");
    for (const row of summary.compounds) {
      lines.push(
        `  ${pad(row.leaf, 34)} ${pad(row.km.toFixed(1), 12)} ${pad(String(row.pct), 8)} ${row.coarseToday}`
      );
    }
  }
  return lines.join("\n");
}

async function auditLeafLengths(geojsonseqPath) {
  const buckets = emptyTagBuckets();
  let includedWays = 0;
  let excludedWays = 0;
  let includedMeters = 0;
  let excludedByReason = {};

  const rl = readline.createInterface({
    input: fs.createReadStream(geojsonseqPath, { encoding: "utf8" }),
    crlfDelay: Infinity
  });

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const jsonText = trimmed.charCodeAt(0) === 0x1e ? trimmed.slice(1) : trimmed;
    if (!jsonText) continue;
    let feat;
    try {
      feat = JSON.parse(jsonText);
    } catch (_) {
      bump(excludedByReason, "json_parse");
      excludedWays += 1;
      continue;
    }
    const props = feat.properties || {};
    const classified = classify(props);
    if (!classified.ok) {
      bump(excludedByReason, classified.reason || "excluded");
      excludedWays += 1;
      continue;
    }
    const meters = geometryMeters(feat.geometry);
    if (!(meters > 0)) {
      bump(excludedByReason, "no_usable_geometry");
      excludedWays += 1;
      continue;
    }
    includedWays += 1;
    includedMeters += meters;
    accumulateLeaf(buckets, props, meters);
  }

  const tagSummaries = LEAF_TAGS.map((tag) => summarizeTag(tag, buckets[tag], includedMeters));
  return {
    source: geojsonseqPath,
    includedWays,
    excludedWays,
    excludedByReason: sorted(excludedByReason),
    includedKm: Number((includedMeters / 1000).toFixed(3)),
    tags: tagSummaries,
    cardinalitySummary: tagSummaries.map((s) => ({
      tag: s.tag,
      dictionaryCardinality: s.dictionaryCardinality,
      uint8Fits: s.uint8Fits,
      uint8Headroom: s.uint8Headroom,
      approachingUint8Limit: s.approachingUint8Limit,
      missingPct: s.missingPct,
      compoundPct: s.compoundPct,
      compoundKm: s.compoundKm
    }))
  };
}

function printLeafAudit(report) {
  const lines = [];
  lines.push("=== PHASE A — OSM leaf length audit (included routable only) ===");
  lines.push(`source: ${report.source}`);
  lines.push(
    `included ways: ${report.includedWays}  |  excluded: ${report.excludedWays}  |  included length: ${report.includedKm.toFixed(1)} km`
  );
  lines.push(`excluded by reason: ${JSON.stringify(report.excludedByReason)}`);
  lines.push("");
  lines.push("=== Cardinality / compound share (gate summary) ===");
  lines.push(
    `${pad("tag", 14)} ${pad("card", 8)} ${pad("U8?", 6)} ${pad("headroom", 10)} ${pad("missing%", 10)} ${pad("compound%", 11)} compound_km`
  );
  lines.push("-".repeat(72));
  for (const row of report.cardinalitySummary) {
    lines.push(
      `${pad(row.tag, 14)} ${pad(row.dictionaryCardinality, 8)} ${pad(row.uint8Fits ? "yes" : "NO", 6)} ${pad(row.uint8Headroom, 10)} ${pad(row.missingPct, 10)} ${pad(row.compoundPct, 11)} ${row.compoundKm.toFixed(1)}${row.approachingUint8Limit ? "  ⚠" : ""}`
    );
  }
  for (const summary of report.tags) {
    lines.push(printTagTable(summary));
  }
  lines.push("");
  lines.push("=== STOP (Phase A only — no schema/pack/router changes) ===");
  return lines.join("\n") + "\n";
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

function accessValueBucket(raw) {
  if (!raw) return "(missing)";
  const v = String(raw).toLowerCase().trim();
  if (!v) return "(missing)";
  if (v === "yes" || v === "designated" || v === "permissive" || v === "no" || v === "conditional") {
    return v;
  }
  return "other";
}

function emptyValueMeters() {
  const out = {};
  for (const b of ATV_VALUE_BUCKETS) out[b] = 0;
  return out;
}

function emptyOffroadClassStats() {
  return {
    totalMeters: 0,
    atvByValue: emptyValueMeters(),
    motorVehicleByValue: emptyValueMeters(),
    atvTaggedMeters: 0,
    motorVehicleTaggedMeters: 0,
    positiveKeepMeters: 0,
    positiveAtvMeters: 0,
    positiveMotorVehicleMeters: 0,
    positiveAndUnknownAccessMeters: 0,
    positiveAndPermissiveAccessMeters: 0,
    positiveAndOtherAccessMeters: 0
  };
}

/**
 * Phase A follow-up: ATV / motor_vehicle tagging on included routable network.
 * Does not change osm-roads.js — uses classify() as-is for inclusion + accessClass.
 */
async function auditAtvAccess(geojsonseqPath) {
  const byHighway = {
    track: emptyOffroadClassStats(),
    path: emptyOffroadClassStats(),
    cycleway: emptyOffroadClassStats()
  };
  /** Whole included graph: positive-keep meters by highway class. */
  const wholePositiveByHighway = {};
  let includedMeters = 0;
  let includedWays = 0;
  let excludedWays = 0;
  const excludedByReason = {};

  // Positive-ATV edges that were excluded (e.g. motor_vehicle=no) — useful context.
  let positiveAtvExcludedMeters = 0;
  const positiveAtvExcludedByReason = {};

  const rl = readline.createInterface({
    input: fs.createReadStream(geojsonseqPath, { encoding: "utf8" }),
    crlfDelay: Infinity
  });

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const jsonText = trimmed.charCodeAt(0) === 0x1e ? trimmed.slice(1) : trimmed;
    if (!jsonText) continue;
    let feat;
    try {
      feat = JSON.parse(jsonText);
    } catch (_) {
      bump(excludedByReason, "json_parse");
      excludedWays += 1;
      continue;
    }
    const props = feat.properties || {};
    const hw = String(props.highway || "").toLowerCase().trim();
    const meters = geometryMeters(feat.geometry);
    if (!(meters > 0)) {
      bump(excludedByReason, "no_usable_geometry");
      excludedWays += 1;
      continue;
    }

    const atvRaw = String(props.atv || "").toLowerCase().trim();
    const mvRaw = String(props.motor_vehicle || "").toLowerCase().trim();
    const atvBucket = accessValueBucket(atvRaw);
    const mvBucket = accessValueBucket(mvRaw);
    const positiveAtv = POSITIVE_ATV.has(atvBucket);
    const positiveMv = POSITIVE_MOTOR_VEHICLE.has(mvBucket);
    const positiveKeep = positiveAtv || positiveMv;

    const classified = classify(props);
    if (!classified.ok) {
      bump(excludedByReason, classified.reason || "excluded");
      excludedWays += 1;
      if (positiveAtv) {
        positiveAtvExcludedMeters += meters;
        bump(positiveAtvExcludedByReason, classified.reason || "excluded", meters);
      }
      continue;
    }

    includedWays += 1;
    includedMeters += meters;

    if (positiveKeep) {
      bump(wholePositiveByHighway, hw || "(missing)", meters);
    }

    if (!byHighway[hw]) continue; // only detailed tables for track/path/cycleway

    const stats = byHighway[hw];
    stats.totalMeters += meters;
    stats.atvByValue[atvBucket] += meters;
    stats.motorVehicleByValue[mvBucket] += meters;
    if (atvBucket !== "(missing)") stats.atvTaggedMeters += meters;
    if (mvBucket !== "(missing)") stats.motorVehicleTaggedMeters += meters;
    if (positiveAtv) stats.positiveAtvMeters += meters;
    if (positiveMv) stats.positiveMotorVehicleMeters += meters;
    if (positiveKeep) {
      stats.positiveKeepMeters += meters;
      if (classified.accessClass === "motorized_unknown") {
        stats.positiveAndUnknownAccessMeters += meters;
      } else if (classified.accessClass === "motorized_permissive") {
        stats.positiveAndPermissiveAccessMeters += meters;
      } else {
        stats.positiveAndOtherAccessMeters += meters;
      }
    }
  }

  function finalizeClass(name, stats) {
    const totalKm = stats.totalMeters / 1000;
    const valueRows = (byValue) =>
      ATV_VALUE_BUCKETS.map((bucket) => ({
        value: bucket,
        km: Number(((byValue[bucket] || 0) / 1000).toFixed(3)),
        pctOfClass: pct(byValue[bucket] || 0, stats.totalMeters)
      }));
    return {
      highway: name,
      totalKm: Number(totalKm.toFixed(3)),
      atvTaggedKm: Number((stats.atvTaggedMeters / 1000).toFixed(3)),
      atvTaggedPct: pct(stats.atvTaggedMeters, stats.totalMeters),
      atvByValue: valueRows(stats.atvByValue),
      motorVehicleTaggedKm: Number((stats.motorVehicleTaggedMeters / 1000).toFixed(3)),
      motorVehicleTaggedPct: pct(stats.motorVehicleTaggedMeters, stats.totalMeters),
      motorVehicleByValue: valueRows(stats.motorVehicleByValue),
      positiveKeepKm: Number((stats.positiveKeepMeters / 1000).toFixed(3)),
      positiveKeepPct: pct(stats.positiveKeepMeters, stats.totalMeters),
      positiveAtvKm: Number((stats.positiveAtvMeters / 1000).toFixed(3)),
      positiveMotorVehicleKm: Number((stats.positiveMotorVehicleMeters / 1000).toFixed(3)),
      positiveAndUnknownAccessKm: Number((stats.positiveAndUnknownAccessMeters / 1000).toFixed(3)),
      positiveAndUnknownAccessPctOfPositive: pct(
        stats.positiveAndUnknownAccessMeters,
        stats.positiveKeepMeters
      ),
      positiveAndPermissiveAccessKm: Number((stats.positiveAndPermissiveAccessMeters / 1000).toFixed(3)),
      positiveAndOtherAccessKm: Number((stats.positiveAndOtherAccessMeters / 1000).toFixed(3))
    };
  }

  const classes = OFFROAD_HIGHWAYS.map((hw) => finalizeClass(hw, byHighway[hw]));
  const offroadTotalMeters = OFFROAD_HIGHWAYS.reduce((n, hw) => n + byHighway[hw].totalMeters, 0);
  const offroadPositiveMeters = OFFROAD_HIGHWAYS.reduce(
    (n, hw) => n + byHighway[hw].positiveKeepMeters,
    0
  );
  const offroadPositiveUnknownMeters = OFFROAD_HIGHWAYS.reduce(
    (n, hw) => n + byHighway[hw].positiveAndUnknownAccessMeters,
    0
  );

  const wholePositiveRows = Object.entries(wholePositiveByHighway)
    .map(([highway, meters]) => ({
      highway,
      km: Number((meters / 1000).toFixed(3)),
      pctOfWholePositive: 0
    }))
    .sort((a, b) => b.km - a.km || a.highway.localeCompare(b.highway));
  const wholePositiveMeters = Object.values(wholePositiveByHighway).reduce((a, b) => a + b, 0);
  for (const row of wholePositiveRows) {
    row.pctOfWholePositive = pct(row.km * 1000, wholePositiveMeters);
  }

  return {
    source: geojsonseqPath,
    includedWays,
    excludedWays,
    includedKm: Number((includedMeters / 1000).toFixed(3)),
    excludedByReason: sorted(excludedByReason),
    positiveDefinition: {
      atv: [...POSITIVE_ATV],
      motor_vehicle: [...POSITIVE_MOTOR_VEHICLE],
      note:
        "positive keep = atv∈{yes,designated,permissive} OR motor_vehicle∈{yes,designated} (proposed path-exception KEEP set)"
    },
    accessPrecedence: "motorcycle > motor_vehicle > vehicle > access (atv NOT in chain today)",
    offroadClasses: classes,
    offroadRollup: {
      totalKm: Number((offroadTotalMeters / 1000).toFixed(3)),
      positiveKeepKm: Number((offroadPositiveMeters / 1000).toFixed(3)),
      positiveAndUnknownAccessKm: Number((offroadPositiveUnknownMeters / 1000).toFixed(3)),
      positiveAndUnknownPctOfPositive: pct(offroadPositiveUnknownMeters, offroadPositiveMeters)
    },
    wholeGraphPositiveByHighway: wholePositiveRows,
    wholeGraphPositiveKm: Number((wholePositiveMeters / 1000).toFixed(3)),
    positiveAtvExcludedKm: Number((positiveAtvExcludedMeters / 1000).toFixed(3)),
    positiveAtvExcludedByReasonKm: Object.fromEntries(
      Object.entries(positiveAtvExcludedByReason)
        .map(([k, m]) => [k, Number((m / 1000).toFixed(3))])
        .sort((a, b) => b[1] - a[1])
    )
  };
}

function printAtvAudit(report) {
  const lines = [];
  lines.push("=== PHASE A follow-up — ATV / motor_vehicle access audit (included routable) ===");
  lines.push(`source: ${report.source}`);
  lines.push(
    `included: ${report.includedKm.toFixed(1)} km / ${report.includedWays} ways  |  excluded ways: ${report.excludedWays}`
  );
  lines.push(`excluded by reason: ${JSON.stringify(report.excludedByReason)}`);
  lines.push(`access precedence today: ${report.accessPrecedence}`);
  lines.push(`positive KEEP set: ${report.positiveDefinition.note}`);
  lines.push("");

  lines.push("=== 1–2. Per highway class (track / path / cycleway) ===");
  for (const c of report.offroadClasses) {
    lines.push("");
    lines.push(`## highway=${c.highway}  —  ${c.totalKm.toFixed(1)} km total`);
    lines.push(
      `atv= tagged: ${c.atvTaggedKm.toFixed(1)} km (${c.atvTaggedPct}%)  |  motor_vehicle= tagged: ${c.motorVehicleTaggedKm.toFixed(1)} km (${c.motorVehicleTaggedPct}%)`
    );
    lines.push(
      `POSITIVE KEEP: ${c.positiveKeepKm.toFixed(1)} km (${c.positiveKeepPct}% of class)` +
        `  [atv+ ${c.positiveAtvKm.toFixed(1)} | mv+ ${c.positiveMotorVehicleKm.toFixed(1)}]`
    );
    lines.push(
      `of positive KEEP → accessClass=motorized_unknown: ${c.positiveAndUnknownAccessKm.toFixed(1)} km` +
        ` (${c.positiveAndUnknownAccessPctOfPositive}% of positive)` +
        `  |  already permissive: ${c.positiveAndPermissiveAccessKm.toFixed(1)} km`
    );
    lines.push("");
    lines.push(`${pad("atv=", 16)} ${pad("km", 12)} ${pad("% class", 10)}`);
    lines.push("-".repeat(40));
    for (const row of c.atvByValue) {
      if (row.km === 0 && row.value !== "(missing)") continue;
      lines.push(`${pad(row.value, 16)} ${pad(row.km.toFixed(1), 12)} ${pad(String(row.pctOfClass), 10)}`);
    }
    lines.push("");
    lines.push(`${pad("motor_vehicle=", 16)} ${pad("km", 12)} ${pad("% class", 10)}`);
    lines.push("-".repeat(40));
    for (const row of c.motorVehicleByValue) {
      if (row.km === 0 && row.value !== "(missing)") continue;
      lines.push(`${pad(row.value, 16)} ${pad(row.km.toFixed(1), 12)} ${pad(String(row.pctOfClass), 10)}`);
    }
  }

  lines.push("");
  lines.push("=== Off-road rollup (track+path+cycleway) ===");
  lines.push(
    `total ${report.offroadRollup.totalKm.toFixed(1)} km  |  positive KEEP ${report.offroadRollup.positiveKeepKm.toFixed(1)} km  |  ` +
      `of those motorized_unknown ${report.offroadRollup.positiveAndUnknownAccessKm.toFixed(1)} km ` +
      `(${report.offroadRollup.positiveAndUnknownPctOfPositive}%)`
  );

  lines.push("");
  lines.push("=== 3. Whole-graph positive KEEP km by highway class ===");
  lines.push(`whole-graph positive KEEP total: ${report.wholeGraphPositiveKm.toFixed(1)} km`);
  lines.push(`${pad("highway", 18)} ${pad("km", 12)} ${pad("% of positive", 14)}`);
  lines.push("-".repeat(46));
  for (const row of report.wholeGraphPositiveByHighway) {
    lines.push(
      `${pad(row.highway, 18)} ${pad(row.km.toFixed(1), 12)} ${pad(String(row.pctOfWholePositive), 14)}`
    );
  }

  lines.push("");
  lines.push("=== 4. Positive ATV signal invisible as motorized_unknown (off-road) ===");
  lines.push(
    `Among track/path/cycleway positive KEEP edges, ${report.offroadRollup.positiveAndUnknownAccessKm.toFixed(1)} km ` +
      `(${report.offroadRollup.positiveAndUnknownPctOfPositive}%) currently resolve to accessClass=motorized_unknown ` +
      `because atv= is not in the motorcycle>motor_vehicle>vehicle>access chain.`
  );
  if (report.positiveAtvExcludedKm > 0) {
    lines.push(
      `Also: ${report.positiveAtvExcludedKm.toFixed(1)} km carry positive atv= but are EXCLUDED entirely ` +
        `(${JSON.stringify(report.positiveAtvExcludedByReasonKm)}) — not in the unknown bucket.`
    );
  }

  lines.push("");
  lines.push("=== STOP (ATV audit only — no access-logic changes) ===");
  return lines.join("\n") + "\n";
}

/** Soft = general-vehicle no an ATV tag might override; hard = private/no land we must not. */
function softHardBucket(winKey, winValue) {
  if ((winKey === "motor_vehicle" || winKey === "vehicle") && winValue === "no") return "soft";
  if (winKey === "access" && (winValue === "private" || winValue === "no")) return "hard";
  return "other";
}

function highwayBucketForExcluded(hw) {
  if (hw === "track" || hw === "path") return hw;
  return "other";
}

/**
 * Phase A follow-up: positive atv= ways excluded as access_restricted —
 * which deny key won, soft vs hard, by highway / atv value.
 */
async function auditAtvExcluded(geojsonseqPath) {
  const byCauseMeters = {};
  const crossTab = {}; // `${hwBucket}|${atvValue}|${cause}` → meters
  const softHard = { soft: 0, hard: 0, other: 0 };
  const softHardByCause = { soft: {}, hard: {}, other: {} };
  const softHardByHighway = {
    soft: { track: 0, path: 0, other: 0 },
    hard: { track: 0, path: 0, other: 0 },
    other: { track: 0, path: 0, other: 0 }
  };
  const softHardByAtv = {
    soft: { yes: 0, designated: 0, permissive: 0 },
    hard: { yes: 0, designated: 0, permissive: 0 },
    other: { yes: 0, designated: 0, permissive: 0 }
  };

  let totalMeters = 0;
  let ways = 0;
  let skippedPositiveAtvOtherExclude = 0;
  let skippedPositiveAtvOtherExcludeMeters = 0;

  const rl = readline.createInterface({
    input: fs.createReadStream(geojsonseqPath, { encoding: "utf8" }),
    crlfDelay: Infinity
  });

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const jsonText = trimmed.charCodeAt(0) === 0x1e ? trimmed.slice(1) : trimmed;
    if (!jsonText) continue;
    let feat;
    try {
      feat = JSON.parse(jsonText);
    } catch (_) {
      continue;
    }
    const props = feat.properties || {};
    const atvRaw = String(props.atv || "").toLowerCase().trim();
    const atvBucket = accessValueBucket(atvRaw);
    if (!POSITIVE_ATV.has(atvBucket)) continue;

    const meters = geometryMeters(feat.geometry);
    if (!(meters > 0)) continue;

    const classified = classify(props);
    if (classified.ok) continue;
    if (classified.reason !== "access_restricted") {
      skippedPositiveAtvOtherExclude += 1;
      skippedPositiveAtvOtherExcludeMeters += meters;
      continue;
    }

    const effective = effectiveMotorcycleAccess(props);
    const winKey = effective.key || "unknown";
    const winValue = effective.value || "unknown";
    const cause = `${winKey}=${winValue}`;
    const hw = String(props.highway || "").toLowerCase().trim() || "(missing)";
    const hwBucket = highwayBucketForExcluded(hw);
    const sh = softHardBucket(winKey, winValue);

    ways += 1;
    totalMeters += meters;
    bump(byCauseMeters, cause, meters);
    bump(crossTab, `${hwBucket}|${atvBucket}|${cause}`, meters);
    softHard[sh] += meters;
    bump(softHardByCause[sh], cause, meters);
    softHardByHighway[sh][hwBucket] += meters;
    if (softHardByAtv[sh][atvBucket] != null) softHardByAtv[sh][atvBucket] += meters;
  }

  function kmMap(metersObj) {
    return Object.fromEntries(
      Object.entries(metersObj)
        .map(([k, m]) => [k, Number((m / 1000).toFixed(3))])
        .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    );
  }

  const causeRows = Object.entries(byCauseMeters)
    .map(([cause, meters]) => ({
      cause,
      km: Number((meters / 1000).toFixed(3)),
      pct: pct(meters, totalMeters),
      softHard: softHardBucket(cause.split("=")[0], cause.slice(cause.indexOf("=") + 1))
    }))
    .sort((a, b) => b.km - a.km || a.cause.localeCompare(b.cause));

  const crossRows = Object.entries(crossTab)
    .map(([key, meters]) => {
      const [highway, atv, ...causeParts] = key.split("|");
      const cause = causeParts.join("|");
      return {
        highway,
        atv,
        cause,
        km: Number((meters / 1000).toFixed(3)),
        softHard: softHardBucket(cause.split("=")[0], cause.slice(cause.indexOf("=") + 1))
      };
    })
    .sort(
      (a, b) =>
        b.km - a.km ||
        a.highway.localeCompare(b.highway) ||
        a.atv.localeCompare(b.atv) ||
        a.cause.localeCompare(b.cause)
    );

  const pivotHighwayAtv = {};
  for (const row of crossRows) {
    const k = `${row.highway}|${row.atv}`;
    bump(pivotHighwayAtv, k, row.km * 1000);
  }

  return {
    source: geojsonseqPath,
    setDefinition:
      "positive atv∈{yes,designated,permissive} AND classify reason=access_restricted " +
      "(deny via motorcycle>motor_vehicle>vehicle>access; atv not consulted)",
    softDefinition: "motor_vehicle=no OR vehicle=no",
    hardDefinition: "access=private OR access=no",
    otherDefinition: "any other winning ACCESS_DENIED key=value (agricultural, forestry, motorcycle=no, …)",
    ways,
    totalKm: Number((totalMeters / 1000).toFixed(3)),
    byCause: causeRows,
    crossTab: crossRows,
    softHardKm: {
      soft: Number((softHard.soft / 1000).toFixed(3)),
      hard: Number((softHard.hard / 1000).toFixed(3)),
      other: Number((softHard.other / 1000).toFixed(3))
    },
    softHardPct: {
      soft: pct(softHard.soft, totalMeters),
      hard: pct(softHard.hard, totalMeters),
      other: pct(softHard.other, totalMeters)
    },
    softHardByCauseKm: {
      soft: kmMap(softHardByCause.soft),
      hard: kmMap(softHardByCause.hard),
      other: kmMap(softHardByCause.other)
    },
    softHardByHighwayKm: {
      soft: {
        track: Number((softHardByHighway.soft.track / 1000).toFixed(3)),
        path: Number((softHardByHighway.soft.path / 1000).toFixed(3)),
        other: Number((softHardByHighway.soft.other / 1000).toFixed(3))
      },
      hard: {
        track: Number((softHardByHighway.hard.track / 1000).toFixed(3)),
        path: Number((softHardByHighway.hard.path / 1000).toFixed(3)),
        other: Number((softHardByHighway.hard.other / 1000).toFixed(3))
      },
      other: {
        track: Number((softHardByHighway.other.track / 1000).toFixed(3)),
        path: Number((softHardByHighway.other.path / 1000).toFixed(3)),
        other: Number((softHardByHighway.other.other / 1000).toFixed(3))
      }
    },
    softHardByAtvKm: {
      soft: {
        yes: Number((softHardByAtv.soft.yes / 1000).toFixed(3)),
        designated: Number((softHardByAtv.soft.designated / 1000).toFixed(3)),
        permissive: Number((softHardByAtv.soft.permissive / 1000).toFixed(3))
      },
      hard: {
        yes: Number((softHardByAtv.hard.yes / 1000).toFixed(3)),
        designated: Number((softHardByAtv.hard.designated / 1000).toFixed(3)),
        permissive: Number((softHardByAtv.hard.permissive / 1000).toFixed(3))
      },
      other: {
        yes: Number((softHardByAtv.other.yes / 1000).toFixed(3)),
        designated: Number((softHardByAtv.other.designated / 1000).toFixed(3)),
        permissive: Number((softHardByAtv.other.permissive / 1000).toFixed(3))
      }
    },
    pivotHighwayAtvKm: Object.fromEntries(
      Object.entries(pivotHighwayAtv)
        .map(([k, m]) => [k, Number((m / 1000).toFixed(3))])
        .sort((a, b) => b[1] - a[1])
    ),
    positiveAtvExcludedOtherReasonWays: skippedPositiveAtvOtherExclude,
    positiveAtvExcludedOtherReasonKm: Number((skippedPositiveAtvOtherExcludeMeters / 1000).toFixed(3))
  };
}

function printAtvExcludedAudit(report) {
  const lines = [];
  lines.push("=== PHASE A follow-up — positive atv= EXCLUDED as access_restricted ===");
  lines.push(`source: ${report.source}`);
  lines.push(`set: ${report.setDefinition}`);
  lines.push(`total: ${report.totalKm.toFixed(1)} km / ${report.ways} ways`);
  if (report.positiveAtvExcludedOtherReasonKm > 0) {
    lines.push(
      `(note: ${report.positiveAtvExcludedOtherReasonKm.toFixed(1)} km positive atv= excluded for other reasons — not in this set)`
    );
  }
  lines.push("");

  lines.push("=== 1. Exclusion cause (winning deny key=value under motorcycle>motor_vehicle>vehicle>access) ===");
  lines.push(`${pad("cause", 36)} ${pad("km", 12)} ${pad("%", 8)} soft/hard`);
  lines.push("-".repeat(70));
  for (const row of report.byCause) {
    lines.push(
      `${pad(row.cause, 36)} ${pad(row.km.toFixed(1), 12)} ${pad(String(row.pct), 8)} ${row.softHard}`
    );
  }

  lines.push("");
  lines.push("=== 2. Cross-tab: highway (track/path/other) × atv value × cause ===");
  lines.push(
    `${pad("highway", 10)} ${pad("atv", 14)} ${pad("cause", 28)} ${pad("km", 10)} soft/hard`
  );
  lines.push("-".repeat(78));
  for (const row of report.crossTab) {
    lines.push(
      `${pad(row.highway, 10)} ${pad(row.atv, 14)} ${pad(row.cause, 28)} ${pad(row.km.toFixed(1), 10)} ${row.softHard}`
    );
  }
  lines.push("");
  lines.push("highway|atv totals:");
  for (const [k, km] of Object.entries(report.pivotHighwayAtvKm)) {
    lines.push(`  ${k}: ${km.toFixed(1)} km`);
  }

  lines.push("");
  lines.push("=== 3. Soft vs hard (policy split) ===");
  lines.push(`soft (${report.softDefinition}): ${report.softHardKm.soft.toFixed(1)} km (${report.softHardPct.soft}%)`);
  lines.push(`hard (${report.hardDefinition}): ${report.softHardKm.hard.toFixed(1)} km (${report.softHardPct.hard}%)`);
  lines.push(`other (${report.otherDefinition}): ${report.softHardKm.other.toFixed(1)} km (${report.softHardPct.other}%)`);
  lines.push("");
  lines.push("soft by cause:");
  for (const [c, km] of Object.entries(report.softHardByCauseKm.soft)) {
    lines.push(`  ${c}: ${km.toFixed(1)} km`);
  }
  lines.push("hard by cause:");
  for (const [c, km] of Object.entries(report.softHardByCauseKm.hard)) {
    lines.push(`  ${c}: ${km.toFixed(1)} km`);
  }
  lines.push("other by cause:");
  for (const [c, km] of Object.entries(report.softHardByCauseKm.other)) {
    lines.push(`  ${c}: ${km.toFixed(1)} km`);
  }
  lines.push("");
  lines.push("soft/hard × highway:");
  lines.push(`${pad("", 8)} ${pad("track", 10)} ${pad("path", 10)} ${pad("other", 10)}`);
  for (const sh of ["soft", "hard", "other"]) {
    const r = report.softHardByHighwayKm[sh];
    lines.push(
      `${pad(sh, 8)} ${pad(r.track.toFixed(1), 10)} ${pad(r.path.toFixed(1), 10)} ${pad(r.other.toFixed(1), 10)}`
    );
  }
  lines.push("");
  lines.push("soft/hard × atv value:");
  lines.push(`${pad("", 8)} ${pad("yes", 10)} ${pad("designated", 12)} ${pad("permissive", 12)}`);
  for (const sh of ["soft", "hard", "other"]) {
    const r = report.softHardByAtvKm[sh];
    lines.push(
      `${pad(sh, 8)} ${pad(r.yes.toFixed(1), 10)} ${pad(r.designated.toFixed(1), 12)} ${pad(r.permissive.toFixed(1), 12)}`
    );
  }

  lines.push("");
  lines.push(
    `POLICY READ: soft ${report.softHardKm.soft.toFixed(1)} km is the candidate ATV-override recovery; ` +
      `hard ${report.softHardKm.hard.toFixed(1)} km must stay excluded; ` +
      `other ${report.softHardKm.other.toFixed(1)} km needs an explicit policy call.`
  );
  lines.push("");
  lines.push("=== STOP (ATV excluded audit only — no access-logic changes) ===");
  return lines.join("\n") + "\n";
}

async function main() {
  const geojsonseqPath = arg("--geojsonseq");
  const oplPath = arg("--opl");
  const packPath = arg("--pack");
  const outPath = arg("--out");
  const atvAudit = hasFlag("--atv-audit");
  const atvExcludedAudit = hasFlag("--atv-excluded-audit");

  if (geojsonseqPath) {
    if (!fs.existsSync(geojsonseqPath)) {
      throw new Error(`geojsonseq not found: ${geojsonseqPath}`);
    }
    if (atvExcludedAudit) {
      const report = await auditAtvExcluded(geojsonseqPath);
      process.stdout.write(printAtvExcludedAudit(report));
      if (outPath) {
        fs.mkdirSync(path.dirname(outPath), { recursive: true });
        fs.writeFileSync(outPath, JSON.stringify(report, null, 2) + "\n");
        process.stderr.write(`JSON written: ${outPath}\n`);
      }
      return;
    }
    if (atvAudit) {
      const report = await auditAtvAccess(geojsonseqPath);
      process.stdout.write(printAtvAudit(report));
      if (outPath) {
        fs.mkdirSync(path.dirname(outPath), { recursive: true });
        fs.writeFileSync(outPath, JSON.stringify(report, null, 2) + "\n");
        process.stderr.write(`JSON written: ${outPath}\n`);
      }
      return;
    }
    const leafReport = await auditLeafLengths(geojsonseqPath);
    process.stdout.write(printLeafAudit(leafReport));
    if (outPath) {
      fs.mkdirSync(path.dirname(outPath), { recursive: true });
      fs.writeFileSync(outPath, JSON.stringify(leafReport, null, 2) + "\n");
      process.stderr.write(`JSON written: ${outPath}\n`);
    }
    return;
  }

  if (!oplPath) {
    throw new Error(
      "Usage:\n" +
        "  Phase A leaf audit:\n" +
        "    audit-osm-surface-normalization.js --geojsonseq <roads.geojsonseq> [--out report.json]\n" +
        "  Phase A ATV audit:\n" +
        "    audit-osm-surface-normalization.js --geojsonseq <roads.geojsonseq> --atv-audit [--out report.json]\n" +
        "  Phase A ATV excluded (soft vs hard):\n" +
        "    audit-osm-surface-normalization.js --geojsonseq <roads.geojsonseq> --atv-excluded-audit [--out report.json]\n" +
        "  Legacy:\n" +
        "    audit-osm-surface-normalization.js --opl <roads.opl> [--pack <graph.v1.json.gz>] [--out report.json]"
    );
  }
  const raw = await loadRawWays(oplPath);
  const report = {
    generatedAt: new Date().toISOString(),
    rawOsm: raw.summary,
    packedGraph: packPath ? await auditPack(packPath, raw.ways) : null
  };
  const json = JSON.stringify(report, null, 2) + "\n";
  if (outPath) {
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
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

if (require.main === module) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  });
}

module.exports = {
  auditLeafLengths,
  auditAtvAccess,
  auditAtvExcluded,
  printLeafAudit,
  printAtvAudit,
  printAtvExcludedAudit,
  LEAF_TAGS,
  summarizeTag,
  coarseMappingToday
};