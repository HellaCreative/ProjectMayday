"use strict";

/**
 * graph.v2 + geometry.v1 binary pack format (Stage 2).
 *
 * graph.v2: CSR topology, bit-packed attrs, quantized lengths, node coords, edge ids.
 * geometry.v1: polylines only. Loaded for snap match + path reconstruction; never during relax.
 *
 * Bit widths (amends addendum 2-bit access/structure): enums need 3 bits each.
 *   surface 3 | access 3 | structure 3 | confidence 2 | seasonal 1  (in u16)
 */

const zlib = require("zlib");
const fs = require("fs");
const path = require("path");

const GRAPH_MAGIC = 0x32473244; // "DG2\x02" little-endian-ish marker
const GEOM_MAGIC = 0x4d4f4547; // "GEOM"
const GRAPH_VERSION = 2;
const GEOM_VERSION = 1;

const CONF_CODE = { high: 0, medium: 1, low: 2 };

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
  return (surface) | (access << 3) | (structure << 6) | ((conf & 3) << 9) | (seasonal << 11);
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
function unpackConfidence(attr) {
  const c = (attr >> 9) & 3;
  return c === 0 ? "high" : c === 2 ? "low" : "medium";
}
function unpackSeasonal(attr) {
  return ((attr >> 11) & 1) === 1;
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
  const idStrings = [];
  let idBytesLen = 0;

  const geomOffsets = new Int32Array(undirectedEdgeCount + 1);
  const coordChunks = [];
  let coordCount = 0;

  for (let ei = 0; ei < undirectedEdgeCount; ei += 1) {
    const edge = edges[ei];
    edgeAttrs[ei] = packAttrs(edge);
    edgeMeters[ei] = Math.max(1, Math.round(Number(edge.m) || 1));
    edgeFrom[ei] = edge.a;
    edgeTo[ei] = edge.b;
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

  // --- assemble graph.v2 ---
  // Header: 72 bytes (includes edgeFrom/edgeTo section offsets)
  const HEADER = 72;
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
  const enumsJson = Buffer.from(JSON.stringify(data.enums || {}), "utf8");
  place("enumsJson", enumsJson.length, 1);
  const metaJson = Buffer.from(
    JSON.stringify({
      schemaVersion: data.schemaVersion || "canada-regional-1",
      regionId: data.regionId || null,
      province: data.province || null,
      bbox: data.bbox || null,
      componentCount: data.componentCount || 0,
      sourceFormat: "graph.v1"
    }),
    "utf8"
  );
  place("metaJson", metaJson.length, 1);

  const graphBuffer = Buffer.allocUnsafe(offset);
  graphBuffer.fill(0);
  graphBuffer.writeUInt32LE(GRAPH_MAGIC, 0);
  graphBuffer.writeUInt16LE(GRAPH_VERSION, 4);
  graphBuffer.writeUInt16LE(1, 6); // flags: bit0 = has edgeFrom/edgeTo
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

  return {
    graphBuffer,
    geomBuffer,
    meta: {
      nodeCount,
      undirectedEdgeCount,
      directedArcCount,
      graphBytes: graphBuffer.length,
      geomBytes: geomBuffer.length,
      regionId: data.regionId || null
    }
  };
}

function viewU32(buf, offset) {
  return buf.readUInt32LE(offset);
}

/**
 * Decode graph.v2 buffer into typed views (zero JSON parse for topology).
 */
function decodeGraphV2(buffer) {
  const buf = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer);
  if (viewU32(buf, 0) !== GRAPH_MAGIC) {
    throw new Error("graph.v2 bad magic");
  }
  const version = buf.readUInt16LE(4);
  if (version !== GRAPH_VERSION) {
    throw new Error("graph.v2 unsupported version " + version);
  }
  const nodeCount = viewU32(buf, 8);
  const undirectedEdgeCount = viewU32(buf, 12);
  const directedArcCount = viewU32(buf, 16);
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
  const flags = buf.readUInt16LE(6);
  const offEdgeFrom = flags & 1 ? viewU32(buf, 64) : 0;
  const offEdgeTo = flags & 1 ? viewU32(buf, 68) : 0;

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

  const enums = JSON.parse(buf.subarray(offEnums, offMeta).toString("utf8") || "{}");
  const meta = JSON.parse(buf.subarray(offMeta).toString("utf8") || "{}");

  function edgeId(ei) {
    const a = idOffsets[ei];
    const b = idOffsets[ei + 1];
    return idBlob.toString("utf8", a, b);
  }

  return {
    format: "v2",
    version,
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
    edgeId,
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

function convertV1FileToV2(v1Path, opts = {}) {
  const raw = fs.readFileSync(v1Path);
  const data = inflateMaybeGzip(raw);
  const paths = v2PathsForV1Path(v1Path);
  const outGraph = opts.graphPath || paths.graph;
  const outGeom = opts.geomPath || paths.geom;
  const meta = writePacksFromV1(data, outGraph, outGeom);
  return { ...meta, outGraph, outGeom, source: v1Path };
}

module.exports = {
  GRAPH_MAGIC,
  GEOM_MAGIC,
  GRAPH_VERSION,
  GEOM_VERSION,
  packsV2Enabled,
  packAttrs,
  unpackSurface,
  unpackAccess,
  unpackStructure,
  unpackConfidence,
  unpackSeasonal,
  encodeFromV1,
  decodeGraphV2,
  decodeGeometryV1,
  v2PathsForV1Path,
  writePacksFromV1,
  convertV1FileToV2
};
