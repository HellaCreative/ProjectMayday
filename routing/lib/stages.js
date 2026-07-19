/**
 * Multi-stage route trip model — pure, framework-free logic shared by the
 * browser planner (app/index.html) and Node tests.
 *
 * Nothing in here touches the DOM, MapLibre, IndexedDB, or the network. The
 * browser wires this to real markers / /api/route; tests import it directly.
 *
 * Contracts preserved from the single-stage app:
 *   - Each routed stage is exactly A -> B (two locations).
 *   - No free-space / straight-line connectors are ever invented. Gaps between
 *     stages are reported as transfer warnings, never joined.
 *   - Trip aggregate percentages are weighted by summed distance, never the
 *     mean of per-stage percentages.
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.RouteStages = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const SAVED_ROUTE_SCHEMA_VERSION = 1;
  const SURFACE_KEYS = ["paved", "gravel", "access", "track", "single", "unknown"];
  const ACCESS_KEYS = ["motorized_verified", "motorized_permissive", "motorized_unknown"];
  const STAGE_STATUS = {
    DRAFT: "draft", // missing A and/or B — never routed
    READY: "ready", // both points set, awaiting/queued routing
    LOADING: "loading", // request in flight
    COMPLETE: "complete", // routed successfully
    FAILED: "failed" // routing attempted and failed
  };
  const COORD_EPSILON = 1e-7; // ~1 cm — same point vs a real gap

  let idCounter = 0;
  function newId(prefix) {
    idCounter += 1;
    const rand = Math.random().toString(36).slice(2, 8);
    return (prefix || "id") + "-" + Date.now().toString(36) + "-" + idCounter.toString(36) + rand;
  }

  function nowIso() {
    return new Date().toISOString();
  }

  function normalizePoint(point) {
    if (!point) return null;
    const lng = Number(point.lng != null ? point.lng : point.lon);
    const lat = Number(point.lat);
    if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
    const out = { lng, lat };
    if (point.label != null) out.label = String(point.label);
    return out;
  }

  function samePoint(a, b) {
    const pa = normalizePoint(a);
    const pb = normalizePoint(b);
    if (!pa || !pb) return false;
    return Math.abs(pa.lng - pb.lng) < COORD_EPSILON && Math.abs(pa.lat - pb.lat) < COORD_EPSILON;
  }

  function normalizeAccessPolicy(input) {
    const policy = input || {};
    return {
      motorizedPermissive: policy.motorizedPermissive !== false,
      motorizedUnknown: !!policy.motorizedUnknown
    };
  }

  function createStage(overrides) {
    const stage = {
      id: newId("stage"),
      name: null,
      profile: "balanced",
      accessPolicy: normalizeAccessPolicy(overrides && overrides.accessPolicy),
      start: null,
      end: null,
      route: null,
      status: STAGE_STATUS.DRAFT,
      error: null,
      requestToken: 0,
      updatedAt: nowIso()
    };
    if (overrides) {
      if (overrides.id) stage.id = overrides.id;
      if (overrides.name != null) stage.name = overrides.name;
      if (overrides.profile) stage.profile = String(overrides.profile);
      if (overrides.start) stage.start = normalizePoint(overrides.start);
      if (overrides.end) stage.end = normalizePoint(overrides.end);
      if (overrides.route) stage.route = overrides.route;
      if (overrides.error != null) stage.error = overrides.error;
      if (overrides.updatedAt) stage.updatedAt = overrides.updatedAt;
    }
    stage.status = computeStageStatus(stage);
    return stage;
  }

  function createTrip(overrides) {
    const trip = {
      id: newId("trip"),
      name: "",
      stages: [],
      profile: "balanced",
      accessPolicy: normalizeAccessPolicy(overrides && overrides.accessPolicy),
      createdAt: nowIso(),
      updatedAt: nowIso()
    };
    if (overrides) {
      if (overrides.id) trip.id = overrides.id;
      if (overrides.name != null) trip.name = overrides.name;
      if (overrides.profile) trip.profile = overrides.profile;
      if (overrides.createdAt) trip.createdAt = overrides.createdAt;
      if (overrides.updatedAt) trip.updatedAt = overrides.updatedAt;
      if (Array.isArray(overrides.stages)) {
        trip.stages = overrides.stages.map((s) => {
          const stage = createStage(s);
          // Older saved routes only had a trip-level policy. Rehydrate that
          // policy onto each stage without losing the new per-stage contract.
          if (!s || s.accessPolicy == null) stage.accessPolicy = normalizeAccessPolicy(trip.accessPolicy);
          return stage;
        });
      }
    }
    if (!trip.stages.length) trip.stages.push(createStage({ accessPolicy: trip.accessPolicy }));
    return trip;
  }

  function stageHasBothPoints(stage) {
    return !!(stage && normalizePoint(stage.start) && normalizePoint(stage.end));
  }

  /**
   * Status is derived from points + route + explicit loading/error flags.
   * Never routed when a point is missing; a route object marks completion.
   */
  function computeStageStatus(stage) {
    if (!stage) return STAGE_STATUS.DRAFT;
    if (!stageHasBothPoints(stage)) return STAGE_STATUS.DRAFT;
    if (stage._loading) return STAGE_STATUS.LOADING;
    if (stage.error) return STAGE_STATUS.FAILED;
    if (stage.route && routeIsComplete(stage.route)) return STAGE_STATUS.COMPLETE;
    return STAGE_STATUS.READY;
  }

  function routeIsComplete(route) {
    if (!route) return false;
    if (route.status && route.status !== "complete") return false;
    const geom = route.geometry || route.coordinates;
    return Array.isArray(geom) && geom.length >= 2;
  }

  /**
   * Pure stage transition reducer. Returns a NEW stage object; callers replace
   * the old one. Events model the async routing lifecycle so tests can assert
   * transitions without a network.
   */
  function transitionStage(stage, event, payload) {
    const base = Object.assign({}, stage);
    payload = payload || {};
    switch (event) {
      case "set-start":
        base.start = normalizePoint(payload.point);
        base.route = null;
        base.error = null;
        base._loading = false;
        break;
      case "set-end":
        base.end = normalizePoint(payload.point);
        base.route = null;
        base.error = null;
        base._loading = false;
        break;
      case "set-points":
        if ("start" in payload) base.start = normalizePoint(payload.start);
        if ("end" in payload) base.end = normalizePoint(payload.end);
        base.route = null;
        base.error = null;
        base._loading = false;
        break;
      case "invalidate":
        base.route = null;
        base.error = null;
        base._loading = false;
        break;
      case "route-start":
        base._loading = true;
        base.error = null;
        if (payload.requestToken != null) base.requestToken = payload.requestToken;
        break;
      case "route-success":
        base._loading = false;
        base.error = null;
        base.route = payload.route || base.route;
        break;
      case "route-failed":
        base._loading = false;
        base.route = null;
        base.error = payload.error || "route_failed";
        break;
      default:
        break;
    }
    base.status = computeStageStatus(base);
    base.updatedAt = nowIso();
    return base;
  }

  /** Default start for a newly appended stage = previous stage's end (editable). */
  function defaultNextStart(trip) {
    if (!trip || !trip.stages || !trip.stages.length) return null;
    const last = trip.stages[trip.stages.length - 1];
    return normalizePoint(last.end) || null;
  }

  function addStage(trip, overrides) {
    const linkedStart = defaultNextStart(trip);
    const stage = createStage(Object.assign(
      { start: linkedStart, accessPolicy: normalizeAccessPolicy(trip && trip.accessPolicy) },
      overrides || {}
    ));
    trip.stages.push(stage);
    trip.updatedAt = nowIso();
    return stage;
  }

  function removeStage(trip, stageId) {
    if (!trip || trip.stages.length <= 1) return false; // cannot delete last remaining
    const idx = trip.stages.findIndex((s) => s.id === stageId);
    if (idx === -1) return false;
    trip.stages.splice(idx, 1);
    trip.updatedAt = nowIso();
    return true;
  }

  function moveStage(trip, fromIndex, toIndex) {
    if (!trip) return false;
    const n = trip.stages.length;
    if (fromIndex < 0 || fromIndex >= n || toIndex < 0 || toIndex >= n || fromIndex === toIndex) {
      return false;
    }
    const [moved] = trip.stages.splice(fromIndex, 1);
    trip.stages.splice(toIndex, 0, moved); // preserves data + results on the stage object
    trip.updatedAt = nowIso();
    return true;
  }

  function findStageIndex(trip, stageId) {
    return trip.stages.findIndex((s) => s.id === stageId);
  }

  // ---- Route breakdown + aggregation -------------------------------------

  function emptySurface() {
    const out = {};
    for (const k of SURFACE_KEYS) out[k] = 0;
    return out;
  }
  function emptyAccess() {
    const out = {};
    for (const k of ACCESS_KEYS) out[k] = 0;
    return out;
  }

  /**
   * Meters-per-category breakdown for a single stage route. Prefers segment
   * distances (most accurate); falls back to stats percentages * distance.
   * Everything downstream sums METERS then divides — never averages percents.
   */
  function routeBreakdown(route) {
    const distanceMeters = Number(route && (route.distanceMeters != null ? route.distanceMeters : 0)) || 0;
    const movingSeconds = Number(
      route && (route.estimatedMovingSeconds != null ? route.estimatedMovingSeconds : route.movingSeconds)
    ) || 0;
    const elapsedSeconds = Number(
      route && (route.estimatedElapsedSeconds != null ? route.estimatedElapsedSeconds : movingSeconds * 1.15)
    ) || 0;
    const surface = emptySurface();
    const access = emptyAccess();

    const segments = route && Array.isArray(route.segments) ? route.segments : null;
    if (segments && segments.length) {
      for (const seg of segments) {
        const m = Number(seg.distanceMeters != null ? seg.distanceMeters : (seg.distanceKm || 0) * 1000) || 0;
        const s = seg.surfaceClass || seg.trackClass || "unknown";
        const a = seg.accessClass || "motorized_unknown";
        if (surface[s] == null) surface[s] = 0;
        surface[s] += m;
        if (access[a] == null) access[a] = 0;
        access[a] += m;
      }
    } else if (route && route.stats && distanceMeters > 0) {
      const st = route.stats;
      surface.paved += (Number(st.pavedPercent) || 0) / 100 * distanceMeters;
      surface.gravel += (Number(st.gravelPercent) || 0) / 100 * distanceMeters;
      surface.access += (Number(st.accessPercent) || 0) / 100 * distanceMeters;
      surface.track += (Number(st.trackPercent) || 0) / 100 * distanceMeters;
      surface.unknown += (Number(st.unknownSurfacePercent) || 0) / 100 * distanceMeters;
      access.motorized_verified += (Number(st.verifiedAccessPercent) || 0) / 100 * distanceMeters;
      access.motorized_permissive += (Number(st.permissiveAccessPercent) || 0) / 100 * distanceMeters;
      access.motorized_unknown += (Number(st.unknownAccessPercent) || 0) / 100 * distanceMeters;
    }

    const dirtMeters = (surface.gravel || 0) + (surface.access || 0) + (surface.track || 0) + (surface.single || 0);
    return { distanceMeters, movingSeconds, elapsedSeconds, surface, access, dirtMeters };
  }

  function weightedPercent(part, total) {
    if (!(total > 0)) return 0;
    return Math.round((part / total) * 100);
  }

  /** Warnings deduped by code (first occurrence wins). */
  function dedupeWarnings(warnings) {
    const seen = new Set();
    const out = [];
    for (const w of warnings || []) {
      if (!w) continue;
      const code = w.code || w.message || "";
      if (seen.has(code)) continue;
      seen.add(code);
      out.push(w);
    }
    return out;
  }

  /**
   * Stages that MUST route for the trip to be complete: those a rider actually
   * set (both points present). A pure-draft stage keeps the trip incomplete.
   */
  function requiredStages(trip) {
    return (trip.stages || []).filter((s) => stageHasBothPoints(s));
  }

  function tripComplete(trip) {
    if (!trip || !trip.stages || !trip.stages.length) return false;
    // Every stage must be complete — draft/ready/loading/failed all block.
    return trip.stages.every((s) => computeStageStatus(s) === STAGE_STATUS.COMPLETE);
  }

  /** Consecutive complete stages whose end != next start = a transfer gap. */
  function detectGaps(trip) {
    const gaps = [];
    const stages = trip.stages || [];
    for (let i = 0; i < stages.length - 1; i += 1) {
      const a = stages[i];
      const b = stages[i + 1];
      if (computeStageStatus(a) !== STAGE_STATUS.COMPLETE) continue;
      if (computeStageStatus(b) !== STAGE_STATUS.COMPLETE) continue;
      if (!samePoint(a.end, b.start)) {
        gaps.push({ fromIndex: i, toIndex: i + 1, fromStageId: a.id, toStageId: b.id });
      }
    }
    return gaps;
  }

  /**
   * Aggregate the whole trip. Percentages are computed from SUMMED meters, not
   * averaged. No connector distance is added across gaps.
   */
  function aggregateTrip(trip) {
    const surface = emptySurface();
    const access = emptyAccess();
    let totalDistance = 0;
    let totalMoving = 0;
    let totalElapsed = 0;
    let dirtMeters = 0;
    let unknownAccessMeters = 0;
    let completeCount = 0;
    const warnings = [];

    for (const stage of trip.stages || []) {
      if (computeStageStatus(stage) !== STAGE_STATUS.COMPLETE || !stage.route) continue;
      completeCount += 1;
      const b = routeBreakdown(stage.route);
      totalDistance += b.distanceMeters;
      totalMoving += b.movingSeconds;
      totalElapsed += b.elapsedSeconds;
      dirtMeters += b.dirtMeters;
      for (const k of Object.keys(b.surface)) surface[k] = (surface[k] || 0) + b.surface[k];
      for (const k of Object.keys(b.access)) access[k] = (access[k] || 0) + b.access[k];
      unknownAccessMeters += b.access.motorized_unknown || 0;
      for (const w of stage.route.warnings || []) warnings.push(w);
    }

    const gaps = detectGaps(trip);
    for (const gap of gaps) {
      warnings.push({
        code: "stage_gap",
        message: "Stage " + (gap.fromIndex + 1) + " ends where Stage " + (gap.toIndex + 1) +
          " does not begin. No connector was drawn — plan a transfer between them."
      });
    }

    const required = requiredStages(trip);
    const complete = tripComplete(trip);

    return {
      complete,
      completedStageCount: completeCount,
      requiredStageCount: required.length,
      stageCount: (trip.stages || []).length,
      totalDistanceMeters: Math.round(totalDistance),
      totalMovingSeconds: Math.round(totalMoving),
      totalElapsedSeconds: Math.round(totalElapsed),
      dirtMeters: Math.round(dirtMeters),
      unknownAccessMeters: Math.round(unknownAccessMeters),
      surfaceMeters: surface,
      accessMeters: access,
      hasGaps: gaps.length > 0,
      gaps,
      percentages: {
        dirtPercent: weightedPercent(dirtMeters, totalDistance),
        pavedPercent: weightedPercent(surface.paved, totalDistance),
        gravelPercent: weightedPercent(surface.gravel, totalDistance),
        accessPercent: weightedPercent(surface.access, totalDistance),
        trackPercent: weightedPercent(surface.track, totalDistance),
        unknownSurfacePercent: weightedPercent(surface.unknown, totalDistance),
        unknownAccessPercent: weightedPercent(access.motorized_unknown, totalDistance),
        permissiveAccessPercent: weightedPercent(access.motorized_permissive, totalDistance),
        verifiedAccessPercent: weightedPercent(access.motorized_verified, totalDistance)
      },
      warnings: dedupeWarnings(warnings)
    };
  }

  // ---- Stale-request protection ------------------------------------------

  /**
   * Per-stage monotonically increasing request tokens. A response is only
   * applied when its token is still the latest issued for that stage, so a slow
   * response can never overwrite a newer edit.
   */
  function createRequestTracker() {
    const tokens = new Map();
    return {
      issue(stageId) {
        const next = (tokens.get(stageId) || 0) + 1;
        tokens.set(stageId, next);
        return next;
      },
      isCurrent(stageId, token) {
        return tokens.get(stageId) === token;
      },
      current(stageId) {
        return tokens.get(stageId) || 0;
      },
      cancel(stageId) {
        // Bump so any in-flight response for the stage becomes stale.
        return this.issue(stageId);
      }
    };
  }

  // ---- Serialize / deserialize saved routes ------------------------------

  function cleanRoute(route) {
    if (!route) return null;
    const geometry = route.geometry || route.coordinates || [];
    if (!Array.isArray(geometry) || geometry.length < 2) return null;
    const segments = (route.segments || []).map((seg) => ({
      trackClass: seg.trackClass || seg.surfaceClass || "unknown",
      surfaceClass: seg.surfaceClass || seg.trackClass || "unknown",
      accessClass: seg.accessClass || "motorized_unknown",
      edgeId: seg.edgeId != null ? seg.edgeId : null,
      distanceMeters: Math.round(Number(seg.distanceMeters != null ? seg.distanceMeters : (seg.distanceKm || 0) * 1000) || 0),
      geometry: seg.geometry || seg.coords || []
    }));
    return {
      geometry,
      segments,
      distanceMeters: Math.round(Number(route.distanceMeters) || 0),
      estimatedMovingSeconds: Math.round(Number(route.estimatedMovingSeconds || route.movingSeconds) || 0),
      estimatedElapsedSeconds: Math.round(Number(route.estimatedElapsedSeconds) || 0),
      stats: route.stats || null,
      warnings: dedupeWarnings(route.warnings || [])
    };
  }

  /**
   * Produce a persistable saved-route record: geometry + points + per-stage
   * results + aggregates. Strips loading/error/debug/token noise.
   */
  function serializeSavedRoute(trip, extra) {
    extra = extra || {};
    const aggregate = extra.aggregate || aggregateTrip(trip);
    const stages = (trip.stages || []).map((stage, index) => ({
      id: stage.id,
      name: stage.name || null,
      profile: stage.profile || trip.profile || "balanced",
      accessPolicy: normalizeAccessPolicy(stage.accessPolicy || trip.accessPolicy),
      index,
      start: normalizePoint(stage.start),
      end: normalizePoint(stage.end),
      status: computeStageStatus(stage),
      route: cleanRoute(stage.route)
    }));
    return {
      schemaVersion: SAVED_ROUTE_SCHEMA_VERSION,
      id: trip.id || newId("route"),
      name: (extra.name != null ? extra.name : trip.name) || "Untitled route",
      profile: trip.profile || "balanced",
      accessPolicy: normalizeAccessPolicy(trip.accessPolicy),
      stages,
      stageCount: stages.length,
      aggregate: {
        complete: aggregate.complete,
        totalDistanceMeters: aggregate.totalDistanceMeters,
        totalMovingSeconds: aggregate.totalMovingSeconds,
        totalElapsedSeconds: aggregate.totalElapsedSeconds,
        percentages: aggregate.percentages,
        surfaceMeters: aggregate.surfaceMeters,
        accessMeters: aggregate.accessMeters,
        hasGaps: aggregate.hasGaps,
        warnings: aggregate.warnings
      },
      isDraft: !aggregate.complete,
      device: extra.device || "this-device",
      createdAt: trip.createdAt || nowIso(),
      updatedAt: nowIso()
    };
  }

  /** Rehydrate a saved record into an editable trip. Throws on bad version. */
  function deserializeSavedRoute(record) {
    if (!record || typeof record !== "object") throw new Error("invalid_saved_route");
    if (record.schemaVersion !== SAVED_ROUTE_SCHEMA_VERSION) {
      throw new Error("unsupported_saved_route_version:" + record.schemaVersion);
    }
    const trip = createTrip({
      id: record.id,
      name: record.name,
      profile: record.profile,
      accessPolicy: record.accessPolicy,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      stages: (record.stages || []).map((s) => ({
        id: s.id,
        name: s.name,
        profile: s.profile || record.profile || "balanced",
        accessPolicy: s.accessPolicy != null ? s.accessPolicy : record.accessPolicy,
        start: s.start,
        end: s.end,
        route: s.route ? Object.assign({ status: "complete" }, s.route) : null
      }))
    });
    return trip;
  }

  function duplicateSavedRoute(record, options) {
    options = options || {};
    const copy = JSON.parse(JSON.stringify(record));
    copy.id = newId("route");
    copy.name = options.name || ((record.name || "Route") + " Copy");
    copy.createdAt = nowIso();
    copy.updatedAt = nowIso();
    return copy;
  }

  // ---- Formatting helpers (shared UI conveniences) -----------------------

  function metersToKmLabel(meters) {
    const km = (Number(meters) || 0) / 1000;
    if (km < 1) return Math.round(km * 1000) + " m";
    return km.toFixed(km >= 10 ? 1 : 2) + " km";
  }

  function secondsToLabel(seconds) {
    const s = Number(seconds) || 0;
    if (s <= 0) return "—";
    const mins = Math.round(s / 60);
    if (mins < 60) return mins + " min";
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return h + " h" + (m ? " " + m + " min" : "");
  }

  return {
    SAVED_ROUTE_SCHEMA_VERSION,
    STAGE_STATUS,
    SURFACE_KEYS,
    ACCESS_KEYS,
    newId,
    normalizePoint,
    samePoint,
    normalizeAccessPolicy,
    createStage,
    createTrip,
    stageHasBothPoints,
    computeStageStatus,
    routeIsComplete,
    transitionStage,
    defaultNextStart,
    addStage,
    removeStage,
    moveStage,
    findStageIndex,
    routeBreakdown,
    weightedPercent,
    dedupeWarnings,
    requiredStages,
    tripComplete,
    detectGaps,
    aggregateTrip,
    createRequestTracker,
    cleanRoute,
    serializeSavedRoute,
    deserializeSavedRoute,
    duplicateSavedRoute,
    metersToKmLabel,
    secondsToLabel
  };
});
