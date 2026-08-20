"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  classify,
  explicitSurfaceClass,
  effectiveMotorcycleAccess
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
  for (const highway of ["service", "residential", "unclassified", "road", "track", "path", "cycleway"]) {
    const result = classify({ highway });
    assert.equal(result.ok, true, highway);
    assert.equal(result.surfaceClass, "unknown", highway);
    assert.equal(result.confidence, "low", highway);
  }
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

test("path and cycleway remain Allow-gated without explicit motor access", () => {
  assert.equal(classify({ highway: "path" }).accessClass, "motorized_unknown");
  assert.equal(classify({ highway: "cycleway" }).accessClass, "motorized_unknown");
  assert.equal(classify({ highway: "path", motorcycle: "yes" }).accessClass, "motorized_permissive");
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
