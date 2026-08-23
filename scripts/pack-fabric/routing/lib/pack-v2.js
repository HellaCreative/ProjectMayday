"use strict";

/**
 * graph.v2/v3 + geometry.v1 binary pack format (Stage 2).
 *
 * graph.v2/v3: CSR topology, bit-packed attrs, quantized lengths, node coords, edge ids.
 * graph.v3 (flags bit1): per-edge leaf sections + dictionaries in enumsJson (Phase C).
 * geometry.v1: polylines only. Loaded for snap match + path reconstruction; never during relax.
 *
 * Bit widths (amends addendum 2-bit access/structure): enums need 3 bits each.
 *   surface 3 | access 3 | structure 3 | confidence 2 | seasonal 1 | roadClass 4  (in u16)
 * roadClass (bits 12–15) unlocks on-device freeway/arterial penalties without a version bump;
 * older clients ignore the high nibble.
 *
 * See docs/PACK-DATA-V3-AUTHORITY.md § "Graph v3 byte layout" for the exact contract.
 */

const zlib = require("zlib");
const fs = require("fs");
const path = require("path");

const GRAPH_MAGIC = 0x32473244; // "DG2\x02" little-endian-ish marker
const GEOM_MAGIC = 0x4d4f4547; // "GEOM"
/** Current encode target. Decoder accepts 2 and 3. */
const GRAPH_VERSION = 3;
const GRAPH_VERSION_MIN_READ = 2;
const GEOM_VERSION = 1;

/** Header sizes: v2 = 72; v3 with leaf section offsets appended = 100. */
const HEADER_V2 = 72;
const HEADER_V3 = 100;

/** flags bit0 = edgeFrom/edgeTo present; bit1 = v3 leaf sections present. */
const FLAG_EDGE_FROM_TO = 1;
const FLAG_V3_LEAVES = 2;

const CONF_CODE = { high: 0, medium: 1, low: 2 };

const TRACKTYPE_CODE = Object.freeze({
  "": 0,
  grade1: 1,
  grade2: 2,
  grade3: 3,
  grade4: 4,
  grade5: 5
});

/** OSM smoothness wiki order → nibble 1..8 (0 = missing). */
const SMOOTHNESS_CODE = Object.freeze({
  "": 0,
  excellent: 1,
  good: 2,
  intermediate: 3,
  bad: 4,
  very_bad: 5,
  horrible: 6,
  very_horrible: 7,
  impassable: 8
});

const TRACKTYPE_NAME = Object.freeze({
  0: null,
  1: "grade1",
  2: "grade2",
  3: "grade3",
  4: "grade4",
  5: "grade5"
});

const SMOOTHNESS_NAME = Object.freeze({
  0: null,
  1: "excellent",
  2: "good",
  3: "intermediate",
  4: "bad",
  5: "very_bad",
  6: "horrible",
  7: "very_horrible",
  8: "impassable"
});

/** Packed road-track class codes — keep in lockstep with OnDeviceProfileCosts. */
const ROAD_CLASS_CODE = Object.freeze({
  unknown: 0,
  freeway: 1,
  arterial: 2,
  collector: 3,
  local: 4,
  service: 5,
  resource: 6,
  recreation: 7,
  track: 8,
  double_track: 9,
  ramp: 10
});

const ROAD_CLASS_NAME = Object.freeze({
  0: "unknown",
  1: "freeway",
  2: "arterial",
  3: "collector",
  4: "local",
  5: "service",
  6: "resource",
  7: "recreation",
  8: "track",
  9: "double_track",
  10: "ramp"
});

function packsV2Enabled() {
  const v = process.env.ROUTING_PACKS_V2;
  if (v === "0" || v === "false" || v === "off") return false;
  if (v === "1" || v === "true" || v === "on") return true;
  return false; // default off until parity
}

function packAttrs(edge) {
  const surface = Number(edge.s) & 7;
  const access = Number(edge.ac) & 7;
  const structure = Number(edge.t) & 7;
  const conf = CONF_CODE[edge.conf] != null ? CONF_CODE[edge.conf] : 1;
  const seasonal = edge.seasonal ? 1 : 0;
  const rtKey = String(edge.rt || edge.roadTrackClass || "unknown").toLowerCase();
  const roadClass = ROAD_CLASS_CODE[rtKey] != null ? ROAD_CLASS_CODE[rtKey] : 0;
  return (
    surface |
    (access << 3) |
    (structure << 6) |
    ((conf & 3) << 9) |
    (seasonal << 11) |
    ((roadClass & 15) << 12)
  );
}

function unpackSurface(attr) {
  return attr & 7;
}
function unpackAccess(attr) {
  return (attr >> 3) & 7;
}
function unpackStructure(attr) {
  return (attr >> 6) & 7;
}
function unpackRoadClass(attr) {
  return (attr >> 12) & 15;
}
function unpackConfidence(attr) {
  const c = (attr >> 9) & 3;
  return c === 0 ? "high" : c === 2 ? "low" : "medium";
}
function unpackSeasonal(attr) {
  return ((attr >> 11) & 1) === 1;
}

