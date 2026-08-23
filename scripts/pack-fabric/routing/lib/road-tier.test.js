#!/usr/bin/env node
"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const {
  roadTierOf,
  isBlockedForCleanLeaf,
  cleanLeafCostMult,
  ROAD_TIER
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
