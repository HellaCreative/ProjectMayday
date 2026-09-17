#!/usr/bin/env node
"use strict";

/**
 * Thin per-region cross-pack-seams.v2.json sidecars for subregion pairs.
 *
 * Full topology (tens of thousands of proofs) is retained in
 * cross-pack-topology.v2.json. Phone/runtime sidecars only need a diversified
 * handover shortlist — Swift JSONDecoder on a 36MB seam file can exhaust the
 * route wall clock before search starts.
 *
 * Usage:
 *   node scripts/pack-fabric/scripts/thin-subregion-seams.js \
 *     --topology scripts/pack-fabric/routing/candidates/fabric-v4-YYYYMMDD-NN/cross-pack-topology.v2.json \
 *     --root scripts/pack-fabric/routing/candidates/fabric-v4-YYYYMMDD-NN/packs \
 *     --pair on-s,on-n \
 *     [--max 600]
 */

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

function parseArgs(argv) {
  const opts = { topology: null, root: null, pair: null, max: 600 };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--topology") opts.topology = path.resolve(argv[++i]);
    else if (a === "--root") opts.root = path.resolve(argv[++i]);
    else if (a === "--pair") opts.pair = argv[++i];
    else if (a === "--max") opts.max = Number(argv[++i]);
    else throw new Error(`unknown argument ${a}`);
  }
  if (!opts.topology || !opts.root || !opts.pair) {
    throw new Error("Usage: thin-subregion-seams.js --topology <file> --root <packs> --pair on-s,on-n [--max 600]");
  }
  const parts = opts.pair.split(",").map((s) => s.trim()).filter(Boolean);
  if (parts.length !== 2) throw new Error("--pair needs exactly two region ids");
  if (!Number.isFinite(opts.max) || opts.max < 50) throw new Error("--max must be >= 50");
  opts.left = parts[0];
  opts.right = parts[1];
  return opts;
}

function usable(rows) {
  const filtered = rows.filter((r) => {
    const e = r.edge || {};
    return e.accessForward === 0 || e.accessForward === 1 || e.accessReverse === 0 || e.accessReverse === 1;
  });
  return filtered.length ? filtered : rows;
}

function shortlist(rows, maxKeep) {
  const pool = usable(rows);
  const grid = new Map();
  for (const row of pool) {
    const [lon, lat] = row.coordinate;
    if (lat >= 45.6 && lat <= 46.4) {
      const key = `${(Math.round(lon * 40) / 40).toFixed(3)}|${(Math.round(lat * 40) / 40).toFixed(3)}`;
      if (!grid.has(key)) grid.set(key, row);
    }
  }
  for (const row of pool) {
    const [lon, lat] = row.coordinate;
    const key = `${(Math.round(lon * 10) / 10).toFixed(1)}|${(Math.round(lat * 10) / 10).toFixed(1)}`;
    if (!grid.has(key)) grid.set(key, row);
  }
  let picked = [...grid.values()];
  if (picked.length > maxKeep) {
    picked.sort((a, b) => a.coordinate[1] - b.coordinate[1] || a.coordinate[0] - b.coordinate[0]);
    const step = picked.length / maxKeep;
    picked = Array.from({ length: maxKeep }, (_, i) => picked[Math.floor(i * step)]);
  }
  return picked;
}

function writeSidecar(root, topology, regionId, neighborId, rows) {
  const doc = {
    schemaVersion: "dirt-cross-pack-seams.v2",
    fabricReleaseId: topology.fabricReleaseId,
    sourceEpoch: topology.sourceEpoch,
    regionId,
    neighbors: { [neighborId]: rows }
  };
  const raw = `${JSON.stringify(doc, null, 2)}\n`;
  const seamPath = path.join(root, regionId, "cross-pack-seams.v2.json");
  fs.writeFileSync(seamPath, raw);
  const sha256 = crypto.createHash("sha256").update(raw).digest("hex");
  const manifestPath = path.join(root, regionId, "pack-manifest.v2.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  manifest.seams = {
    name: "cross-pack-seams.v2.json",
    bytes: Buffer.byteLength(raw),
    sha256
  };
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return { regionId, proofs: rows.length, bytes: Buffer.byteLength(raw), sha256 };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const topology = JSON.parse(fs.readFileSync(opts.topology, "utf8"));
  const leftRows = topology.regions?.[opts.left]?.neighbors?.[opts.right];
  const rightRows = topology.regions?.[opts.right]?.neighbors?.[opts.left];
  if (!Array.isArray(leftRows) || !Array.isArray(rightRows)) {
    throw new Error(`topology missing pair ${opts.left}/${opts.right}`);
  }
  const left = writeSidecar(opts.root, topology, opts.left, opts.right, shortlist(leftRows, opts.max));
  const right = writeSidecar(opts.root, topology, opts.right, opts.left, shortlist(rightRows, opts.max));
  console.log(JSON.stringify({ pair: [opts.left, opts.right], left, right }, null, 2));
}

if (require.main === module) main();

module.exports = { shortlist, parseArgs };