function packGrade(tracktype, smoothness) {
  const ttRaw = tracktype == null ? "" : String(tracktype).toLowerCase().trim();
  const smRaw = smoothness == null ? "" : String(smoothness).toLowerCase().trim();
  const tt = TRACKTYPE_CODE[ttRaw] != null ? TRACKTYPE_CODE[ttRaw] : 0;
  const sm = SMOOTHNESS_CODE[smRaw] != null ? SMOOTHNESS_CODE[smRaw] : 0;
  return (tt & 15) | ((sm & 15) << 4);
}

function unpackTracktypeCode(gradeByte) {
  return gradeByte & 15;
}
function unpackSmoothnessCode(gradeByte) {
  return (gradeByte >> 4) & 15;
}

/**
 * Build a string dictionary with index 0 = sentinel. Fail closed if >255 entries.
 */
function buildLeafDictionary(values, sentinel, dictName) {
  const names = [sentinel];
  const index = new Map();
  index.set(sentinel, 0);
  if (sentinel !== "") index.set("", 0);
  for (const raw of values) {
    if (raw == null) continue;
    const key = String(raw).trim().toLowerCase();
    if (!key || key === sentinel) continue;
    if (index.has(key)) continue;
    if (names.length >= 255) {
      throw new Error(
        `graph.v3 ${dictName} exceeds 255 entries (fail-closed); widen index or split dictionary`
      );
    }
    index.set(key, names.length);
    names.push(key);
  }
  return { names, index };
}

function leafIndex(indexMap, value, sentinel) {
  if (value == null) return 0;
  const key = String(value).trim().toLowerCase();
  if (!key || key === sentinel) return 0;
  const at = indexMap.get(key);
  return at != null ? at : 0;
}

/**
 * Convert inflated graph.v1 JSON object to { graphBuffer, geomBuffer, meta }.
 */
