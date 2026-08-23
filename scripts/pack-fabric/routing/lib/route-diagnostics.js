"use strict";

/**
 * Logging-only helpers. Do not change search, costs, corridors, or fuel selection.
 */

function sumPops(attempts) {
  if (!Array.isArray(attempts)) return 0;
  return attempts.reduce((sum, row) => sum + (Number(row && row.pops) || 0), 0);
}

function finiteCorridorAttempts(attempts) {
  return (attempts || []).filter((row) =>
    row != null && row.corridorMeters != null && Number.isFinite(Number(row.corridorMeters))
  );
}

function unboundedAttempts(attempts) {
  return (attempts || []).filter((row) =>
    !(row != null && row.corridorMeters != null && Number.isFinite(Number(row.corridorMeters)))
  );
}

/**
 * Classify "No route on the eligible graph" (and related) into one of:
 * pop_cap | time_cap | corridor_clip | snap_failure | disconnected
 */
function classifyRouteFailureReason(input = {}) {
  if (input.snapFailure) return "snap_failure";
  if (input.disconnectedComponents) return "disconnected";
  if (input.corridorClipLoad) return "corridor_clip";

  const outcome = String(input.searchOutcome || "");
  const attempts = Array.isArray(input.attempts) ? input.attempts : [];

  if (outcome === "popCap" || attempts.some((row) => row && row.outcome === "popCap")) {
    return "pop_cap";
  }
  if (outcome === "timeCap" || attempts.some((row) => row && row.outcome === "timeCap")) {
    return "time_cap";
  }

  const finite = finiteCorridorAttempts(attempts);
  const unbounded = unboundedAttempts(attempts);
  const finiteAllNoPath =
    finite.length > 0 && finite.every((row) => row.outcome === "noPath");
  const unboundedTried = unbounded.length > 0;
  const unboundedNoPath =
    unboundedTried && unbounded.every((row) => row.outcome === "noPath");

  // Hard corridors rejected every width and the search never proved an
  // unbounded (null-width) connection — treat as corridor clip, not fabric gap.
  if (finiteAllNoPath && !unboundedTried) return "corridor_clip";
  if (finiteAllNoPath && unboundedNoPath) return "disconnected";
  if (outcome === "noPath" || !outcome) return "disconnected";
  return "disconnected";
}

function effectiveProfileInfo(requestedProfile, flags = {}) {
  const requested = String(requestedProfile || "balanced").toLowerCase();
  const fallbacks = [];
  if (flags.urbanCoreFallbackUsed) fallbacks.push("urban_core_last_resort");
  if (flags.cleanUnpavedFallbackUsed) fallbacks.push("clean_unpaved_last_resort");
  if (flags.settlementFallbackUsed) fallbacks.push("settlement_relaxed");

  // Urban-core last resort is the Clean escape hatch; when Dirt/Balanced/Direct
  // only connect after that hatch, the ride is effectively a Clean connectivity
  // result under the requested objective label.
  let effective = requested;
  if (flags.urbanCoreFallbackUsed && requested !== "cleanest") {
    effective = "cleanest";
  } else if (flags.cleanUnpavedFallbackUsed && requested === "cleanest") {
    effective = "cleanest";
  }

  return {
    requestedProfile: requested,
    effectiveProfile: effective,
    profileFallbacks: fallbacks
  };
}

function corridorAttemptSummary(attempts) {
  return (attempts || []).map((row) => {
    const hasWidth = row != null && row.corridorMeters != null && Number.isFinite(Number(row.corridorMeters));
    return {
      corridorMeters: hasWidth ? Number(row.corridorMeters) : null,
      outcome: row && row.outcome ? String(row.outcome) : "unknown",
      pops: Number(row && row.pops) || 0,
      searchMs: Number.isFinite(Number(row && row.searchMs)) ? Number(row.searchMs) : null,
      succeeded: !!(row && row.outcome === "completed")
    };
  });
}

