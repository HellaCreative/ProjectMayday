'use strict';
// Private execution experiment. Limits/capabilities must come from a versioned
// device qualification record; this file establishes no iPhone capacity claim.
const crypto = require('node:crypto');
const immutable = value => {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(immutable); Object.freeze(value);
  }
  return value;
};
const stable = x => Array.isArray(x) ? x.map(stable) : x && typeof x === 'object'
  ? Object.fromEntries(Object.keys(x).sort().map(k => [k, stable(x[k])])) : x;
function snapshot(request) {
  // Preserve the full itinerary, including fields this policy does not inspect.
  // Engine adapters must reject unsupported fields, never silently omit them.
  const value = structuredClone(request);
  const jsonValue = x => x === null || typeof x === 'string' || typeof x === 'boolean' ||
    (typeof x === 'number' && Number.isFinite(x)) ||
    (Array.isArray(x) && Array.from(x).every(jsonValue)) ||
    (x && Object.getPrototypeOf(x) === Object.prototype && Object.values(x).every(jsonValue));
  if (!value || Array.isArray(value) || typeof value !== 'object' || !jsonValue(value)) throw new Error('Finite JSON itinerary object required');
  const canonical = JSON.stringify(stable(value));
  return immutable({ value, fingerprint: crypto.createHash('sha256').update(canonical).digest('hex') });
}
function requiredFeatures(q) {
  return ['road', ...(q.fuel ? ['fuel'] : []),
    ...(q.waypoints?.length ? ['waypoints'] : []),
    ...(q.preferences ? ['preferences'] : []),
    ...(q.arrivalHistory?.length ? ['arrivalHistory'] : []),
    ...(q.allowUnknown ? ['unknownAccess'] : [])];
}
function decide(request, context, policy = 'capability') {
  if (!['region', 'distance', 'capability'].includes(policy)) throw new Error('Unknown policy');
  if (request.fuel && (!Number.isFinite(request.fuel.usableRangeMeters) || request.fuel.usableRangeMeters <= 0 || !Number.isFinite(request.fuel.initialUsableMeters) || request.fuel.initialUsableMeters < 0 || request.fuel.initialUsableMeters > request.fuel.usableRangeMeters)) throw new Error('Invalid usable fuel constraints');
  const { coverage, qualification: limits } = context;
  let reason;
  if (!coverage?.downloaded) reason = 'data_missing';
  else if (!coverage.current) reason = 'data_outdated';
  else if (coverage.legalTopology !== true) reason = 'legal_data_unverified';
  else if (!limits?.deviceIdentity || !limits?.sourceIdentity) reason = 'device_not_qualified';
  else if (!Array.isArray(limits.features) || !['maxEdges', 'maxNodes', 'maxPeakBytes', 'distanceThresholdMeters', 'maxRegions', 'maxTestedStraightLineMeters', 'maxSearchMillis'].every(k => Number.isFinite(limits[k]) && limits[k] > 0) || !Number.isFinite(limits.minimumTestedStartingFuelMeters) || limits.minimumTestedStartingFuelMeters < 0) reason = 'qualification_invalid';
  else if (context.deviceIdentity !== limits.deviceIdentity || context.sourceIdentity !== limits.sourceIdentity) reason = 'qualification_identity_mismatch';
  else if (limits.cooperativeCancellation !== true) reason = 'cancellation_not_qualified';
  else if (requiredFeatures(request).some(x => !limits.features.includes(x))) reason = 'local_feature_unsupported';
  else if (!coverage.searchDomainComplete) reason = 'coverage_incomplete';
  else if (![context.edges, context.nodes, context.estimatedPeakBytes, context.straightLineMeters].every(x => Number.isFinite(x) && x >= 0)) reason = 'resource_estimate_missing';
  else if (context.edges > limits.maxEdges || context.nodes > limits.maxNodes || context.estimatedPeakBytes > limits.maxPeakBytes) reason = 'local_resource_limit';
  else if (policy === 'region' && coverage.regions.length !== 1) reason = 'region_policy';
  else if (policy === 'distance' && context.straightLineMeters > limits.distanceThresholdMeters) reason = 'distance_policy';
  else if (coverage.regions.length > limits.maxRegions) reason = 'region_count_unqualified';
  else if (context.straightLineMeters > limits.maxTestedStraightLineMeters) reason = 'distance_untested';
  else if (request.fuel && request.fuel.initialUsableMeters < limits.minimumTestedStartingFuelMeters) reason = 'starting_fuel_untested';
  if (!reason) return { target: 'local', reason: `${policy}_qualified`, searchMillis: limits.maxSearchMillis };
  // No automatic paid/shared work. Server access is an explicit, per-request
  // product admission decision; being online alone is insufficient.
  return { target: context.online && context.serverAdmission === 'allowed' ? 'server' : 'incomplete', reason };
}
class ExecutionCoordinator {
  constructor({ local, server, verify, stopGraceMillis = 250 }) {
    this.engines = { local, server }; this.verify = verify;
    this.stopGraceMillis = stopGraceMillis; this.generation = 0;
    this.active = null; this.lastValid = null; this.trace = [];
  }
  async stop(job) {
    if (!job) return true;
    job.cancel();
    let timer;
    try { return await Promise.race([job.stopped.then(() => true, () => false), new Promise(resolve => { timer = setTimeout(() => resolve(false), this.stopGraceMillis); })]); }
    finally { clearTimeout(timer); }
  }
  async calculate(request, context, policy = 'capability') {
    const generation = ++this.generation, old = this.active;
    // One computation per device. A non-cooperative worker cannot be replaced
    // with another active worker or trigger a parallel server retry.
    if (!(await this.stop(old))) return { state: 'incomplete', reason: 'cancellation_not_acknowledged', generation };
    if (generation !== this.generation) return { state: 'superseded', generation };
    if (this.active === old) this.active = null;
    const envelope = snapshot(request), decision = decide(request, context, policy);
    this.trace.push({ generation, fingerprint: envelope.fingerprint, ...decision });
    if (decision.target === 'incomplete') return { state: 'incomplete', reason: decision.reason, generation };
    return this.run(envelope, context, decision, generation);
  }
  async run(envelope, context, decision, generation) {
    const engine = this.engines[decision.target];
    if (!engine || !engine.supports(envelope.value)) return { state: 'incomplete', reason: `${decision.target}_feature_unsupported`, generation };
    const began = performance.now(), job = engine.start(envelope, { generation, decision });
    this.active = job;
    let timer;
    const limit = decision.target === 'local' ? decision.searchMillis : context.serverTimeoutMillis ?? 90000;
    const timeout = new Promise(resolve => { timer = setTimeout(() => resolve({ state: 'incomplete', reason: 'time_budget' }), limit); });
    const result = await Promise.race([job.result.catch(error => ({ state: 'incomplete', reason: String(error) })), timeout]);
    clearTimeout(timer);
    const stopped = await this.stop(job);
    if (stopped && this.active === job) this.active = null;
    if (generation !== this.generation) return { state: 'superseded', generation };
    if (!stopped) return { state: 'incomplete', reason: 'cancellation_not_acknowledged', generation };
    this.trace.push({ generation, target: decision.target, state: result.state, seconds: (performance.now()-began)/1000 });
    if (result.state === 'complete') {
      if (result.fingerprint !== envelope.fingerprint || !await this.verify(result, envelope.value)) return { state: 'incomplete', reason: 'result_contract_rejected', generation };
      if (generation !== this.generation) return { state: 'superseded', generation };
      this.lastValid = immutable(structuredClone(result));
      return { ...result, generation };
    }
    if (decision.target === 'local' && context.online && context.serverAdmission === 'allowed' && context.fallbackAllowed === true) {
      this.trace.push({ generation, target: 'server', reason: 'fresh_search_after_local_incomplete', fingerprint: envelope.fingerprint });
      return this.run(envelope, context, { target: 'server', reason: 'explicit_fallback' }, generation);
    }
    return { state: 'incomplete', reason: result.reason ?? 'local_computation_incomplete', generation };
  }
  async cancel() {
    ++this.generation;
    const job = this.active, stopped = await this.stop(job);
    if (stopped && this.active === job) this.active = null;
    return stopped;
  }
}
module.exports = { decide, snapshot, requiredFeatures, ExecutionCoordinator };
