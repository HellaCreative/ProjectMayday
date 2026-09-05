#!/usr/bin/env node

import { access } from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const REPO_ROOT = path.resolve(path.dirname(SCRIPT_PATH), "..");
const DEFAULT_DESTINATION = "platform=iOS Simulator,name=iPhone 17,OS=26.5";
const MODE_RANK = Object.freeze({ fast: 0, package: 1, full: 2 });

function fail(message) {
  throw new Error(message);
}

export function parseArgs(argv) {
  const options = {
    mode: "fast",
    archive: null,
    destination: DEFAULT_DESTINATION,
    plan: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") {
      options.help = true;
      continue;
    }
    if (value === "--plan") {
      options.plan = true;
      continue;
    }
    if (value === "--mode") {
      const mode = argv[index + 1];
      if (!Object.hasOwn(MODE_RANK, mode)) fail("--mode must be fast, package, or full");
      options.mode = mode;
      index += 1;
      continue;
    }
    if (value === "--archive") {
      const archive = argv[index + 1];
      if (!archive || !path.isAbsolute(archive)) fail("--archive requires an absolute .xcarchive path");
      if (!archive.endsWith(".xcarchive")) fail("--archive path must end in .xcarchive");
      options.archive = path.resolve(archive);
      index += 1;
      continue;
    }
    if (value === "--destination") {
      const destination = argv[index + 1];
      if (!destination || destination.startsWith("--")) fail("--destination requires an xcodebuild destination");
      options.destination = destination;
      index += 1;
      continue;
    }
    fail(`unknown argument: ${value}`);
  }

  return options;
}

function commandStep({ id, label, command, args, minimumMode = "fast", requires = [] }) {
  return { id, label, command, args, minimumMode, requires };
}

export function buildPlan(options) {
  const steps = [
    commandStep({
      id: "launch-contract-tests",
      label: "launch verifier contract tests",
      command: "node",
      args: [
        "--test",
        "scripts/verify-launch-health.test.mjs",
        "scripts/verify-launch-candidate.test.mjs",
      ],
    }),
    commandStep({
      id: "release-contract-tests",
      label: "immutable pack, Rider Services, and publication contract tests",
      command: "node",
      args: [
        "--test",
        "--test-concurrency=1",
        "scripts/pack-fabric/bench/release-pack.test.js",
        "scripts/pack-fabric/poi/fuel-filter.test.js",
        "scripts/pack-fabric/poi/poi-api.test.js",
        "scripts/pack-fabric/scripts/assert-live-pack-lockstep.test.js",
        "scripts/pack-fabric/scripts/repair-pack-catalog.test.js",
        "scripts/pack-fabric/scripts/service-publication.test.js",
        "scripts/pack-fabric/scripts/ship-routing.test.js",
      ],
    }),
    commandStep({
      id: "shared-tests",
      label: "complete shared routing and pack test suite",
      command: "npm",
      args: ["test"],
      minimumMode: "full",
    }),
    commandStep({
      id: "release-build",
      label: "unsigned DIRT Production Release build",
      command: "xcodebuild",
      args: [
        "-project", "Dirt.xcodeproj",
        "-scheme", "DIRT Production",
        "-configuration", "Release",
        "-destination", "generic/platform=iOS",
        "-disableAutomaticPackageResolution",
        "-onlyUsePackageVersionsFromResolvedFile",
        "CODE_SIGNING_ALLOWED=NO",
        "build",
      ],
      minimumMode: "package",
    }),
    {
      id: "release-bundle",
      label: "Release identity, resources, privacy, and package gate",
      minimumMode: "package",
      requires: ["release-build"],
      execute: verifyBuiltRelease,
    },
    commandStep({
      id: "ios-tests",
      label: "iOS unit and integration tests",
      command: "xcodebuild",
      args: [
        "test",
        "-project", "Dirt.xcodeproj",
        "-scheme", "DIRT Dev",
        "-destination", options.destination,
        "-disableAutomaticPackageResolution",
        "-onlyUsePackageVersionsFromResolvedFile",
        "-only-testing:DirtTests",
        "CODE_SIGNING_ALLOWED=NO",
      ],
      minimumMode: "full",
    }),
    commandStep({
      id: "release-analysis",
      label: "Xcode Production Release static analysis",
      command: "xcodebuild",
      args: [
        "-project", "Dirt.xcodeproj",
        "-scheme", "DIRT Production",
        "-configuration", "Release",
        "-destination", "generic/platform=iOS",
        "-disableAutomaticPackageResolution",
        "-onlyUsePackageVersionsFromResolvedFile",
        "CODE_SIGNING_ALLOWED=NO",
        "analyze",
      ],
      minimumMode: "full",
    }),
  ].filter((step) => MODE_RANK[step.minimumMode] <= MODE_RANK[options.mode]);

  if (options.archive) {
    steps.push(commandStep({
      id: "signed-archive",
      label: "supplied signed archive gate",
      command: path.join(REPO_ROOT, "scripts/verify-ios-archive.sh"),
      args: [options.archive],
    }));
  }
  return steps;
}

