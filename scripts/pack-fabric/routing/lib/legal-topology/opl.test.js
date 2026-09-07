"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { decodeOplString, parseTags, parseOpl, parseOplFile } = require("./opl");

test("OPL percent escapes decode without URL-decoder corruption", () => {
  assert.equal(decodeOplString("MacDonald%20%Road"), "MacDonald Road");
  assert.equal(
    decodeOplString("no_left_turn%20%%40%%20%(Mo-Fr%20%07:00-09:00)"),
    "no_left_turn @ (Mo-Fr 07:00-09:00)"
  );
  assert.deepEqual(
    parseTags("Tdestination=Digby%2C%%20%NS,source=A%3D%B"),
    { destination: "Digby, NS", source: "A=B" }
  );
});

test("OPL relation parser preserves decoded conditional restriction tags", () => {
  const parsed = parseOpl(
    "r4116373 Trestriction:conditional=no_left_turn%20%%40%%20%(Mo-Fr%20%07:00-09:00),type=restriction Mn1@via,w2@to,w3@from\n"
  );
  assert.equal(parsed.relations[0].tags["restriction:conditional"], "no_left_turn @ (Mo-Fr 07:00-09:00)");
  assert.deepEqual(parsed.relations[0].members, [
    { type: "node", ref: "1", role: "via" },
    { type: "way", ref: "2", role: "to" },
    { type: "way", ref: "3", role: "from" }
  ]);
});

test("streaming OPL parser preserves the in-memory legal identity", async (t) => {
  const text = [
    "n1 v1 dV c0 t i0 u T x-64.2 y45.8",
    "n2 v1 dV c0 t i0 u Tbarrier=gate x-64.1 y45.9",
    "w10 v1 dV c0 t i0 u Thighway=track Nn1,n2",
    "r20 v1 dV c0 t i0 u Ttype=restriction,restriction=no_left_turn Mw10@from,n2@via,w10@to"
  ].join("\n");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dirt-opl-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "fixture.opl");
  fs.writeFileSync(file, text);
  const streamed = await parseOplFile(file);
  const memory = parseOpl(text);
  assert.deepEqual(streamed.ways, memory.ways);
  assert.deepEqual(streamed.relations, memory.relations);
  assert.deepEqual(streamed.nodes.map((row) => ({ ...row, tags: row.tags || {} })), memory.nodes);
});
