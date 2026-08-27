#!/usr/bin/env node
"use strict";

/**
 * Apply the approved legacy-CanVec access change to an existing frozen v3
 * graph without rebuilding or re-segmenting its topology. The independently
 * rebuilt classified graph is used only as an audited edge-id oracle.
 *
 * Usage:
 *   node scripts/pack-fabric/scripts/reclassify-legacy-canvec-v3.js \
 *     <frozen-graph.v3.bin> <classified-graph.v3.bin> <output-graph.v3.bin>
 */
const fs = require("fs");
const path = require("path");
const { decodeGraphV2, unpackAccess, unpackConfidence } = require("../routing/lib/pack-v2");

const ACCESS_MASK = 7 << 3;
const CONFIDENCE_MASK = 3 << 9;
const ACCESS_PERMISSIVE = 1;
const ACCESS_UNKNOWN = 2;
const CONFIDENCE_LOW = 2;

function reclassifiedEdgeIds(base, classified) {
  const classifiedById = new Map();
  for (let ei = 0; ei < classified.undirectedEdgeCount; ei += 1) {
    classifiedById.set(classified.edgeId(ei), classified.edgeAttrs[ei]);
  }

  const selected = [];
  for (let ei = 0; ei < base.undirectedEdgeCount; ei += 1) {
    const id = base.edgeId(ei);
    const classifiedAttr = classifiedById.get(id);
    if (classifiedAttr == null) continue;
    if (
      unpackAccess(base.edgeAttrs[ei]) === ACCESS_PERMISSIVE &&
      unpackAccess(classifiedAttr) === ACCESS_UNKNOWN &&
      unpackConfidence(classifiedAttr) === "low"
    ) {
      selected.push({ ei, id });
    }
  }
  return selected;
}

function patchedAttribute(attr) {
  return (
    (Number(attr) & ~ACCESS_MASK & ~CONFIDENCE_MASK) |
    (ACCESS_UNKNOWN << 3) |
    (CONFIDENCE_LOW << 9)
  );
}

function patchGraph(baseBuffer, classifiedBuffer) {
  const base = decodeGraphV2(baseBuffer);
  const classified = decodeGraphV2(classifiedBuffer);
  if (!base.hasLeaves || !classified.hasLeaves) {
    throw new Error("both inputs must be graph-v3 packs with leaf data");
  }
  if (base.meta.regionId !== classified.meta.regionId) {
    throw new Error(`region mismatch: ${base.meta.regionId} vs ${classified.meta.regionId}`);
  }
  const selected = reclassifiedEdgeIds(base, classified);
  if (!selected.length) throw new Error("no permissive-to-unknown CanVec edges were identified");

  const output = Buffer.from(baseBuffer);
  const attrsOffset = output.readUInt32LE(36);
  for (const { ei } of selected) {
    output.writeUInt16LE(patchedAttribute(base.edgeAttrs[ei]), attrsOffset + ei * 2);
  }

  const decoded = decodeGraphV2(output);
  let unknownEdges = 0;
  for (let ei = 0; ei < decoded.undirectedEdgeCount; ei += 1) {
    if (unpackAccess(decoded.edgeAttrs[ei]) === ACCESS_UNKNOWN) unknownEdges += 1;
  }
  return {
    output,
    changedEdges: selected.length,
    unknownEdges,
    edgeCount: decoded.undirectedEdgeCount,
    regionId: decoded.meta.regionId
  };
}

function main(argv = process.argv.slice(2)) {
  const [basePath, classifiedPath, outputPath] = argv;
  if (!basePath || !classifiedPath || !outputPath) {
    throw new Error(
      "Usage: reclassify-legacy-canvec-v3.js <frozen-graph> <classified-graph> <output-graph>"
    );
  }
  const result = patchGraph(fs.readFileSync(basePath), fs.readFileSync(classifiedPath));
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, result.output);
  console.log(JSON.stringify({
    outputPath,
    bytes: result.output.length,
    regionId: result.regionId,
    edgeCount: result.edgeCount,
    changedEdges: result.changedEdges,
    unknownEdges: result.unknownEdges
  }, null, 2));
  return result;
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { patchGraph, patchedAttribute, reclassifiedEdgeIds };
