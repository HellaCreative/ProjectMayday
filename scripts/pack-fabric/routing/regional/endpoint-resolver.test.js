"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { resolveLocationsByEligibleEdge } = require("./endpoint-resolver");
const { resolveGraphRequest } = require("./select");

test("admin polygon resolves an NS road inside overlapping province rectangles without graph I/O", async () => {
  const probes = [];
  const input = {
    profile: "dirt",
    allowUnknown: false,
    locations: [
      { lat: 45.874661, lon: -61.910289 },
      { lat: 43.651303, lon: -65.684758 }
    ]
  };
  const resolved = await resolveLocationsByEligibleEdge(input, {
    probeRegion: async (regionId, location) => {
      probes.push(regionId);
      if (location.lat === 45.874661 && regionId === "ns") {
        return {
          ok: true,
          edgeId: "ns-road",
          accessClass: "motorized_permissive",
          distanceM: 12
        };
      }
      if (location.lat === 45.874661) {
        return { ok: false, reason: "snap_no_eligible_edge" };
      }
      return {
        ok: true,
        edgeId: "ns-south-road",
        accessClass: "motorized_verified",
        distanceM: 8
      };
    }
  });

  assert.equal(resolved.body.locations[0].resolvedRegionId, "ns");
  assert.deepEqual(probes, []);
  assert.equal(resolved.resolutions[0].source, "admin_polygon");
  const selection = resolveGraphRequest(resolved.body);
  assert.deepEqual(selection.regionIds, ["ns"]);
  assert.notEqual(selection.mode, "canada-chain");
});

test("an admin-owned primary region does not probe overlapping packs", async () => {
  const probes = [];
  const resolved = await resolveLocationsByEligibleEdge({
    profile: "cleanest",
    locations: [{ lat: 46.24, lon: -63.13 }]
  }, {
    probeRegion: async (regionId) => {
      probes.push(regionId);
      return {
        ok: true,
        edgeId: `${regionId}-road`,
        accessClass: "motorized_verified",
        distanceM: 5
      };
    }
  });
  assert.equal(resolved.body.locations[0].resolvedRegionId, "pe");
  assert.deepEqual(probes, []);
  assert.equal(resolved.resolutions[0].source, "admin_polygon");
});

test("a polygon-ambiguous point still resolves by eligible road fabric", async () => {
  const probes = [];
  const resolved = await resolveLocationsByEligibleEdge({
    profile: "dirt",
    locations: [{ lat: 45.874661, lon: -61.910289 }]
  }, {
    regionOwner: () => null,
    probeRegion: async (regionId) => {
      probes.push(regionId);
      return regionId === "pe"
        ? { ok: true, edgeId: "pe-road", accessClass: "motorized_verified", distanceM: 5 }
        : { ok: false, reason: "snap_no_eligible_edge" };
    }
  });

  assert.equal(resolved.body.locations[0].resolvedRegionId, "pe");
  assert.deepEqual(probes, ["ns", "pe"]);
  assert.equal(resolved.resolutions[0].source, "eligible_edge_probe");
});
