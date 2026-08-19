"use strict";

/**
 * Grade-separation buckets for regional pack node identity (Phase A).
 * Same XY + different bucket → distinct nodes → no false overpass turn.
 *
 * Precedence: structureType bridge/tunnel first, then OSM layer/level, else ground.
 * Ford stays ground (at-grade water crossing, not stacked roads).
 */

function gradeBucketFromFeature(feature) {
  if (!feature || typeof feature !== "object") return "ground";
  const st = feature.structureType;
  if (st === "bridge") return "bridge";
  if (st === "tunnel") return "tunnel";

  const meta = feature.meta || {};
  const layerRaw = meta.layer != null ? meta.layer : meta.osmLayer;
  const layerBucket = layerOrLevelBucket(layerRaw);
  if (layerBucket) return layerBucket;

  const levelBucket = layerOrLevelBucket(meta.level);
  if (levelBucket) return levelBucket;

  return "ground";
}

function layerOrLevelBucket(raw) {
  if (raw == null || raw === "") return null;
  const s = String(raw).trim();
  // OSM level can be "0;1" — take first integer token only.
  const m = s.match(/^-?\d+/);
  if (!m) return null;
  const n = Number(m[0]);
  if (!Number.isFinite(n)) return null;
  return "layer:" + String(Math.trunc(n));
}

function coordKey5(coord) {
  return Number(coord[0]).toFixed(5) + "," + Number(coord[1]).toFixed(5);
}

function nodeKeyGraded(coord, gradeBucket) {
  return coordKey5(coord) + "|" + (gradeBucket || "ground");
}

function gradesCompatible(a, b) {
  return (a || "ground") === (b || "ground");
}

module.exports = {
  gradeBucketFromFeature,
  layerOrLevelBucket,
  coordKey5,
  nodeKeyGraded,
  gradesCompatible
};
