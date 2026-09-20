"use strict";

// Git commits remain provenance, not a cache key: an app-only change must not
// invalidate an otherwise identical pack. Deliberately conservative tool scope;
// tests, build outputs and mobile code are not factory inputs.
const fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const { clipGeojsonPath } = require("./fetch-admin-polygon");
const ROOT = path.resolve(__dirname, "../../..");
const sha = bytes => crypto.createHash("sha256").update(bytes).digest("hex");

function fingerprint(inputs, tools) {
  const files = Object.keys(inputs).sort().map(name => ({ name, sha256: sha(inputs[name]) }));
  const runtimes = Object.fromEntries(Object.entries(tools).sort(([a], [b]) => a.localeCompare(b)));
  const recipe = { schema: "dirt-factory-recipe.v1", files, tools: runtimes };
  return { ...recipe, sha256: sha(JSON.stringify(recipe)) };
}

function version(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  if (result.error || result.status !== 0) throw new Error(`cannot identify ${command}`);
  return result.stdout.trim().split("\n")[0];
}

function factoryRecipe(regionId) {
  const inputs = {};
  function walk(relative) {
    for (const entry of fs.readdirSync(path.join(ROOT, relative), { withFileTypes: true })) {
      const name = path.join(relative, entry.name);
      if (entry.isDirectory()) walk(name);
      else if (/\.(js|sh|json|osmium|yml)$/.test(name) && !/\.test\.js$/.test(name)) {
        inputs[name] = fs.readFileSync(path.join(ROOT, name));
      }
    }
  }
  for (const dir of ["scripts/pack-fabric/scripts", "scripts/pack-fabric/routing/lib",
    "scripts/pack-fabric/routing/registry", "profiles"]) walk(dir);
  for (const file of ["package.json", "package-lock.json"]) inputs[file] = fs.readFileSync(path.join(ROOT, file));
  const polygon = clipGeojsonPath(regionId);
  if (!polygon) throw new Error(`${regionId}: missing factory polygon`);
  inputs[path.relative(ROOT, polygon)] = fs.readFileSync(polygon);
  return fingerprint(inputs, { node: process.version,
    osmium: version("osmium", ["--version"]), ogr2ogr: version("ogr2ogr", ["--version"]) });
}

module.exports = { fingerprint, factoryRecipe };