function encodeFromV1(data) {
  const nodeCount = data.nodeCount || (data.nodes && data.nodes.length) || 0;
  const edges = data.edges || [];
  const undirectedEdgeCount = edges.length;

  // Build undirected CSR (two arcs per edge).
  const outDegree = new Int32Array(nodeCount);
  for (const edge of edges) {
    if (edge.a >= 0 && edge.a < nodeCount) outDegree[edge.a] += 1;
    if (edge.b >= 0 && edge.b < nodeCount) outDegree[edge.b] += 1;
  }
  const nodeOffsets = new Int32Array(nodeCount + 1);
  for (let i = 0; i < nodeCount; i += 1) {
    nodeOffsets[i + 1] = nodeOffsets[i] + outDegree[i];
  }
  const directedArcCount = nodeOffsets[nodeCount];
  const edgeTargets = new Int32Array(directedArcCount);
  const edgeUndirectedIndex = new Int32Array(directedArcCount);
  const cursor = new Int32Array(nodeCount);
  for (let i = 0; i < nodeCount; i += 1) cursor[i] = nodeOffsets[i];

  const edgeAttrs = new Uint16Array(undirectedEdgeCount);
  const edgeMeters = new Uint32Array(undirectedEdgeCount);
  const edgeFrom = new Int32Array(undirectedEdgeCount);
  const edgeTo = new Int32Array(undirectedEdgeCount);
  const edgeSurfaceLeaf = new Uint8Array(undirectedEdgeCount);
  const edgeRoadClassLeaf = new Uint8Array(undirectedEdgeCount);
  const edgeGrade = new Uint8Array(undirectedEdgeCount);
  const edgeLayer = new Int8Array(undirectedEdgeCount);
  const edgeStructureLeaf = new Uint8Array(undirectedEdgeCount);
  const edgeAccessLeaf = new Uint8Array(undirectedEdgeCount);
  const edgeFlags = new Uint8Array(undirectedEdgeCount);
  const idStrings = [];
  let idBytesLen = 0;

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

  const geomOffsets = new Int32Array(undirectedEdgeCount + 1);
  const coordChunks = [];
  let coordCount = 0;

  for (let ei = 0; ei < undirectedEdgeCount; ei += 1) {
    const edge = edges[ei];
    // Coarse u16 remains a derived cache from existing coarse fields (unchanged).
    edgeAttrs[ei] = packAttrs(edge);
    edgeMeters[ei] = Math.max(1, Math.round(Number(edge.m) || 1));
    edgeFrom[ei] = edge.a;
    edgeTo[ei] = edge.b;
    edgeSurfaceLeaf[ei] = leafIndex(surfaceDict.index, edge.surfaceLeaf, "");
    edgeRoadClassLeaf[ei] = leafIndex(
      roadClassDict.index,
      edge.roadClassLeaf == null || edge.roadClassLeaf === "" ? "unknown" : edge.roadClassLeaf,
      "unknown"
    );
    edgeGrade[ei] = packGrade(edge.tracktype, edge.smoothness);
    const layerN = Number(edge.layer);
    edgeLayer[ei] = Number.isFinite(layerN) ? Math.max(-128, Math.min(127, Math.trunc(layerN))) : 0;
    edgeStructureLeaf[ei] = leafIndex(structureDict.index, edge.structureLeaf, "");
    edgeAccessLeaf[ei] = leafIndex(accessDict.index, edge.accessLeaf, "");
    let flagsByte = 0;
    if (edge.atvDesignated) flagsByte |= 1;
    if (edge.seasonal) flagsByte |= 2;
    edgeFlags[ei] = flagsByte;

    const id = String(edge.i || ei);
    idStrings.push(id);
    idBytesLen += Buffer.byteLength(id, "utf8");

    const g = edge.g || [];
    geomOffsets[ei] = coordCount;
    for (const c of g) {
      coordChunks.push(Number(c[0]), Number(c[1]));
      coordCount += 2;
    }

    const a = edge.a;
    const b = edge.b;
    if (a >= 0 && a < nodeCount) {
      const slot = cursor[a]++;
      edgeTargets[slot] = b;
      edgeUndirectedIndex[slot] = ei;
    }
    if (b >= 0 && b < nodeCount) {
      const slot = cursor[b]++;
      edgeTargets[slot] = a;
      edgeUndirectedIndex[slot] = ei;
    }
  }
  geomOffsets[undirectedEdgeCount] = coordCount;

  const nodeCoords = new Float32Array(nodeCount * 2);
  if (Array.isArray(data.nodes) && data.nodes.length === nodeCount) {
    for (let i = 0; i < nodeCount; i += 1) {
      nodeCoords[i * 2] = Number(data.nodes[i][0]);
      nodeCoords[i * 2 + 1] = Number(data.nodes[i][1]);
    }
  } else {
    // Derive from first endpoint seen on an incident edge geometry.
    const seen = new Uint8Array(nodeCount);
    for (let ei = 0; ei < undirectedEdgeCount; ei += 1) {
      const edge = edges[ei];
      const g = edge.g || [];
      if (!g.length) continue;
      if (edge.a >= 0 && edge.a < nodeCount && !seen[edge.a]) {
        nodeCoords[edge.a * 2] = g[0][0];
        nodeCoords[edge.a * 2 + 1] = g[0][1];
        seen[edge.a] = 1;
      }
      if (edge.b >= 0 && edge.b < nodeCount && !seen[edge.b]) {
        const last = g[g.length - 1];
        nodeCoords[edge.b * 2] = last[0];
        nodeCoords[edge.b * 2 + 1] = last[1];
        seen[edge.b] = 1;
      }
    }
  }

  // Edge id blob
  const idOffsets = new Int32Array(undirectedEdgeCount + 1);
  const idBlob = Buffer.allocUnsafe(idBytesLen);
  let idAt = 0;
  for (let i = 0; i < undirectedEdgeCount; i += 1) {
    idOffsets[i] = idAt;
    idAt += idBlob.write(idStrings[i], idAt, "utf8");
  }
  idOffsets[undirectedEdgeCount] = idAt;

  const geomCoords = Float32Array.from(coordChunks);

  // --- assemble geometry.v1 ---
  const geomHeaderSize = 16;
  const geomOffBytes = geomOffsets.byteLength;
  let geomCoordsAt = geomHeaderSize + geomOffBytes;
  // Float32Array requires 4-byte alignment.
  if (geomCoordsAt % 4 !== 0) geomCoordsAt += 4 - (geomCoordsAt % 4);
  const geomCoordBytes = geomCoords.byteLength;
  const geomTotal = geomCoordsAt + geomCoordBytes;
  const abGeom = new ArrayBuffer(geomTotal);
  const geomBuffer = Buffer.from(abGeom);
  geomBuffer.fill(0, 0, geomCoordsAt);
  geomBuffer.writeUInt32LE(GEOM_MAGIC, 0);
  geomBuffer.writeUInt16LE(GEOM_VERSION, 4);
  geomBuffer.writeUInt16LE(0, 6); // float32 coords
  geomBuffer.writeUInt32LE(undirectedEdgeCount, 8);
  geomBuffer.writeUInt32LE(coordCount, 12);
  Buffer.from(geomOffsets.buffer, geomOffsets.byteOffset, geomOffBytes).copy(geomBuffer, geomHeaderSize);
  Buffer.from(geomCoords.buffer, geomCoords.byteOffset, geomCoordBytes).copy(geomBuffer, geomCoordsAt);

  // --- assemble graph.v3 (v2 section table preserved; leaf offsets appended) ---
  const HEADER = HEADER_V3;
  let offset = HEADER;
  const sections = {};
  function place(name, byteLength, align) {
    if (align > 1) offset = Math.ceil(offset / align) * align;
    sections[name] = offset;
    offset += byteLength;
    return sections[name];
  }

  place("nodeOffsets", nodeOffsets.byteLength, 4);
  place("edgeTargets", edgeTargets.byteLength, 4);
  place("edgeUndirectedIndex", edgeUndirectedIndex.byteLength, 4);
  place("edgeAttrs", edgeAttrs.byteLength, 2);
  place("edgeMeters", edgeMeters.byteLength, 4);
  place("edgeFrom", edgeFrom.byteLength, 4);
  place("edgeTo", edgeTo.byteLength, 4);
  place("nodeCoords", nodeCoords.byteLength, 4);
  place("idOffsets", idOffsets.byteLength, 4);
  place("idBlob", idBlob.length, 1);

  const { SURFACE_FAMILY_MAP } = require("./surface-family");
  const enumsPayload = {
    ...(data.enums || {}),
    surfaceLeafNames: surfaceDict.names,
    roadClassLeafNames: roadClassDict.names,
    structureLeafNames: structureDict.names,
    accessLeafNames: accessDict.names,
    // Phase E1: shared read-time family table — JS + Swift must derive identically.
    surfaceFamilyMap: { ...SURFACE_FAMILY_MAP }
  };
  const enumsJson = Buffer.from(JSON.stringify(enumsPayload), "utf8");
  place("enumsJson", enumsJson.length, 1);
  const metaJson = Buffer.from(
    JSON.stringify({
      schemaVersion: data.schemaVersion || "canada-regional-1",
      regionId: data.regionId || null,
      province: data.province || null,
      bbox: data.bbox || null,
      componentCount: data.componentCount || 0,
      crossPackSeams: data.crossPackSeams || null,
      urbanCores: data.urbanCores || null,
      settlements: data.settlements || null,
      sourceFormat: "graph.v1",
      graphBinaryVersion: GRAPH_VERSION
    }),
    "utf8"
  );
  place("metaJson", metaJson.length, 1);
  // Leaf sections appended after meta so v2-style meta parse can bound at first leaf offset.
  place("edgeSurfaceLeaf", edgeSurfaceLeaf.byteLength, 1);
  place("edgeRoadClassLeaf", edgeRoadClassLeaf.byteLength, 1);
  place("edgeGrade", edgeGrade.byteLength, 1);
  place("edgeLayer", edgeLayer.byteLength, 1);
  place("edgeStructureLeaf", edgeStructureLeaf.byteLength, 1);
  place("edgeAccessLeaf", edgeAccessLeaf.byteLength, 1);
  place("edgeFlags", edgeFlags.byteLength, 1);

  const graphBuffer = Buffer.allocUnsafe(offset);
  graphBuffer.fill(0);
  graphBuffer.writeUInt32LE(GRAPH_MAGIC, 0);
  graphBuffer.writeUInt16LE(GRAPH_VERSION, 4);
  graphBuffer.writeUInt16LE(FLAG_EDGE_FROM_TO | FLAG_V3_LEAVES, 6);
  graphBuffer.writeUInt32LE(nodeCount, 8);
  graphBuffer.writeUInt32LE(undirectedEdgeCount, 12);
  graphBuffer.writeUInt32LE(directedArcCount, 16);
  graphBuffer.writeUInt32LE(HEADER, 20);
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

  function copyTyped(arr, at) {
    Buffer.from(arr.buffer, arr.byteOffset, arr.byteLength).copy(graphBuffer, at);
  }
  copyTyped(nodeOffsets, sections.nodeOffsets);
  copyTyped(edgeTargets, sections.edgeTargets);
  copyTyped(edgeUndirectedIndex, sections.edgeUndirectedIndex);
  copyTyped(edgeAttrs, sections.edgeAttrs);
  copyTyped(edgeMeters, sections.edgeMeters);
  copyTyped(edgeFrom, sections.edgeFrom);
  copyTyped(edgeTo, sections.edgeTo);
  copyTyped(nodeCoords, sections.nodeCoords);
  copyTyped(idOffsets, sections.idOffsets);
  idBlob.copy(graphBuffer, sections.idBlob);
  enumsJson.copy(graphBuffer, sections.enumsJson);
  metaJson.copy(graphBuffer, sections.metaJson);
  copyTyped(edgeSurfaceLeaf, sections.edgeSurfaceLeaf);
  copyTyped(edgeRoadClassLeaf, sections.edgeRoadClassLeaf);
  copyTyped(edgeGrade, sections.edgeGrade);
  copyTyped(edgeLayer, sections.edgeLayer);
  copyTyped(edgeStructureLeaf, sections.edgeStructureLeaf);
  copyTyped(edgeAccessLeaf, sections.edgeAccessLeaf);
  copyTyped(edgeFlags, sections.edgeFlags);

  return {
    graphBuffer,
    geomBuffer,
    meta: {
      nodeCount,
      undirectedEdgeCount,
      directedArcCount,
      graphBytes: graphBuffer.length,
      geomBytes: geomBuffer.length,
      regionId: data.regionId || null,
      graphVersion: GRAPH_VERSION,
      surfaceLeafNames: surfaceDict.names.length,
      roadClassLeafNames: roadClassDict.names.length,
      structureLeafNames: structureDict.names.length,
      accessLeafNames: accessDict.names.length
    }
  };
}

