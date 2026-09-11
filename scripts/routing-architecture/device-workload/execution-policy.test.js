'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { decide, snapshot, ExecutionCoordinator } = require('./execution-policy');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
// SYNTHETIC qualification values test dispatch only, never phone performance.
const request = () => ({ start: [-63.3, 44.7], end: [-63.4, 44.9], profile: 'dirt',
  waypoints: [{ position: [-63.35, 44.8], profile: 'balanced' }],
  preferences: { wander: .6, avoidCities: true }, allowUnknown: true,
  fuel: { usableRangeMeters: 180000, initialUsableMeters: 80000, reserveMeters: 20000 },
  excludedStationIds: ['closed-station'], arrivalHistory: ['edge-a', 'edge-b'] });
const context = () => ({ online: true, serverAdmission: 'none', fallbackAllowed: false,
  deviceIdentity: 'synthetic-device', sourceIdentity: 'synthetic-source',
  coverage: { downloaded: true, current: true, legalTopology: true, searchDomainComplete: true, regions: ['ns'] },
  edges: 200000, nodes: 150000, estimatedPeakBytes: 200000000, straightLineMeters: 20000,
  qualification: { deviceIdentity: 'synthetic-device', sourceIdentity: 'synthetic-source',
    features: ['road','fuel','waypoints','preferences','arrivalHistory','unknownAccess'],
    cooperativeCancellation: true, maxEdges: 400000, maxNodes: 350000, maxPeakBytes: 500000000,
    maxRegions: 2, distanceThresholdMeters: 1000000, maxTestedStraightLineMeters: 1500000,
    minimumTestedStartingFuelMeters: 50000, maxSearchMillis: 1000 } });
