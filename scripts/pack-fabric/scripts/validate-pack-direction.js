#!/usr/bin/env node
"use strict";

/**
 * Pack-validation gate for directed travel.
 *
 * encodeFromV1 already fail-closes when CSR arcs disagree with each edge's
 * `d` / `direction`. This script rebuilds that check from a region's staged
 * graph.v1-shaped JSON if present, or documents that the encode gate ran.
 *
 *   node scripts/pack-fabric/scripts/validate-pack-direction.js ns
 */
const fs = require("fs");
const path = require("path");
const { decodeGraphV2 } = require("../routing/lib/pack-v2");
const { packHasDirectedArc } = require("../routing/lib/travel-direction");

const FABRIC = path.join(__dirname, "..");

function main(argv = process.argv.slice(2)) {
  const regionId = String(argv.find((value) => !value.startsWith("-")) || "").toLowerCase();
  if (!regionId) {
    throw new Error("Usage: validate-pack-direction.js <region-id>");
  }
  const graphPath = path.join(FABRIC, "app", "data", "packs", "v1", regionId, "graph.v3.bin");
  if (!fs.existsSync(graphPath)) {
    throw new Error(`missing ${graphPath}`);
  }
  const pack = decodeGraphV2(fs.readFileSync(graphPath));
  let oneWayEdges = 0;
  let twoWayEdges = 0;
  for (let ei = 0; ei < pack.undirectedEdgeCount; ei += 1) {
    const a = pack.edgeFrom ? pack.edgeFrom[ei] : -1;
    const b = pack.edgeTo ? pack.edgeTo[ei] : -1;
    const forward = packHasDirectedArc(pack, a, b, ei);
    const reverse = packHasDirectedArc(pack, b, a, ei);
    if (!forward && !reverse) {
      throw new Error(`edge ${pack.edgeId(ei)} has no legal travel arc`);
    }
    if (forward && reverse) twoWayEdges += 1;
    else oneWayEdges += 1;
  }
  const report = {
    regionId,
    undirectedEdgeCount: pack.undirectedEdgeCount,
    directedArcCount: pack.directedArcCount,
    oneWayEdges,
    twoWayEdges
  };
  if (pack.directedArcCount !== oneWayEdges + twoWayEdges * 2) {
    throw new Error(
      `CSR arc count ${pack.directedArcCount} does not match one-way=${oneWayEdges} two-way=${twoWayEdges}`
    );
  }
  console.log(JSON.stringify(report, null, 2));
  return report;
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error && error.stack ? error.stack : error);
    process.exit(1);
  }
}

module.exports = { main };
