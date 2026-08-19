#!/usr/bin/env node
"use strict";

/**
 * Tag honesty pass for BC OSM feasibility.
 * Does NOT invent surface/tracktype — flags missing attribution with data_confidence=low.
 *
 * Osmium geojsonseq is RFC 8142 (RS `\x1e`-delimited). Output is NDJSON for tippecanoe.
 *
 * Usage:
 *   node scripts/normalize-bc-osm-tags.js <in.geojsonseq> <out.geojsonseq>
 */
const fs = require("fs");
const path = require("path");

const inPath = process.argv[2];
const outPath = process.argv[3];
if (!inPath || !outPath) {
  console.error("Usage: normalize-bc-osm-tags.js <in.geojsonseq> <out.geojsonseq>");
  process.exit(1);
}

const KEEP_PROPS = new Set([
  "highway",
  "surface",
  "tracktype",
  "mtb:scale",
  "access",
  "motor_vehicle",
  "atv",
  "ohv",
  "maxwidth",
  "width",
  "trail_visibility",
  "smoothness",
  "name",
  "ref",
  "type",
  "id",
  "version",
  "timestamp",
  "@id"
]);

const RS = 0x1e;
const counts = Object.create(null);
let total = 0;
let lowConfidence = 0;

function handleRecord(text, out) {
  const chunk = text.trim();
  if (!chunk) return;
  let feat;
  try {
    feat = JSON.parse(chunk);
  } catch {
    return;
  }
  if (!feat || feat.type !== "Feature") return;
  const props = feat.properties || {};
  const highway = props.highway;
  if (!highway) return;

  total += 1;
  counts[highway] = (counts[highway] || 0) + 1;

  const kept = {};
  for (const [k, v] of Object.entries(props)) {
    if (KEEP_PROPS.has(k) || k.startsWith("mtb:")) kept[k] = v;
  }

  const hasSurface = kept.surface != null && String(kept.surface).trim() !== "";
  const hasTracktype = kept.tracktype != null && String(kept.tracktype).trim() !== "";
  if (!hasSurface && !hasTracktype) {
    kept.data_confidence = "low";
    lowConfidence += 1;
  }

  feat.properties = kept;
  out.write(JSON.stringify(feat) + "\n");
}

async function main() {
  await fs.promises.mkdir(path.dirname(outPath), { recursive: true });
  const out = fs.createWriteStream(outPath);
  const input = fs.createReadStream(inPath);
  let pending = Buffer.alloc(0);

  await new Promise((resolve, reject) => {
    input.on("data", (buf) => {
      pending = Buffer.concat([pending, buf]);
      let start = 0;
      for (let i = 0; i < pending.length; i++) {
        if (pending[i] === RS) {
          if (i > start) handleRecord(pending.slice(start, i).toString("utf8"), out);
          start = i + 1;
        }
      }
      pending = pending.slice(start);
      // Also accept NDJSON fallback: flush complete lines without RS
      if (!pending.includes(RS) && pending.includes(0x0a)) {
        const text = pending.toString("utf8");
        const lines = text.split(/\r?\n/);
        pending = Buffer.from(lines.pop() || "", "utf8");
        for (const line of lines) handleRecord(line, out);
      }
    });
    input.on("error", reject);
    input.on("end", () => {
      if (pending.length) handleRecord(pending.toString("utf8"), out);
      out.end(() => resolve());
    });
    out.on("error", reject);
  });

  const report = {
    totalFeatures: total,
    lowConfidence,
    lowConfidencePct: total ? +(100 * lowConfidence / total).toFixed(1) : 0,
    highwayCounts: Object.fromEntries(
      Object.entries(counts).sort((a, b) => b[1] - a[1])
    )
  };
  const reportPath = outPath.replace(/\.geojsonseq$/i, "") + ".normalize-report.json";
  await fs.promises.writeFile(reportPath, JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify(report, null, 2));
  console.log("Wrote", outPath);
  console.log("Report", reportPath);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
