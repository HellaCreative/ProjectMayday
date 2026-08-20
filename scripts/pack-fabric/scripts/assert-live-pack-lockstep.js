#!/usr/bin/env node
"use strict";

/**
 * Fail if live `/api/route` is not the phone pack.
 *
 *   node scripts/pack-fabric/scripts/assert-live-pack-lockstep.js
 *   LIVE_ROUTE_URL=https://dirt-mayday.vercel.app/api/route node ...
 */

const fs = require("fs");
const path = require("path");
const https = require("https");
const http = require("http");

const DIRT = path.resolve(__dirname, "../../..");
const FABRIC = path.join(DIRT, "scripts/pack-fabric");
const LIVE_URL = process.env.LIVE_ROUTE_URL || "https://dirt-mayday.vercel.app/api/route";
const PACKS = path.join(FABRIC, "app/data/packs/v1");
const REGION_IDS = ["bc", "ab", "wa"];

function fail(msg) {
  console.error("LOCKSTEP FAIL:", msg);
  process.exit(1);
}

function request(url, method) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const lib = u.protocol === "https:" ? https : http;
    const req = lib.request(
      {
        hostname: u.hostname,
        port: u.port || (u.protocol === "https:" ? 443 : 80),
        path: u.pathname + u.search,
        method: method || "GET"
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () =>
          resolve({
            status: res.statusCode,
            headers: res.headers,
            body: Buffer.concat(chunks)
          })
        );
      }
    );
    req.on("error", reject);
    req.setTimeout(20000, () => req.destroy(new Error("timeout " + url)));
    req.end();
  });
}

function postJson(url, payload) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const lib = u.protocol === "https:" ? https : http;
    const body = JSON.stringify(payload);
    const req = lib.request(
      {
        hostname: u.hostname,
        port: u.port || (u.protocol === "https:" ? 443 : 80),
        path: u.pathname,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body)
        }
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json = null;
          try {
            json = JSON.parse(text);
          } catch (_) {
            json = { raw: text.slice(0, 400) };
          }
          resolve({ status: res.statusCode, json });
        });
      }
    );
    req.on("error", reject);
    req.setTimeout(120000, () => req.destroy(new Error("route timeout")));
    req.write(body);
    req.end();
  });
}

async function main() {
  const selectPath = path.join(FABRIC, "routing/regional/select.js");
  if (fs.existsSync(selectPath)) {
    const src = fs.readFileSync(selectPath, "utf8");
    if (/useLonghaulPacks\s*=\s*!!/.test(src) || /useLonghaulPacks\s*=\s*onVercel/.test(src)) {
      fail(selectPath + " still opts Vercel into longhaul. Live must be graph.v2.bin.");
    }
    if (!/graph\.v2\.bin/.test(src)) {
      fail(selectPath + " does not mention graph.v2.bin");
    }
    console.log("ok select.js points at graph.v2.bin");
  } else {
    fail("missing " + selectPath);
  }

  const costsPath = path.join(FABRIC, "routing/lib/profile-costs.js");
  const dirt = require(costsPath);
  console.log("ok cost tables dirt.paved =", dirt.PROFILE_SURFACE_WEIGHTS.dirt.paved);

  const publicBase = "https://pub-eb539dc7777942b889388ebb4b701697.r2.dev";
  for (const regionId of REGION_IDS) {
    for (const fileName of ["graph.v2.bin", "geometry.v1.bin", "fuel.v1.json"]) {
      const remote = `${publicBase}/${regionId}/${fileName}`;
      const head = await request(remote, "HEAD");
      if (head.status !== 200) fail(`R2 pack missing HTTP ${head.status} ${remote}`);
      const remoteBytes = Number(head.headers["content-length"] || 0);
      const local = path.join(PACKS, regionId, fileName);
      if (!fs.existsSync(local)) fail("missing local staged file " + local);
      const localBytes = fs.statSync(local).size;
      if (remoteBytes !== localBytes) {
        fail(`${regionId}/${fileName} local=${localBytes} R2=${remoteBytes}`);
      }
      console.log(`ok R2 ${regionId}/${fileName} matches local ${localBytes} bytes`);
    }
  }

  const route = await postJson(LIVE_URL, {
    profile: "dirt",
    allowUnknown: false,
    locations: [
      { lat: 49.0504, lon: -122.3045, label: "A" },
      { lat: 50.111, lon: -120.786, label: "B" }
    ]
  });
  if (route.status !== 200 || !route.json || route.json.status !== "complete") {
    fail("live route HTTP " + route.status + " " + JSON.stringify(route.json && (route.json.error || route.json.message || route.json.status)));
  }
  const g = (route.json.debug && route.json.debug.graph) || {};
  const mode = (route.json.debug && route.json.debug.graphMode) || "";
  const schema = String(g.schemaVersion || "");
  const edges = Number(g.edgeCount || 0);
  if (/longhaul/i.test(schema) || /longhaul/i.test(mode)) {
    fail("live still on longhaul extract schema=" + schema + " mode=" + mode);
  }
  if (edges < 400000) {
    fail("live edgeCount " + edges + " looks like the thinned extract, not the phone pack (~556k)");
  }
  console.log(
    "ok live",
    LIVE_URL,
    "mode=" + mode,
    "schema=" + schema,
    "edges=" + edges,
    "dirt%=" + ((route.json.stats && route.json.stats.dirtPercent) || "?")
  );
}

main().catch((err) => {
  fail(err && err.message ? err.message : String(err));
});
