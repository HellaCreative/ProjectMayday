"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const index = require("../schema/national-connections/index.json");
const cache = new Map();
const regions = {};
for (const id of Object.keys(index.regions)) {
  Object.defineProperty(regions, id, { enumerable: true, get() {
    let region = cache.get(id);
    if (region) cache.delete(id);
    else region = JSON.parse(zlib.gunzipSync(fs.readFileSync(
      path.join(__dirname, "../schema/national-connections", id + ".json.gz")
    )).toString("utf8"));
    cache.set(id, region);
    while (cache.size > 3) cache.delete(cache.keys().next().value);
    return region;
  }});
}
// Keep every crossing, but retain only three regions' lookup records at a time.
module.exports = { ...index, regions };
