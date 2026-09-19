"use strict";

const crypto = require("crypto");
const {
  GEOM_MAGIC,
  GEOM_VERSION,
  packAttrs,
  packGrade,
  buildLeafDictionary,
  decodeGeometryV1,
  unpackSeasonal,
  unpackTracktypeCode,
  unpackSmoothnessCode
} = require("./pack-v2");
const { SURFACE_FAMILY_MAP } = require("./surface-family");
const { ROAD_TIER_MAP } = require("./road-tier");
const { packHasDirectedArc } = require("./travel-direction");

const GRAPH_V4_MAGIC = 0x34545244;
const GRAPH_V4_VERSION = 4;
const HEADER_V4 = 140;
const FLAG_EDGE_FROM_TO = 1;
const FLAG_V3_LEAVES = 2;
const FLAG_V3_CROSSING_SECONDS = 4;
const FLAG_V4_LEGAL_TOPOLOGY = 8;
// V4 already stores the exact OSM way id and both endpoint indexes for every
// edge.  Persisting `w<way>:<from>:<to>` a second time as UTF-8 costs hundreds
// of megabytes in large regions without adding information.  New V4 writers
// derive that stable id at read time; readers remain compatible with the
// original, explicit-string layout.
const FLAG_V4_DERIVED_EDGE_IDS = 16;
const CAPABILITY = "legal-topology.v1";

function sha256(buf) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

function sha256Bytes(buf) {
  return crypto.createHash("sha256").update(buf).digest();
}

function assertLegalReader(pack) {
  if (!pack || pack.graphBinaryVersion !== GRAPH_V4_VERSION) {
    throw new Error("unsupported graph version");
  }
  if (!pack.capabilities || !pack.capabilities.includes(CAPABILITY)) {
    throw new Error("missing required capability legal-topology.v1");
  }
  if (!pack.restrictionsSection || !pack.barriersSection || !pack.edgeAccess) {
    throw new Error("missing or corrupt restriction, barrier, or access sections");
  }
}

function encodeGeometry(edges, { includeSpatialGrid = true } = {}) {
  const undirectedEdgeCount = edges.length;
  const geomOffsets = new Uint32Array(undirectedEdgeCount + 1);
  const coordChunks = [];
  let coordCount = 0;
  for (let ei = 0; ei < undirectedEdgeCount; ei += 1) {
    geomOffsets[ei] = coordCount;
    const coords = edges[ei].coords || [];
    for (const c of coords) {
      coordChunks.push(Number(c[0]), Number(c[1]));
      coordCount += 2;
    }
  }
  geomOffsets[undirectedEdgeCount] = coordCount;
  const geomCoords = Float32Array.from(coordChunks);
  const geomHeaderSize = 16;
  let geomCoordsAt = geomHeaderSize + geomOffsets.byteLength;
  if (geomCoordsAt % 4 !== 0) geomCoordsAt += 4 - (geomCoordsAt % 4);
  const gridAt = geomCoordsAt + geomCoords.byteLength;
  const geomBuffer = Buffer.alloc(gridAt + (includeSpatialGrid ? undirectedEdgeCount * 8 : 0));
  geomBuffer.writeUInt32LE(GEOM_MAGIC, 0);
  geomBuffer.writeUInt16LE(GEOM_VERSION, 4);
  // Optional exact preparation table, geometry.v1 flag bit 1. Existing readers
  // still read the same coordinates; new readers avoid decoding every polyline
  // just to recover its 0.05-degree matching-grid bounds. Hash covers the table.
  geomBuffer.writeUInt16LE(includeSpatialGrid ? 2 : 0, 6);
  geomBuffer.writeUInt32LE(undirectedEdgeCount, 8);
  geomBuffer.writeUInt32LE(coordCount, 12);
  Buffer.from(geomOffsets.buffer, geomOffsets.byteOffset, geomOffsets.byteLength).copy(geomBuffer, geomHeaderSize);
  Buffer.from(geomCoords.buffer, geomCoords.byteOffset, geomCoords.byteLength).copy(geomBuffer, geomCoordsAt);
  if (includeSpatialGrid) {
    for (let edge = 0; edge < undirectedEdgeCount; edge++) {
      let x0 = 32767, x1 = -32768, y0 = 32767, y1 = -32768;
      for (let i = geomOffsets[edge]; i < geomOffsets[edge+1]; i += 2) {
        const lon = geomCoords[i], lat = geomCoords[i+1];
        if (!Number.isFinite(lon) || !Number.isFinite(lat) || Math.abs(lon) > 180 || Math.abs(lat) > 90)
          throw new Error(`invalid geometry coordinate on edge ${edge}`);
        // Derive from the stored Float32 values, not higher precision inputs.
        const x = Math.floor(lon / 0.05), y = Math.floor(lat / 0.05);
        x0 = Math.min(x0,x); x1 = Math.max(x1,x); y0 = Math.min(y0,y); y1 = Math.max(y1,y);
      }
      [x0,x1,y0,y1].forEach((value,i) => geomBuffer.writeInt16LE(value,gridAt + edge*8 + i*2));
    }
  }
  return geomBuffer;
}

