import assert from "node:assert/strict";
import test from "node:test";

import {
  buildPlan,
  formatSummary,
  parseArgs,
  runPlan,
} from "./verify-launch-candidate.mjs";

test("fast is the local-only default", () => {
  assert.deepEqual(parseArgs([]), {
    mode: "fast",
    archive: null,
    destination: "platform=iOS Simulator,name=iPhone 17,OS=26.5",
    plan: false,
    help: false,
  });
  assert.deepEqual(
    buildPlan(parseArgs([])).map((step) => step.id),
    ["launch-contract-tests", "release-contract-tests"],
  );
});

test("package and full modes expand the same ordered local gate", () => {
  assert.deepEqual(
    buildPlan(parseArgs(["--mode", "package"])).map((step) => step.id),
    ["launch-contract-tests", "release-contract-tests", "release-build", "release-bundle"],
  );
  assert.deepEqual(
    buildPlan(parseArgs(["--mode", "full"])).map((step) => step.id),
    ["launch-contract-tests", "release-contract-tests", "shared-tests", "release-build", "release-bundle", "ios-tests", "release-analysis"],
  );
});

test("archive verification must be explicit and absolute", () => {
  assert.throws(() => parseArgs(["--archive", "build/Dirt.xcarchive"]), /absolute/);
  assert.throws(() => parseArgs(["--archive", "/tmp/Dirt.app"]), /end in \.xcarchive/);
  const options = parseArgs(["--archive", "/tmp/Dirt.xcarchive"]);
  assert.equal(buildPlan(options).at(-1).id, "signed-archive");
  assert.throws(() => parseArgs(["--mode", "remote"]), /fast, package, or full/);
  assert.throws(() => parseArgs(["--deploy"]), /unknown argument/);
});

test("a failed prerequisite step deterministically skips only its dependent", async () => {
  const steps = [
    { id: "build", label: "build", command: "false", args: [], requires: [] },
    { id: "bundle", label: "bundle", command: "unused", args: [], requires: ["build"] },
    { id: "independent", label: "independent", command: "true", args: [], requires: [] },
  ];
  const calls = [];
  const results = await runPlan(steps, async (command) => {
    calls.push(command);
    return { code: command === "false" ? 9 : 0 };
  });
  assert.deepEqual(calls, ["false", "true"]);
  assert.deepEqual(results.map(({ id, status }) => ({ id, status })), [
    { id: "build", status: "fail" },
    { id: "bundle", status: "skip" },
    { id: "independent", status: "pass" },
  ]);
  const summary = formatSummary("package", results, 1.25);
  assert.match(summary, /result: FAIL/);
  assert.match(summary, /steps: 1 passed, 1 failed, 1 skipped/);
  assert.match(summary, /SKIP bundle \(0\.0s\) — requires build/);
});
