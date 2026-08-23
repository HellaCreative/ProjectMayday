"use strict";

const {
  SURFACE_CLASS,
  ACCESS_CLASS,
  STRUCTURE_TYPE,
  ROAD_TRACK_CLASS,
  SOURCE_CONFIDENCE,
  PROVINCE_CODES,
  surfaceForCosting,
  accessForPolicy
} = require("./enums");

/**
 * Normalize optional OSM leaf strings. Empty / missing → null.
 * Compounds keep their full ordered token (e.g. "asphalt;gravel").
 */
function normalizeLeafString(value) {
  if (value == null) return null;
  const s = String(value).trim().toLowerCase();
  return s || null;
}

/**
 * Signed OSM layer as int; default 0 when absent / unparseable.
 */
function normalizeLayer(value) {
  if (value == null || value === "") return 0;
  const m = String(value).trim().match(/^-?\d+/);
  if (!m) return 0;
  const n = Number(m[0]);
  return Number.isFinite(n) ? Math.trunc(n) : 0;
}

/**
 * Create a canonical normalized edge record.
 * Missing access must remain unknown — never invent permissive.
 *
 * Coarse fields (surfaceClass, roadTrackClass, structureType, …) remain the
 * derived routing cache. OSM leaf fields are carried alongside for Graph-v3.
 */
function createNormalizedEdge(partial) {
  const surfaceClass = partial.surfaceClass || SURFACE_CLASS.unknown;
  const accessClass = partial.accessClass || ACCESS_CLASS.motorized_unknown;
  const structureType = partial.structureType || STRUCTURE_TYPE.none;
  const roadTrackClass = partial.roadTrackClass || ROAD_TRACK_CLASS.unknown;
  const confidence = partial.sourceConfidence || SOURCE_CONFIDENCE.medium;

  if (!SURFACE_CLASS[surfaceClass] && surfaceClass !== "access") {
    throw new Error("invalid_surface_class:" + surfaceClass);
  }
  if (!ACCESS_CLASS[accessClass] && !["motorized_verified", "motorized_restricted", "motorized_excluded"].includes(accessClass)) {
    throw new Error("invalid_access_class:" + accessClass);
  }
  if (!STRUCTURE_TYPE[structureType] && structureType !== "ford") {
    throw new Error("invalid_structure_type:" + structureType);
  }

  const geometry = partial.geometry;
  if (!geometry || geometry.type !== "LineString" || !Array.isArray(geometry.coordinates) || geometry.coordinates.length < 2) {
    throw new Error("invalid_geometry");
  }

  const surfaceLeaf = normalizeLeafString(
    partial.surfaceLeaf !== undefined ? partial.surfaceLeaf : null
  );
  const roadClassLeaf =
    normalizeLeafString(
      partial.roadClassLeaf !== undefined ? partial.roadClassLeaf : null
    ) || "unknown";
  const tracktype = normalizeLeafString(
    partial.tracktype !== undefined ? partial.tracktype : null
  );
  const smoothness = normalizeLeafString(
    partial.smoothness !== undefined ? partial.smoothness : null
  );
  const layer =
    partial.layer !== undefined && partial.layer !== null && partial.layer !== ""
      ? normalizeLayer(partial.layer)
      : 0;
  const structureLeaf = normalizeLeafString(
    partial.structureLeaf !== undefined ? partial.structureLeaf : null
  );
  const accessLeaf = normalizeLeafString(
    partial.accessLeaf !== undefined ? partial.accessLeaf : null
  );
  const atv = normalizeLeafString(partial.atv !== undefined ? partial.atv : null);
  const atvDesignated =
    partial.atvDesignated != null
      ? !!partial.atvDesignated
      : atv === "yes" || atv === "designated" || atv === "permissive";

  return {
    edgeId: String(partial.edgeId),
    lineageId: String(partial.lineageId || partial.edgeId),
    province: String(partial.province || ""),
    sourceName: String(partial.sourceName || ""),
    sourceDatasetVersion: partial.sourceDatasetVersion || null,
    sourceFeatureId: partial.sourceFeatureId != null ? String(partial.sourceFeatureId) : null,
    sourceGeometryLineage: partial.sourceGeometryLineage || null,
    geometry: {
      type: "LineString",
      coordinates: geometry.coordinates
    },
    startNodeId: partial.startNodeId != null ? partial.startNodeId : null,
    endNodeId: partial.endNodeId != null ? partial.endNodeId : null,
    componentId: partial.componentId != null ? Number(partial.componentId) : -1,
    surfaceClass,
    surfaceForCosting: surfaceForCosting(surfaceClass),
    roadTrackClass,
    accessClass,
    accessForPolicy: accessForPolicy(accessClass),
    structureType,
    // Graph-v3 leaf fields (Phase B2) — defaults safe when adapters omit them.
    surfaceLeaf,
    roadClassLeaf,
    tracktype,
    smoothness,
    layer,
    structureLeaf,
    accessLeaf,
    atv,
    atvDesignated,
    roadName: partial.roadName || null,
    direction: partial.direction || "both",
    seasonal: !!partial.seasonal,
    seasonalNotes: partial.seasonalNotes || null,
    sourceConfidence: confidence,
    exclusionReason: partial.exclusionReason || null,
    distanceMeters: Number(partial.distanceMeters) || 0,
    meta: partial.meta || {}
  };
}

function assertCanonicalEdge(edge) {
  createNormalizedEdge(edge);
  return true;
}

module.exports = {
  createNormalizedEdge,
  assertCanonicalEdge,
  normalizeLeafString,
  normalizeLayer,
  SURFACE_CLASS,
  ACCESS_CLASS,
  STRUCTURE_TYPE,
  ROAD_TRACK_CLASS,
  SOURCE_CONFIDENCE,
  PROVINCE_CODES
};