function viewU32(buf, offset) {
  return buf.readUInt32LE(offset);
}

/**
 * Decode graph.v2 or graph.v3 buffer into typed views (zero JSON parse for topology).
 * v3 leaf sections are optional: missing/absent → coarse fallback (no error).
 */
function decodeGraphV2(buffer) {
  const buf = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
  if (viewU32(buf, 0) !== GRAPH_MAGIC) {
    throw new Error("graph.v2 bad magic");
  }
  const version = buf.readUInt16LE(4);
  if (version < GRAPH_VERSION_MIN_READ || version > GRAPH_VERSION) {
    throw new Error("graph.v2 unsupported version " + version);
  }
  const flags = buf.readUInt16LE(6);
  const nodeCount = viewU32(buf, 8);
  const undirectedEdgeCount = viewU32(buf, 12);
  const directedArcCount = viewU32(buf, 16);
  const headerSize = viewU32(buf, 20) || HEADER_V2;
  const offNodeOffsets = viewU32(buf, 24);
  const offEdgeTargets = viewU32(buf, 28);
  const offEdgeUndirected = viewU32(buf, 32);
  const offEdgeAttrs = viewU32(buf, 36);
  const offEdgeMeters = viewU32(buf, 40);
  const offNodeCoords = viewU32(buf, 44);
  const offIdOffsets = viewU32(buf, 48);
  const offIdBlob = viewU32(buf, 52);
  const offEnums = viewU32(buf, 56);
  const offMeta = viewU32(buf, 60);
  const offEdgeFrom = flags & FLAG_EDGE_FROM_TO ? viewU32(buf, 64) : 0;
  const offEdgeTo = flags & FLAG_EDGE_FROM_TO ? viewU32(buf, 68) : 0;

  const hasLeaves = version >= 3 && (flags & FLAG_V3_LEAVES) !== 0 && headerSize >= HEADER_V3;
  const offEdgeSurfaceLeaf = hasLeaves ? viewU32(buf, 72) : 0;
  const offEdgeRoadClassLeaf = hasLeaves ? viewU32(buf, 76) : 0;
  const offEdgeGrade = hasLeaves ? viewU32(buf, 80) : 0;
  const offEdgeLayer = hasLeaves ? viewU32(buf, 84) : 0;
  const offEdgeStructureLeaf = hasLeaves ? viewU32(buf, 88) : 0;
  const offEdgeAccessLeaf = hasLeaves ? viewU32(buf, 92) : 0;
  const offEdgeFlags = hasLeaves ? viewU32(buf, 96) : 0;

  const base = buf.byteOffset;
  const ab = buf.buffer;

  const nodeOffsets = new Int32Array(ab, base + offNodeOffsets, nodeCount + 1);
  const edgeTargets = new Int32Array(ab, base + offEdgeTargets, directedArcCount);
  const edgeUndirectedIndex = new Int32Array(ab, base + offEdgeUndirected, directedArcCount);
  const edgeAttrs = new Uint16Array(ab, base + offEdgeAttrs, undirectedEdgeCount);
  const edgeMeters = new Uint32Array(ab, base + offEdgeMeters, undirectedEdgeCount);
  const edgeFrom =
    offEdgeFrom > 0 ? new Int32Array(ab, base + offEdgeFrom, undirectedEdgeCount) : null;
  const edgeTo = offEdgeTo > 0 ? new Int32Array(ab, base + offEdgeTo, undirectedEdgeCount) : null;
  const nodeCoords = new Float32Array(ab, base + offNodeCoords, nodeCount * 2);
  const idOffsets = new Int32Array(ab, base + offIdOffsets, undirectedEdgeCount + 1);
  const idBlob = buf.subarray(offIdBlob, offEnums);

  const metaEnd = hasLeaves && offEdgeSurfaceLeaf > offMeta ? offEdgeSurfaceLeaf : buf.length;
  const enums = JSON.parse(buf.subarray(offEnums, offMeta).toString("utf8") || "{}");
  const meta = JSON.parse(buf.subarray(offMeta, metaEnd).toString("utf8") || "{}");

  const edgeSurfaceLeaf = hasLeaves
    ? new Uint8Array(ab, base + offEdgeSurfaceLeaf, undirectedEdgeCount)
    : null;
  const edgeRoadClassLeaf = hasLeaves
    ? new Uint8Array(ab, base + offEdgeRoadClassLeaf, undirectedEdgeCount)
    : null;
  const edgeGrade = hasLeaves ? new Uint8Array(ab, base + offEdgeGrade, undirectedEdgeCount) : null;
  const edgeLayer = hasLeaves ? new Int8Array(ab, base + offEdgeLayer, undirectedEdgeCount) : null;
  const edgeStructureLeaf = hasLeaves
    ? new Uint8Array(ab, base + offEdgeStructureLeaf, undirectedEdgeCount)
    : null;
  const edgeAccessLeaf = hasLeaves
    ? new Uint8Array(ab, base + offEdgeAccessLeaf, undirectedEdgeCount)
    : null;
  const edgeFlagBytes = hasLeaves
    ? new Uint8Array(ab, base + offEdgeFlags, undirectedEdgeCount)
    : null;

  const surfaceLeafNames = enums.surfaceLeafNames || [""];
  const roadClassLeafNames = enums.roadClassLeafNames || ["unknown"];
  const structureLeafNames = enums.structureLeafNames || [""];
  const accessLeafNames = enums.accessLeafNames || [""];
  const { SURFACE_FAMILY_MAP } = require("./surface-family");
  const surfaceFamilyMap =
    enums.surfaceFamilyMap && typeof enums.surfaceFamilyMap === "object"
      ? enums.surfaceFamilyMap
      : SURFACE_FAMILY_MAP;

  function edgeId(ei) {
    const a = idOffsets[ei];
    const b = idOffsets[ei + 1];
    return idBlob.toString("utf8", a, b);
  }

  function nameAt(names, idx, fallback) {
    if (idx == null || idx < 0 || idx >= names.length) return fallback;
    const v = names[idx];
    return v == null || v === "" ? fallback : v;
  }

  /** Resolve v3 leaves for undirected edge ei (coarse fallback when sections absent). */
  function edgeLeaves(ei) {
    if (!hasLeaves) {
      return {
        surfaceLeaf: null,
        roadClassLeaf: null,
        tracktype: null,
        smoothness: null,
        layer: 0,
        structureLeaf: null,
        accessLeaf: null,
        atvDesignated: false,
        seasonal: unpackSeasonal(edgeAttrs[ei]),
        fromLeaves: false
      };
    }
    const surfaceIdx = edgeSurfaceLeaf[ei];
    const roadIdx = edgeRoadClassLeaf[ei];
    const grade = edgeGrade[ei];
    const tt = unpackTracktypeCode(grade);
    const sm = unpackSmoothnessCode(grade);
    const flagsB = edgeFlagBytes[ei];
    const surfaceLeaf = surfaceIdx === 0 ? null : nameAt(surfaceLeafNames, surfaceIdx, null);
    const roadClassLeaf = nameAt(roadClassLeafNames, roadIdx, "unknown");
    const structureLeaf = edgeStructureLeaf[ei] === 0
      ? null
      : nameAt(structureLeafNames, edgeStructureLeaf[ei], null);
    const accessLeaf = edgeAccessLeaf[ei] === 0
      ? null
      : nameAt(accessLeafNames, edgeAccessLeaf[ei], null);
    return {
      surfaceLeaf,
      roadClassLeaf,
      tracktype: TRACKTYPE_NAME[tt] != null ? TRACKTYPE_NAME[tt] : null,
      smoothness: SMOOTHNESS_NAME[sm] != null ? SMOOTHNESS_NAME[sm] : null,
      layer: edgeLayer[ei],
      structureLeaf,
      accessLeaf,
      atvDesignated: (flagsB & 1) !== 0,
      seasonal: (flagsB & 2) !== 0 || unpackSeasonal(edgeAttrs[ei]),
      fromLeaves: true
    };
  }

  return {
    format: hasLeaves ? "v3" : "v2",
    version,
    flags,
    hasLeaves,
    surfaceFamilyMap,
    nodeCount,
    undirectedEdgeCount,
    directedArcCount,
    edgeCount: undirectedEdgeCount,
    nodeOffsets,
    edgeTargets,
    edgeUndirectedIndex,
    edgeAttrs,
    edgeMeters,
    edgeFrom,
    edgeTo,
    nodeCoords,
    edgeSurfaceLeaf,
    edgeRoadClassLeaf,
    edgeGrade,
    edgeLayer,
    edgeStructureLeaf,
    edgeAccessLeaf,
    edgeFlags: edgeFlagBytes,
    edgeId,
    edgeLeaves,
    enums,
    meta,
    regionId: meta.regionId || null,
    province: meta.province || null,
    schemaVersion: meta.schemaVersion || "graph.v2",
    bbox: meta.bbox || null
  };
}

