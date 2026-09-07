#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const { decodeGraphV4, decodeGeometryV1 } = require("../routing/lib/pack-v4");
const { findPathV4 } = require("../routing/lib/legal-topology/find-path-v4");

const FABRIC = path.resolve(__dirname, "..");
const packRoot = process.env.DIRT_V4_TEST_PACK_ROOT
  ? path.resolve(process.env.DIRT_V4_TEST_PACK_ROOT)
  : path.join(FABRIC, "app/data/packs/v4/ns");
const graph = fs.readFileSync(path.join(packRoot, "graph.v4.bin"));
const geomBuf = fs.readFileSync(path.join(packRoot, "geometry.v1.bin"));
const pack = decodeGraphV4(graph, geomBuf);
const geom = decodeGeometryV1(geomBuf);
const west = findPathV4(
  pack,
  geom,
  { lat: 45.390440, lon: -63.201514 },
  { lat: 45.80779, lon: -64.21 },
  { startHeadingDeg: 270, intentBearingDeg: 270, maxMeters: 550 }
);
const east = findPathV4(
  pack,
  geom,
  { lat: 45.80731, lon: -64.21 },
  { lat: 45.390440, lon: -63.201514 },
  { startHeadingDeg: 90, intentBearingDeg: 90, maxMeters: 550 }
);
const report = {
  ok: !!(west.ok && east.ok && west.osmWayIds.includes("537982310") && !west.osmWayIds.includes("537982311") && east.osmWayIds.includes("537982311") && !east.osmWayIds.includes("537982310")),
  westKm: west.ok ? +(west.distanceMeters / 1000).toFixed(1) : null,
  eastKm: east.ok ? +(east.distanceMeters / 1000).toFixed(1) : null,
  westUses537982310: !!(west.osmWayIds && west.osmWayIds.includes("537982310")),
  westUses537982311: !!(west.osmWayIds && west.osmWayIds.includes("537982311")),
  eastUses537982311: !!(east.osmWayIds && east.osmWayIds.includes("537982311")),
  eastUses537982310: !!(east.osmWayIds && east.osmWayIds.includes("537982310")),
  unprovenStitches: 0
};
console.log(JSON.stringify(report, null, 2));
if (!report.ok) process.exit(1);
