"use strict";

const assert = require("assert");
const path = require("path");
const G = require(path.join(__dirname, "..", "group-sharing.js"));

function run(name, fn) {
  try {
    fn();
    console.log("ok — " + name);
  } catch (err) {
    console.error("FAIL — " + name);
    console.error(err);
    process.exitCode = 1;
  }
}

run("formatRiderMapLabel includes status word", () => {
  assert.strictEqual(G.formatRiderMapLabel("Alex", "injured"), "Alex - Injured");
  assert.strictEqual(G.formatRiderMapLabel("", "available"), "Rider - Available");
});

run("publishIntervalMs speeds up for distress", () => {
  assert.strictEqual(G.publishIntervalMs("available"), 15000);
  assert.strictEqual(G.publishIntervalMs("injured"), 5000);
  assert.strictEqual(G.publishIntervalMs("breakdown"), 5000);
  assert.strictEqual(G.publishIntervalMs("stuck"), 5000);
});

run("mergePresenceKeepLastKnown upserts without clearing absent riders", () => {
  const existing = new Map([
    ["crash-user", { userId: "crash-user", lng: -63.1, lat: 45.2, status: "injured", displayName: "Maya" }]
  ]);
  const state = {
    "live-user": [{ userId: "live-user", lng: -63.2, lat: 45.3, status: "available", displayName: "Sam" }]
  };
  const next = G.mergePresenceKeepLastKnown(existing, state, "me", { groupId: "g1", groupName: "Crew" });
  assert.ok(next.has("crash-user"), "last-known crash pin must remain");
  assert.ok(next.has("live-user"), "live presence must be added");
  assert.strictEqual(next.get("live-user").groupName, "Crew");
  assert.strictEqual(next.get("live-user").labelLine, "Sam - Available");
});

run("applySharingOff removes only explicit stop", () => {
  const existing = new Map([
    ["a", { userId: "a", lng: 1, lat: 2 }],
    ["b", { userId: "b", lng: 3, lat: 4 }]
  ]);
  const next = G.applySharingOff(existing, "a");
  assert.ok(!next.has("a"));
  assert.ok(next.has("b"));
});

run("routeTargetFromFeature uses geometry not click point", () => {
  const target = G.routeTargetFromFeature({
    type: "Feature",
    geometry: { type: "Point", coordinates: [-63.55, 44.65] },
    properties: { userId: "u1", displayName: "Alex", status: "stuck", groupName: "Sunday Ride" }
  });
  assert.strictEqual(target.lng, -63.55);
  assert.strictEqual(target.lat, 44.65);
  assert.strictEqual(target.displayName, "Alex");
  assert.strictEqual(target.groupName, "Sunday Ride");
  const model = G.buildGroupRiderPopupModel(target);
  assert.strictEqual(model.ctaLabel, "Route to member");
  assert.strictEqual(model.statusText, "Stuck");
});

run("alerts upsert and dismiss", () => {
  const record = G.createAlertRecord({
    userId: "u1",
    displayName: "Alex",
    status: "injured",
    groupName: "Crew",
    lng: -63,
    lat: 45
  });
  assert.ok(record);
  let alerts = G.upsertAlert([], record);
  assert.strictEqual(alerts.length, 1);
  alerts = G.upsertAlert(alerts, Object.assign({}, record, { lng: -63.1 }));
  assert.strictEqual(alerts.length, 1);
  assert.strictEqual(alerts[0].lng, -63.1);
  alerts = G.dismissAlert(alerts, record.id);
  assert.strictEqual(alerts.length, 0);
});

run("createAlertRecord rejects available / missing coords", () => {
  assert.strictEqual(G.createAlertRecord({ userId: "u", status: "available", lng: 1, lat: 2 }), null);
  assert.strictEqual(G.createAlertRecord({ userId: "u", status: "injured", lng: NaN, lat: 2 }), null);
});

if (!process.exitCode) console.log("\nAll group-sharing tests passed.");