function decodeGeometryV1(buffer) {
  const buf = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
  if (viewU32(buf, 0) !== GEOM_MAGIC) {
    throw new Error("geometry.v1 bad magic");
  }
  const edgeCount = viewU32(buf, 8);
  const coordCount = viewU32(buf, 12);
  const flags = buf.readUInt16LE(6);
  const header = 16;
  const base = buf.byteOffset;
  const ab = buf.buffer;
  const offsets = new Int32Array(ab, base + header, edgeCount + 1);
  let coordsAt = header + (edgeCount + 1) * 4;
  if (coordsAt % 4 !== 0) coordsAt += 4 - (coordsAt % 4);
  const bytesPer = flags & 1 ? 8 : 4;
  if (flags & 1 && coordsAt % 8 !== 0) coordsAt += 8 - (coordsAt % 8);
  const coordBytes = coordCount * bytesPer;
  // Prefer zero-copy when the Buffer is already aligned at coordsAt.
  let coords;
  if ((base + coordsAt) % bytesPer === 0) {
    coords =
      flags & 1
        ? new Float64Array(ab, base + coordsAt, coordCount)
        : new Float32Array(ab, base + coordsAt, coordCount);
  } else {
    const raw = buf.subarray(coordsAt, coordsAt + coordBytes);
    const aligned = Buffer.alloc(coordBytes);
    raw.copy(aligned);
    coords =
      flags & 1
        ? new Float64Array(aligned.buffer, aligned.byteOffset, coordCount)
        : new Float32Array(aligned.buffer, aligned.byteOffset, coordCount);
  }

  function polyline(ei) {
    const start = offsets[ei];
    const end = offsets[ei + 1];
    const out = [];
    for (let i = start; i < end; i += 2) {
      out.push([coords[i], coords[i + 1]]);
    }
    return out;
  }

  function polylineMaybeReversed(ei, forward) {
    const coordsList = polyline(ei);
    if (forward) return coordsList;
    return coordsList.slice().reverse();
  }

  return {
    format: "geometry.v1",
    edgeCount,
    offsets,
    coords,
    polyline,
    polylineMaybeReversed
  };
}