function engine({ delay = 0, state = 'complete', cooperative = true, supports = true, wrongIdentity = false } = {}) {
  const e = { starts: [], cancels: 0, supports: () => supports,
    start(envelope, options) {
      e.starts.push({ envelope, options });
      let settle, stopped, done = false;
      const stop = new Promise(resolve => { stopped = resolve; });
      const result = new Promise(resolve => { settle = resolve; });
      const timer = setTimeout(() => {
        done = true; settle({ state, reason: state === 'incomplete' ? 'memory_budget' : undefined,
          fingerprint: wrongIdentity ? 'wrong' : envelope.fingerprint, route: { preserved: envelope.value } }); stopped();
      }, delay);
      return { result, stopped: stop, cancel() {
        e.cancels++;
        if (!done && cooperative) { done = true; clearTimeout(timer); settle({ state: 'incomplete', reason: 'cancelled' }); stopped(); }
      } };
    } };
  return e;
}
test('regional qualified dispatch; no real device is implicitly qualified', () => {
  assert.equal(decide(request(), context()).target, 'local');
  const c = context(); c.qualification = null;
  assert.deepEqual(decide(request(), c), { target: 'incomplete', reason: 'device_not_qualified' });
});
test('invalid fields cannot disappear during request fingerprinting', () => {
  for (const bad of [undefined, NaN, Infinity, new Date(), [undefined]]) {
    assert.throws(() => snapshot({ ...request(), extra: bad }), /JSON/);
  }
  const q = request(); q.fuel.initialUsableMeters = NaN;
  assert.throws(() => decide(q,context()), /fuel/);
});
test('1000 km comparison is straight-line policy, never a route-distance promise', () => {
  const c = context(); c.straightLineMeters = 1100000;
  assert.equal(decide(request(), c, 'distance').target, 'incomplete');
  assert.equal(decide(request(), c, 'capability').target, 'local');
});
test('short border crossing differentiates region policy without ignoring capability', () => {
  const c = context(); c.coverage.regions = ['ns', 'nb']; c.straightLineMeters = 1000;
  assert.equal(decide(request(), c, 'region').reason, 'region_policy');
  assert.equal(decide(request(), c, 'capability').target, 'local');
});
test('dense short route exceeds resource budget; sparse long route can fit a tested envelope', () => {
  const c = context(); c.edges = 2000000;
  assert.equal(decide(request(), c).reason, 'local_resource_limit');
  c.edges = 100000; c.straightLineMeters = 900000;
  assert.equal(decide(request(), c).target, 'local');
});
test('same-region endpoints do not prove route coverage', () => {
  const c = context(); c.coverage.searchDomainComplete = false;
  assert.equal(decide(request(), c).reason, 'coverage_incomplete');
});
test('missing/stale data, legal topology, unsupported settings, device identity and low starting fuel fail closed', () => {
  for (const [mutate, reason] of [
    [c => c.coverage.downloaded = false, 'data_missing'],
    [c => c.coverage.current = false, 'data_outdated'],
    [c => c.coverage.legalTopology = false, 'legal_data_unverified'],
    [c => c.qualification.features = ['road'], 'local_feature_unsupported'],
    [c => c.deviceIdentity = 'different', 'qualification_identity_mismatch'],
    [c => c.qualification.maxEdges = undefined, 'qualification_invalid'],
    [c => c.qualification.minimumTestedStartingFuelMeters = 90000, 'starting_fuel_untested'],
    [c => c.qualification.cooperativeCancellation = false, 'cancellation_not_qualified'],
  ]) { const c = context(); mutate(c); assert.deepEqual(decide(request(), c), { target: 'incomplete', reason }); }
});
test('ambitious NS-BC shape never starts server work by default', async () => {
  const local = engine(), server = engine(), c = context();
  c.coverage.regions = ['ns','nb','qc','on','mb','sk','ab','bc']; c.straightLineMeters = 4500000;
  const x = new ExecutionCoordinator({ local, server, verify: () => true });
  const r = await x.calculate({ ...request(), end: [-123.12, 49.28] }, c);
  assert.equal(r.state, 'incomplete'); assert.equal(local.starts.length, 0); assert.equal(server.starts.length, 0);
});
test('explicit server admission sends the complete immutable itinerary without local work', async () => {
  const local = engine(), server = engine(), c = context(); c.coverage.downloaded = false; c.serverAdmission = 'allowed';
  const q = request(), x = new ExecutionCoordinator({ local, server, verify: () => true });
  assert.equal((await x.calculate(q,c)).state, 'complete'); assert.equal(local.starts.length, 0);
  assert.deepEqual(server.starts[0].envelope.value, q); assert(Object.isFrozen(server.starts[0].envelope.value.fuel));
});
test('server adapter rejects unsupported contract rather than stripping settings', async () => {
  const c = context(); c.coverage.downloaded = false; c.serverAdmission = 'allowed';
  const server = engine({ supports: false });
  const x = new ExecutionCoordinator({ local: engine(), server, verify: () => true });
  assert.equal((await x.calculate(request(),c)).reason, 'server_feature_unsupported'); assert.equal(server.starts.length,0);
});
test('local memory event is incomplete, preserves last valid route and does not auto-escalate', async () => {
  const server = engine(), x = new ExecutionCoordinator({ local: engine(), server, verify: () => true });
  await x.calculate(request(),context()); const retained = x.lastValid;
  x.engines.local = engine({ state: 'incomplete' });
  assert.equal((await x.calculate(request(),context())).reason, 'memory_budget');
  assert.equal(x.lastValid, retained); assert.equal(server.starts.length,0);
});
test('explicit fallback waits for local stop and restarts with identical constraints', async () => {
  const local = engine({ delay: 100 }), server = engine(), c = context();
  c.qualification.maxSearchMillis = 5; c.serverAdmission = 'allowed'; c.fallbackAllowed = true;
  const x = new ExecutionCoordinator({ local, server, verify: () => true });
  assert.equal((await x.calculate(request(),c)).state, 'complete');
  assert(local.cancels > 0); assert.equal(server.starts.length,1);
  assert.deepEqual(local.starts[0].envelope,server.starts[0].envelope);
  assert(x.trace.some(x => x.reason === 'fresh_search_after_local_incomplete'));
});
test('offline timeout stays incomplete', async () => {
  const c = context(); c.online = false; c.serverAdmission = 'allowed'; c.fallbackAllowed = true; c.qualification.maxSearchMillis = 5;
  const server = engine(), x = new ExecutionCoordinator({ local: engine({delay:100}), server, verify: () => true });
  assert.equal((await x.calculate(request(),c)).reason,'time_budget'); assert.equal(server.starts.length,0);
});
test('superseded generation cancels old work and accepts only replacement', async () => {
  const local = engine({delay:30}), x = new ExecutionCoordinator({local,server:engine(),verify:()=>true});
  const a = x.calculate(request(),context()); await sleep(5);
  const q = {...request(),profile:'clean'}, b = x.calculate(q,context());
  assert.equal((await a).state,'superseded'); assert.equal((await b).state,'complete');
  assert.equal(x.lastValid.fingerprint,snapshot(q).fingerprint);
});
test('unacknowledged cancellation blocks duplicate/fallback work; late response is stale', async () => {
  const local = engine({delay:100,cooperative:false}), server = engine(), c = context();
  c.qualification.maxSearchMillis = 5; c.serverAdmission = 'allowed'; c.fallbackAllowed = true;
  const x = new ExecutionCoordinator({local,server,verify:()=>true,stopGraceMillis:5});
  assert.equal((await x.calculate(request(),c)).reason,'cancellation_not_acknowledged');
  assert.equal((await x.calculate(request(),c)).reason,'cancellation_not_acknowledged');
  assert.equal(local.starts.length,1); assert.equal(server.starts.length,0);
  await sleep(110); assert.equal(x.lastValid,null);
});
test('wrong request identity or failed independent verification cannot replace valid route', async () => {
  for(const [wrongIdentity,verified] of [[true,true],[false,false]]) {
    const x = new ExecutionCoordinator({local:engine({wrongIdentity}),server:engine(),verify:()=>verified});
    assert.equal((await x.calculate(request(),context())).reason,'result_contract_rejected'); assert.equal(x.lastValid,null);
  }
});
