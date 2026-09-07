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
          tags: sparseEmptyNodeTags && !fields.T ? null : parseTags(fields.T)
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
async function parseOplFile(file) {
  const nodes = [];
  const ways = [];
  const relations = [];
  const input = fs.createReadStream(file, { encoding: "utf8" });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });
  for await (const line of lines) {
    const parsed = parseOplLine(line, { sparseEmptyNodeTags: true });
    if (!parsed) continue;
    if (parsed.kind === "node") nodes.push(parsed.value);
    else if (parsed.kind === "way") ways.push(parsed.value);
    else relations.push(parsed.value);
  }
  return { nodes, ways, relations };
}

module.exports = { parseOpl, parseOplFile, parseOplLine, parseTags, decodeOplString };
