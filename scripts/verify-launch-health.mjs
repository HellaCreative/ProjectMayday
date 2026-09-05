#!/usr/bin/env node

import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

const REGION_COUNT = 63;
const ROUTING_CONTRACT = "dirt-routing.r0.v1";
const PACK_CDN = "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
const SHORTBREAD = "https://dirt-shortbread-tiles.dirt-shortbread-edge.workers.dev";

const ENVIRONMENTS = Object.freeze({
  production: Object.freeze({
    routingBase: "https://dirt-mayday.vercel.app",
    supabaseURL: "https://iiiguqknqxoumlmppzfw.supabase.co",
    supabaseRef: "iiiguqknqxoumlmppzfw",
  }),
  development: Object.freeze({
    routingBase: "https://pack-fabric.vercel.app",
    supabaseURL: "https://xoufaiypnrgukzmdwicz.supabase.co",
    supabaseRef: "xoufaiypnrgukzmdwicz",
  }),
});

function fail(message) {
  throw new Error(message);
}

export function parseArgs(argv) {
  const options = {
    environment: "production",
    deep: false,
    json: false,
    strict: false,
    timeoutMs: 15_000,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") return { ...options, help: true };
    if (value === "--deep") {
      options.deep = true;
      continue;
    }
    if (value === "--json") {
      options.json = true;
      continue;
    }
    if (value === "--strict") {
      options.strict = true;
      continue;
    }
    if (value === "--environment") {
      const environment = argv[index + 1];
      if (!Object.hasOwn(ENVIRONMENTS, environment)) {
        fail("--environment must be production or development");
      }
      options.environment = environment;
      index += 1;
      continue;
    }
    if (value === "--timeout-ms") {
      const timeoutMs = Number(argv[index + 1]);
      if (!Number.isInteger(timeoutMs) || timeoutMs < 1_000 || timeoutMs > 120_000) {
        fail("--timeout-ms must be an integer from 1000 through 120000");
      }
      options.timeoutMs = timeoutMs;
      index += 1;
      continue;
    }
    fail(`unknown argument: ${value}`);
  }
  return options;
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function committedBuild(value) {
  return /^[a-f0-9]{7,40}$/i.test(String(value || ""));
}

function advertisedFiles(manifest) {
  return manifest.regions.flatMap((region) =>
    region.files.map((file) => ({ ...file, regionId: region.id })),
  );
}

export function validatePackManifest(manifest) {
  if (manifest?.schemaVersion !== "pack-manifest.v1") fail("unexpected pack manifest schema");
  if (manifest?.version !== "v1") fail("unexpected pack manifest version");
  if (!Array.isArray(manifest.regions) || manifest.regions.length !== REGION_COUNT) {
    fail(`pack manifest advertises ${manifest?.regions?.length ?? 0} regions, expected ${REGION_COUNT}`);
  }
  const ids = new Set();
  for (const region of manifest.regions) {
    if (!/^[a-z0-9][a-z0-9_-]{1,15}$/.test(region?.id || "") || ids.has(region.id)) {
      fail(`invalid or duplicate pack region: ${region?.id || "missing"}`);
    }
    ids.add(region.id);
    const names = new Set((region.files || []).map((file) => file.name));
    if (![...names].some((name) => /^graph\.v[23]\.bin$/.test(name))) {
      fail(`${region.id} has no graph file`);
    }
    for (const required of ["geometry.v1.bin", "fuel.v1.json"]) {
      if (!names.has(required)) fail(`${region.id} has no ${required}`);
    }
    for (const file of region.files || []) {
      if (!Number.isSafeInteger(file.bytes) || file.bytes <= 0) fail(`${region.id}/${file.name} has invalid bytes`);
      if (!/^[a-f0-9]{64}$/.test(file.sha256 || "")) fail(`${region.id}/${file.name} has invalid SHA-256`);
    }
  }
  return advertisedFiles(manifest);
}

export function validateRiderServicesManifest(manifest) {
  if (manifest?.schema !== "rider-services-manifest.v1") fail("unexpected Rider Services manifest schema");
  if (!Array.isArray(manifest.regions) || manifest.regions.length !== REGION_COUNT) {
    fail(`Rider Services advertises ${manifest?.regions?.length ?? 0} regions, expected ${REGION_COUNT}`);
  }
  const ids = new Set();
  for (const region of manifest.regions) {
    if (!/^[a-z0-9][a-z0-9_-]{1,15}$/.test(region?.id || "") || ids.has(region.id)) {
      fail(`invalid or duplicate Rider Services region: ${region?.id || "missing"}`);
    }
    ids.add(region.id);
    for (const category of ["campground", "lodging", "liquor"]) {
      if (!Number.isSafeInteger(region.counts?.[category]) || region.counts[category] <= 0) {
        fail(`${region.id} has no advertised ${category} data`);
      }
    }
    if (!region.file?.name || !Number.isSafeInteger(region.file.bytes) || region.file.bytes <= 0) {
      fail(`${region.id} has invalid Rider Services file metadata`);
    }
    if (!/^[a-f0-9]{64}$/.test(region.file.sha256 || "")) {
      fail(`${region.id} has invalid Rider Services SHA-256`);
    }
  }
  return manifest.regions.map((region) => ({
    regionId: region.id,
    name: region.file.name,
    bytes: region.file.bytes,
    sha256: region.file.sha256,
    riderServices: true,
  }));
}

function makeRecorder(options) {
  const checks = [];
  const warnings = [];
  const failures = [];
  return {
    pass(name, detail) {
      checks.push({ status: "pass", name, detail });
      if (!options.json) console.log(`PASS  ${name}: ${detail}`);
    },
    warn(name, detail) {
      warnings.push({ status: "warning", name, detail });
      if (!options.json) console.warn(`WARN  ${name}: ${detail}`);
    },
    failure(name, detail) {
      failures.push({ status: "failure", name, detail });
      if (!options.json) console.error(`FAIL  ${name}: ${detail}`);
    },
    get checks() { return checks; },
    get warnings() { return warnings; },
    get failures() { return failures; },
  };
}

function safeMethod(method = "GET") {
  const normalized = method.toUpperCase();
  if (normalized !== "GET" && normalized !== "HEAD") {
    fail(`health verification refuses mutating HTTP method ${normalized}`);
  }
  return normalized;
}

async function request(fetchImpl, url, options, timeoutMs) {
  const method = safeMethod(options?.method);
  const response = await fetchImpl(url, {
    ...options,
    method,
    redirect: "error",
    signal: AbortSignal.timeout(timeoutMs),
  });
  return response;
}

async function jsonRequest(fetchImpl, url, options, timeoutMs, acceptedStatuses = [200]) {
  const response = await request(fetchImpl, url, options, timeoutMs);
  if (!acceptedStatuses.includes(response.status)) fail(`${url} returned HTTP ${response.status}`);
  let body;
  try {
    body = await response.json();
  } catch (error) {
    fail(`${url} returned invalid JSON: ${error.message}`);
  }
  return { response, body };
}

async function verifyServiceEndpoints(fetchImpl, config, options, recorder) {
  const services = [
    ["route", "dirt-route", true],
    ["fuel", "dirt-live-fuel", true],
    ["fuel-chain", "dirt-live-fuel-chain", true],
    ["poi", "dirt-rider-services", false],
  ];
  let build = null;
  for (const [path, expectedService, carriesRoutingIdentity] of services) {
    try {
      const { response, body } = await jsonRequest(
        fetchImpl,
        `${config.routingBase}/api/${path}`,
        { headers: { Accept: "application/json" } },
        options.timeoutMs,
      );
      if (body.ok !== true || body.service !== expectedService) fail(`${path} health contract is invalid`);
      const requestID = response.headers.get("x-dirt-request-id");
      if (!requestID) fail(`${path} health response has no X-Dirt-Request-ID`);
      if (path === "poi") {
        if (body.source !== "packed-r2") fail("Rider Services is not using packed R2 data");
        const categories = new Set(body.categories || []);
        for (const category of ["campground", "lodging", "liquor"]) {
          if (!categories.has(category)) fail(`Rider Services health omits ${category}`);
        }
      }
      if (carriesRoutingIdentity) {
        if (body.serviceContract !== ROUTING_CONTRACT) fail(`${path} has the wrong routing contract`);
        if (!committedBuild(body.serviceBuild)) fail(`${path} has untraceable serviceBuild ${body.serviceBuild || "missing"}`);
        if (build && build !== body.serviceBuild) fail(`${path} build differs from the route build`);
        build = body.serviceBuild;
      }
      recorder.pass(`${path} endpoint`, carriesRoutingIdentity ? `${body.serviceBuild} · ${requestID}` : `${body.source} · ${requestID}`);
    } catch (error) {
      recorder.failure(`${path} endpoint`, error?.message || String(error));
    }
  }
  return build;
}

async function verifySupabase(fetchImpl, config, options, recorder, environment) {
  const key = process.env.DIRT_SUPABASE_PUBLISHABLE_KEY?.trim();
  const headers = { Accept: "application/json" };
  if (key) headers.apikey = key;
  const accepted = key ? [200] : [401];
  const { response, body } = await jsonRequest(
    fetchImpl,
    `${config.supabaseURL}/auth/v1/health`,
    { headers },
    options.timeoutMs,
    accepted,
  );
  const responseRef = response.headers.get("sb-project-ref");
  if (responseRef && responseRef !== config.supabaseRef) fail(`Supabase responded as ${responseRef}, expected ${config.supabaseRef}`);
  if (key) {
    if (body.name !== "GoTrue" || !body.version) fail("Supabase Auth health payload is invalid");
    recorder.pass("Supabase Auth", `${environment} ${config.supabaseRef} · ${body.version}`);
  } else {
    if (body.message !== "No API key found in request") fail("Supabase gateway returned an unexpected unauthenticated response");
    recorder.warn(
      "Supabase Auth",
      `${environment} gateway is reachable; set DIRT_SUPABASE_PUBLISHABLE_KEY for a full Auth health check`,
    );
  }
}

async function verifyCatalogs(fetchImpl, options, recorder) {
  const packURL = `${PACK_CDN}/manifest.json?launch-health=${Date.now()}`;
  const packResponse = await request(fetchImpl, packURL, { headers: { Accept: "application/json" } }, options.timeoutMs);
  if (packResponse.status !== 200) fail(`pack manifest returned HTTP ${packResponse.status}`);
  const packBytes = Buffer.from(await packResponse.arrayBuffer());
  const packManifest = JSON.parse(packBytes.toString("utf8"));
  const packFiles = validatePackManifest(packManifest);
  recorder.pass("pack catalog", `${packManifest.regions.length} regions · ${packFiles.length} files · sha256 ${sha256(packBytes)}`);

  const riderURL = `${PACK_CDN}/rider-services/v1/manifest.json?launch-health=${Date.now()}`;
  const riderResponse = await request(fetchImpl, riderURL, { headers: { Accept: "application/json" } }, options.timeoutMs);
  if (riderResponse.status !== 200) fail(`Rider Services manifest returned HTTP ${riderResponse.status}`);
  const riderBytes = Buffer.from(await riderResponse.arrayBuffer());
  const riderManifest = JSON.parse(riderBytes.toString("utf8"));
  const riderFiles = validateRiderServicesManifest(riderManifest);
  recorder.pass("Rider Services catalog", `${riderManifest.regions.length} regions · sha256 ${sha256(riderBytes)}`);

  if (options.deep) {
    const objects = [
      ...packFiles.map((file) => ({ ...file, url: `${PACK_CDN}/${file.regionId}/${file.name}` })),
      ...riderFiles.map((file) => ({ ...file, url: `${PACK_CDN}/rider-services/v1/${file.regionId}/${file.name}` })),
    ];
    for (let index = 0; index < objects.length; index += 8) {
      await Promise.all(objects.slice(index, index + 8).map(async (file) => {
        const response = await request(fetchImpl, file.url, { method: "HEAD" }, options.timeoutMs);
        if (response.status !== 200) fail(`${file.regionId}/${file.name} returned HTTP ${response.status}`);
        const length = Number(response.headers.get("content-length"));
        if (length !== file.bytes) fail(`${file.regionId}/${file.name} is ${length} bytes, catalog says ${file.bytes}`);
      }));
    }
    recorder.pass("advertised objects", `${objects.length} HEAD checks match catalog sizes`);
  }
}

async function verifyShortbread(fetchImpl, options, recorder) {
  const { body } = await jsonRequest(
    fetchImpl,
    `${SHORTBREAD}/shortbread/v1/health`,
    { headers: { Accept: "application/json" } },
    options.timeoutMs,
  );
  if (body.ok !== true || body.contract !== "dirt.shortbread-manifest.v1") fail("Shortbread health contract is invalid");
  if (!body.releaseID || !(body.archiveBytes > 0) || !(body.sampleBytes > 0)) fail("Shortbread release is incomplete");
  recorder.pass("Shortbread", `${body.releaseID} · archive ${body.archiveBytes} bytes · sample ${body.sampleBytes} bytes`);
}

export async function runHealthCheck(options, fetchImpl = fetch) {
  const config = ENVIRONMENTS[options.environment];
  if (!config) fail(`unknown environment ${options.environment}`);
  const recorder = makeRecorder(options);
  const startedAt = new Date().toISOString();
  const serviceBuild = await verifyServiceEndpoints(fetchImpl, config, options, recorder);
  for (const [name, check] of [
    ["Supabase", () => verifySupabase(fetchImpl, config, options, recorder, options.environment)],
    ["R2 catalogs", () => verifyCatalogs(fetchImpl, options, recorder)],
    ["Shortbread", () => verifyShortbread(fetchImpl, options, recorder)],
  ]) {
    try {
      await check();
    } catch (error) {
      recorder.failure(name, error?.message || String(error));
    }
  }
  const result = {
    ok: recorder.failures.length === 0 && (recorder.warnings.length === 0 || !options.strict),
    environment: options.environment,
    mode: options.deep ? "deep" : "fast",
    startedAt,
    completedAt: new Date().toISOString(),
    serviceBuild,
    checks: recorder.checks,
    warnings: recorder.warnings,
    failures: recorder.failures,
  };
  if (options.json) console.log(JSON.stringify(result, null, 2));
  if (!result.ok) {
    const warningFailure = options.strict ? recorder.warnings.length : 0;
    fail(`${recorder.failures.length} failure(s), ${warningFailure} strict warning(s)`);
  }
  return result;
}

function usage() {
  console.log(`Usage: node scripts/verify-launch-health.mjs [options]

Read-only DIRT dependency verification. This program permits GET and HEAD only.

Options:
  --environment production|development   Default: production
  --deep                                 HEAD every advertised R2 object
  --strict                               Treat missing optional credentials as failure
  --json                                 Machine-readable output
  --timeout-ms N                         Per-request timeout (1000-120000)
  --help

Set DIRT_SUPABASE_PUBLISHABLE_KEY to test Supabase Auth beyond gateway reachability.
Never provide a service-role key.`);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) usage();
    else await runHealthCheck(options);
  } catch (error) {
    console.error(`LAUNCH HEALTH FAIL: ${error?.message || String(error)}`);
    process.exitCode = 1;
  }
}
