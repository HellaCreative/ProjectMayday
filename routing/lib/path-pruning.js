"use strict";

/**
 * Remove geographic loops from a returned path.
 *
 * A shortest path is node-simple, but merged OSM/provincial fabrics can model
 * the same physical road with different node ids and edge ids. Dirt discounts
 * can then make a topologically-simple path ride one representation outward
 * and a parallel representation back. In geographic space that is a pointless
 * out-and-back which inflates dirt distance without advancing the journey.
 */

function haversineMeters(a, b) {
  const R = 6371000;
  const toR = Math.PI / 180;
  const dLat = (b[1] - a[1]) * toR;
  const dLon = (b[0] - a[0]) * toR;
  const lat1 = a[1] * toR;
  const lat2 = b[1] * toR;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function lineMeters(coords) {
  let total = 0;
  for (let i = 1; i < coords.length; i += 1) {
    total += haversineMeters(coords[i - 1], coords[i]);
  }
  return total;
}

function coordKey(coord, precision) {
  return coord[0].toFixed(precision) + "," + coord[1].toFixed(precision);
}

function clonePiece(edge, coords, resolveCoords) {
  if (!coords || coords.length < 2) return null;
  const originalCoords = resolveCoords(edge) || [];
  const originalGeomMeters = lineMeters(originalCoords);
  const pieceGeomMeters = lineMeters(coords);
  if (!(pieceGeomMeters > 0)) return null;
  const originalMeters = Number(edge.meters) || originalGeomMeters;
  const meters =
    originalGeomMeters > 0
      ? originalMeters * (pieceGeomMeters / originalGeomMeters)
      : pieceGeomMeters;
  return {
    ...edge,
    coords,
    meters
  };
}

function findLargestLoop(edges, resolveCoords, precision, minLoopMeters) {
  const seen = new Map();
  let previousKey = null;
  let alongMeters = 0;
  let previousCoord = null;
  let largest = null;

  for (let edgeIndex = 0; edgeIndex < edges.length; edgeIndex += 1) {
    const coords = resolveCoords(edges[edgeIndex]) || [];
    for (let coordIndex = 0; coordIndex < coords.length; coordIndex += 1) {
      const coord = coords[coordIndex];
      const key = coordKey(coord, precision);
      // Adjacent segment boundaries repeat by construction; they are not loops.
      if (key === previousKey) continue;
      if (previousCoord) alongMeters += haversineMeters(previousCoord, coord);

      const first = seen.get(key);
      if (first && alongMeters - first.alongMeters >= minLoopMeters) {
        const candidate = {
          first,
          second: { edgeIndex, coordIndex, coord, alongMeters },
          loopMeters: alongMeters - first.alongMeters
        };
        if (!largest || candidate.loopMeters > largest.loopMeters) largest = candidate;
      }
      if (!first) seen.set(key, { edgeIndex, coordIndex, coord, alongMeters });
      previousKey = key;
      previousCoord = coord;
    }
  }
  return largest;
}

function eraseLoop(edges, loop, resolveCoords) {
  const { first, second } = loop;
  const out = edges.slice(0, first.edgeIndex);
  const firstEdge = edges[first.edgeIndex];
  const secondEdge = edges[second.edgeIndex];
  const firstCoords = resolveCoords(firstEdge) || [];
  const secondCoords = resolveCoords(secondEdge) || [];

  if (first.edgeIndex === second.edgeIndex) {
    const joined = firstCoords
      .slice(0, first.coordIndex + 1)
      .concat(firstCoords.slice(second.coordIndex + 1));
    const piece = clonePiece(firstEdge, joined, resolveCoords);
    if (piece) out.push(piece);
  } else {
    const prefix = clonePiece(
      firstEdge,
      firstCoords.slice(0, first.coordIndex + 1),
      resolveCoords
    );
    if (prefix) out.push(prefix);
    const joinIndex = out.length;
    const suffix = clonePiece(
      secondEdge,
      secondCoords.slice(second.coordIndex),
      resolveCoords
    );
    if (suffix) out.push(suffix);
    out.push(...edges.slice(second.edgeIndex + 1));
    if (out[joinIndex]) {
      const joinedEdge = out[joinIndex];
      const joinedCoords = (resolveCoords(joinedEdge) || []).map((coord) => [...coord]);
      if (joinedCoords.length) joinedCoords[0] = [...first.coord];
      out[joinIndex] = { ...joinedEdge, coords: joinedCoords };
    }
    return out;
  }

  out.push(...edges.slice(second.edgeIndex + 1));
  return out;
}

function totalMeters(edges) {
  return edges.reduce((sum, edge) => sum + (Number(edge.meters) || 0), 0);
}

/**
 * Loop-erases a path at repeated geographic vertices.
 * Returns original edge objects when no loop is present.
 */
function pruneGeographicLoops(edges, resolveCoords, options = {}) {
  const precision = Number.isInteger(options.precision) ? options.precision : 6;
  const minLoopMeters =
    Number.isFinite(options.minLoopMeters) && options.minLoopMeters >= 0
      ? options.minLoopMeters
      : 50;
  const beforeMeters = totalMeters(edges);
  let result = edges;
  let prunedLoopCount = 0;

  // Each pass removes at least one coordinate interval. The guard prevents a
  // malformed self-overlapping polyline from consuming unbounded CPU.
  for (let pass = 0; pass < 100; pass += 1) {
    const loop = findLargestLoop(result, resolveCoords, precision, minLoopMeters);
    if (!loop) break;
    result = eraseLoop(result, loop, resolveCoords);
    prunedLoopCount += 1;
  }

  return {
    edges: result,
    prunedLoopCount,
    prunedMeters: Math.max(0, beforeMeters - totalMeters(result))
  };
}

module.exports = { pruneGeographicLoops };
