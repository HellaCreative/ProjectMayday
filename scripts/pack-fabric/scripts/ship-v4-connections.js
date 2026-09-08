#!/usr/bin/env node
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");
const FABRIC = path.join(__dirname,"..");
const PUBLIC = "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
function sha(bytes) { return crypto.createHash("sha256").update(bytes).digest("hex"); }
function same(file, expected) {
  const data = fs.readFileSync(file);
  if (data.length !== expected.bytes || sha(data) !== expected.sha256) throw new Error(`identity mismatch: ${file}`);
  return data;
}
function plan(root) {
  const read = name => JSON.parse(fs.readFileSync(path.join(root,name)));
  const revision = read("revision.json");
  if (!/^connections-v4-\d{8}-\d+$/.test(revision.connectionRevision)) throw new Error("invalid revision");
  const source = path.join(FABRIC,"routing/candidates",revision.fabricReleaseId);
  same(path.join(source,"cross-pack-topology.v2.json"),revision.sourceTopology);
  same(path.join(root,"cross-pack-topology.v2.json"),revision.topology);
  same(path.join(root,"manifest.json"),revision.catalog);
  const catalog = read("manifest.json");
  const original = JSON.parse(fs.readFileSync(path.join(source,"manifest.json")));
  if (catalog.version !== revision.connectionRevision || catalog.fabricReleaseId !== original.fabricReleaseId || catalog.regions.length !== original.regions.length) throw new Error("catalog identity mismatch");
  const names=[];
  for (const region of catalog.regions) {
    const old = original.regions.find(r => r.id === region.id);
    if (!old || region.files.length !== old.files.length) throw new Error("region files changed");
    for (const file of region.files) {
      if (file.name !== "cross-pack-seams.v2.json") {
        if (JSON.stringify(file) !== JSON.stringify(old.files.find(f => f.name === file.name))) throw new Error(`${region.id}: immutable artifact changed`);
      } else {
        const name = `${region.id}/${file.name}`;
        const bytes = same(path.join(root,name),file);
        const sidecar = JSON.parse(bytes);
        if (sidecar.regionId !== region.id || sidecar.connectionRevision !== revision.connectionRevision || sidecar.fabricReleaseId !== revision.fabricReleaseId || sidecar.sourceEpoch !== revision.sourceEpoch) throw new Error("sidecar identity mismatch");
        names.push(name);
      }
    }
  }
  // Publish the catalog last; every referenced object is verified first.
  names.push("cross-pack-topology.v2.json","revision.json","manifest.json");
  return names.map(name => ({file:path.join(root,name),key:`v4/connections/${revision.connectionRevision}/${name}`}));
}
async function publish(items) {
  for (const item of items) {
    const bytes=fs.readFileSync(item.file), expected=sha(bytes), url=`${PUBLIC}/${item.key}`;
    const existing=await fetch(url,{cache:"no-store"});
    if (existing.ok) {
      if (sha(Buffer.from(await existing.arrayBuffer())) !== expected) throw new Error(`immutable remote revision differs: ${item.key}`);
      console.log(`verified existing ${item.key}`); continue;
    }
    if (existing.status !== 404) throw new Error(`remote preflight ${existing.status}: ${item.key}`);
    const put=spawnSync("npx",["wrangler","r2","object","put",`dirt-packs/${item.key}`,`--file=${item.file}`,"--remote"],{cwd:FABRIC,stdio:"pipe"});
    if (put.status !== 0) throw new Error(`upload failed: ${item.key}: ${String(put.stderr).slice(-600)}`);
    const response=await fetch(`${url}?verify=${expected}`,{cache:"no-store"});
    if (!response.ok || sha(Buffer.from(await response.arrayBuffer())) !== expected) throw new Error(`remote verification failed: ${item.key}`);
    console.log(`uploaded and verified ${item.key}`);
  }
}
if (require.main === module) {
  const [root,action] = process.argv.slice(2);
  if (!root || ![undefined,"--upload"].includes(action)) throw new Error("usage: ship-v4-connections.js ROOT [--upload]");
  const items=plan(path.resolve(root));
  console.log(`verified ${items.length} connection-only objects locally`);
  if (action === "--upload") publish(items).catch(e=>{console.error(e);process.exitCode=1;});
}
module.exports={plan};
