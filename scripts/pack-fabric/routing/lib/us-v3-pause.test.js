"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  assertPackFactoryNotPaused,
  assertUsV3NotPaused,
  PACK_FACTORY_PAUSE_MESSAGE
} = require("./us-v3-pause");

test("pack factory pause blocks every region until resume", () => {
  assert.throws(
    () => assertPackFactoryNotPaused("mt", { resumeEnv: undefined, usResumeEnv: undefined }),
    new RegExp(PACK_FACTORY_PAUSE_MESSAGE)
  );
  assert.throws(
    () => assertUsV3NotPaused("ns", { resumeEnv: "", usResumeEnv: "" }),
    /Pack factory is paused/
  );
  assert.throws(
    () => assertPackFactoryNotPaused("nb", { resumeEnv: undefined, usResumeEnv: undefined }),
    /Pack factory is paused/
  );
  assert.doesNotThrow(() =>
    assertPackFactoryNotPaused("mt", { resumeEnv: "1", usResumeEnv: undefined })
  );
  assert.doesNotThrow(() =>
    assertPackFactoryNotPaused("ns", { resumeEnv: undefined, usResumeEnv: "1" })
  );
});
