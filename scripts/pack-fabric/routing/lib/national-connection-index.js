"use strict";
// All source crossings retained. The full audit records remain in the candidate;
// this compressed projection contains exactly the fields used for live selection.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
module.exports = JSON.parse(zlib.gunzipSync(fs.readFileSync(
  path.join(__dirname, "../schema/cross-pack-topology.v2.json.gz")
)).toString("utf8"));