function traversable(code) {
  return code === 0 || code === 1 || code === 3 || code === 4;
}

function encodeGraphV4(graph, provenance, geometryBuffer) {
  if (graph.restrictionRepairs && graph.restrictionRepairs.length) provenance = { ...provenance, restrictionRepairs: graph.restrictionRepairs };
  const nodes = graph.nodes || [];
  const edges = graph.edges || [];
  const nodeCount = nodes.length;
  const undirectedEdgeCount = edges.length;
  const degree = new Int32Array(nodeCount);
  for (let ei = 0; ei < undirectedEdgeCount; ei += 1) {
    const e = edges[ei];
    if (e.from >= 0 && e.from < nodeCount && traversable(e.accessForward)) degree[e.from] += 1;
    if (e.to >= 0 && e.to < nodeCount && traversable(e.accessReverse)) degree[e.to] += 1;
  }
  const nodeOff = new Int32Array(nodeCount + 1);
  for (let i = 0; i < nodeCount; i += 1) nodeOff[i + 1] = nodeOff[i] + degree[i];
  const directedArcCount = nodeOff[nodeCount];
  const targets = new Int32Array(directedArcCount);
  const undirected = new Int32Array(directedArcCount);
  const cursor = Int32Array.from(nodeOff);
  for (let ei = 0; ei < undirectedEdgeCount; ei += 1) {
    const e = edges[ei];
    if (e.from >= 0 && e.from < nodeCount && traversable(e.accessForward)) {
      const slot = cursor[e.from]++;
      targets[slot] = e.to;
      undirected[slot] = ei;
    }
    if (e.to >= 0 && e.to < nodeCount && traversable(e.accessReverse)) {
      const slot = cursor[e.to]++;
      targets[slot] = e.from;
      undirected[slot] = ei;
    }
  }
  const edgeFrom = new Int32Array(undirectedEdgeCount);
  const edgeTo = new Int32Array(undirectedEdgeCount);
  const edgeMeters = new Uint32Array(undirectedEdgeCount);
  const edgeAttrs = new Uint16Array(undirectedEdgeCount);
  const edgeAccess = Buffer.alloc(undirectedEdgeCount * 2);
  const osmWayIds = Buffer.alloc(undirectedEdgeCount * 8);
  const surfaceDict = buildLeafDictionary(
    edges.map((e) => e.surfaceLeaf),
    "",
    "surfaceLeafNames"
  );
  const roadClassDict = buildLeafDictionary(
    edges.map((e) => (e.roadClassLeaf == null || e.roadClassLeaf === "" ? "unknown" : e.roadClassLeaf)),
    "unknown",
    "roadClassLeafNames"
  );
  const structureDict = buildLeafDictionary(
    edges.map((e) => e.structureLeaf),
    "",
    "structureLeafNames"
  );
  const accessDict = buildLeafDictionary(
    edges.map((e) => e.accessLeaf),
    "",
    "accessLeafNames"
  );
  const edgeSurfaceLeaf = new Uint8Array(undirectedEdgeCount);
  const edgeRoadClassLeaf = new Uint8Array(undirectedEdgeCount);
  const edgeGrade = new Uint8Array(undirectedEdgeCount);
  const edgeLayer = new Int8Array(undirectedEdgeCount);
  const edgeStructureLeaf = new Uint8Array(undirectedEdgeCount);
  const edgeAccessLeaf = new Uint8Array(undirectedEdgeCount);
  const edgeFlagBytes = new Uint8Array(undirectedEdgeCount);
  const crossing = new Uint32Array(undirectedEdgeCount);
  function leafIndex(indexMap, value, sentinel) {
    if (value == null) return 0;
    const key = String(value).trim().toLowerCase();
    if (!key || key === sentinel) return 0;
    const at = indexMap.get(key);
    return at != null ? at : 0;
  }
  for (let ei = 0; ei < undirectedEdgeCount; ei += 1) {
    const e = edges[ei];
    edgeFrom[ei] = e.from;
    edgeTo[ei] = e.to;
    edgeMeters[ei] = Math.max(1, Math.round(e.meters || 1));
    edgeAttrs[ei] = packAttrs({
      s: e.s != null ? e.s : 4,
      ac: e.ac != null ? e.ac : e.accessForward === 0 ? 1 : e.accessForward === 2 ? 4 : 2,
      t: e.t != null ? e.t : e.grade === "bridge" ? 1 : e.grade === "tunnel" ? 2 : 0,
      conf: e.conf || "medium",
      seasonal: e.seasonal,
      rt: e.rt || e.highway || "unknown"
    });
    edgeSurfaceLeaf[ei] = leafIndex(surfaceDict.index, e.surfaceLeaf, "");
    edgeRoadClassLeaf[ei] = leafIndex(
      roadClassDict.index,
      e.roadClassLeaf == null || e.roadClassLeaf === "" ? "unknown" : e.roadClassLeaf,
      "unknown"
    );
    edgeGrade[ei] = packGrade(e.tracktype, e.smoothness);
    const layerN = Number(e.layer);
    edgeLayer[ei] = Number.isFinite(layerN) ? Math.max(-128, Math.min(127, Math.trunc(layerN))) : 0;
    edgeStructureLeaf[ei] = leafIndex(structureDict.index, e.structureLeaf, "");
    edgeAccessLeaf[ei] = leafIndex(accessDict.index, e.accessLeaf, "");
    let flagsByte = 0;
    if (e.atvDesignated) flagsByte |= 1;
    if (e.seasonal) flagsByte |= 2;
    edgeFlagBytes[ei] = flagsByte;
    const xs = Number(e.xs) || 0;
    crossing[ei] = xs > 0 ? Math.min(0xffffffff, Math.round(xs)) : 0;
    edgeAccess[ei * 2] = e.accessForward;
    edgeAccess[ei * 2 + 1] = e.accessReverse;
    osmWayIds.writeBigInt64LE(BigInt(e.osmWayId || 0), ei * 8);
  }
  // Retain one aligned sentinel so the legacy section offsets remain valid,
  // while omitting the redundant (edgeCount + 1) offsets and UTF-8 blob.
  const idOffsets = new Int32Array(1);
  const idBlob = Buffer.alloc(0);

  const nodeCoords = new Float32Array(nodeCount * 2);
  const osmNodeIds = Buffer.alloc(nodeCount * 8);
  for (let i = 0; i < nodeCount; i += 1) {
    nodeCoords[i * 2] = nodes[i].lon;
    nodeCoords[i * 2 + 1] = nodes[i].lat;
    osmNodeIds.writeBigInt64LE(BigInt(nodes[i].osmNodeId || 0), i * 8);
  }

  const barriers = graph.barriers || [];
  const barrierBuf = Buffer.alloc(4 + barriers.length * 16);
  barrierBuf.writeUInt32LE(barriers.length, 0);
  for (let i = 0; i < barriers.length; i += 1) {
    const at = 4 + i * 16;
    barrierBuf.writeBigInt64LE(BigInt(barriers[i].osmNodeId || 0), at);
    barrierBuf.writeUInt32LE(barriers[i].graphNode || 0, at + 8);
    barrierBuf.writeUInt8(barriers[i].decisionCode || 0, at + 12);
  }

  const restrictions = graph.restrictions || [];
  const restChunks = [Buffer.alloc(4)];
  restChunks[0].writeUInt32LE(restrictions.length, 0);
  for (const r of restrictions) {
    const viaWays = r.viaWayIds || [];
    const viaEdges = r.viaEdges || [];
    if (viaWays.length !== viaEdges.length) {
      throw new Error(`restriction ${r.osmRelationId || "unknown"} has mismatched via-way/edge sequence`);
    }
    const rec = Buffer.alloc(32 + viaWays.length * 12);
    rec.writeBigInt64LE(BigInt(r.osmRelationId || 0), 0);
    rec.writeUInt8(r.kind || 0, 8);
    rec.writeUInt8(r.only ? 2 : 0, 9);
    rec.writeUInt16LE(viaWays.length, 10);
    rec.writeUInt32LE(r.fromEdge || 0, 12);
    rec.writeUInt32LE(r.toEdge || 0, 16);
    rec.writeInt32LE(r.viaNode == null ? -1 : r.viaNode, 20);
    rec.writeUInt16LE(0, 24);
    rec.writeUInt16LE(r.vehicleMask || 7, 26);
    rec.writeInt32LE(-1, 28);
    let o = 32;
    for (let i = 0; i < viaWays.length; i += 1) {
      rec.writeBigInt64LE(BigInt(viaWays[i] || 0), o);
      rec.writeInt32LE(viaEdges[i] != null ? viaEdges[i] : -1, o + 8);
      o += 12;
    }
    restChunks.push(rec);
  }
  const restrictionBuf = Buffer.concat(restChunks);

  const conditionals = Buffer.from(
    JSON.stringify({
      rules: graph.conditionals || provenance.conditionals || [],
      timezone: graph.timezone || provenance.timezone || "UTC",
      policy: "fail_closed"
    }),
    "utf8"
  );
  const capabilities = Buffer.from(JSON.stringify([CAPABILITY]), "utf8");
  const provenanceJson = Buffer.from(
    JSON.stringify({
      ...provenance,
      conditionals: graph.conditionals || provenance.conditionals || [],
      unprovenStitches: 0,
      rejected: graph.rejected || []
    }),
    "utf8"
  );
  const geometrySha = geometryBuffer ? sha256Bytes(geometryBuffer) : Buffer.alloc(32);
  const enumsJson = Buffer.from(
    JSON.stringify({
      legalTopology: CAPABILITY,
      SURFACE_NAME: { 0: "paved", 1: "gravel", 2: "access", 3: "track", 4: "unknown" },
      ACCESS_NAME: {
        0: "motorized_verified",
        1: "motorized_permissive",
        2: "motorized_unknown",
        3: "motorized_restricted",
        4: "motorized_excluded"
      },
      STRUCTURE_NAME: {
        0: "none",
        1: "bridge",
        2: "tunnel",
        3: "ford",
        4: "ferry",
        5: "blocked_passage",
        6: "unknown"
      },
      surfaceLeafNames: surfaceDict.names,
      roadClassLeafNames: roadClassDict.names,
      structureLeafNames: structureDict.names,
      accessLeafNames: accessDict.names,
      surfaceFamilyMap: { ...SURFACE_FAMILY_MAP },
      roadTierMap: { ...ROAD_TIER_MAP }
    }),
    "utf8"
  );
  const metaJson = Buffer.from(
    JSON.stringify({
      regionId: provenance.regionId || null,
      province: provenance.regionId || null,
      graphBinaryVersion: GRAPH_V4_VERSION,
      capabilities: [CAPABILITY],
      urbanCores: provenance.urbanCores || null,
      settlements: provenance.settlements || null,
      bbox: provenance.bbox || null
    }),
    "utf8"
  );

  let offset = HEADER_V4;
  const sections = {};
  function place(name, len, align) {
    if (align > 1) offset = Math.ceil(offset / align) * align;
    sections[name] = offset;
    offset += len;
    return sections[name];
  }
  place("nodeOffsets", nodeOff.byteLength, 4);
  place("edgeTargets", targets.byteLength, 4);
  place("edgeUndirectedIndex", undirected.byteLength, 4);
  place("edgeAttrs", edgeAttrs.byteLength, 2);
  place("edgeMeters", edgeMeters.byteLength, 4);
  place("edgeFrom", edgeFrom.byteLength, 4);
  place("edgeTo", edgeTo.byteLength, 4);
  place("nodeCoords", nodeCoords.byteLength, 4);
  place("idOffsets", idOffsets.byteLength, 4);
  place("idBlob", idBlob.length, 1);
  place("enumsJson", enumsJson.length, 1);
  place("metaJson", metaJson.length, 1);
  place("edgeSurfaceLeaf", edgeSurfaceLeaf.length, 1);
  place("edgeRoadClassLeaf", edgeRoadClassLeaf.length, 1);
  place("edgeGrade", edgeGrade.length, 1);
  place("edgeLayer", edgeLayer.byteLength, 1);
  place("edgeStructureLeaf", edgeStructureLeaf.length, 1);
  place("edgeAccessLeaf", edgeAccessLeaf.length, 1);
  place("edgeFlags", edgeFlagBytes.length, 1);
  place("edgeCrossingSeconds", crossing.byteLength, 4);
  place("osmNodeIds", osmNodeIds.length, 8);
  place("osmWayIds", osmWayIds.length, 8);
  place("edgeAccess", edgeAccess.length, 1);
  place("barriers", barrierBuf.length, 4);
  place("restrictions", restrictionBuf.length, 4);
  place("conditionals", conditionals.length, 1);
  place("provenanceJson", provenanceJson.length, 1);
  place("capabilitiesJson", capabilities.length, 1);
  place("geometrySha256", 32, 1);

  const graphBuffer = Buffer.alloc(offset);
  graphBuffer.writeUInt32LE(GRAPH_V4_MAGIC, 0);
  graphBuffer.writeUInt16LE(GRAPH_V4_VERSION, 4);
  graphBuffer.writeUInt16LE(
    FLAG_EDGE_FROM_TO | FLAG_V3_LEAVES | FLAG_V3_CROSSING_SECONDS |
      FLAG_V4_LEGAL_TOPOLOGY | FLAG_V4_DERIVED_EDGE_IDS,
    6
  );
  graphBuffer.writeUInt32LE(nodeCount, 8);
  graphBuffer.writeUInt32LE(undirectedEdgeCount, 12);
  graphBuffer.writeUInt32LE(directedArcCount, 16);
  graphBuffer.writeUInt32LE(HEADER_V4, 20);
  graphBuffer.writeUInt32LE(sections.nodeOffsets, 24);
  graphBuffer.writeUInt32LE(sections.edgeTargets, 28);
  graphBuffer.writeUInt32LE(sections.edgeUndirectedIndex, 32);
  graphBuffer.writeUInt32LE(sections.edgeAttrs, 36);
  graphBuffer.writeUInt32LE(sections.edgeMeters, 40);
  graphBuffer.writeUInt32LE(sections.nodeCoords, 44);
  graphBuffer.writeUInt32LE(sections.idOffsets, 48);
  graphBuffer.writeUInt32LE(sections.idBlob, 52);
  graphBuffer.writeUInt32LE(sections.enumsJson, 56);
  graphBuffer.writeUInt32LE(sections.metaJson, 60);
  graphBuffer.writeUInt32LE(sections.edgeFrom, 64);
  graphBuffer.writeUInt32LE(sections.edgeTo, 68);
  graphBuffer.writeUInt32LE(sections.edgeSurfaceLeaf, 72);
  graphBuffer.writeUInt32LE(sections.edgeRoadClassLeaf, 76);
  graphBuffer.writeUInt32LE(sections.edgeGrade, 80);
  graphBuffer.writeUInt32LE(sections.edgeLayer, 84);
  graphBuffer.writeUInt32LE(sections.edgeStructureLeaf, 88);
  graphBuffer.writeUInt32LE(sections.edgeAccessLeaf, 92);
  graphBuffer.writeUInt32LE(sections.edgeFlags, 96);
  graphBuffer.writeUInt32LE(sections.edgeCrossingSeconds, 100);
  graphBuffer.writeUInt32LE(sections.osmNodeIds, 104);
  graphBuffer.writeUInt32LE(sections.osmWayIds, 108);
  graphBuffer.writeUInt32LE(sections.edgeAccess, 112);
  graphBuffer.writeUInt32LE(sections.barriers, 116);
  graphBuffer.writeUInt32LE(sections.restrictions, 120);
  graphBuffer.writeUInt32LE(sections.conditionals, 124);
  graphBuffer.writeUInt32LE(sections.provenanceJson, 128);
  graphBuffer.writeUInt32LE(sections.capabilitiesJson, 132);
  graphBuffer.writeUInt32LE(sections.geometrySha256, 136);

  function copy(buf, at) {
    if (Buffer.isBuffer(buf)) buf.copy(graphBuffer, at);
    else Buffer.from(buf.buffer, buf.byteOffset, buf.byteLength).copy(graphBuffer, at);
  }
  copy(nodeOff, sections.nodeOffsets);
  copy(targets, sections.edgeTargets);
  copy(undirected, sections.edgeUndirectedIndex);
  copy(edgeAttrs, sections.edgeAttrs);
  copy(edgeMeters, sections.edgeMeters);
  copy(edgeFrom, sections.edgeFrom);
  copy(edgeTo, sections.edgeTo);
  copy(nodeCoords, sections.nodeCoords);
  copy(idOffsets, sections.idOffsets);
  idBlob.copy(graphBuffer, sections.idBlob);
  enumsJson.copy(graphBuffer, sections.enumsJson);
  metaJson.copy(graphBuffer, sections.metaJson);
  copy(edgeSurfaceLeaf, sections.edgeSurfaceLeaf);
  copy(edgeRoadClassLeaf, sections.edgeRoadClassLeaf);
  copy(edgeGrade, sections.edgeGrade);
  copy(edgeLayer, sections.edgeLayer);
  copy(edgeStructureLeaf, sections.edgeStructureLeaf);
  copy(edgeAccessLeaf, sections.edgeAccessLeaf);
  copy(edgeFlagBytes, sections.edgeFlags);
  copy(crossing, sections.edgeCrossingSeconds);
  osmNodeIds.copy(graphBuffer, sections.osmNodeIds);
  osmWayIds.copy(graphBuffer, sections.osmWayIds);
  edgeAccess.copy(graphBuffer, sections.edgeAccess);
  barrierBuf.copy(graphBuffer, sections.barriers);
  restrictionBuf.copy(graphBuffer, sections.restrictions);
  conditionals.copy(graphBuffer, sections.conditionals);
  provenanceJson.copy(graphBuffer, sections.provenanceJson);
  capabilities.copy(graphBuffer, sections.capabilitiesJson);
  geometrySha.copy(graphBuffer, sections.geometrySha256);

  return {
    graphBuffer,
    meta: {
      nodeCount,
      undirectedEdgeCount,
      directedArcCount,
      graphBytes: graphBuffer.length,
      graphSha256: sha256(graphBuffer),
      geometrySha256: geometryBuffer ? sha256(geometryBuffer) : null
    }
  };
}

