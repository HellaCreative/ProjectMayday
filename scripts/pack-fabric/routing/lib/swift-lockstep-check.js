"use strict";

/**
 * Cross-engine lockstep check: outputs reference values from JS so they can
 * be compared against Swift RoutingEngineLockstepTests.
 *
 * Run: node scripts/pack-fabric/routing/lib/swift-lockstep-check.js
 */

const {
  chooseDirtRideCandidate,
  DIRT_BASE_SEARCH_BUDGET_MS,
  DIRT_MAX_SEARCH_BUDGET_MS,
  BALANCED_BASE_SEARCH_BUDGET_MS,
  BALANCED_MAX_SEARCH_BUDGET_MS,
  LARGE_GRAPH_BASE_SEARCH_BUDGET_MS,
  CLEAN_BASE_SEARCH_BUDGET_MS,
  CLEAN_MAX_SEARCH_BUDGET_MS,
  BALANCED_LONG_ROUTE_METERS,
  BALANCED_LARGE_GRAPH_NODES,
  PROVINCE_SCALE_GRAPH_NODES,
  DIRT_RECOVERY_EXTRA_METERS,
  DIRT_RECOVERY_DISTANCE_RATIO,
  balancedSearchBudgetMs,
  profileSearchBudgetMs,
  profileSearchPopCap,
  dirtRecoveryPathCap,
  balancedCorridorMultipliers
} = require("./find-path-v2");
const { PASS2_POP_CAP, BALANCED_BUCKETS, VARIETY_SLOTS } = require("./hop-search");

const results = {};
const passed = [];
const failed = [];

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    passed.push(name);
  } else {
    failed.push({ name, actual, expected });
  }
  results[name] = { actual, expected, ok };
}

// Constants
check("DIRT_BASE_SEARCH_BUDGET_MS", DIRT_BASE_SEARCH_BUDGET_MS, 3500);
check("DIRT_MAX_SEARCH_BUDGET_MS", DIRT_MAX_SEARCH_BUDGET_MS, 18000);
check("BALANCED_BASE_SEARCH_BUDGET_MS", BALANCED_BASE_SEARCH_BUDGET_MS, 8000);
check("BALANCED_MAX_SEARCH_BUDGET_MS", BALANCED_MAX_SEARCH_BUDGET_MS, 45000);
check("LARGE_GRAPH_BASE_SEARCH_BUDGET_MS", LARGE_GRAPH_BASE_SEARCH_BUDGET_MS, 12000);
check("CLEAN_BASE_SEARCH_BUDGET_MS", CLEAN_BASE_SEARCH_BUDGET_MS, 12000);
check("CLEAN_MAX_SEARCH_BUDGET_MS", CLEAN_MAX_SEARCH_BUDGET_MS, 18000);
check("BALANCED_LONG_ROUTE_METERS", BALANCED_LONG_ROUTE_METERS, 500000);
check("BALANCED_LARGE_GRAPH_NODES", BALANCED_LARGE_GRAPH_NODES, 500000);
check("PROVINCE_SCALE_GRAPH_NODES", PROVINCE_SCALE_GRAPH_NODES, 1500000);
check("PASS2_POP_CAP", PASS2_POP_CAP, 400000);
check("BALANCED_BUCKETS", BALANCED_BUCKETS, 20);

// Budget tests — exact values for Swift comparison
const budgetTests = [
  { profile: "dirt", meters: 67000, nodes: 250000 },
  { profile: "dirt", meters: 67000, nodes: 1470000 },
  { profile: "dirt", meters: 500000, nodes: 1000000 },
  { profile: "balanced", meters: 250000, nodes: 250000 },
  { profile: "balanced", meters: 67000, nodes: 1470000 },
  { profile: "balanced", meters: 1016620, nodes: 1470000 },
  { profile: "balanced", meters: 100000, nodes: 750000 },
  { profile: "cleanest", meters: 67000, nodes: 250000 },
  { profile: "cleanest", meters: 67000, nodes: 1470000 },
];

console.log("\n=== BUDGET COMPARISON (JS ms) ===");
for (const { profile, meters, nodes } of budgetTests) {
  const ms = profileSearchBudgetMs(profile, meters, nodes);
  console.log(`  ${profile} m=${meters} n=${nodes}: ${ms}ms`);
}

// Pop cap
console.log("\n=== POP CAP ===");
console.log(`  dirt(250k, comp=true):  ${profileSearchPopCap("dirt", 250000, true)}`);
console.log(`  dirt(250k, comp=false): ${profileSearchPopCap("dirt", 250000, false)}`);
console.log(`  balanced(250k):         ${profileSearchPopCap("balanced", 250000)}`);
console.log(`  dirt(1.47M, comp=true): ${profileSearchPopCap("dirt", 1470000, true)}`);
console.log(`  balanced(1.47M):        ${profileSearchPopCap("balanced", 1470000)}`);

