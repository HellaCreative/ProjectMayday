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
 * Create a canonical normalized edge record.
 * Missing access must remain unknown — never invent permissive.
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
  SURFACE_CLASS,
  ACCESS_CLASS,
  STRUCTURE_TYPE,
  ROAD_TRACK_CLASS,
  SOURCE_CONFIDENCE,
  PROVINCE_CODES
};
