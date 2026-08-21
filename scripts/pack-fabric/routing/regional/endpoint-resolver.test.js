"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { resolveLocationsByEligibleEdge } = require("./endpoint-resolver");
const { resolveGraphRequest } = require("./select");

test("NS road inside the PE rectangle resolves by eligible edge, not bbox size", async () => {
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
  assert.ok(probes.indexOf("pe") < probes.indexOf("ns"));
  const selection = resolveGraphRequest(resolved.body);
  assert.deepEqual(selection.regionIds, ["ns"]);
  assert.notEqual(selection.mode, "canada-chain");
});

test("an eligible primary region does not probe every overlapping pack", async () => {
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
  assert.deepEqual(probes, ["pe"]);
});
