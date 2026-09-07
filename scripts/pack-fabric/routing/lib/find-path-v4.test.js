"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { findPathV4 } = require("./legal-topology/find-path-v4");

test("find-path-v4 module loads", () => {
  assert.equal(typeof findPathV4, "function");
});