// Corridor multipliers
console.log("\n=== CORRIDOR MULTIPLIERS ===");
console.log(`  250k: ${JSON.stringify(balancedCorridorMultipliers(250000))}`);
console.log(`  500k: ${JSON.stringify(balancedCorridorMultipliers(500000))}`);
console.log(`  500001: ${JSON.stringify(balancedCorridorMultipliers(500001))}`);
console.log(`  1016620: ${JSON.stringify(balancedCorridorMultipliers(1016620))}`);

// Recovery path cap
console.log("\n=== RECOVERY PATH CAP ===");
console.log(`  51864: ${dirtRecoveryPathCap(51864)}`);
console.log(`  110275: ${dirtRecoveryPathCap(110275)}`);
console.log(`  382484 cap=382500: ${dirtRecoveryPathCap(382484, 382500)}`);

// Candidate selection
function candidate({ dirt, paved, backward = 0, lateral = 0, route = 300000, width,
  firstSection = dirt, minimumSection = dirt, longestPavedRun = paved, urbanCore = 0 }) {
  return {
    ride: { id: width }, width, dirtPercent: dirt, pavedMeters: paved,
    firstSectionDirtPercent: firstSection, minimumSectionDirtPercent: minimumSection,
    longestPavedRunMeters: longestPavedRun, urbanCoreMeters: urbanCore,
    routeMeters: route, backwardMeters: backward, lateralMeters: lateral
  };
}

console.log("\n=== CANDIDATE SELECTION ===");
const tests = [
  {
    name: "consistent quality over front-loaded",
    candidates: [
      candidate({ dirt: 68, paved: 130000, minimumSection: 12, longestPavedRun: 46000, width: 60000 }),
      candidate({ dirt: 67, paved: 145000, minimumSection: 38, longestPavedRun: 24000, width: 120000 }),
    ],
    expectedWidth: 120000
  },
  {
    name: "higher dirt wins",
    candidates: [
      candidate({ dirt: 58, paved: 260000, backward: 10000, lateral: 30000, width: 50000 }),
      candidate({ dirt: 72, paved: 210000, backward: 35000, lateral: 80000, width: 150000 }),
    ],
    expectedWidth: 150000
  },
  {
    name: "rejects meander",
    candidates: [
      candidate({ dirt: 71, paved: 190000, backward: 8000, lateral: 25000, width: 100000 }),
      candidate({ dirt: 72, paved: 191000, backward: 70000, lateral: 160000, width: 150000 }),
    ],
    expectedWidth: 100000
  },
  {
    name: "less pavement before meander",
    candidates: [
      candidate({ dirt: 70, paved: 220000, backward: 0, lateral: 0, width: 50000 }),
      candidate({ dirt: 71, paved: 180000, backward: 20000, lateral: 20000, width: 100000 }),
    ],
    expectedWidth: 100000
  },
  {
    name: "narrower corridor when identical",
    candidates: [
      candidate({ dirt: 70, paved: 180000, backward: 10000, lateral: 20000, width: 200000 }),
      candidate({ dirt: 70, paved: 180000, backward: 10000, lateral: 20000, width: 50000 }),
    ],
    expectedWidth: 50000
  },
  {
    name: "rejects loop for small gain",
    candidates: [
      candidate({ dirt: 70, paved: 120000, backward: 4000, route: 250000, width: 50000 }),
      candidate({ dirt: 77, paved: 110000, backward: 80000, route: 340000, width: 200000 }),
    ],
    expectedWidth: 50000
  },
];

let candidatesPassed = 0;
for (const t of tests) {
  const winner = chooseDirtRideCandidate(t.candidates);
  const ok = winner && winner.width === t.expectedWidth;
  console.log(`  ${ok ? "PASS" : "FAIL"}: ${t.name} → width=${winner?.width} (expected ${t.expectedWidth})`);
  if (ok) candidatesPassed++;
}

console.log(`\n=== SUMMARY ===`);
console.log(`Constants: ${passed.length}/${passed.length + failed.length} passed`);
console.log(`Candidate selection: ${candidatesPassed}/${tests.length} passed`);
if (failed.length) {
  console.log("FAILED:");
  for (const f of failed) console.log(`  ${f.name}: got ${f.actual}, expected ${f.expected}`);
}
console.log(passed.length === passed.length + failed.length && candidatesPassed === tests.length
  ? "\n✓ ALL JS REFERENCE VALUES VERIFIED"
  : "\n✗ SOME CHECKS FAILED");
