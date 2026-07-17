/**
 * Pure helpers for group live-sharing (map labels, presence merge, alerts, publish cadence).
 * Loaded as a classic script; also require()-able from Node tests.
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.DirtGroupSharing = factory();
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const STATUS_LABELS = {
    available: "Available",
    breakdown: "Breakdown",
    injured: "Injured",
    stuck: "Stuck"
  };

  const DISTRESS_STATUSES = ["breakdown", "injured", "stuck"];
  const PUBLISH_MS_DEFAULT = 15000;
  const PUBLISH_MS_DISTRESS = 5000;

  function statusLabel(status) {
    const key = String(status || "available").toLowerCase();
    return STATUS_LABELS[key] || STATUS_LABELS.available;
  }

  function isDistressStatus(status) {
    return DISTRESS_STATUSES.includes(String(status || "").toLowerCase());
  }

  function publishIntervalMs(status) {
    return isDistressStatus(status) ? PUBLISH_MS_DISTRESS : PUBLISH_MS_DEFAULT;
  }

  function formatRiderMapLabel(displayName, status) {
    const name = String(displayName || "Rider").trim() || "Rider";
    return name + " - " + statusLabel(status);
  }

  function normalizeHeading(heading) {
    const n = Number(heading);
    if (!Number.isFinite(n)) return null;
    const wrapped = ((n % 360) + 360) % 360;
    return wrapped;
  }

  function normalizeCoordinate(value) {
    if (value == null || (typeof value === "string" && value.trim() === "")) return null;
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }

  /**
   * Merge a presence snapshot into last-known riders.
   * Never removes riders who dropped off presence (crash / offline) — only upserts.
   */
  function mergePresenceKeepLastKnown(existingEntries, presenceState, selfUserId, meta) {
    const next = new Map(existingEntries instanceof Map ? existingEntries : []);
    const groupId = meta && meta.groupId != null ? meta.groupId : null;
    const groupName = meta && meta.groupName != null ? meta.groupName : null;
    for (const [userId, values] of Object.entries(presenceState || {})) {
      if (!userId || userId === selfUserId) continue;
      const entry = Array.isArray(values) ? values[values.length - 1] : values;
      if (!entry) continue;
      const prev = next.get(userId) || {};
      const lng = normalizeCoordinate(entry.lng) ?? normalizeCoordinate(prev.lng);
      const lat = normalizeCoordinate(entry.lat) ?? normalizeCoordinate(prev.lat);
      if (lng == null || lat == null) {
        if (prev.userId) next.delete(userId);
        continue;
      }
      next.set(userId, Object.assign({}, prev, entry, {
        userId,
        lng,
        lat,
        groupId: entry.groupId || groupId || prev.groupId || null,
        groupName: entry.groupName || groupName || prev.groupName || null,
        status: entry.status || prev.status || "available",
        displayName: entry.displayName || prev.displayName || "Rider",
        labelLine: formatRiderMapLabel(entry.displayName || prev.displayName || "Rider", entry.status || prev.status || "available"),
        heading: normalizeHeading(entry.heading != null ? entry.heading : prev.heading)
      }));
    }
    return next;
  }

  function applyLocationUpdate(existingEntries, payload, selfUserId) {
    const next = new Map(existingEntries instanceof Map ? existingEntries : []);
    if (!payload || !payload.userId || payload.userId === selfUserId) return next;
    const lng = normalizeCoordinate(payload.lng);
    const lat = normalizeCoordinate(payload.lat);
    if (lng == null || lat == null) return next;
    const prev = next.get(payload.userId) || {};
    const status = payload.status || prev.status || "available";
    const displayName = payload.displayName || prev.displayName || "Rider";
    next.set(payload.userId, Object.assign({}, prev, payload, {
      userId: payload.userId,
      lng,
      lat,
      status,
      displayName,
      labelLine: formatRiderMapLabel(displayName, status),
      heading: normalizeHeading(payload.heading != null ? payload.heading : prev.heading)
    }));
    return next;
  }

  /** Explicit stop-sharing from the rider who owns the pin — only they can remove it. */
  function applySharingOff(existingEntries, userId) {
    const next = new Map(existingEntries instanceof Map ? existingEntries : []);
    if (userId) next.delete(userId);
    return next;
  }

  function routeTargetFromFeature(feature) {
    if (!feature || !feature.geometry || feature.geometry.type !== "Point") return null;
    const coords = feature.geometry.coordinates;
    if (!Array.isArray(coords) || coords.length < 2) return null;
    const properties = feature.properties || {};
    const sourceLng = normalizeCoordinate(properties.routeLng);
    const sourceLat = normalizeCoordinate(properties.routeLat);
    const lng = sourceLng == null ? Number(coords[0]) : sourceLng;
    const lat = sourceLat == null ? Number(coords[1]) : sourceLat;
    if (!Number.isFinite(lng) || !Number.isFinite(lat)) return null;
    const p = properties;
    return {
      lng,
      lat,
      userId: p.userId || null,
      displayName: p.displayName || "Rider",
      status: p.status || "available",
      groupId: p.groupId || null,
      groupName: p.groupName || null,
      lastSeenAt: p.lastSeenAt || null
    };
  }

  function buildGroupRiderPopupModel(target) {
    if (!target) return null;
    return {
      displayName: target.displayName || "Rider",
      groupName: target.groupName || "Group",
      status: target.status || "available",
      statusText: statusLabel(target.status),
      lastSeenAt: target.lastSeenAt || null,
      ctaLabel: "Route to member"
    };
  }

  function createAlertRecord(payload) {
    if (!payload || !payload.userId || !isDistressStatus(payload.status)) return null;
    if (!Number.isFinite(payload.lat) || !Number.isFinite(payload.lng)) return null;
    return {
      id: payload.alertId || (payload.userId + ":" + payload.status + ":" + (payload.createdAt || Date.now())),
      userId: payload.userId,
      displayName: payload.displayName || "Rider",
      status: String(payload.status).toLowerCase(),
      statusText: statusLabel(payload.status),
      groupId: payload.groupId || null,
      groupName: payload.groupName || "Group",
      lng: payload.lng,
      lat: payload.lat,
      createdAt: payload.createdAt || new Date().toISOString()
    };
  }

  /** Upsert alert by userId+status so repeat publishes refresh location without stacking duplicates. */
  function upsertAlert(alerts, record) {
    const list = Array.isArray(alerts) ? alerts.slice() : [];
    if (!record) return list;
    const idx = list.findIndex((row) => row.userId === record.userId && row.status === record.status);
    if (idx >= 0) list[idx] = Object.assign({}, list[idx], record);
    else list.push(record);
    return list;
  }

  function dismissAlert(alerts, alertId) {
    return (Array.isArray(alerts) ? alerts : []).filter((row) => row.id !== alertId);
  }

  function riderFeatureProperties(entry) {
    const status = entry.status || "available";
    const displayName = entry.displayName || "Rider";
    const heading = normalizeHeading(entry.heading);
    return {
      userId: entry.userId,
      displayName,
      status,
      statusLabel: statusLabel(status),
      labelLine: entry.labelLine || formatRiderMapLabel(displayName, status),
      groupId: entry.groupId || null,
      groupName: entry.groupName || null,
      lastSeenAt: entry.lastSeenAt || null,
      heading: heading == null ? -1 : heading
    };
  }

  return {
    STATUS_LABELS,
    DISTRESS_STATUSES,
    PUBLISH_MS_DEFAULT,
    PUBLISH_MS_DISTRESS,
    statusLabel,
    isDistressStatus,
    publishIntervalMs,
    formatRiderMapLabel,
    normalizeHeading,
    mergePresenceKeepLastKnown,
    applyLocationUpdate,
    applySharingOff,
    routeTargetFromFeature,
    buildGroupRiderPopupModel,
    createAlertRecord,
    upsertAlert,
    dismissAlert,
    riderFeatureProperties
  };
});
