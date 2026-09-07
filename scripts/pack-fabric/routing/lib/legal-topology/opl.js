"use strict";

const fs = require("fs");
const readline = require("readline");

/**
 * Parse osmium OPL into lossless OSM objects. IDs stay 64-bit strings.
 */

/**
 * OPL uses `%HH%` escapes, including the trailing percent. Adjacent escaped
 * characters therefore look like `%20%%40%%20%`. This is deliberately not
 * URL encoding; decodeURIComponent would either leave a trailing `%` behind
 * or reject the complete tag and silently return raw access/restriction data.
 */
function decodeOplString(value) {
  return String(value || "").replace(/%([0-9a-f]{2})%/gi, (_match, hex) =>
    String.fromCharCode(Number.parseInt(hex, 16))
  );
}

function parseTags(field) {
  const tags = {};
  if (!field) return tags;
  const body = field.startsWith("T") ? field.slice(1) : field;
  if (!body) return tags;
  for (const part of body.split(",")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const key = decodeOplString(part.slice(0, eq));
    const value = decodeOplString(part.slice(eq + 1)).replace(/\\s/g, " ");
    tags[key] = value;
  }
  return tags;
}

function parseOplLine(line, { sparseEmptyNodeTags = false } = {}) {
    if (!line) return null;
    const tokens = line.split(" ");
    const first = tokens[0] || "";
    const kind = first[0];
    const osmId = first.slice(1);
    if (!osmId) return null;
    const fields = {};
    for (let i = 1; i < tokens.length; i += 1) {
      const tok = tokens[i];
      if (!tok) continue;
      fields[tok[0]] = tok;
    }
    if (kind === "n") {
      const x = fields.x ? Number(fields.x.slice(1)) : NaN;
      const y = fields.y ? Number(fields.y.slice(1)) : NaN;
      return {
        kind: "node",
        value: {
          id: osmId,
          lon: x,
          lat: y,
          tags: sparseEmptyNodeTags && (!fields.T || fields.T === "T") ? null : parseTags(fields.T)
        }
      };
    } else if (kind === "w") {
      const nd = fields.N ? fields.N.slice(1).split(",").map((s) => s.replace(/^n/, "")) : [];
      return { kind: "way", value: { id: osmId, nodeIds: nd, tags: parseTags(fields.T) } };
    } else if (kind === "r") {
      const members = [];
      if (fields.M) {
        for (const m of fields.M.slice(1).split(",")) {
          const [refRole, role] = m.split("@");
          if (!refRole) continue;
          const type = refRole[0] === "n" ? "node" : refRole[0] === "w" ? "way" : "relation";
          members.push({ type, ref: refRole.slice(1), role: role || "" });
        }
      }
      return { kind: "relation", value: { id: osmId, members, tags: parseTags(fields.T) } };
    }
    return null;
}

const PACKED_NODE_CHUNK_SIZE = 1024 * 1024;

/**
 * OSM road extracts contain tens of millions of coordinate-only nodes. Keeping
 * each one as a JavaScript object (plus a duplicated string id) exhausts the
 * heap on large regions such as California. This sorted, chunked store keeps
 * the exact numeric identity and double-precision coordinates in typed arrays.
 * Only access/barrier node tags are retained because those are the only node
 * tags consumed by the legal-topology graph builder.
 */
class PackedOplNodeStore {
  constructor(chunkSize = PACKED_NODE_CHUNK_SIZE) {
    this.chunkSize = chunkSize;
    this.chunks = [];
    this.tagged = new Map();
    this.count = 0;
    this.lastId = -Infinity;
  }

  add(node) {
    const id = Number(node.id);
    if (!Number.isSafeInteger(id)) throw new Error(`OPL node id is not a safe integer: ${node.id}`);
    if (id < this.lastId) throw new Error(`OPL nodes are not sorted: ${node.id} follows ${this.lastId}`);
    let chunk = this.chunks[this.chunks.length - 1];
    if (!chunk || chunk.used === this.chunkSize) {
      chunk = {
        ids: new Float64Array(this.chunkSize),
        lons: new Float64Array(this.chunkSize),
        lats: new Float64Array(this.chunkSize),
        used: 0,
        minId: id,
        maxId: id
      };
      this.chunks.push(chunk);
    }
    const at = chunk.used++;
    chunk.ids[at] = id;
    chunk.lons[at] = node.lon;
    chunk.lats[at] = node.lat;
    chunk.maxId = id;
    this.lastId = id;
    const tags = node.tags;
    if (tags && (tags.barrier != null || tags.access != null || tags.locked != null)) {
      this.tagged.set(id, tags);
    }
    this.count += 1;
  }

  indexOf(value) {
    const id = Number(value);
    if (!Number.isSafeInteger(id) || !this.chunks.length) return -1;
    let lo = 0;
    let hi = this.chunks.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      const chunk = this.chunks[mid];
      if (id < chunk.minId) hi = mid - 1;
      else if (id > chunk.maxId) lo = mid + 1;
      else {
        let left = 0;
        let right = chunk.used - 1;
        while (left <= right) {
          const at = (left + right) >> 1;
          const found = chunk.ids[at];
          if (found === id) return mid * this.chunkSize + at;
          if (found < id) left = at + 1;
          else right = at - 1;
        }
        return -1;
      }
    }
    return -1;
  }

  getByIndex(index) {
    if (!Number.isSafeInteger(index) || index < 0 || index >= this.count) return null;
    const chunk = this.chunks[Math.floor(index / this.chunkSize)];
    const at = index % this.chunkSize;
    const id = chunk.ids[at];
    return {
      id: String(id),
      lon: chunk.lons[at],
      lat: chunk.lats[at],
      tags: this.tagged.get(id) || null
    };
  }

  get(value) {
    return this.getByIndex(this.indexOf(value));
  }

  clear() {
    this.chunks.length = 0;
    this.tagged.clear();
    this.count = 0;
    this.lastId = -Infinity;
  }
}

function parseOpl(text) {
  const nodes = [];
  const ways = [];
  const relations = [];
  for (const line of String(text).split(/\n+/)) {
    const parsed = parseOplLine(line);
    if (!parsed) continue;
    if (parsed.kind === "node") nodes.push(parsed.value);
    else if (parsed.kind === "way") ways.push(parsed.value);
    else relations.push(parsed.value);
  }
  return { nodes, ways, relations };
}

/** Stream continent-scale extracts instead of duplicating a giant OPL string
 * into an equally giant line array. */
async function parseOplFile(file, { packedNodes = false } = {}) {
  const nodes = [];
  const nodeStore = packedNodes ? new PackedOplNodeStore() : null;
  const ways = [];
  const relations = [];
  const input = fs.createReadStream(file, { encoding: "utf8" });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });
  for await (const line of lines) {
    const parsed = parseOplLine(line, { sparseEmptyNodeTags: true });
    if (!parsed) continue;
    if (parsed.kind === "node") {
      if (nodeStore) nodeStore.add(parsed.value);
      else nodes.push(parsed.value);
    }
    else if (parsed.kind === "way") ways.push(parsed.value);
    else relations.push(parsed.value);
  }
  return { nodes, nodeStore, ways, relations };
}

module.exports = {
  parseOpl,
  parseOplFile,
  parseOplLine,
  parseTags,
  decodeOplString,
  PackedOplNodeStore
};
