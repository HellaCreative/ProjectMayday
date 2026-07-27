"use strict";

/**
 * Remove geographic loops from a returned path.
 *
 * A shortest path is node-simple, but merged OSM/provincial fabrics can model
 * the same physical road with different node ids and edge ids. Dirt discounts
 * can then make a topologically-simple path ride one representation outward
 * and a parallel representation back. In geographic space that is a pointless
 * out-and-back which inflates dirt distance without advancing the journey.
 *
 * Matching uses proximity cells (~20 m), not exact coordinate equality: dual
 * fabrics rarely share identical vertices even when they retrace the same
 * road, and that is what paints the "triangle" chords riders see on the map.
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

/**
 * Quantize lon/lat into ~cellMeters grid cells so near-miss dual-fabric
 * revisits still register as the same geographic place.
 */
function proximityKey(coord, cellMeters) {
  const latRad = (coord[1] * Math.PI) / 180;
  const metersPerLon = Math.max(1e-6, 111320 * Math.cos(latRad));
  const x = Math.round((coord[0] * metersPerLon) / cellMeters);
  const y = Math.round((coord[1] * 110540) / cellMeters);
  return { key: x + ":" + y, x, y };
}

function neighborKeys(x, y) {
  const keys = [];
  for (let dx = -1; dx <= 1; dx += 1) {
    for (let dy = -1; dy <= 1; dy += 1) {
      keys.push(x + dx + ":" + (y + dy));
    }
  }
  return keys;
}

function makeKeyFn(options) {
  const cellMeters =
    Number.isFinite(options.cellMeters) && options.cellMeters > 0
      ? options.cellMeters
      : 20;
  const matchMeters =
    Number.isFinite(options.matchMeters) && options.matchMeters > 0
      ? options.matchMeters
      : Math.max(cellMeters, 25);
  if (options.exactOnly) {
    const precision = Number.isInteger(options.precision) ? options.precision : 6;
    return {
      primary: (coord) => coordKey(coord, precision),
      candidates: (coord) => [coordKey(coord, precision)],
      matchMeters: 0
    };
  }
  return {
    primary: (coord) => proximityKey(coord, cellMeters).key,
    candidates: (coord) => {
      const { x, y } = proximityKey(coord, cellMeters);
      return neighborKeys(x, y);
    },
    matchMeters
  };
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

function findLargestLoop(edges, resolveCoords, keying, minLoopMeters) {
  const seen = new Map();
  let previousKey = null;
  let alongMeters = 0;
  let previousCoord = null;
  let largest = null;

  for (let edgeIndex = 0; edgeIndex < edges.length; edgeIndex += 1) {
    const coords = resolveCoords(edges[edgeIndex]) || [];
    for (let coordIndex = 0; coordIndex < coords.length; coordIndex += 1) {
      const coord = coords[coordIndex];
      const key = keying.primary(coord);
      // Adjacent segment boundaries repeat by construction; they are not loops.
      if (key === previousKey) continue;
      if (previousCoord) alongMeters += haversineMeters(previousCoord, coord);

      for (const candidateKey of keying.candidates(coord)) {
        const first = seen.get(candidateKey);
        if (!first) continue;
        if (keying.matchMeters > 0 && haversineMeters(first.coord, coord) > keying.matchMeters) {
          continue;
        }
        if (alongMeters - first.alongMeters >= minLoopMeters) {
          const candidate = {
            first,
            second: { edgeIndex, coordIndex, coord, alongMeters },
            loopMeters: alongMeters - first.alongMeters
          };
          if (!largest || candidate.loopMeters > largest.loopMeters) largest = candidate;
        }
      }
      if (!seen.has(key)) seen.set(key, { edgeIndex, coordIndex, coord, alongMeters });
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
    out.push(...edges.slice(second.edgeIndex + 1));
    return out;
  }

  const prefix = clonePiece(
    firstEdge,
    firstCoords.slice(0, first.coordIndex + 1),
    resolveCoords
  );
  if (prefix) out.push(prefix);

  const suffixCoords = secondCoords.slice(second.coordIndex);
  let suffix = clonePiece(secondEdge, suffixCoords, resolveCoords);
  const rest = edges.slice(second.edgeIndex + 1);

  // Near-miss joins can leave a single-vertex suffix. Drop it and stitch the
  // next edge onto the loop start so we do not open a geometry gap.
  if (!suffix && rest.length) {
    const nextCoords = (resolveCoords(rest[0]) || []).map((coord) => [...coord]);
    if (nextCoords.length >= 2) {
      nextCoords[0] = [...first.coord];
      suffix = clonePiece(rest[0], nextCoords, resolveCoords);
      if (suffix) {
        out.push(suffix, ...rest.slice(1));
        return out;
      }
    }
  }

  if (suffix) {
    const joinedCoords = (resolveCoords(suffix) || []).map((coord) => [...coord]);
    if (joinedCoords.length) joinedCoords[0] = [...first.coord];
    out.push({ ...suffix, coords: joinedCoords });
  }
  out.push(...rest);
  return out;
}

function totalMeters(edges) {
  return edges.reduce((sum, edge) => sum + (Number(edge.meters) || 0), 0);
}

/**
 * Loop-erases a path at repeated geographic vertices (proximity cells by default).
 * Returns original edge objects when no loop is present.
 *
 * Options:
 *   cellMeters   — proximity grid size (default 20). Set exactOnly to skip.
 *   exactOnly    — legacy precision-N exact coordinate keys
 *   precision    — used only with exactOnly (default 6)
 *   minLoopMeters — ignore tiny revisits (default 50)
 */
function pruneGeographicLoops(edges, resolveCoords, options = {}) {
  const minLoopMeters =
    Number.isFinite(options.minLoopMeters) && options.minLoopMeters >= 0
      ? options.minLoopMeters
      : 50;
  const keying = makeKeyFn(options);
  const beforeMeters = totalMeters(edges);
  let result = edges;
  let prunedLoopCount = 0;

  // Each pass removes at least one coordinate interval. The guard prevents a
  // malformed self-overlapping polyline from consuming unbounded CPU.
  for (let pass = 0; pass < 100; pass += 1) {
    const loop = findLargestLoop(result, resolveCoords, keying, minLoopMeters);
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

module.exports = {
  pruneGeographicLoops,
  proximityKey: (coord, cellMeters) => proximityKey(coord, cellMeters).key
};
