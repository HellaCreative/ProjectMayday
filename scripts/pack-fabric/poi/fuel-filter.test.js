"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { isMotorcycleUsable, rejection } = require("./fuel-filter.js");

test("bare amenity=fuel is kept", () => {
  assert.equal(isMotorcycleUsable({ name: "Esso", tags: { amenity: "fuel" } }), true);
  assert.equal(rejection({ tags: {} }), null);
});

test("hgv=yes is kept; hgv=designated is dropped", () => {
  assert.equal(rejection({ tags: { hgv: "yes" } }), null);
  assert.equal(rejection({ tags: { hgv: "designated" } }), "truckOnly");
  assert.equal(rejection({ tags: { hgv: "only" } }), "truckOnly");
});

test("cardlock / bulk names are dropped", () => {
  assert.equal(rejection({ name: "UFA Cardlock" }), "bulkOrCardlock");
  assert.equal(rejection({ name: "Petro-Canada Card Lock" }), "bulkOrCardlock");
  assert.equal(rejection({ brand: "Fas Gas Cardlock" }), "bulkOrCardlock");
  assert.equal(rejection({ name: "Bulk Fuel Depot" }), "bulkOrCardlock");
  assert.equal(rejection({ name: "Bulkley Valley Co-op" }), null);
});

test("private / customers access is dropped", () => {
  assert.equal(rejection({ tags: { access: "private" } }), "privateAccess");
  assert.equal(rejection({ tags: { access: "customers" } }), "privateAccess");
  assert.equal(rejection({ tags: { access: "yes" } }), null);
});

test("known-closed tags and hours are dropped", () => {
  assert.equal(rejection({ tags: { disused: "yes" } }), "closed");
  assert.equal(rejection({ tags: { "abandoned:amenity": "fuel" } }), "closed");
  assert.equal(rejection({ openingHours: "closed" }), "closed");
});

test("diesel-only only when gasoline is explicit no", () => {
  assert.equal(
    rejection({ tags: { "fuel:diesel": "yes" } }),
    null,
    "sparse diesel tag is not enough"
  );
  assert.equal(
    rejection({ tags: { "fuel:diesel": "yes", "fuel:gasoline": "no" } }),
    "dieselOnly"
  );
  assert.equal(
    rejection({
      tags: { "fuel:diesel": "yes", "fuel:gasoline": "no", "fuel:octane_91": "yes" }
    }),
    null
  );
  assert.equal(
    rejection({ tags: { "fuel:hgv_diesel": "yes" } }),
    "truckOnly"
  );
});
