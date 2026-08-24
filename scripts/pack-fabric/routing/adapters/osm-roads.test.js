"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  classify,
  explicitSurfaceClass,
  effectiveMotorcycleAccess,
  INCLUDE_HIGHWAY
} = require("./osm-roads");
const { accessAllowed } = require("../lib/router");

test("explicit OSM surface tags map to honest riding surfaces", () => {
  assert.equal(explicitSurfaceClass("asphalt"), "paved");
  assert.equal(explicitSurfaceClass("chipseal"), "paved");
  assert.equal(explicitSurfaceClass("brick"), "paved");
  assert.equal(explicitSurfaceClass("gravel"), "gravel");
  assert.equal(explicitSurfaceClass("loose_gravel"), "gravel");
  assert.equal(explicitSurfaceClass("bare_rock"), "resource");
  assert.equal(explicitSurfaceClass("dirt;gravel"), "unknown");
  assert.equal(explicitSurfaceClass("asphalt;concrete"), "paved");
  assert.equal(explicitSurfaceClass("invented_surface"), "unknown");
});

test("missing minor-road surface is never invented as dirt", () => {
  for (const highway of ["service", "residential", "unclassified", "road", "track"]) {
    const result = classify({ highway });
    assert.equal(result.ok, true, highway);
    assert.equal(result.surfaceClass, "unknown", highway);
    assert.equal(result.confidence, "low", highway);
  }
  // path without atv is excluded; path with atv keeps unknown surface when untagged.
  assert.equal(classify({ highway: "path", atv: "yes" }).surfaceClass, "unknown");
});

test("explicit surface always wins over road-type fallback", () => {
  assert.equal(classify({ highway: "service", surface: "asphalt" }).surfaceClass, "paved");
  assert.equal(classify({ highway: "track", surface: "asphalt" }).surfaceClass, "paved");
  assert.equal(classify({ highway: "service", surface: "gravel" }).surfaceClass, "gravel");
  assert.equal(classify({ highway: "track", surface: "rubber" }).surfaceClass, "paved");
});

test("conventional untagged major roads retain the paved default", () => {
  for (const highway of ["motorway", "trunk", "primary", "secondary", "tertiary", "primary_link"]) {
    assert.equal(classify({ highway }).surfaceClass, "paved", highway);
  }
});

test("motorcycle-specific access overrides broader OSM access tags", () => {
  assert.deepEqual(
    effectiveMotorcycleAccess({ access: "no", motor_vehicle: "no", motorcycle: "yes" }),
    { key: "motorcycle", value: "yes" }
  );
  assert.equal(classify({ highway: "track", access: "no", motorcycle: "yes" }).ok, true);
  assert.equal(classify({ highway: "track", motor_vehicle: "yes", motorcycle: "no" }).ok, false);
});

test("known through-access restrictions do not become permissive green edges", () => {
  for (const access of ["private", "customers", "delivery", "forestry", "agricultural", "destination"]) {
    const result = classify({ highway: "service", access });
    assert.equal(result.ok, false, access);
    assert.equal(result.reason, "access_restricted", access);
  }
});

test("adventure membership: cycleway dropped; path requires positive atv", () => {
  assert.equal(INCLUDE_HIGHWAY.has("cycleway"), false);
  assert.equal(INCLUDE_HIGHWAY.has("path"), true);
  assert.equal(INCLUDE_HIGHWAY.has("track"), true);
  assert.equal(classify({ highway: "cycleway" }).ok, false);
  assert.equal(classify({ highway: "cycleway" }).reason, "highway_excluded");
  assert.equal(classify({ highway: "path" }).ok, false);
  assert.equal(classify({ highway: "path" }).reason, "path_without_atv");
  assert.equal(classify({ highway: "path", atv: "yes" }).ok, true);
  assert.equal(classify({ highway: "path", atv: "designated" }).ok, true);
  assert.equal(classify({ highway: "path", atv: "permissive" }).ok, true);
  assert.equal(classify({ highway: "track" }).ok, true);
});

test("positive atv overrides motorcycle=no but never access=private|no", () => {
  const recovered = classify({ highway: "path", atv: "yes", motorcycle: "no" });
  assert.equal(recovered.ok, true);
  assert.equal(recovered.accessClass, "motorized_permissive");

  const trackRecovered = classify({ highway: "track", atv: "yes", motorcycle: "no" });
  assert.equal(trackRecovered.ok, true);
  assert.equal(trackRecovered.accessClass, "motorized_permissive");

  assert.equal(classify({ highway: "path", atv: "yes", access: "private" }).ok, false);
  assert.equal(classify({ highway: "path", atv: "yes", access: "no" }).ok, false);
  assert.equal(
    classify({ highway: "path", atv: "yes", motorcycle: "no", access: "private" }).ok,
    false
  );
  // Without atv, motorcycle=no still excludes.
  assert.equal(classify({ highway: "track", motorcycle: "no" }).ok, false);
});

test("OSM source identity cannot bypass an unknown access class", () => {
  const enums = {
    ACCESS_NAME: {
      1: "motorized_permissive",
      2: "motorized_unknown"
    }
  };
  assert.equal(
    accessAllowed(2, { motorizedPermissive: true, motorizedUnknown: false }, enums, { src: "OpenStreetMap" }),
    false
  );
  assert.equal(
    accessAllowed(2, { motorizedPermissive: true, motorizedUnknown: true }, enums, { src: "OpenStreetMap" }),
    true
  );
});