async function verifyBuiltRelease(context) {
  const settings = await context.capture("xcodebuild", [
    "-project", "Dirt.xcodeproj",
    "-scheme", "DIRT Production",
    "-configuration", "Release",
    "-destination", "generic/platform=iOS",
    "-disableAutomaticPackageResolution",
    "-onlyUsePackageVersionsFromResolvedFile",
    "-showBuildSettings",
  ]);
  const targetDirectory = settings.stdout.match(/^\s*TARGET_BUILD_DIR = (.+)$/m)?.[1]?.trim();
  const productName = settings.stdout.match(/^\s*FULL_PRODUCT_NAME = (.+)$/m)?.[1]?.trim();
  if (!targetDirectory || !productName) fail("xcodebuild did not report the built application path");
  return context.run(path.join(REPO_ROOT, "scripts/verify-ios-release.sh"), [
    path.join(targetDirectory, productName),
  ]);
}

function renderCommand(command, args) {
  const quote = (value) => /^[A-Za-z0-9_./:=+-]+$/.test(value)
    ? value
    : `'${value.replaceAll("'", "'\\''")}'`;
  return [command, ...args].map(quote).join(" ");
}

async function runCommand(command, args, { capture = false } = {}) {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      cwd: REPO_ROOT,
      env: process.env,
      stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
    });
    let stdout = "";
    let stderr = "";
    if (capture) {
      child.stdout.on("data", (chunk) => { stdout += chunk; });
      child.stderr.on("data", (chunk) => { stderr += chunk; });
    }
    child.on("error", (error) => resolve({ code: 127, stdout, stderr, error }));
    child.on("close", (code, signal) => resolve({
      code: code ?? 1,
      stdout,
      stderr,
      signal,
    }));
  });
}

function elapsedSeconds(started) {
  return Number(((Date.now() - started) / 1000).toFixed(1));
}

export async function runPlan(steps, executor = runCommand) {
  const results = [];
  const byID = new Map();
  for (const step of steps) {
    const blockedBy = step.requires.find((id) => byID.get(id)?.status !== "pass");
    if (blockedBy) {
      const result = { id: step.id, label: step.label, status: "skip", seconds: 0, detail: `requires ${blockedBy}` };
      results.push(result);
      byID.set(step.id, result);
      continue;
    }

    const started = Date.now();
    console.log(`\n==> ${step.label}`);
    if (step.command) console.log(`    ${renderCommand(step.command, step.args)}`);
    let outcome;
    try {
      if (step.execute) {
        outcome = await step.execute({
          run: (command, args) => executor(command, args),
          capture: async (command, args) => {
            const captured = await executor(command, args, { capture: true });
            if (captured.code !== 0) {
              const detail = captured.stderr?.trim() || captured.stdout?.trim() || `exit ${captured.code}`;
              fail(detail);
            }
            return captured;
          },
        });
      } else {
        outcome = await executor(step.command, step.args);
      }
    } catch (error) {
      outcome = { code: 1, error };
    }
    const seconds = elapsedSeconds(started);
    const status = outcome.code === 0 ? "pass" : "fail";
    const detail = outcome.error?.message || outcome.signal || `exit ${outcome.code}`;
    const result = { id: step.id, label: step.label, status, seconds, detail };
    results.push(result);
    byID.set(step.id, result);
  }
  return results;
}