function viewU32(buf, offset) {
  return buf.readUInt32LE(offset);
}

/**
 * Array-like, lazy string view over packed signed Int64 OSM ids. Large regions
 * contain millions of repeated way ids; eagerly materializing each one as a JS
 * string can consume more memory than the graph binary itself.
 */
class Int64StringView {
  constructor(buffer, offset, length) {
    this.buffer = buffer;
    this.offset = offset;
    this.length = length;
  }

  valueAt(index) {
    if (!Number.isInteger(index) || index < 0 || index >= this.length) return undefined;
    return this.buffer.readBigInt64LE(this.offset + index * 8).toString();
  }

  at(index) {
    const normalized = index < 0 ? this.length + index : index;
    return this.valueAt(normalized);
  }

  includes(value, fromIndex = 0) {
    if (typeof value !== "string") return false;
    let start = Math.trunc(fromIndex);
    if (start < 0) start = Math.max(0, this.length + start);
    for (let i = start; i < this.length; i += 1) {
      if (this.valueAt(i) === value) return true;
    }
    return false;
  }

  findIndex(predicate, thisArg) {
    for (let i = 0; i < this.length; i += 1) {
      if (predicate.call(thisArg, this.valueAt(i), i, this)) return i;
    }
    return -1;
  }

  map(callback, thisArg) {
    const out = new Array(this.length);
    for (let i = 0; i < this.length; i += 1) {
      out[i] = callback.call(thisArg, this.valueAt(i), i, this);
    }
    return out;
  }

