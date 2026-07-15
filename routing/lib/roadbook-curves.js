/**
 * Geometry-derived rally roadbook curve cues.
 * One authoritative generator for navigation HUD + speech + tests.
 *
 * Roadbook numbers (do not invert):
 *   6 = fast / easy, 5 = moderate-fast, 4 = normal,
 *   3 = tighter, 2 = very tight, 1 = hairpin
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.RoadbookCurves = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const DEFAULTS = {
    densifyMeters: 15,
    smoothWindow: 3,
    minTurnDeg: 28,
    startRateDeg: 1.8,
    continueRateDeg: 0.7,
    minCurveLengthM: 28,
    minSeparationM: 80,
    mergeJunctionM: 70,
    endQuietSamples: 2
  };

  function haversineMeters(a, b) {
    const R = 6371000;
    const toRad = Math.PI / 180;
    const dLat = (b[1] - a[1]) * toRad;
    const dLng = (b[0] - a[0]) * toRad;
    const lat1 = a[1] * toRad;
    const lat2 = b[1] * toRad;
    const x =
      Math.sin(dLat / 2) ** 2 +
      Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
    return 2 * R * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
  }

  function bearingDeg(a, b) {
    const toRad = Math.PI / 180;
    const φ1 = a[1] * toRad;
    const φ2 = b[1] * toRad;
    const Δλ = (b[0] - a[0]) * toRad;
    const y = Math.sin(Δλ) * Math.cos(φ2);
    const x =
      Math.cos(φ1) * Math.sin(φ2) -
      Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ);
    return ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
  }

  function angleDeltaDeg(a, b) {
    let d = b - a;
    while (d > 180) d -= 360;
    while (d < -180) d += 360;
    return d;
  }

  function densify(coords, stepM) {
    if (!coords || coords.length < 2) return [];
    const out = [coords[0]];
    for (let i = 1; i < coords.length; i += 1) {
      const a = coords[i - 1];
      const b = coords[i];
      const segM = haversineMeters(a, b);
      const steps = Math.max(1, Math.ceil(segM / stepM));
      for (let s = 1; s <= steps; s += 1) {
        const t = s / steps;
        out.push([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]);
      }
    }
    return out;
  }

  function smoothCircular(values, window) {
    if (!values.length) return [];
    const half = Math.max(1, window | 0);
    const out = new Array(values.length);
    for (let i = 0; i < values.length; i += 1) {
      let sx = 0;
      let sy = 0;
      let n = 0;
      for (let j = i - half; j <= i + half; j += 1) {
        if (j < 0 || j >= values.length) continue;
        const rad = (values[j] * Math.PI) / 180;
        sx += Math.cos(rad);
        sy += Math.sin(rad);
        n += 1;
      }
      out[i] = ((Math.atan2(sy / n, sx / n) * 180) / Math.PI + 360) % 360;
    }
    return out;
  }

  /**
   * Classify a curve from heading change + length (radius), not angle alone.
   * Returns null when below the meaningful-turn threshold.
   */
  function classifyCurve(totalAbsDeg, lengthM, opts) {
    const minTurn = (opts && opts.minTurnDeg) || DEFAULTS.minTurnDeg;
    if (!(totalAbsDeg >= minTurn) || !(lengthM > 0)) return null;

    const angleRad = (totalAbsDeg * Math.PI) / 180;
    const radiusM = lengthM / Math.max(angleRad, 0.08);

    // Radius-led numbering; long sweeps stay high even at ~90°.
    let number;
    if (radiusM >= 220) number = 6;
    else if (radiusM >= 140) number = 5;
    else if (radiusM >= 85) number = 4;
    else if (radiusM >= 50) number = 3;
    else if (radiusM >= 28) number = 2;
    else number = 1;

    // Sweeping 80–100° corner on a large radius must not become a 3.
    if (totalAbsDeg >= 75 && radiusM >= 160) number = Math.max(number, 5);
    if (totalAbsDeg >= 75 && radiusM >= 240) number = 6;

    // Short, decisive medium angles on a small radius get tighter numbers.
    if (totalAbsDeg >= 55 && lengthM < 55 && radiusM < 45) {
      number = Math.min(number, 3);
    }
    if (totalAbsDeg >= 70 && lengthM < 45 && radiusM < 32) {
      number = Math.min(number, 2);
    }

    // Hairpin only when geometry supports it — not merely a large angle.
    if (number === 1) {
      const hairpin = totalAbsDeg >= 120 && radiusM < 36;
      if (!hairpin) number = 2;
    } else if (totalAbsDeg >= 140 && radiusM < 28) {
      number = 1;
    }

    // Tiny wiggles that somehow passed minTurn with huge synthetic radius.
    if (totalAbsDeg < 35 && number <= 3) number = 6;

    const confidence = Math.max(
      0.35,
      Math.min(
        0.98,
        0.45 +
          Math.min(totalAbsDeg, 160) / 320 +
          Math.min(lengthM, 120) / 400
      )
    );

    let severity = "easy";
    if (number <= 2) severity = "tight";
    else if (number <= 4) severity = "normal";
    else severity = "fast";

    return {
      number,
      radiusM: Math.round(radiusM),
      confidence: Math.round(confidence * 100) / 100,
      severity
    };
  }

  function formatCurveLabels(side, number, isHairpin) {
    const dir = side === "right" ? "RIGHT" : "LEFT";
    const spokenDir = side === "right" ? "right" : "left";
    if (isHairpin && number === 1) {
      return {
        text: dir + " 1 HAIRPIN",
        spoken: spokenDir + " 1 hairpin",
        key: "1-" + spokenDir + "-hairpin"
      };
    }
    return {
      text: dir + " " + number,
      spoken: spokenDir + " " + number,
      key: number + "-" + spokenDir
    };
  }

  function buildCurveEvents(coords, options) {
    const opts = Object.assign({}, DEFAULTS, options || {});
    const dense = densify(coords, opts.densifyMeters);
    if (dense.length < 6) return [];

    const alongM = new Array(dense.length);
    alongM[0] = 0;
    for (let i = 1; i < dense.length; i += 1) {
      alongM[i] = alongM[i - 1] + haversineMeters(dense[i - 1], dense[i]);
    }

    const rawBearings = [];
    for (let i = 0; i < dense.length - 1; i += 1) {
      rawBearings.push(bearingDeg(dense[i], dense[i + 1]));
    }
    // Last sample mirrors previous for window math.
    rawBearings.push(rawBearings[rawBearings.length - 1]);
    const bearings = smoothCircular(rawBearings, opts.smoothWindow);

    const rates = new Array(bearings.length).fill(0);
    for (let i = 1; i < bearings.length; i += 1) {
      rates[i] = angleDeltaDeg(bearings[i - 1], bearings[i]);
    }

    const events = [];
    let i = 1;
    while (i < rates.length) {
      const rate = rates[i];
      if (Math.abs(rate) < opts.startRateDeg) {
        i += 1;
        continue;
      }
      const sign = rate > 0 ? 1 : -1;
      const startI = i;
      let totalDeg = 0;
      let quiet = 0;
      let endI = i;

      while (i < rates.length) {
        const r = rates[i];
        const same = r === 0 ? false : r > 0 === sign > 0;
        if (same && Math.abs(r) >= opts.continueRateDeg) {
          totalDeg += Math.abs(r);
          endI = i;
          quiet = 0;
          i += 1;
          continue;
        }
        if (same && Math.abs(r) >= opts.continueRateDeg * 0.45) {
          totalDeg += Math.abs(r);
          endI = i;
          quiet = 0;
          i += 1;
          continue;
        }
        quiet += 1;
        if (quiet > opts.endQuietSamples) break;
        i += 1;
      }

      // Use the high-rate core for radius/class so approach bleed from
      // bearing smoothing does not soften a real hairpin into a 2.
      let coreStart = startI;
      let coreEnd = endI;
      let acc = 0;
      const targetLo = totalDeg * 0.08;
      const targetHi = totalDeg * 0.92;
      for (let k = startI; k <= endI; k += 1) {
        const r = Math.abs(rates[k]);
        if (r >= opts.continueRateDeg) {
          if (acc < targetLo) coreStart = k;
          acc += r;
          coreEnd = k;
          if (acc >= targetHi) break;
        }
      }
      const lengthM = Math.max(
        opts.minCurveLengthM * 0.5,
        alongM[coreEnd] - alongM[coreStart]
      );
      const spanM = alongM[endI] - alongM[startI];
      const classified = classifyCurve(totalDeg, lengthM, opts);
      if (
        classified &&
        spanM >= opts.minCurveLengthM &&
        totalDeg >= opts.minTurnDeg
      ) {
        const side = sign > 0 ? "right" : "left";
        const isHairpin = classified.number === 1;
        const labels = formatCurveLabels(side, classified.number, isHairpin);
        const apexI = Math.min(
          dense.length - 1,
          Math.round((coreStart + coreEnd) / 2)
        );
        events.push({
          alongKm: alongM[startI] / 1000,
          apexAlongKm: alongM[apexI] / 1000,
          endAlongKm: alongM[endI] / 1000,
          coord: dense[startI],
          apexCoord: dense[apexI],
          direction: side.toUpperCase(),
          side,
          number: classified.number,
          degrees: Math.round(totalDeg),
          curveLengthM: Math.round(lengthM),
          radiusM: classified.radiusM,
          severity: classified.severity,
          confidence: classified.confidence,
          source: "geometry",
          kind: "curve",
          delta: sign * totalDeg,
          text: labels.text,
          spoken: labels.spoken,
          key: labels.key + "-c-" + (alongM[startI] / 1000).toFixed(3),
          exitBearing: Math.round(bearings[endI])
        });
      }
    }

    // Drop duplicates within min separation (keep stronger / lower number).
    const pruned = [];
    for (const ev of events) {
      const prev = pruned[pruned.length - 1];
      if (
        prev &&
        (ev.alongKm - prev.alongKm) * 1000 < opts.minSeparationM
      ) {
        if (ev.number < prev.number) pruned[pruned.length - 1] = ev;
        continue;
      }
      pruned.push(ev);
    }
    return pruned;
  }

  function distanceToCueMeters(riderAlongKm, cueAlongKm) {
    return Math.max(0, Math.round((cueAlongKm - riderAlongKm) * 1000));
  }

  function classifyJunctionDelta(deltaDeg, opts) {
    // Junctions are short; estimate a compact length from the deflection.
    const abs = Math.abs(deltaDeg);
    const lengthM = Math.max(22, Math.min(55, abs * 0.45));
    const classified = classifyCurve(abs, lengthM, opts);
    if (!classified) {
      return {
        number: 0,
        side: null,
        key: "straight",
        text: "Straight",
        spoken: "straight",
        severity: "straight",
        degrees: Math.round(abs),
        confidence: 0
      };
    }
    const side = deltaDeg > 0 ? "right" : "left";
    const isHairpin = classified.number === 1;
    const labels = formatCurveLabels(side, classified.number, isHairpin);
    return {
      number: classified.number,
      side,
      key: labels.key,
      text: labels.text,
      spoken: labels.spoken,
      severity: classified.severity,
      degrees: Math.round(abs),
      confidence: classified.confidence,
      radiusM: classified.radiusM
    };
  }

  /**
   * Merge geometry curves with junction cues for ALL mode.
   * Junction-only mode should pass curves=[] or call junctions alone.
   */
  function mergeNavCues(curves, junctions, options) {
    const opts = Object.assign({}, DEFAULTS, options || {});
    const items = [];
    for (const c of curves || []) items.push(Object.assign({}, c));
    for (const j of junctions || []) {
      if (!j || j.severity === "arrive") continue;
      items.push(
        Object.assign({}, j, {
          kind: "junction",
          source: j.source || "junction",
          direction: j.side ? String(j.side).toUpperCase() : null
        })
      );
    }
    items.sort((a, b) => a.alongKm - b.alongKm);

    const merged = [];
    for (const item of items) {
      const prev = merged[merged.length - 1];
      if (
        prev &&
        Math.abs(item.alongKm - prev.alongKm) * 1000 < opts.mergeJunctionM
      ) {
        // Prefer real junction decision when overlapping a geometry curve.
        if (item.kind === "junction" && prev.kind !== "junction") {
          merged[merged.length - 1] = Object.assign({}, item, {
            // Keep the tighter roadbook number if curve was more severe.
            number:
              prev.number && item.number
                ? Math.min(prev.number, item.number)
                : item.number || prev.number,
            text:
              prev.number && item.number && prev.number < item.number
                ? prev.text
                : item.text,
            spoken:
              prev.number && item.number && prev.number < item.number
                ? prev.spoken
                : item.spoken
          });
          const keep = merged[merged.length - 1];
          if (keep.number && keep.side) {
            const labels = formatCurveLabels(
              keep.side,
              keep.number,
              keep.number === 1
            );
            keep.text = labels.text;
            keep.spoken = labels.spoken;
          }
        } else if (item.kind !== "junction" && prev.kind === "junction") {
          if (item.number && prev.number && item.number < prev.number) {
            prev.number = item.number;
            const labels = formatCurveLabels(
              prev.side || item.side,
              prev.number,
              prev.number === 1
            );
            prev.text = labels.text;
            prev.spoken = labels.spoken;
            prev.degrees = item.degrees || prev.degrees;
          }
        } else if (item.number && prev.number && item.number < prev.number) {
          merged[merged.length - 1] = item;
        }
        continue;
      }
      if (
        prev &&
        (item.alongKm - prev.alongKm) * 1000 < opts.minSeparationM &&
        item.kind !== "junction"
      ) {
        if (item.number < prev.number) merged[merged.length - 1] = item;
        continue;
      }
      merged.push(item);
    }
    return merged;
  }

  return {
    DEFAULTS,
    haversineMeters,
    bearingDeg,
    angleDeltaDeg,
    densify,
    classifyCurve,
    classifyJunctionDelta,
    buildCurveEvents,
    mergeNavCues,
    distanceToCueMeters,
    formatCurveLabels
  };
});
