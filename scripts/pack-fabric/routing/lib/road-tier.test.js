#!/usr/bin/env node
"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  roadTierOf,
  isBlockedForCleanLeaf,
  cleanLeafCostMult,
  e4AvoidMotorwaysMult,
  e4PreferBackRoadsMult,
  e4LeafCostMult,
  ROAD_TIER,
  E4_AVOID_MOTORWAY_MULT,
  E4_PREFER_BACK_ARTERIAL_MULT
} = require("./road-tier");

describe("road-tier E2 Clean", () => {
  it("maps highway leaves to locked tiers", () => {
    assert.equal(roadTierOf("secondary"), ROAD_TIER.COLLECTOR);
    assert.equal(roadTierOf("primary"), ROAD_TIER.ARTERIAL);
    assert.equal(roadTierOf("residential"), ROAD_TIER.DESTINATION);
    assert.equal(roadTierOf("motorway_link"), ROAD_TIER.MOTORWAY);
    assert.equal(roadTierOf("track"), ROAD_TIER.ADVENTURE);
  });

  it("blocks destination through-routes and adventure on pavedOnly", () => {
    assert.equal(
      isBlockedForCleanLeaf({
        family: "paved",
        tier: ROAD_TIER.DESTINATION,
        pavedOnly: true,
        isEndpointEdge: false
      }),
      true
    );
    assert.equal(
      isBlockedForCleanLeaf({
        family: "paved",
        tier: ROAD_TIER.DESTINATION,
        pavedOnly: true,
        isEndpointEdge: true
      }),
      false
    );
    assert.equal(
      isBlockedForCleanLeaf({
        family: "paved",
        tier: ROAD_TIER.COLLECTOR,
        pavedOnly: true,
        isEndpointEdge: false
      }),
      false
    );
    assert.equal(
      isBlockedForCleanLeaf({
        family: "gravel",
        tier: ROAD_TIER.COLLECTOR,
        pavedOnly: true,
        isEndpointEdge: false
      }),
      true
    );
  });

  it("prefers collector over arterial/motorway in cost", () => {
    const collector = cleanLeafCostMult(ROAD_TIER.COLLECTOR, "paved");
    const arterial = cleanLeafCostMult(ROAD_TIER.ARTERIAL, "paved");
    const motorway = cleanLeafCostMult(ROAD_TIER.MOTORWAY, "paved");
    assert.ok(collector < arterial);
    assert.ok(arterial < motorway);
  });
});

describe("road-tier E4 knobs", () => {
  it("defaults off leave costs at 1", () => {
    assert.equal(e4AvoidMotorwaysMult(ROAD_TIER.MOTORWAY, false, 1e9, 1e9, false, false), 1);
    assert.equal(e4PreferBackRoadsMult(ROAD_TIER.ARTERIAL, false), 1);
    assert.equal(
      e4LeafCostMult({
        tier: ROAD_TIER.MOTORWAY,
        avoidMotorways: false,
        preferBackRoads: false,
        metersFromStart: 1e9,
        metersToDestination: 1e9
      }),
      1
    );
  });

  it("avoid motorways and prefer back roads are independent", () => {
    const avoidOnly = e4LeafCostMult({
      tier: ROAD_TIER.MOTORWAY,
      avoidMotorways: true,
      preferBackRoads: false,
      metersFromStart: 1e9,
      metersToDestination: 1e9
    });
    const backOnlyArterial = e4LeafCostMult({
      tier: ROAD_TIER.ARTERIAL,
      avoidMotorways: false,
      preferBackRoads: true,
      metersFromStart: 1e9,
      metersToDestination: 1e9
    });
    const backOnlyMotorway = e4LeafCostMult({
      tier: ROAD_TIER.MOTORWAY,
      avoidMotorways: false,
      preferBackRoads: true,
      metersFromStart: 1e9,
      metersToDestination: 1e9
    });
    assert.equal(avoidOnly, E4_AVOID_MOTORWAY_MULT);
    assert.equal(backOnlyArterial, E4_PREFER_BACK_ARTERIAL_MULT);
    assert.equal(backOnlyMotorway, 1);
    assert.ok(e4PreferBackRoadsMult(ROAD_TIER.COLLECTOR, true) < 1);
    assert.ok(e4PreferBackRoadsMult(ROAD_TIER.ARTERIAL, true) > 1);
  });

  it("never hard-blocks arterial/collector when prefer-back is on", () => {
    assert.ok(e4PreferBackRoadsMult(ROAD_TIER.ARTERIAL, true) < Infinity);
    assert.ok(e4PreferBackRoadsMult(ROAD_TIER.COLLECTOR, true) > 0);
  });
});
