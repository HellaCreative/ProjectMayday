"use strict";
const test = require('node:test'), assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { dispatchRouting, parseRoutingBody } = require('./dispatch');

test('Atlantic complete, unknown and error results never enter compatibility routing', async () => {
  for (const kind of ['route', 'fuel']) for (const status of ['complete', 'unknown', 'error']) {
    const result = { status, routes: [], stops: [] };
    assert.equal(await dispatchRouting({}, kind, { adventure: async () => result,
      compatibility: () => assert.fail('unexpected old engine') }), result);
  }
});
test('only explicit out-of-coverage result uses compatibility with unchanged request', async () => {
  const body = { profile: 'balanced', fuel: { firstLegMaxMeters: 123 } };
  const result = { status: 'complete' };
  assert.equal(await dispatchRouting(body, 'fuel', { adventure: async () => null,
    compatibility: (request, kind) => { assert.equal(request, body); assert.equal(kind, 'fuel'); return result; } }), result);
});
test('new engine exceptions are not retried on another engine', async () => {
  await assert.rejects(dispatchRouting({}, 'route', { adventure: async () => { throw Error('load failed'); },
    compatibility: () => assert.fail('unexpected old engine') }), /load failed/);
});
test('cancellation before or during pending work prevents stale success and fallback', async () => {
  for (const initial of [true, false]) for (const result of [null, {status: 'complete'}]) {
    const controller = new AbortController(); if (initial) controller.abort();
    let calls = 0;
    const actual = await dispatchRouting({options: {abortSignal: controller.signal}}, 'fuel', {
      adventure: async () => { calls++; await Promise.resolve(); controller.abort(); return result; },
      compatibility: () => assert.fail('cancelled request entered old engine')
    });
    assert.equal(actual.error, 'request_cancelled'); assert.equal(calls, initial ? 0 : 1);
    assert.deepEqual(actual.routes, []); assert.equal(actual.windowComplete, false);
  }
});
test('a cancelled compatibility request cannot return stale geometry', async () => {
  const controller = new AbortController();
  const actual = await dispatchRouting({options: {abortSignal: controller.signal}}, 'route', {
    adventure: async () => null, compatibility: async () => { controller.abort(); return {status:'complete'}; }
  });
  assert.equal(actual.error, 'request_cancelled');
});
test('request parsing rejects malformed containers without mutating caller controls', () => {
  for (const raw of [undefined, null, 'null', '[]', 'bad json', 5, [], {options: []}, {fuel: 'bad'}])
    assert.throws(() => parseRoutingBody(raw), {code: 'invalid_request_body'});
  const signal = new AbortController().signal, raw = {options:{ridePreferences:{wander:0.5}}};
  const body = parseRoutingBody(raw, signal);
  assert.notEqual(body, raw); assert.notEqual(body.options, raw.options);
  assert.equal(body.options.abortSignal, signal); assert.equal(raw.options.abortSignal, undefined);
  assert.deepEqual(body.options.ridePreferences, raw.options.ridePreferences);
});
for (const name of ['route','fuel-chain']) {
  const handler = require('../../api/'+name);
  function response() {
    const res = new EventEmitter(); res.setHeader=()=>{};res.status=n=>{res.code=n;return res};
    res.json=value=>{res.value=value;res.writableEnded=true;return res};return res;
  }
  test(name+' HTTP malformed body is a client error with service identity',async()=>{
    for(const body of ['{', 'null', '[]', {fuel:[]}]) {
      const req=new EventEmitter();Object.assign(req,{method:'POST',headers:{},body});const res=response();
      await handler(req,res);assert.equal(res.code,400);assert.equal(res.value.error,'invalid_request_body');
      assert.ok(res.value.serviceContract);assert.ok(res.value.serviceBuild);
    }
  });
  test(name+' HTTP already-disconnected request does not start routing',async()=>{
    const req=new EventEmitter();Object.assign(req,{method:'POST',headers:{},body:{profile:'balanced'},aborted:true});const res=response();
    await handler(req,res);assert.equal(res.code,422);assert.equal(res.value.error,'request_cancelled');
  });
}

test('loading HTTP handlers does not eagerly load compatibility search engines',()=>{
 for(const name of ['router','fuel-chain'])assert.equal(require.cache[require.resolve('./'+name)],undefined);
});
