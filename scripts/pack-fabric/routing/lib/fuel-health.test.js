'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
test('fuel health does not initialize compatibility topology', () => {
  const script = `
    const assert = require('node:assert/strict');
    const handler = require('./api/fuel-chain');
    const res = { setHeader(){}, status(code){assert.equal(code,200);return this;},
      json(body){assert.equal(body.ok,true);assert.equal(body.service,'dirt-live-fuel-chain');
      assert.ok(body.serviceVersion);assert.ok(!Object.keys(require.cache).some(p=>p.endsWith('/lib/router.js')));}};
    handler({method:'GET',headers:{}},res).catch(e=>{console.error(e);process.exitCode=1;});`;
  execFileSync(process.execPath, ['-e', script], {
    cwd: path.resolve(__dirname, '../..'),
    env: {...process.env, DIRT_V4_CONNECTION_REVISION:'deliberately-invalid-for-health-test'},
    stdio:'pipe'
  });
});
