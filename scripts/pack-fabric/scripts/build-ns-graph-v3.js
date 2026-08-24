#!/usr/bin/env node
"use strict";

/**
 * NS convenience wrapper around the generic v3 stamp.
 *
 *   node --max-old-space-size=8192 scripts/pack-fabric/scripts/build-ns-graph-v3.js
 *
 * Prefer the region-stamped command for any other province:
 *   node --max-old-space-size=8192 scripts/pack-fabric/scripts/build-region-graph-v3.js nb
 */
const { main } = require("./build-region-graph-v3");

main(["ns", ...process.argv.slice(2)]).catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
