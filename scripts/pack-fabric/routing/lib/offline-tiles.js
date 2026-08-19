(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DirtOfflineTiles = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function mercatorX(lon) {
    return (lon + 180) / 360;
  }

  function mercatorY(lat) {
    const safeLat = clamp(lat, -85.05112878, 85.05112878);
    const rad = safeLat * Math.PI / 180;
    return (1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2;
  }

  function coordToTile(coord, z) {
    const scale = 2 ** z;
    return {
      x: clamp(Math.floor(mercatorX(coord[0]) * scale), 0, scale - 1),
      y: clamp(Math.floor(mercatorY(coord[1]) * scale), 0, scale - 1)
    };
  }

  function tileKey(z, x, y) {
    return z + "/" + x + "/" + y;
  }

  function validCoords(coords) {
    return (coords || []).filter((coord) =>
      Array.isArray(coord) &&
      Number.isFinite(Number(coord[0])) &&
      Number.isFinite(Number(coord[1]))
    ).map((coord) => [Number(coord[0]), Number(coord[1])]);
  }

  function routeBounds(coords, paddingRatio) {
    let minLon = Infinity;
    let minLat = Infinity;
    let maxLon = -Infinity;
    let maxLat = -Infinity;
    for (const coord of coords) {
      minLon = Math.min(minLon, coord[0]);
      minLat = Math.min(minLat, coord[1]);
      maxLon = Math.max(maxLon, coord[0]);
      maxLat = Math.max(maxLat, coord[1]);
    }
    const lonPad = Math.max(0.002, (maxLon - minLon) * paddingRatio);
    const latPad = Math.max(0.002, (maxLat - minLat) * paddingRatio);
    return [
      clamp(minLon - lonPad, -180, 180),
      clamp(minLat - latPad, -85.05112878, 85.05112878),
      clamp(maxLon + lonPad, -180, 180),
      clamp(maxLat + latPad, -85.05112878, 85.05112878)
    ];
  }

  function fitZoomForBounds(bounds, viewport, maxZoom) {
    const width = Math.max(120, Number(viewport && viewport.width) || 390);
    const height = Math.max(120, Number(viewport && viewport.height) || 844);
    const usableWidth = Math.max(80, width - 80);
    const usableHeight = Math.max(80, height - 250);
    const xSpan = Math.max(1e-9, Math.abs(mercatorX(bounds[2]) - mercatorX(bounds[0])));
    const ySpan = Math.max(1e-9, Math.abs(mercatorY(bounds[3]) - mercatorY(bounds[1])));
    const scale = Math.min(usableWidth / (512 * xSpan), usableHeight / (512 * ySpan));
    return clamp(Math.floor(Math.log2(Math.max(1, scale))), 0, maxZoom);
  }

  function traceRouteTileKeys(rawCoords, z) {
    const coords = validCoords(rawCoords);
    const keys = new Set();
    if (!coords.length) return keys;
    const scale = 2 ** z;
    for (let i = 1; i < coords.length; i += 1) {
      const a = [mercatorX(coords[i - 1][0]) * scale, mercatorY(coords[i - 1][1]) * scale];
      const b = [mercatorX(coords[i][0]) * scale, mercatorY(coords[i][1]) * scale];
      const steps = Math.max(1, Math.ceil(Math.max(Math.abs(b[0] - a[0]), Math.abs(b[1] - a[1])) * 2));
      for (let step = 0; step <= steps; step += 1) {
        const t = step / steps;
        const x = clamp(Math.floor(a[0] + (b[0] - a[0]) * t), 0, scale - 1);
        const y = clamp(Math.floor(a[1] + (b[1] - a[1]) * t), 0, scale - 1);
        keys.add(tileKey(z, x, y));
      }
    }
    if (coords.length === 1) {
      const tile = coordToTile(coords[0], z);
      keys.add(tileKey(z, tile.x, tile.y));
    }
    return keys;
  }

  function parseKey(key) {
    const parts = key.split("/").map(Number);
    return { z: parts[0], x: parts[1], y: parts[2] };
  }

  function evenlySelect(values, limit) {
    if (limit <= 0 || !values.length) return [];
    if (values.length <= limit) return values.slice();
    if (limit === 1) return [values[0]];
    const selected = [];
    const seen = new Set();
    for (let i = 0; i < limit; i += 1) {
      const index = Math.round(i * (values.length - 1) / (limit - 1));
      const value = values[index];
      if (!seen.has(value)) {
        seen.add(value);
        selected.push(value);
      }
    }
    return selected;
  }

  function levelCandidates(coords, bounds, z) {
    const max = 2 ** z;
    const core = Array.from(traceRouteTileKeys(coords, z));
    const all = new Set(core);
    const padding = z >= 12 ? 1 : 0;

    if (z <= 11) {
      const nw = coordToTile([bounds[0], bounds[3]], z);
      const se = coordToTile([bounds[2], bounds[1]], z);
      const area = (se.x - nw.x + 3) * (se.y - nw.y + 3);
      if (area <= 180) {
        for (let x = Math.max(0, nw.x - 1); x <= Math.min(max - 1, se.x + 1); x += 1) {
          for (let y = Math.max(0, nw.y - 1); y <= Math.min(max - 1, se.y + 1); y += 1) {
            all.add(tileKey(z, x, y));
          }
        }
      }
    } else if (padding) {
      for (const key of core) {
        const tile = parseKey(key);
        for (let dx = -padding; dx <= padding; dx += 1) {
          for (let dy = -padding; dy <= padding; dy += 1) {
            const x = tile.x + dx;
            const y = tile.y + dy;
            if (x >= 0 && y >= 0 && x < max && y < max) all.add(tileKey(z, x, y));
          }
        }
      }
    }

    return { z, core, extras: Array.from(all).filter((key) => !core.includes(key)) };
  }

  function collectRouteTiles(rawCoords, options) {
    const coords = validCoords(rawCoords);
    const opts = options || {};
    const maxZoom = clamp(Number(opts.maxNativeZoom) || 14, 0, 22);
    const maxTiles = Math.max(32, Number(opts.maxTiles) || 1200);
    if (coords.length < 2) {
      return { tiles: [], fitZoom: maxZoom, minZoom: maxZoom, maxZoom, truncated: false };
    }

    const bounds = routeBounds(coords, Number(opts.paddingRatio) || 0.05);
    const fitZoom = fitZoomForBounds(bounds, opts.viewport, maxZoom);
    const levels = [];
    for (let z = fitZoom; z <= maxZoom; z += 1) levels.push(levelCandidates(coords, bounds, z));
    const totalCandidates = levels.reduce((sum, level) => sum + level.core.length + level.extras.length, 0);

    let selectedKeys;
    if (totalCandidates <= maxTiles) {
      selectedKeys = levels.flatMap((level) => level.core.concat(level.extras));
    } else {
      const weights = levels.map((level, index) => Math.max(1, (index + 1) ** 1.35));
      const weightTotal = weights.reduce((sum, weight) => sum + weight, 0);
      const budgets = weights.map((weight) => Math.max(2, Math.floor(maxTiles * weight / weightTotal)));
      while (budgets.reduce((sum, value) => sum + value, 0) > maxTiles) {
        const index = budgets.findIndex((value) => value > 2);
        if (index < 0) break;
        budgets[index] -= 1;
      }
      while (budgets.reduce((sum, value) => sum + value, 0) < maxTiles) {
        budgets[budgets.length - 1] += 1;
      }
      selectedKeys = levels.flatMap((level, index) => {
        const budget = budgets[index];
        const core = evenlySelect(level.core, Math.min(level.core.length, budget));
        const remaining = budget - core.length;
        return core.concat(evenlySelect(level.extras, Math.max(0, remaining)));
      });
    }

    return {
      tiles: selectedKeys.map(parseKey),
      fitZoom,
      minZoom: fitZoom,
      maxZoom,
      bounds,
      truncated: totalCandidates > maxTiles,
      candidateCount: totalCandidates
    };
  }

  return {
    collectRouteTiles,
    coordToTile,
    fitZoomForBounds,
    routeBounds,
    traceRouteTileKeys
  };
});
