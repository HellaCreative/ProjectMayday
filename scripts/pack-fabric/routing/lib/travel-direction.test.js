"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  travelDirectionFromOsmTags,
  legalDirectedArcs
} = require("./travel-direction");

test("oneway=yes and equivalents are forward along the way", () => {
  for (const oneway of ["yes", "true", "1", "YES"]) {
    assert.equal(travelDirectionFromOsmTags({ oneway }), "forward", oneway);
  }
});

test("oneway=-1 and reverse travel against way geometry", () => {
  assert.equal(travelDirectionFromOsmTags({ oneway: "-1" }), "reverse");
  assert.equal(travelDirectionFromOsmTags({ oneway: "reverse" }), "reverse");
});

test("explicit two-way wins over motorway and roundabout implication", () => {
  assert.equal(
    travelDirectionFromOsmTags({ highway: "motorway", oneway: "no" }),
    "both"
  );
  assert.equal(
    travelDirectionFromOsmTags({ junction: "roundabout", oneway: "no" }),
    "both"
  );
  assert.equal(travelDirectionFromOsmTags({ oneway: "false" }), "both");
  assert.equal(travelDirectionFromOsmTags({ oneway: "0" }), "both");
});

test("roundabouts and motorway links imply forward when oneway is absent", () => {
  assert.equal(travelDirectionFromOsmTags({ junction: "roundabout" }), "forward");
  assert.equal(travelDirectionFromOsmTags({ junction: "circular" }), "forward");
  assert.equal(travelDirectionFromOsmTags({ highway: "motorway" }), "forward");
  assert.equal(travelDirectionFromOsmTags({ highway: "motorway_link" }), "forward");
});

test("missing or ambiguous direction defaults to bidirectional", () => {
  assert.equal(travelDirectionFromOsmTags({}), "both");
  assert.equal(travelDirectionFromOsmTags({ highway: "trunk" }), "both");
  assert.equal(travelDirectionFromOsmTags({ highway: "primary" }), "both");
  assert.equal(travelDirectionFromOsmTags({ highway: "track" }), "both");
  assert.equal(travelDirectionFromOsmTags({ highway: "path" }), "both");
  assert.equal(travelDirectionFromOsmTags({ highway: "unclassified" }), "both");
  assert.equal(travelDirectionFromOsmTags({ oneway: "reversible" }), "both");
  assert.equal(travelDirectionFromOsmTags({ oneway: "alternating" }), "both");
  assert.equal(travelDirectionFromOsmTags({ oneway: "sometimes" }), "both");
});

test("direction is independent of surface and trail type", () => {
  assert.equal(
    travelDirectionFromOsmTags({ highway: "track", surface: "dirt", atv: "yes" }),
    "both"
  );
  assert.equal(
    travelDirectionFromOsmTags({
      highway: "track",
      surface: "dirt",
      atv: "yes",
      oneway: "yes"
    }),
    "forward"
  );
});

test("legalDirectedArcs encodes only permitted travel", () => {
  assert.deepEqual(legalDirectedArcs("both"), { forward: true, reverse: true });
  assert.deepEqual(legalDirectedArcs("forward"), { forward: true, reverse: false });
  assert.deepEqual(legalDirectedArcs("reverse"), { forward: false, reverse: true });
  assert.deepEqual(legalDirectedArcs(undefined), { forward: true, reverse: true });
});
