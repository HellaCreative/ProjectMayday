#!/usr/bin/env node
"use strict";

/**
 * Verify one explicit live/download region against the production service.
 *
 *   node scripts/pack-fabric/scripts/assert-live-pack-lockstep.js --region on
 *
 * The command deliberately has no all-regions default. Work on Ontario must
 * not fail because an unrelated BC, Nova Scotia, or Washington staging folder
 * differs from the promoted catalog.
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const https = require("https");
const http = require("http");
const {
  decodeGraphV2,
  unpackAccess,
  unpackStructure
} = require("../routing/lib/pack-v2");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const PACKS = path.join(FABRIC, "app/data/packs/v1");
const LIVE_URL = process.env.LIVE_ROUTE_URL || "https://dirt-mayday.vercel.app/api/route";
const PUBLIC_R2_BASE = (
  process.env.R2_PUBLIC_BASE || "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev"
).replace(/\/$/, "");

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  let regionId = null;
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") return { help: true, regionId: null };
    if (value !== "--region") fail(`Unknown argument: ${value}`);
    const candidate = String(argv[index + 1] || "").toLowerCase();
    if (!/^[a-z0-9][a-z0-9_-]{1,15}$/.test(candidate)) {
      fail("--region requires a valid region id");
    }
    if (regionId) fail("--region may be provided only once");
    regionId = candidate;
    index += 1;
  }
  if (!regionId) fail("verification requires exactly one --region <id>");
  return { help: false, regionId };
}

function request(url, options = {}) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const transport = parsed.protocol === "https:" ? https : http;
    const req = transport.request(
      {
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
        path: parsed.pathname + parsed.search,
        method: options.method || "GET",
        headers: options.headers || {}
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => resolve({
          status: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks)
        }));
      }
    );
    req.on("error", reject);
    req.setTimeout(options.timeoutMs || 20_000, () => {
      req.destroy(new Error(`timeout ${url}`));
    });
    if (options.body) req.write(options.body);
    req.end();
  });
}

async function getJson(url) {
  const response = await request(url);
  if (response.status !== 200) fail(`HTTP ${response.status} ${url}`);
  try {
    return JSON.parse(response.body.toString("utf8"));
  } catch (error) {
    fail(`Malformed JSON from ${url}: ${error.message}`);
  }
}

async function postJson(url, payload) {
  const body = JSON.stringify(payload);
  const response = await request(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body)
    },
    body,
    timeoutMs: 120_000
  });
  let json;
  try {
    json = JSON.parse(response.body.toString("utf8"));
  } catch (_) {
    json = { raw: response.body.toString("utf8").slice(0, 400) };
  }
  return { status: response.status, json };
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function regionRecord(manifest, regionId) {
  const region = manifest && Array.isArray(manifest.regions)
    ? manifest.regions.find((entry) => entry.id === regionId)
    : null;
  if (!region) fail(`Promoted manifest has no region '${regionId}'`);
  const files = Array.isArray(region.files) ? region.files : [];
  if (!files.some((file) => /^graph\.v[23]\.bin$/.test(file.name || ""))) {
    fail(`Promoted manifest region '${regionId}' has no graph`);
  }
  if (!files.some((file) => file.name === "geometry.v1.bin")) {
    fail(`Promoted manifest region '${regionId}' has no geometry`);
  }
  return region;
}

function verifyLocalFile(regionId, record) {
  const local = path.join(PACKS, regionId, record.name);
  if (!fs.existsSync(local)) fail(`Missing local ${regionId}/${record.name}`);
  const localBytes = fs.statSync(local).size;
  if (localBytes !== Number(record.bytes)) {
    fail(`${regionId}/${record.name} local=${localBytes} manifest=${record.bytes}`);
  }
  const localSha = sha256File(local);
  if (localSha !== record.sha256) {
    fail(`${regionId}/${record.name} local SHA-256 does not match promoted manifest`);
  }
  return local;
}

async function verifyRemoteFile(regionId, record) {
  const url = `${PUBLIC_R2_BASE}/${regionId}/${record.name}`;
  const response = await request(url, { method: "HEAD" });
  if (response.status !== 200) fail(`R2 HTTP ${response.status} ${regionId}/${record.name}`);
  const remoteBytes = Number(response.headers["content-length"] || 0);
  if (remoteBytes !== Number(record.bytes)) {
    fail(`${regionId}/${record.name} R2=${remoteBytes} manifest=${record.bytes}`);
  }
}

function graphFileRecord(region) {
  return region.files.find((file) => file.name === "graph.v3.bin") ||
    region.files.find((file) => file.name === "graph.v2.bin");
}

function smokeLocations(graphPath) {
  const pack = decodeGraphV2(fs.readFileSync(graphPath));
  if (!pack.edgeFrom || !pack.edgeTo) fail(`${path.basename(graphPath)} has no endpoint table`);
  const bbox = Array.isArray(pack.bbox) && pack.bbox.length >= 4
    ? pack.bbox.map(Number)
    : null;
  const centerLon = bbox ? (bbox[0] + bbox[2]) / 2 : 0;
  const centerLat = bbox ? (bbox[1] + bbox[3]) / 2 : 0;
  const width = bbox ? Math.max(0.1, bbox[2] - bbox[0]) : 1;
  const height = bbox ? Math.max(0.1, bbox[3] - bbox[1]) : 1;
  let best = null;

  for (let edgeIndex = 0; edgeIndex < pack.undirectedEdgeCount; edgeIndex += 1) {
    const accessName = pack.enums.ACCESS_NAME[String(unpackAccess(pack.edgeAttrs[edgeIndex]))];
    if (accessName !== "motorized_verified" && accessName !== "motorized_permissive") continue;
    const structureName = pack.enums.STRUCTURE_NAME[String(unpackStructure(pack.edgeAttrs[edgeIndex]))];
    if (structureName === "ferry" || structureName === "blocked_passage") continue;
    const meters = Number(pack.edgeMeters[edgeIndex]);
    if (meters < 250 || meters > 5_000) continue;
    const fromNode = pack.edgeFrom[edgeIndex];
    const toNode = pack.edgeTo[edgeIndex];
    const from = {
      lon: Number(pack.nodeCoords[fromNode * 2]),
      lat: Number(pack.nodeCoords[fromNode * 2 + 1])
    };
    const to = {
      lon: Number(pack.nodeCoords[toNode * 2]),
      lat: Number(pack.nodeCoords[toNode * 2 + 1])
    };
    if (![from.lon, from.lat, to.lon, to.lat].every(Number.isFinite)) continue;
    const midLon = (from.lon + to.lon) / 2;
    const midLat = (from.lat + to.lat) / 2;
    const score = ((midLon - centerLon) / width) ** 2 + ((midLat - centerLat) / height) ** 2;
    if (!best || score < best.score) best = { from, to, score };
  }

  if (!best) fail(`No suitable smoke-test edge in ${path.basename(graphPath)}`);
  return [best.from, best.to];
}

function verifyRouteIdentity(result, regionId, region) {
  const identities = result && result.debug && Array.isArray(result.debug.packIdentity)
    ? result.debug.packIdentity
    : [];
  const identity = identities.find((entry) => entry.regionId === regionId);
  if (!identity) fail(`Live route did not report region '${regionId}'`);
  const graph = graphFileRecord(region);
  const geometry = region.files.find((file) => file.name === "geometry.v1.bin");
  if (identity.graphSha256 !== graph.sha256 || Number(identity.graphBytes) !== Number(graph.bytes)) {
    fail(`Live route graph identity does not match promoted ${regionId}/${graph.name}`);
  }
  if (
    identity.geometrySha256 !== geometry.sha256 ||
    Number(identity.geometryBytes) !== Number(geometry.bytes)
  ) {
    fail(`Live route geometry identity does not match promoted ${regionId}/geometry.v1.bin`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log("Usage: node scripts/pack-fabric/scripts/assert-live-pack-lockstep.js --region <id>");
    return;
  }
  const { regionId } = args;
  const manifest = await getJson(`${PUBLIC_R2_BASE}/manifest.json`);
  const region = regionRecord(manifest, regionId);
  const graph = graphFileRecord(region);

  for (const file of region.files) {
    verifyLocalFile(regionId, file);
    await verifyRemoteFile(regionId, file);
    console.log(`ok ${regionId}/${file.name} matches promoted manifest`);
  }

  const service = await getJson(LIVE_URL);
  if (service.serviceContract !== "dirt-routing.r0.v1") {
    fail(`Unexpected live service contract ${service.serviceContract || "missing"}`);
  }
  if (!/^[a-f0-9]{7,40}$/i.test(String(service.serviceBuild || ""))) {
    fail(`Live service build is not a committed identity: ${service.serviceBuild || "missing"}`);
  }

  const locations = smokeLocations(path.join(PACKS, regionId, graph.name));
  const route = await postJson(LIVE_URL, {
    profile: "balanced",
    locations,
    vehicle: "dual-sport-motorcycle",
    accessPolicy: {
      motorizedPermissive: true,
      motorizedUnknown: false
    },
    options: { sessionSeed: 0 }
  });
  if (route.status !== 200 || !route.json || route.json.status !== "complete") {
    fail(`Live ${regionId} route HTTP ${route.status}: ${
      route.json && (route.json.error || route.json.message || route.json.status)
    }`);
  }
  if (route.json.serviceBuild !== service.serviceBuild) {
    fail("Live route and service identity responses came from different builds");
  }
  verifyRouteIdentity(route.json, regionId, region);
  console.log(
    `ok live ${regionId} route uses ${graph.name} from service build ${service.serviceBuild}`
  );
}

if (require.main === module) {
  main().catch((error) => {
    console.error("LOCKSTEP FAIL:", error && error.message ? error.message : String(error));
    process.exit(1);
  });
}

module.exports = {
  graphFileRecord,
  parseArgs,
  regionRecord,
  smokeLocations,
  verifyRouteIdentity
};
