#!/usr/bin/env node
"use strict";

/**
 * Losslessly compact one sealed local V4 candidate.  This script has no upload,
 * deployment, alias, catalog-promotion, or production path.
 *
 *   node scripts/pack-fabric/scripts/compact-v4-candidate.js \
 *     --candidate fabric-v4-YYYYMMDD-NN --apply
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { OSM_REGION } = require("../routing/registry/geofabrik");
const {
  FLAG_V4_DERIVED_EDGE_IDS,
  compactGraphV4Buffer
} = require("../routing/lib/pack-v4");

const FABRIC = path.resolve(__dirname, "..");

function die(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const options = { candidate: null, root: null, apply: false };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--candidate") options.candidate = argv[++i];
    else if (value === "--root") options.root = path.resolve(argv[++i]);
    else if (value === "--apply") options.apply = true;
    else die(`unknown argument ${value}`);
  }
  if (!options.candidate || !/^fabric-v4-[0-9]{8}-[0-9]{2}$/.test(options.candidate)) {
    die("--candidate must be fabric-v4-YYYYMMDD-NN");
  }
  options.root = options.root || path.join(FABRIC, "routing", "candidates", options.candidate);
  return options;
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJSONAtomic(file, value) {
  const temp = `${file}.compact-${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2) + "\n");
  fs.renameSync(temp, file);
}

function sha256File(file) {
  const hash = crypto.createHash("sha256");
  const fd = fs.openSync(file, "r");
  const chunk = Buffer.allocUnsafe(8 * 1024 * 1024);
  try {
    for (;;) {
      const count = fs.readSync(fd, chunk, 0, chunk.length, null);
      if (!count) break;
      hash.update(chunk.subarray(0, count));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest("hex");
}

function identity(file) {
  return {
    name: path.basename(file),
    bytes: fs.statSync(file).size,
    sha256: sha256File(file)
  };
}

function sha256Buffer(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function compactGraphFile(file, apply) {
  const journalPath = `${file}.compaction-state.json`;
  const before = fs.readFileSync(file);
  const beforeBytes = before.length;
  const result = compactGraphV4Buffer(before);
  if (result.alreadyCompact && fs.existsSync(journalPath)) {
    const journal = readJSON(journalPath);
    if (journal.schema !== "dirt-v4-compaction-state.v1" ||
        journal.graphBytesAfter !== beforeBytes ||
        journal.graphSha256After !== sha256Buffer(before)) {
      die(`${file}: stale or corrupt compaction journal`);
    }
    return {
      beforeBytes: journal.graphBytesBefore,
      afterBytes: journal.graphBytesAfter,
      savedBytes: journal.savedBytes,
      alreadyCompact: true,
      journalPath
    };
  }
  if (!apply || result.alreadyCompact) {
    return {
      beforeBytes,
      afterBytes: result.graphBuffer.length,
      savedBytes: result.savedBytes,
      alreadyCompact: result.alreadyCompact,
      journalPath: null
    };
  }
  writeJSONAtomic(journalPath, {
    schema: "dirt-v4-compaction-state.v1",
    graphBytesBefore: beforeBytes,
    graphBytesAfter: result.graphBuffer.length,
    savedBytes: result.savedBytes,
    graphSha256After: sha256Buffer(result.graphBuffer)
  });
  const temp = `${file}.compact-${process.pid}`;
  fs.writeFileSync(temp, result.graphBuffer);
  const header = Buffer.alloc(140);
  const fd = fs.openSync(temp, "r");
  try {
    if (fs.readSync(fd, header, 0, header.length, 0) !== header.length) {
      die(`${file}: compact graph header is truncated`);
    }
  } finally {
    fs.closeSync(fd);
  }
  if ((header.readUInt16LE(6) & FLAG_V4_DERIVED_EDGE_IDS) === 0) {
    die(`${file}: compact graph is missing its derived-edge-id flag`);
  }
  fs.renameSync(temp, file);
  return {
    beforeBytes,
    afterBytes: result.graphBuffer.length,
    savedBytes: result.savedBytes,
    alreadyCompact: false,
    journalPath
  };
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const releasePath = path.join(options.root, "release.json");
  const release = readJSON(releasePath);
  const expected = Object.keys(OSM_REGION).sort();
  const actual = (release.regions || []).map((row) => row.id).sort();
  if (release.releaseId !== options.candidate || release.status !== "local-candidate-sealed" ||
      !release.completeFabric || JSON.stringify(actual) !== JSON.stringify(expected)) {
    die("candidate is not a sealed 63-region V4 fabric");
  }

  let totalBefore = 0;
  let totalAfter = 0;
  const rows = [];
  for (const id of expected) {
    const dir = path.join(options.root, "packs", id);
    const graphPath = path.join(dir, "graph.v4.bin");
    const manifestPath = path.join(dir, "pack-manifest.v2.json");
    const reportPath = path.join(dir, "legal-topology-report.json");
    const manifest = readJSON(manifestPath);
    const report = readJSON(reportPath);
    const outcome = compactGraphFile(graphPath, options.apply);
    totalBefore += outcome.beforeBytes;
    totalAfter += outcome.afterBytes;

    if (options.apply) {
      manifest.graph = identity(graphPath);
      report.manifest = manifest;
      const priorPackaging = report.packaging || {};
      const graphBytesBefore = outcome.savedBytes > 0
        ? outcome.beforeBytes
        : (priorPackaging.graphBytesBefore || outcome.beforeBytes);
      report.packaging = {
        schema: "dirt-v4-packaging.v1",
        edgeIdEncoding: "derived-osm-way-from-to",
        lossless: true,
        graphBytesBefore,
        graphBytesAfter: outcome.afterBytes,
        savedBytes: graphBytesBefore - outcome.afterBytes
      };
      writeJSONAtomic(manifestPath, manifest);
      writeJSONAtomic(reportPath, report);
      const releaseRegion = release.regions.find((row) => row.id === id);
      if (!releaseRegion) die(`${id}: release row is missing`);
      releaseRegion.packManifest = manifest;
      releaseRegion.legalTopologyReport = identity(reportPath);
      if (outcome.journalPath && fs.existsSync(outcome.journalPath)) {
        fs.unlinkSync(outcome.journalPath);
      }
    }
    rows.push({ id, ...outcome });
    console.log(
      `${options.apply ? "COMPACT" : "WOULD COMPACT"} ${id} ` +
      `${Math.round(outcome.beforeBytes / 1e6)}MB -> ${Math.round(outcome.afterBytes / 1e6)}MB`
    );
  }
  if (options.apply) writeJSONAtomic(releasePath, release);
  console.log(JSON.stringify({
    candidate: options.candidate,
    applied: options.apply,
    regions: rows.length,
    graphBytesBefore: totalBefore,
    graphBytesAfter: totalAfter,
    savedBytes: totalBefore - totalAfter
  }, null, 2));
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { parseArgs, compactGraphFile, main };
