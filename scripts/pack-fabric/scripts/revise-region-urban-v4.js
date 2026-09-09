#!/usr/bin/env node
"use strict";
const fs = require("fs"), path = require("path"), assert = require("node:assert/strict");
const { hashFile } = require("./extract-locked-place-records");
const { metadata, reviseMetadata } = require("../routing/lib/revise-v4-metadata");
const { decodeGraphV4 } = require("../routing/lib/pack-v4");
const { verifyRegion } = require("./build-v4-fabric");
const read = p => JSON.parse(fs.readFileSync(p));
const write = (p, data) => fs.writeFileSync(p, JSON.stringify(data, null, 2) + "\n");
const identity = p => ({ name: path.basename(p), bytes: fs.statSync(p).size, sha256: hashFile(p) });
const clone = (a,b) => {
  if (fs.existsSync(b)) fs.unlinkSync(b); // Only this unsealed revision's output.
  require("child_process").execFileSync("/bin/cp",["-c",a,b]);
};

function revise(oldRoot, newRoot, id, nbReviewPath) {
  const releaseId = path.basename(newRoot), src = path.join(oldRoot,"packs",id), dst = path.join(newRoot,"packs",id);
  if (fs.existsSync(path.join(dst,"metadata-revision.json"))) return read(path.join(dst,"metadata-revision.json"));
  const disk = fs.statfsSync(newRoot);
  if (disk.bavail * disk.bsize < 16 * 1024 ** 3) throw new Error("Pack working-space floor reached");
  fs.mkdirSync(dst,{recursive:true});
  const oldManifest = read(path.join(src,"pack-manifest.v2.json"));
  let oldBuffer = fs.readFileSync(path.join(src,"graph.v4.bin"));
  assert.equal(require("crypto").createHash("sha256").update(oldBuffer).digest("hex"),oldManifest.graph.sha256);
  const prior = metadata(oldBuffer), generated = read(path.join(newRoot,"place-records",id,"urban-cores.v1.json"));
  assert.equal(generated.regionId,id);
  let classification = generated, next = null, delta = 0;
  if (id === "nb") classification = read(nbReviewPath);
  const graphPath = path.join(dst,"graph.v4.bin");
  clone(path.join(src,"graph.v4.bin"), graphPath);
  if (id !== "ns") {
    next = { ...prior, urbanCores: classification.cores, settlements: classification.settlements,
      urbanClassification: { revision: classification.revision, policy: classification.policy, provenance: classification.provenance, sourceNodePassComplete: true,
        classificationSha256: hashFile(id === "nb" ? nbReviewPath : path.join(newRoot,"place-records",id,"urban-cores.v1.json")) } };
    const revised = reviseMetadata(oldBuffer,next); delta = revised.delta;
    // The cloned road prefix stays shared on APFS; write only the shifted suffix.
    const fd = fs.openSync(graphPath,"r+");
    try {
      fs.writeSync(fd,revised.buffer,0,140,0);
      const start = oldBuffer.readUInt32LE(60);
      fs.writeSync(fd,revised.buffer,start,revised.buffer.length-start,start);
      fs.ftruncateSync(fd,revised.buffer.length);
    } finally { fs.closeSync(fd); }
    const decoded = decodeGraphV4(fs.readFileSync(graphPath));
    assert.deepEqual(decoded.meta,next);
    assert.equal(decoded.nodeCount,oldBuffer.readUInt32LE(8));
    assert.equal(decoded.edgeCount,oldBuffer.readUInt32LE(12));
    assert.equal(decoded.directedArcCount,oldBuffer.readUInt32LE(16));
  }
  for(const name of ["geometry.v1.bin","fuel.v1.json"]) {
    clone(path.join(src,name),path.join(dst,name));
    const key = name.startsWith("geometry") ? "geometry" : "fuel";
    assert.deepEqual(identity(path.join(dst,name)),oldManifest[key]);
  }
  const seamSource=path.join(src,"cross-pack-seams.v2.json"), seamDest=path.join(dst,"cross-pack-seams.v2.json");
  const seamBytes=fs.readFileSync(seamSource), seams=JSON.parse(seamBytes);
  assert.equal(seams.fabricReleaseId,path.basename(oldRoot));
  assert.equal(releaseId.length,path.basename(oldRoot).length);
  const releaseAt=seamBytes.indexOf(Buffer.from(seams.fabricReleaseId));
  assert(releaseAt>0 && releaseAt<256);
  clone(seamSource,seamDest);
  const seamFd=fs.openSync(seamDest,"r+");
  try { fs.writeSync(seamFd,Buffer.from(releaseId),0,releaseId.length,releaseAt); }
  finally { fs.closeSync(seamFd); }
  const manifest = {...oldManifest,fabricReleaseId:releaseId,graph:identity(graphPath),seams:identity(path.join(dst,"cross-pack-seams.v2.json"))};
  write(path.join(dst,"pack-manifest.v2.json"),manifest);
  const report = read(path.join(src,"legal-topology-report.json"));
  report.manifest=manifest;
  report.metadataRevision={fromRelease:path.basename(oldRoot),graphBefore:oldManifest.graph,graphAfter:manifest.graph,roadAndLegalSectionsUnchanged:true,urbanClassificationSource:id==="ns"?"accepted-embedded-ns":classification.revision};
  write(path.join(dst,"legal-topology-report.json"),report);
  const riderDir=path.join(newRoot,"rider-services",id);fs.mkdirSync(riderDir,{recursive:true});
  clone(path.join(oldRoot,"rider-services",id,"rider-services.v1.json"),path.join(riderDir,"rider-services.v1.json"));
  const verified=verifyRegion({packRoot:path.join(newRoot,"packs"),riderRoot:path.join(newRoot,"rider-services")},id,releaseId,read(path.join(oldRoot,"source-lock.json")),{requireSeams:true});
  const evidence={...verified,metadataRevision:report.metadataRevision,delta,cores:id==="ns"?prior.urbanCores.length:classification.cores.length,settlements:id==="ns"?prior.settlements.length:classification.settlements.length};
  write(path.join(dst,"metadata-revision.json"),evidence);
  console.log(JSON.stringify({id,graph:manifest.graph.sha256,cores:evidence.cores,delta,roadAndLegalSectionsUnchanged:true}));
  return evidence;
}
if(require.main===module)revise(...process.argv.slice(2));
module.exports={revise};
