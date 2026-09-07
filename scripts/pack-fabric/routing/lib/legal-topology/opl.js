"use strict";

/**
 * Parse osmium OPL into lossless OSM objects. IDs stay 64-bit strings.
 */

function parseTags(field) {
  const tags = {};
  if (!field) return tags;
  const body = field.startsWith("T") ? field.slice(1) : field;
  if (!body) return tags;
  for (const part of body.split(",")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    let key = part.slice(0, eq);
    let value = part.slice(eq + 1);
    try {
      key = decodeURIComponent(key.replace(/%2C/gi, ",").replace(/%3D/gi, "="));
      value = decodeURIComponent(value.replace(/%2C/gi, ",").replace(/%3D/gi, "=").replace(/\\s/g, " "));
    } catch {
      // keep raw
    }
    tags[key] = value;
  }
  return tags;
}

function parseOpl(text) {
  const nodes = [];
  const ways = [];
  const relations = [];
  for (const line of String(text).split(/\n+/)) {
    if (!line) continue;
    const tokens = line.split(" ");
    const first = tokens[0] || "";
    const kind = first[0];
    const osmId = first.slice(1);
    if (!osmId) continue;
    const fields = {};
    for (let i = 1; i < tokens.length; i += 1) {
      const tok = tokens[i];
      if (!tok) continue;
      fields[tok[0]] = tok;
    }
    if (kind === "n") {
      const x = fields.x ? Number(fields.x.slice(1)) : NaN;
      const y = fields.y ? Number(fields.y.slice(1)) : NaN;
      nodes.push({ id: osmId, lon: x, lat: y, tags: parseTags(fields.T) });
    } else if (kind === "w") {
      const nd = fields.N ? fields.N.slice(1).split(",").map((s) => s.replace(/^n/, "")) : [];
      ways.push({ id: osmId, nodeIds: nd, tags: parseTags(fields.T) });
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
      relations.push({ id: osmId, members, tags: parseTags(fields.T) });
    }
  }
  return { nodes, ways, relations };
}

module.exports = { parseOpl, parseTags };
