"use strict";
// LOCAL EXPERIMENT. Decoder adapted from routing/lib/pack-v4.js at bf8f740.
// Same legal metadata and exact IDs; typed columns become demand-read views.
// Complete immutable source hashing is a caller prerequisite. No live imports.
const fs=require('node:fs'),crypto=require('node:crypto');
const {GRAPH_V4_MAGIC,GRAPH_V4_VERSION,FLAG_V4_LEGAL_TOPOLOGY,FLAG_V4_DERIVED_EDGE_IDS,HEADER_V4,CAPABILITY,assertLegalReader,int64StringView}=require('../../routing/lib/pack-v4');
const {unpackSeasonal,unpackTracktypeCode,unpackSmoothnessCode}=require('../../routing/lib/pack-v2');
const {SURFACE_FAMILY_MAP}=require('../../routing/lib/surface-family');
const {ROAD_TIER_MAP}=require('../../routing/lib/road-tier');
const {packHasDirectedArc}=require('../../routing/lib/travel-direction');
const viewU32=(b,o)=>b.readUInt32LE(o);
const sha256Bytes=b=>crypto.createHash('sha256').update(b).digest();
function openGraph(file,maxBytes,geometrySha) {
 const fd=fs.openSync(file,'r'),size=fs.fstatSync(fd).size,pageSize=8192;
 if(!Number.isSafeInteger(maxBytes)||maxBytes<pageSize){fs.closeSync(fd);throw new TypeError('Topology byte cap must hold one page');}
 const slots=Math.floor(maxBytes/pageSize),pages=new Map(),touched=new Set();
 const stats={reads:0,bytesRead:0,hits:0,misses:0,peakResidentBytes:0,metadataBytes:0,uniquePages:0};
 function read(at,length) {
  if(!Number.isSafeInteger(at)||at<0||at+length>size)throw new Error('Truncated graph');
  const b=Buffer.allocUnsafeSlow(length);let done=0;
  while(done<length){const n=fs.readSync(fd,b,done,length-done,at+done);if(!n)throw new Error('Truncated graph');done+=n;}
  stats.reads++;stats.bytesRead+=length;return b;
 }
 function page(at) {
  const key=Math.floor(at/pageSize);let b=pages.get(key);
  if(b){pages.delete(key);pages.set(key,b);stats.hits++;}
  else {
   if(pages.size>=slots)pages.delete(pages.keys().next().value);
   b=read(key*pageSize,Math.min(pageSize,size-key*pageSize));pages.set(key,b);stats.misses++;
   touched.add(key);stats.uniquePages=touched.size;stats.peakResidentBytes=Math.max(stats.peakResidentBytes,pages.size*pageSize);
  }
  return {b,at:at%pageSize};
 }
 const types=new Map([[Int32Array,['readInt32LE',4]],[Uint32Array,['readUInt32LE',4]],[Float32Array,['readFloatLE',4]],
  [Uint16Array,['readUInt16LE',2]],[Uint8Array,['readUInt8',1]],[Int8Array,['readInt8',1]]]);
 const disk={subarray(start,end){stats.metadataBytes+=end-start;return read(start,end-start);},view(Type,offset,length) {
  const [method,width]=types.get(Type);
  if(offset%width||offset+length*width>size)throw new Error('Invalid graph column');
  const value=i=>{if(!Number.isInteger(i)||i<0||i>=length)return undefined;const p=page(offset+i*width);return p.b[method](p.at);};
  const target={length,at:i=>value(i<0?length+i:i),*[Symbol.iterator](){for(let i=0;i<length;i++)yield value(i);}};
  return new Proxy(target,{get(t,k){return typeof k==='string'&&/^(0|[1-9][0-9]*)$/.test(k)?value(Number(k)):t[k];}});
 }};
 for(const method of ['readUInt32LE','readUInt16LE','readUInt8','readInt32LE','readBigInt64LE'])disk[method]=at=>{
  const width=method==='readBigInt64LE'?8:method==='readUInt16LE'?2:method==='readUInt8'?1:4;
  if(at+width>size)throw new Error('Truncated graph');const p=page(at);
  return p.at+width<=p.b.length?p.b[method](p.at):read(at,width)[method](0);
 };
 try {if(geometrySha&&disk.subarray(disk.readUInt32LE(136),disk.readUInt32LE(136)+32).toString('hex')!==geometrySha)throw new Error('Graph/geometry mismatch');const pack=decodeGraphV4(disk);return {pack,stats,close(){fs.closeSync(fd);}};}
 catch(error){fs.closeSync(fd);throw error;}
}
function decodeGraphV4(buffer, geometryBuffer) {
  const buf = buffer;
  if (viewU32(buf, 0) !== GRAPH_V4_MAGIC) {
    throw new Error("unsupported graph version");
  }
  const version = buf.readUInt16LE(4);
  if (version !== GRAPH_V4_VERSION) {
    throw new Error("unsupported graph version " + version);
  }
  const flags = buf.readUInt16LE(6);
  if ((flags & FLAG_V4_LEGAL_TOPOLOGY) === 0) {
    throw new Error("missing required capability legal-topology.v1");
  }
  const headerSize = viewU32(buf, 20);
  if (headerSize < HEADER_V4) throw new Error("missing or corrupt restriction, barrier, or access sections");
  const nodeCount = viewU32(buf, 8);
  const undirectedEdgeCount = viewU32(buf, 12);
  const directedArcCount = viewU32(buf, 16);
  const required = [104, 108, 112, 116, 120, 124, 128, 132, 136];
  for (const off of required) {
    if (viewU32(buf, off) === 0) {
      throw new Error("missing or corrupt restriction, barrier, or access sections");
    }
  }
  const nodeOffsets = buf.view(Int32Array, viewU32(buf, 24), nodeCount + 1);
  const edgeTargets = buf.view(Int32Array, viewU32(buf, 28), directedArcCount);
  const edgeUndirectedIndex = buf.view(Int32Array, viewU32(buf, 32), directedArcCount);
  const edgeFrom = buf.view(Int32Array, viewU32(buf, 64), undirectedEdgeCount);
  const edgeTo = buf.view(Int32Array, viewU32(buf, 68), undirectedEdgeCount);
  const edgeMeters = buf.view(Uint32Array, viewU32(buf, 40), undirectedEdgeCount);
  const nodeCoords = buf.view(Float32Array, viewU32(buf, 44), nodeCount * 2);
  const edgeAccess = buf.view(Uint8Array, viewU32(buf, 112), undirectedEdgeCount * 2);
  const osmAt = viewU32(buf, 104);
  const osmNodeIds = int64StringView(buf, osmAt, nodeCount);
  const wayAt = viewU32(buf, 108);
  const osmWayIds = int64StringView(buf, wayAt, undirectedEdgeCount);
  const capabilities = JSON.parse(buf.subarray(viewU32(buf, 132), viewU32(buf, 136)).toString("utf8"));
  if (!capabilities.includes(CAPABILITY)) {
    throw new Error("missing required capability legal-topology.v1");
  }
  const provenance = JSON.parse(buf.subarray(viewU32(buf, 128), viewU32(buf, 132)).toString("utf8"));
  const geometrySha = buf.subarray(viewU32(buf, 136), viewU32(buf, 136) + 32);
  if (geometryBuffer) {
    const got = sha256Bytes(geometryBuffer);
    if (!got.equals(geometrySha)) throw new Error("graph/geometry identity mismatch");
  }
  const barrierAt = viewU32(buf, 116);
  const barrierCount = viewU32(buf, barrierAt);
  const barriers = [];
  for (let i = 0; i < barrierCount; i += 1) {
    const at = barrierAt + 4 + i * 16;
    barriers.push({
      osmNodeId: buf.readBigInt64LE(at).toString(),
      graphNode: viewU32(buf, at + 8),
      decisionCode: buf.readUInt8(at + 12)
    });
  }
  const restAt = viewU32(buf, 120);
  const restCount = viewU32(buf, restAt);
  const restrictions = [];
  let cursor = restAt + 4;
  for (let i = 0; i < restCount; i += 1) {
    const viaWayCount = buf.readUInt16LE(cursor + 10);
    const viaWayIds = [];
    const viaEdges = [];
    for (let v = 0; v < viaWayCount; v += 1) {
      viaWayIds.push(buf.readBigInt64LE(cursor + 32 + v * 12).toString());
      viaEdges.push(buf.readInt32LE(cursor + 32 + v * 12 + 8));
    }
    restrictions.push({
      osmRelationId: buf.readBigInt64LE(cursor).toString(),
      kind: buf.readUInt8(cursor + 8),
      fromEdge: viewU32(buf, cursor + 12),
      toEdge: viewU32(buf, cursor + 16),
      viaNode: buf.readInt32LE(cursor + 20),
      only: (buf.readUInt8(cursor + 9) & 2) !== 0,
      vehicleMask: buf.readUInt16LE(cursor + 26),
      viaWayIds,
      viaEdges: viaEdges.filter((id) => id >= 0)
    });
    cursor += 32 + viaWayCount * 12;
  }
  const derivesEdgeIds = (flags & FLAG_V4_DERIVED_EDGE_IDS) !== 0;
  const idOffsets = derivesEdgeIds
    ? null
    : buf.view(Int32Array, viewU32(buf, 48), undirectedEdgeCount + 1);
  const idBlob = derivesEdgeIds ? null : buf.subarray(viewU32(buf, 52), viewU32(buf, 56));
  function edgeId(ei) {
    if (ei < 0 || ei >= undirectedEdgeCount) return "";
    if (derivesEdgeIds) return `w${osmWayIds[ei]}:${edgeFrom[ei]}:${edgeTo[ei]}`;
    return idBlob.toString("utf8", idOffsets[ei], idOffsets[ei + 1]);
  }
  const edgeAttrs = buf.view(Uint16Array, viewU32(buf, 36), undirectedEdgeCount);
  const enums = JSON.parse(buf.subarray(viewU32(buf, 56), viewU32(buf, 60)).toString("utf8") || "{}");
  const meta = JSON.parse(buf.subarray(viewU32(buf, 60), viewU32(buf, 72)).toString("utf8") || "{}");
  const edgeSurfaceLeaf = buf.view(Uint8Array, viewU32(buf, 72), undirectedEdgeCount);
  const edgeRoadClassLeaf = buf.view(Uint8Array, viewU32(buf, 76), undirectedEdgeCount);
  const edgeGrade = buf.view(Uint8Array, viewU32(buf, 80), undirectedEdgeCount);
  const edgeLayer = buf.view(Int8Array, viewU32(buf, 84), undirectedEdgeCount);
  const edgeStructureLeaf = buf.view(Uint8Array, viewU32(buf, 88), undirectedEdgeCount);
  const edgeAccessLeaf = buf.view(Uint8Array, viewU32(buf, 92), undirectedEdgeCount);
  const edgeFlagBytes = buf.view(Uint8Array, viewU32(buf, 96), undirectedEdgeCount);
  const edgeCrossingSeconds = buf.view(Uint32Array, viewU32(buf, 100), undirectedEdgeCount);
  const TRACKTYPE_NAME = { 0: null, 1: "grade1", 2: "grade2", 3: "grade3", 4: "grade4", 5: "grade5" };
  const SMOOTHNESS_NAME = {
    0: null,
    1: "excellent",
    2: "good",
    3: "intermediate",
    4: "bad",
    5: "very_bad",
    6: "horrible",
    7: "very_horrible",
    8: "impassable"
  };
  const surfaceLeafNames = enums.surfaceLeafNames || [""];
  const roadClassLeafNames = enums.roadClassLeafNames || ["unknown"];
  const structureLeafNames = enums.structureLeafNames || [""];
  const accessLeafNames = enums.accessLeafNames || [""];
  function nameAt(names, idx, fallback) {
    if (idx == null || idx < 0 || idx >= names.length) return fallback;
    const v = names[idx];
    return v == null || v === "" ? fallback : v;
  }
  function edgeLeaves(ei) {
    const grade = edgeGrade[ei];
    return {
      surfaceLeaf: edgeSurfaceLeaf[ei] === 0 ? null : nameAt(surfaceLeafNames, edgeSurfaceLeaf[ei], null),
      roadClassLeaf: nameAt(roadClassLeafNames, edgeRoadClassLeaf[ei], "unknown"),
      tracktype: TRACKTYPE_NAME[unpackTracktypeCode(grade)] || null,
      smoothness: SMOOTHNESS_NAME[unpackSmoothnessCode(grade)] || null,
      layer: edgeLayer[ei],
      structureLeaf: edgeStructureLeaf[ei] === 0
        ? null
        : nameAt(structureLeafNames, edgeStructureLeaf[ei], null),
      accessLeaf: edgeAccessLeaf[ei] === 0 ? null : nameAt(accessLeafNames, edgeAccessLeaf[ei], null),
      atvDesignated: (edgeFlagBytes[ei] & 1) !== 0,
      seasonal: (edgeFlagBytes[ei] & 2) !== 0 || unpackSeasonal(edgeAttrs[ei]),
      fromLeaves: true
    };
  }
  function crossingSeconds(ei) {
    if (ei < 0 || ei >= undirectedEdgeCount) return 0;
    return edgeCrossingSeconds[ei] || 0;
  }
  const pack = {
    format: "v3",
    version: GRAPH_V4_VERSION,
    graphBinaryVersion: GRAPH_V4_VERSION,
    hasLeaves: true,
    hasCrossingSeconds: true,
    capabilities,
    provenance,
    enums,
    meta,
    regionId: meta.regionId || provenance.regionId || null,
    province: meta.province || provenance.regionId || null,
    surfaceFamilyMap: enums.surfaceFamilyMap || SURFACE_FAMILY_MAP,
    roadTierMap: enums.roadTierMap || ROAD_TIER_MAP,
    nodeCount,
    undirectedEdgeCount,
    directedArcCount,
    edgeCount: undirectedEdgeCount,
    nodeOffsets,
    edgeTargets,
    edgeUndirectedIndex,
    edgeAttrs,
    edgeFrom,
    edgeTo,
    edgeMeters,
    nodeCoords,
    edgeAccess,
    edgeSurfaceLeaf,
    edgeRoadClassLeaf,
    edgeGrade,
    edgeLayer,
    edgeStructureLeaf,
    edgeAccessLeaf,
    edgeFlags: edgeFlagBytes,
    edgeCrossingSeconds,
    crossingSeconds,
    edgeLeaves,
    osmNodeIds,
    osmWayIds,
    barriers,
    restrictions,
    barriersSection: barriers,
    restrictionsSection: restrictions,
    edgeId,
    hasDirectedArc(from, to, ei) {
      return packHasDirectedArc(pack, from, to, ei);
    }
  };
  assertLegalReader(pack);
  return pack;
}

module.exports={openGraph};
