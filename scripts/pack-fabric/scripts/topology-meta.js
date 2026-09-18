"use strict";

/**
 * Read seal/upload metadata from a national cross-pack topology without
 * JSON.parse of the whole file. CA-scale topologies exceed Node's ~512MB
 * string limit (same class of bug as streaming checkpoints / thin sidecars).
 */

const fs = require("fs");

function scalarFromHead(head, key) {
  const match = new RegExp(`"${key}"\\s*:\\s*"([^"]*)"`).exec(head);
  return match ? match[1] : null;
}

function readHead(file, bytes = 16384) {
  const size = fs.statSync(file).size;
  const len = Math.min(bytes, size);
  const buf = Buffer.alloc(len);
  const fd = fs.openSync(file, "r");
  try {
    fs.readSync(fd, buf, 0, len, 0);
  } finally {
    fs.closeSync(fd);
  }
  return buf.toString("utf8");
}

function readTail(file, bytes = 512 * 1024) {
  const size = fs.statSync(file).size;
  const len = Math.min(bytes, size);
  const buf = Buffer.alloc(len);
  const fd = fs.openSync(file, "r");
  try {
    fs.readSync(fd, buf, 0, len, size - len);
  } finally {
    fs.closeSync(fd);
  }
  return buf.toString("utf8");
}

function parsePairsFromTail(tail) {
  const match = /"pairs"\s*:\s*(\[[\s\S]*\])\s*\}\s*$/.exec(tail);
  if (!match) throw new Error("topology tail missing pairs array");
  return JSON.parse(match[1]);
}

/**
 * Scan for top-level region entries written as `"id":{"neighbors":`.
 * Neighbor maps use `"id":[` so they do not match.
 */
function collectRegionIdsSync(file) {
  const ids = [];
  const seen = new Set();
  const fd = fs.openSync(file, "r");
  const buffer = Buffer.allocUnsafe(8 * 1024 * 1024);
  let carry = "";
  try {
    for (;;) {
      const read = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (!read) break;
      const text = carry + buffer.toString("utf8", 0, read);
      const re = /"([a-z0-9-]+)":\{"neighbors":/g;
      let match;
      while ((match = re.exec(text))) {
        const id = match[1];
        if (!seen.has(id)) {
          seen.add(id);
          ids.push(id);
        }
      }
      carry = text.slice(Math.max(0, text.length - 64));
    }
  } finally {
    fs.closeSync(fd);
  }
  return ids.sort();
}

function collectRegionIds(file) {
  return Promise.resolve(collectRegionIdsSync(file));
}

function readTopologySealMetaSync(file, { regions = true } = {}) {
  if (!fs.existsSync(file)) throw new Error(`topology missing: ${file}`);
  const head = readHead(file);
  const tail = readTail(file);
  const pairs = parsePairsFromTail(tail);
  const meta = {
    schemaVersion: scalarFromHead(head, "schemaVersion"),
    fabricReleaseId: scalarFromHead(head, "fabricReleaseId"),
    sourceEpoch: scalarFromHead(head, "sourceEpoch"),
    generatedAt: scalarFromHead(head, "generatedAt"),
    pairs,
    pairCount: pairs.length
  };
  if (regions) meta.regionIds = collectRegionIdsSync(file);
  return meta;
}

async function readTopologySealMeta(file, opts) {
  return readTopologySealMetaSync(file, opts);
}

module.exports = {
  readTopologySealMetaSync,
  readTopologySealMeta,
  collectRegionIds,
  collectRegionIdsSync,
  parsePairsFromTail,
  scalarFromHead
};