function v2PathsForV1Path(graphPath) {
  // Already a phone pack URL or file — do not path.join (breaks https://) or append .v2.bin again.
  if (/graph\.v2\.bin$/i.test(graphPath)) {
    return {
      graph: graphPath,
      geom: String(graphPath).replace(/graph\.v2\.bin$/i, "geometry.v1.bin")
    };
  }
  // regions/ns/graph.v1.json.gz -> graph.v2.bin + geometry.v1.bin
  // regions/ns/longhaul.v1.json.gz -> longhaul.v2.bin + longhaul.geometry.v1.bin
  // ns-graph.v1.json.gz -> ns-graph.v2.bin + ns-graph.geometry.v1.bin
  if (/longhaul\.v1\.json\.gz$/i.test(graphPath)) {
    return {
      graph: graphPath.replace(/longhaul\.v1\.json\.gz$/i, "longhaul.v2.bin"),
      geom: graphPath.replace(/longhaul\.v1\.json\.gz$/i, "longhaul.geometry.v1.bin")
    };
  }
  if (/graph\.v1\.json\.gz$/i.test(graphPath)) {
    return {
      graph: graphPath.replace(/graph\.v1\.json\.gz$/i, "graph.v2.bin"),
      geom: graphPath.replace(/graph\.v1\.json\.gz$/i, "geometry.v1.bin")
    };
  }
  if (/ns-graph\.v1\.json\.gz$/i.test(graphPath)) {
    return {
      graph: graphPath.replace(/ns-graph\.v1\.json\.gz$/i, "ns-graph.v2.bin"),
      geom: graphPath.replace(/ns-graph\.v1\.json\.gz$/i, "ns-graph.geometry.v1.bin")
    };
  }
  const dir = path.dirname(graphPath);
  const base = path.basename(graphPath).replace(/\.json\.gz$/i, "");
  return {
    graph: path.join(dir, base + ".v2.bin"),
    geom: path.join(dir, base + ".geometry.v1.bin")
  };
}