test("Allow unknown is an eligibility gate for dirt/balanced/direct, not a cost", () => {
  const enums = {
    ACCESS_NAME: {
      1: "motorized_permissive",
      2: "motorized_unknown"
    }
  };
  const off = { motorizedPermissive: true, motorizedUnknown: false };
  const on = { motorizedPermissive: true, motorizedUnknown: true };
  for (const profile of ["dirt", "balanced", "direct"]) {
    assert.equal(accessAllowed(2, off, enums, null, profile), false, profile + " off");
    assert.equal(accessAllowed(2, on, enums, null, profile), true, profile + " on");
    assert.equal(accessAllowed(1, off, enums, null, profile), true, profile + " permissive");
  }
  assert.equal(accessAllowed(2, on, enums, null, "cleanest"), false);
  const { normalizePolicy } = require("../lib/router");
  assert.equal(normalizePolicy({}, "direct", { allowUnknown: true }).motorizedUnknown, true);
  assert.equal(normalizePolicy({}, "direct", { allowUnknown: false }).motorizedUnknown, false);
  assert.equal(normalizePolicy({ motorizedUnknown: true }, "cleanest", { allowUnknown: true }).motorizedUnknown, false);
});

test("leaf fields populate alongside unchanged coarse classes", () => {
  const { leafFieldsFromProps } = require("./osm-roads");
  const leaves = leafFieldsFromProps({
    highway: "track",
    surface: "fine_gravel",
    tracktype: "grade2",
    smoothness: "bad",
    layer: "1",
    bridge: "boardwalk",
    motorcycle: "no",
    atv: "yes"
  });
  assert.equal(leaves.surfaceLeaf, "fine_gravel");
  assert.equal(leaves.roadClassLeaf, "track");
  assert.equal(leaves.tracktype, "grade2");
  assert.equal(leaves.smoothness, "bad");
  assert.equal(leaves.layer, 1);
  assert.equal(leaves.structureLeaf, "boardwalk");
  assert.equal(leaves.accessLeaf, "no");
  assert.equal(leaves.atv, "yes");
  assert.equal(leaves.atvDesignated, true);
  const classified = classify({
    highway: "track",
    surface: "fine_gravel",
    bridge: "boardwalk",
    atv: "yes",
    motorcycle: "no"
  });
  assert.equal(classified.ok, true);
  assert.equal(classified.surfaceClass, "gravel");
  assert.equal(classified.structureType, "bridge");
  assert.equal(classified.accessClass, "motorized_permissive");
});

test("ford / tunnel / viaduct / culvert set coarse structureType from richer leaves", () => {
  assert.equal(classify({ highway: "unclassified", ford: "stepping_stones" }).structureType, "ford");
  assert.equal(classify({ highway: "unclassified", tunnel: "culvert" }).structureType, "tunnel");
  assert.equal(classify({ highway: "unclassified", bridge: "viaduct" }).structureType, "bridge");
  assert.equal(classify({ highway: "unclassified", bridge: "low_water_crossing" }).structureType, "ford");
  const { leafFieldsFromProps } = require("./osm-roads");
  assert.equal(leafFieldsFromProps({ highway: "track", ford: "stream" }).structureLeaf, "stream");
  assert.equal(leafFieldsFromProps({ highway: "secondary", layer: "-1" }).layer, -1);
  assert.equal(leafFieldsFromProps({ highway: "primary", bridge: "yes", layer: "1" }).layer, 1);
});

test("createNormalizedEdge defaults leaf fields safely when omitted", () => {
  const { createNormalizedEdge } = require("../schema/edge");
  const edge = createNormalizedEdge({
    edgeId: "t1",
    geometry: { type: "LineString", coordinates: [[-63, 44], [-63.1, 44.1]] },
    surfaceClass: "paved",
    accessClass: "motorized_permissive",
    structureType: "none",
    roadTrackClass: "local"
  });
  assert.equal(edge.surfaceLeaf, null);
  assert.equal(edge.roadClassLeaf, "unknown");
  assert.equal(edge.tracktype, null);
  assert.equal(edge.smoothness, null);
  assert.equal(edge.layer, 0);
  assert.equal(edge.structureLeaf, null);
  assert.equal(edge.accessLeaf, null);
  assert.equal(edge.atv, null);
  assert.equal(edge.atvDesignated, false);
  assert.equal(edge.surfaceClass, "paved");
});

test("route=ferry ways classify as timed ferry connectors", () => {
  const ferry = classify({ route: "ferry", duration: "15" });
  assert.equal(ferry.ok, true);
  assert.equal(ferry.isFerry, true);
  assert.equal(ferry.structureType, "ferry");
  assert.equal(ferry.surfaceClass, "unknown");
  assert.equal(ferry.roadTrackClass, "unknown");
});

test("route=ferry rejects vehicle=no and private access", () => {
  assert.equal(classify({ route: "ferry", motor_vehicle: "no" }).ok, false);
  assert.equal(classify({ route: "ferry", access: "private" }).ok, false);
});

test("ferry connectors are not highway leaf fields", () => {
  const { leafFieldsFromProps } = require("./osm-roads");
  const leaves = leafFieldsFromProps({ route: "ferry", duration: "10" });
  assert.equal(leaves.surfaceLeaf, null);
  assert.equal(leaves.roadClassLeaf, "unknown");
  const classified = classify({ route: "ferry", duration: "10" });
  assert.equal(classified.structureType, "ferry");
});