function buildRouteDiagnostics({
  requestedProfile,
  buildMs,
  searchMs,
  attempts,
  searchMeta,
  backtrackPct,
  urbanCoreFallbackUsed,
  cleanUnpavedFallbackUsed,
  settlementFallbackUsed,
  failureReason,
  searchOutcome,
  cleanMetroMultiplier
} = {}) {
  const meta = searchMeta || {};
  const attemptRows = Array.isArray(attempts)
    ? attempts
    : (Array.isArray(meta.corridorCandidates) ? meta.corridorCandidates : []);
  const profileInfo = effectiveProfileInfo(requestedProfile, {
    urbanCoreFallbackUsed: urbanCoreFallbackUsed || meta.urbanCoreFallbackUsed,
    cleanUnpavedFallbackUsed: cleanUnpavedFallbackUsed || meta.cleanUnpavedFallbackUsed,
    settlementFallbackUsed: settlementFallbackUsed || meta.settlementFallbackUsed
  });
  const corridorMeters = Number.isFinite(Number(meta.corridorMeters))
    ? Number(meta.corridorMeters)
    : null;
  const shape = meta.routeShape || {};
  const maxCrossTrack = Number.isFinite(Number(meta.maxCrossTrackMeters))
    ? Number(meta.maxCrossTrackMeters)
    : (Number.isFinite(Number(shape.p95CrossTrackMeters)) ? Number(shape.p95CrossTrackMeters) : null);
  const metroOverride = (() => {
    const raw = cleanMetroMultiplier != null ? cleanMetroMultiplier : meta.cleanMetroMultiplier;
    if (raw == null || raw === "") return null;
    const n = Number(raw);
    return Number.isFinite(n) ? n : null;
  })();

  return {
    buildMs: Number.isFinite(Number(buildMs)) ? Math.round(Number(buildMs)) : null,
    searchMs: Number.isFinite(Number(searchMs)) ? Math.round(Number(searchMs)) : null,
    searchAttempts: corridorAttemptSummary(attemptRows),
    pops: Number.isFinite(Number(meta.pops)) ? Number(meta.pops) : sumPops(attemptRows),
    corridorMeters,
    corridorWidened: meta.corridorWidened === true,
    corridorWidthsTried: attemptRows.map((row) =>
      (row != null && row.corridorMeters != null && Number.isFinite(Number(row.corridorMeters)))
        ? Number(row.corridorMeters)
        : null
    ),
    maxCrossTrackMeters: maxCrossTrack,
    backtrackPct: Number.isFinite(Number(backtrackPct))
      ? Number(backtrackPct)
      : (Number.isFinite(Number(shape.backwardPercent)) ? Number(shape.backwardPercent) : null),
    failureReason: failureReason || null,
    searchOutcome: searchOutcome || meta.pass2Outcome || null,
    cleanMetroMultiplier: metroOverride,
    ...profileInfo
  };
}

function classifyFuelFailureReason(planned = {}) {
  if (planned.error === "window_time_budget" || planned.timeBudgetExceeded) {
    return "timeout";
  }
  if (planned.error === "no_route_connected_fuel_chain") {
    return "gap_no_forward_station";
  }
  if (planned.error) return String(planned.error);
  return null;
}

function enrichFuelDiagnostics(diagnostics, extras = {}) {
  const base = diagnostics && typeof diagnostics === "object" ? { ...diagnostics } : {};
  if (Number.isFinite(Number(extras.stationsReachableWithinRange))) {
    base.stationsReachableWithinRange = Number(extras.stationsReachableWithinRange);
  }
  if (Number.isFinite(Number(extras.candidatesEvaluated))) {
    base.candidatesEvaluated = Number(extras.candidatesEvaluated);
  } else if (Array.isArray(extras.stationCandidates)) {
    base.candidatesEvaluated = extras.stationCandidates.length;
  } else if (Array.isArray(base.stationCandidates)) {
    base.candidatesEvaluated = base.stationCandidates.length;
  }
  if (extras.gapReason != null) base.gapReason = extras.gapReason;
  if (extras.failureReason != null) base.failureReason = extras.failureReason;
  return base;
}

module.exports = {
  buildRouteDiagnostics,
  classifyFuelFailureReason,
  classifyRouteFailureReason,
  effectiveProfileInfo,
  enrichFuelDiagnostics,
  sumPops
};