/** Local-only v3 candidate paths — never the shipped graph.v2.bin name. */
function v3CandidatePathsForV1Path(graphPath) {
  const v2 = v2PathsForV1Path(graphPath);
  return {
    graph: String(v2.graph).replace(/\.v2\.bin$/i, ".v3.candidate.bin"),
    geom: String(v2.geom).replace(/geometry\.v1\.bin$/i, "geometry.v3.candidate.bin")
      .replace(/\.geometry\.v1\.bin$/i, ".geometry.v3.candidate.bin")
  };
}

function writePacksFromV1(data, outGraphPath, outGeomPath) {
  const { graphBuffer, geomBuffer, meta } = encodeFromV1(data);
  fs.writeFileSync(outGraphPath, graphBuffer);
  fs.writeFileSync(outGeomPath, geomBuffer);
  return meta;
}

function inflateMaybeGzip(buf) {
  if (buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b) {
    return JSON.parse(zlib.gunzipSync(buf).toString("utf8"));
  }
  return JSON.parse(buf.toString("utf8"));
}

function boxIntersectsPackBbox(box, bbox) {
  if (!box || !Array.isArray(bbox) || bbox.length < 4) return false;
  const [minLon, minLat, maxLon, maxLat] = bbox.map(Number);
  return !(
    Number(box.maxLon) < minLon || Number(box.minLon) > maxLon ||
    Number(box.maxLat) < minLat || Number(box.minLat) > maxLat
  );
}