  *[Symbol.iterator]() {
    for (let i = 0; i < this.length; i += 1) yield this.valueAt(i);
  }
}

function int64StringView(buffer, offset, length) {
  const target = new Int64StringView(buffer, offset, length);
  return new Proxy(target, {
    get(view, property, receiver) {
      if (typeof property === "string" && /^(0|[1-9][0-9]*)$/.test(property)) {
        return view.valueAt(Number(property));
      }
      return Reflect.get(view, property, receiver);
    }
  });
}

/**
 * Losslessly remove the original V4 edge-id string table.  Edge identity is
 * exactly reproducible from the already-packed OSM way id and endpoints.  The
 * suffix shift is kept four-byte aligned so every typed-array section retains
 * its required alignment.
 */
function compactGraphV4Buffer(buffer) {
  const buf = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
  if (viewU32(buf, 0) !== GRAPH_V4_MAGIC || buf.readUInt16LE(4) !== GRAPH_V4_VERSION) {
    throw new Error("unsupported graph version");
  }
  const flags = buf.readUInt16LE(6);
  if ((flags & FLAG_V4_DERIVED_EDGE_IDS) !== 0) {
    return { graphBuffer: buf, savedBytes: 0, alreadyCompact: true };
  }
  const edgeCount = viewU32(buf, 12);
  const idOffsetsAt = viewU32(buf, 48);
  const idBlobAt = viewU32(buf, 52);
  const enumsAt = viewU32(buf, 56);
  const expectedOffsetsBytes = (edgeCount + 1) * 4;
  if (idBlobAt - idOffsetsAt !== expectedOffsetsBytes || enumsAt < idBlobAt || enumsAt > buf.length) {
    throw new Error("corrupt V4 edge-id sections");
  }

  const oldSpan = enumsAt - idOffsetsAt;
  const alignmentPad = (enumsAt - idBlobAt) & 3;
  const newSpan = 4 + alignmentPad;
  const savedBytes = oldSpan - newSpan;
  if (savedBytes <= 0 || (savedBytes & 3) !== 0) {
    throw new Error("V4 edge-id compaction did not preserve alignment");
  }

  const out = Buffer.alloc(buf.length - savedBytes);
  buf.copy(out, 0, 0, idOffsetsAt);
  // Four-byte zero sentinel + at most three bytes of alignment padding.
  out.fill(0, idOffsetsAt, idOffsetsAt + newSpan);
  buf.copy(out, idOffsetsAt + newSpan, enumsAt);

  out.writeUInt16LE(flags | FLAG_V4_DERIVED_EDGE_IDS, 6);
  out.writeUInt32LE(idOffsetsAt, 48);
  out.writeUInt32LE(idOffsetsAt + 4, 52);
  const pointerFields = [
    24, 28, 32, 36, 40, 44, 56, 60, 64, 68, 72, 76, 80, 84,
    88, 92, 96, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136
  ];
  for (const field of pointerFields) {
    const prior = viewU32(buf, field);
    out.writeUInt32LE(prior >= enumsAt ? prior - savedBytes : prior, field);
  }
  return { graphBuffer: out, savedBytes, alreadyCompact: false };
}