export function formatSummary(mode, results, totalSeconds) {
  const passed = results.filter((result) => result.status === "pass").length;
  const failed = results.filter((result) => result.status === "fail");
  const skipped = results.filter((result) => result.status === "skip");
  const lines = [
    "",
    "LAUNCH CANDIDATE SUMMARY",
    `mode: ${mode}`,
    `result: ${failed.length === 0 ? "PASS" : "FAIL"}`,
    `steps: ${passed} passed, ${failed.length} failed, ${skipped.length} skipped`,
    `duration: ${totalSeconds.toFixed(1)}s`,
  ];
  for (const result of results) {
    lines.push(`${result.status.toUpperCase().padEnd(4)} ${result.id} (${result.seconds.toFixed(1)}s)${result.status === "pass" ? "" : ` — ${result.detail}`}`);
  }
  return lines.join("\n");
}

async function checkPrerequisites(options, steps) {
  const requiredFiles = new Set([
    "package.json",
    "scripts/verify-launch-health.mjs",
    "scripts/verify-launch-health.test.mjs",
    "scripts/verify-launch-candidate.test.mjs",
  ]);
  if (MODE_RANK[options.mode] >= MODE_RANK.package) {
    requiredFiles.add("Dirt.xcodeproj/project.pbxproj");
    requiredFiles.add("Dirt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved");
    requiredFiles.add("scripts/verify-ios-release.sh");
  }
  if (options.archive) requiredFiles.add("scripts/verify-ios-archive.sh");

  const missing = [];
  for (const file of requiredFiles) {
    try {
      await access(path.join(REPO_ROOT, file));
    } catch {
      missing.push(file);
    }
  }
  const commands = new Set(steps.filter((step) => step.command).map((step) => step.command));
  if (MODE_RANK[options.mode] >= MODE_RANK.package) {
    for (const command of ["awk", "codesign", "find", "lipo", "plutil", "stat", "strings", "xcrun"]) {
      commands.add(command);
    }
  }
  if (options.archive) commands.add("dwarfdump");
  for (const command of commands) {
    if (command.includes("/")) continue;
    const outcome = await runCommand("/usr/bin/env", ["which", command], { capture: true });
    if (outcome.code !== 0) missing.push(`command:${command}`);
  }
  if (missing.length > 0) fail(`missing prerequisite(s): ${missing.sort().join(", ")}`);
}

function printPlan(options, steps) {
  console.log(`DIRT launch-candidate verification plan (${options.mode})`);
  console.log("Local-only by default: no signing, archiving, deployment, publication, production calls, secrets, or physical devices.");
  for (const [index, step] of steps.entries()) {
    const detail = step.command ? renderCommand(step.command, step.args) : "resolve the built Dirt.app, then run scripts/verify-ios-release.sh";
    console.log(`${index + 1}. ${step.id}: ${detail}`);
  }
}

function usage() {
  console.log(`Usage: scripts/verify-launch-candidate.mjs [options]

Repeatable, local-only launch-candidate verification. The default fast mode
runs deterministic verifier and release/publication contract tests without
Xcode. Timing-sensitive routing coverage is retained in explicit full mode.

Options:
  --mode fast       Verifier + release/publication contract tests (default)
  --mode package    Fast mode + unsigned Production build + existing bundle gate
  --mode full       Package + complete shared/iOS tests + Xcode static analysis
  --archive PATH    Also verify an existing signed archive; never creates/signs one
  --destination D   Simulator destination used only by full mode
  --plan            Print the exact commands without running them
  --help

Package resolution is locked to Package.resolved and automatic resolution is
disabled, so package/full require the resolved dependencies to be present in
Xcode's existing cache. Remote launch health remains a separate, explicitly
invoked read-only gate in scripts/verify-launch-health.mjs.`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }
  const steps = buildPlan(options);
  if (options.plan) {
    printPlan(options, steps);
    return;
  }
  await checkPrerequisites(options, steps);
  printPlan(options, steps);
  const started = Date.now();
  const results = await runPlan(steps);
  const duration = elapsedSeconds(started);
  console.log(formatSummary(options.mode, results, duration));
  if (results.some((result) => result.status === "fail")) process.exitCode = 1;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((error) => {
    console.error(`LAUNCH CANDIDATE FAIL: ${error?.message || String(error)}`);
    process.exitCode = 1;
  });
}