function mergeUniqueBoxes(base, additions) {
  const out = Array.isArray(base) ? base.slice() : [];
  const seen = new Set(out.map((box) =>
    `${box.name || ""}|${box.minLat}|${box.maxLat}|${box.minLon}|${box.maxLon}`
  ));
  for (const box of additions || []) {
    const key = `${box.name || ""}|${box.minLat}|${box.maxLat}|${box.minLon}|${box.maxLon}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(box);
  }
  return out;
}

function applyMetadataSidecars(data, sourcePath, opts = {}) {
  const sourceDir = path.dirname(sourcePath);
  const seamPath = opts.seamPath || path.join(sourceDir, "cross-pack-seams.v1.json");
  const urbanPath = opts.urbanPath || path.join(sourceDir, "urban-cores.v1.json");
  if (fs.existsSync(seamPath)) {
    const sidecar = JSON.parse(fs.readFileSync(seamPath, "utf8"));
    data.crossPackSeams = sidecar.neighbors || sidecar.crossPackSeams || null;
  }
  if (fs.existsSync(urbanPath)) {
    const sidecar = JSON.parse(fs.readFileSync(urbanPath, "utf8"));
    data.urbanCores = sidecar.cores || sidecar.urbanCores || null;
    data.settlements = sidecar.settlements || null;
  }
  // Regional OSM extracts intentionally overlap around borders. A hop routed
  // on one pack can therefore travel briefly inside its neighbour. Carry the
  // neighbour's overlapping avoidance boxes too, or that overlap becomes an
  // urban-policy blind spot (and an intermediate seam can route through it).
  const neighbors = Object.keys(data.crossPackSeams || {});
  for (const neighbor of neighbors) {
    const neighborPath = path.join(sourceDir, "..", neighbor, "urban-cores.v1.json");
    if (!fs.existsSync(neighborPath)) continue;
    const sidecar = JSON.parse(fs.readFileSync(neighborPath, "utf8"));
    const adjacentCores = (sidecar.cores || sidecar.urbanCores || [])
      .filter((box) => boxIntersectsPackBbox(box, data.bbox));
    const adjacentSettlements = (sidecar.settlements || [])
      .filter((box) => boxIntersectsPackBbox(box, data.bbox));
    data.urbanCores = mergeUniqueBoxes(data.urbanCores, adjacentCores);
    data.settlements = mergeUniqueBoxes(data.settlements, adjacentSettlements);
  }
  return data;
}

/**
 * Convert v1 JSON graph to binary packs.
 * Phase C default: write LOCAL v3 candidate files only (never overwrite shipped graph.v2.bin).
 * Pass opts.writeShippedPath=true only for explicit legacy v2 path writes (not used in Phase C).
 */
function convertV1FileToV2(v1Path, opts = {}) {
  const raw = fs.readFileSync(v1Path);
  const data = inflateMaybeGzip(raw);
  applyMetadataSidecars(data, v1Path, opts);
  const paths = opts.writeShippedPath ? v2PathsForV1Path(v1Path) : v3CandidatePathsForV1Path(v1Path);
  const outGraph = opts.graphPath || paths.graph;
  const outGeom = opts.geomPath || paths.geom;
  // Refuse to clobber a shipped v2 pack unless explicitly forced.
  if (
    !opts.writeShippedPath &&
    !opts.graphPath &&
    /graph\.v2\.bin$/i.test(outGraph)
  ) {
    throw new Error("refusing to overwrite shipped graph.v2.bin; use v3 candidate path");
  }
  const meta = writePacksFromV1(data, outGraph, outGeom);
  return { ...meta, outGraph, outGeom, source: v1Path };
}

module.exports = {
  GRAPH_MAGIC,
  GEOM_MAGIC,
  GRAPH_VERSION,
  GRAPH_VERSION_MIN_READ,
  GEOM_VERSION,
  HEADER_V2,
  HEADER_V3,
  FLAG_EDGE_FROM_TO,
  FLAG_V3_LEAVES,
  ROAD_CLASS_CODE,
  ROAD_CLASS_NAME,
  TRACKTYPE_CODE,
  SMOOTHNESS_CODE,
  packsV2Enabled,
  packAttrs,
  packGrade,
  unpackSurface,
  unpackAccess,
  unpackStructure,
  unpackRoadClass,
  unpackConfidence,
  unpackSeasonal,
  unpackTracktypeCode,
  unpackSmoothnessCode,
  buildLeafDictionary,
  encodeFromV1,
  decodeGraphV2,
  decodeGeometryV1,
  v2PathsForV1Path,
  v3CandidatePathsForV1Path,
  writePacksFromV1,
  applyMetadataSidecars,
  boxIntersectsPackBbox,
  convertV1FileToV2
};