function decodeGraphV4(buffer, geometryBuffer) {
  const buf = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
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
  const base = buf.byteOffset;
  const ab = buf.buffer;
  const nodeOffsets = new Int32Array(ab, base + viewU32(buf, 24), nodeCount + 1);
  const edgeTargets = new Int32Array(ab, base + viewU32(buf, 28), directedArcCount);
  const edgeUndirectedIndex = new Int32Array(ab, base + viewU32(buf, 32), directedArcCount);
  const edgeFrom = new Int32Array(ab, base + viewU32(buf, 64), undirectedEdgeCount);
  const edgeTo = new Int32Array(ab, base + viewU32(buf, 68), undirectedEdgeCount);
  const edgeMeters = new Uint32Array(ab, base + viewU32(buf, 40), undirectedEdgeCount);
  const nodeCoords = new Float32Array(ab, base + viewU32(buf, 44), nodeCount * 2);
  const edgeAccess = buf.subarray(viewU32(buf, 112), viewU32(buf, 112) + undirectedEdgeCount * 2);
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
    : new Int32Array(ab, base + viewU32(buf, 48), undirectedEdgeCount + 1);
  const idBlob = derivesEdgeIds ? null : buf.subarray(viewU32(buf, 52), viewU32(buf, 56));
  function edgeId(ei) {
    if (ei < 0 || ei >= undirectedEdgeCount) return "";
    if (derivesEdgeIds) return `w${osmWayIds[ei]}:${edgeFrom[ei]}:${edgeTo[ei]}`;
    return idBlob.toString("utf8", idOffsets[ei], idOffsets[ei + 1]);
  }
  const edgeAttrs = new Uint16Array(ab, base + viewU32(buf, 36), undirectedEdgeCount);
  const enums = JSON.parse(buf.subarray(viewU32(buf, 56), viewU32(buf, 60)).toString("utf8") || "{}");
  const meta = JSON.parse(buf.subarray(viewU32(buf, 60), viewU32(buf, 72)).toString("utf8") || "{}");
  const edgeSurfaceLeaf = new Uint8Array(ab, base + viewU32(buf, 72), undirectedEdgeCount);
  const edgeRoadClassLeaf = new Uint8Array(ab, base + viewU32(buf, 76), undirectedEdgeCount);
  const edgeGrade = new Uint8Array(ab, base + viewU32(buf, 80), undirectedEdgeCount);
  const edgeLayer = new Int8Array(ab, base + viewU32(buf, 84), undirectedEdgeCount);
  const edgeStructureLeaf = new Uint8Array(ab, base + viewU32(buf, 88), undirectedEdgeCount);
  const edgeAccessLeaf = new Uint8Array(ab, base + viewU32(buf, 92), undirectedEdgeCount);
  const edgeFlagBytes = new Uint8Array(ab, base + viewU32(buf, 96), undirectedEdgeCount);
  const edgeCrossingSeconds = new Uint32Array(ab, base + viewU32(buf, 100), undirectedEdgeCount);
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

function encodeFromOsmGraph(graph, provenance = {}) {
  const geomBuffer = encodeGeometry(graph.edges || []);
  const geometryPreparation = verifyGeometryGrid(geomBuffer);
  const encoded = encodeGraphV4(graph, provenance, geomBuffer);
  return { graphBuffer: encoded.graphBuffer, geomBuffer, meta: encoded.meta, geometryPreparation };
}

// Factory gate: validate every stored row against the exact shipped coordinates.
// The phone can trust this hash-bound derived table without decoding every shape.
function verifyGeometryGrid(bytes) {
  const geometry = decodeGeometryV1(bytes);
  if (!(bytes.readUInt16LE(6) & 2)) return { present: false, edges: geometry.edgeCount };
  const width = bytes.readUInt16LE(6) & 1 ? 8 : 4;
  const coordsAt = Math.ceil((16 + (geometry.edgeCount + 1) * 4) / width) * width;
  const tableAt = coordsAt + geometry.coords.length * width;
  if (bytes.length !== tableAt + geometry.edgeCount * 8) throw new Error("geometry grid size mismatch");
  for (let edge = 0; edge < geometry.edgeCount; edge++) {
    const begin = geometry.offsets[edge], end = geometry.offsets[edge + 1];
    if (begin < 0 || begin > end || end > geometry.coords.length || begin % 2 || end % 2)
      throw new Error(`geometry offsets invalid on edge ${edge}`);
    let west = Infinity, east = -Infinity, south = Infinity, north = -Infinity;
    for (let i = begin; i < end; i += 2) {
      const x = geometry.coords[i], y = geometry.coords[i + 1];
      if (!Number.isFinite(x) || !Number.isFinite(y) || Math.abs(x) > 180 || Math.abs(y) > 90)
        throw new Error(`geometry coordinate invalid on edge ${edge}`);
      west = Math.min(west, x); east = Math.max(east, x);
      south = Math.min(south, y); north = Math.max(north, y);
    }
    const expected = begin === end ? [32767, -32768, 32767, -32768]
      : [west, east, south, north].map(value => Math.floor(value / 0.05));
    for (let i = 0; i < 4; i++) {
      if (bytes.readInt16LE(tableAt + edge * 8 + i * 2) !== expected[i])
        throw new Error(`geometry grid differs from stored shape on edge ${edge}`);
    }
  }
  return { present: true, edges: geometry.edgeCount, bytes: geometry.edgeCount * 8 };
}

function rejectMixedContract(packs) {
  const epochs = new Set((packs || []).map((p) => p.provenance && p.provenance.sourceEpoch));
  const versions = new Set((packs || []).map((p) => p.graphBinaryVersion));
  if (versions.size > 1) throw new Error("mixed-contract cross-region routing");
  if (epochs.size > 1) throw new Error("mixed-contract cross-region routing");
}

module.exports = {
  GRAPH_V4_MAGIC,
  GRAPH_V4_VERSION,
  FLAG_V4_DERIVED_EDGE_IDS,
  HEADER_V4,
  FLAG_V4_LEGAL_TOPOLOGY,
  CAPABILITY,
  encodeGeometry,
  verifyGeometryGrid,
  encodeGraphV4,
  encodeFromOsmGraph,
  compactGraphV4Buffer,
  int64StringView,
  decodeGraphV4,
  decodeGeometryV1,
  assertLegalReader,
  rejectMixedContract,
  sha256
};
