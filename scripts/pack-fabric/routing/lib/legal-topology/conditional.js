"use strict";

/**
 * Normalize a supported subset of OSM conditional / seasonal tags.
 * Unevaluable relevant conditions fail closed.
 */

const OPEN_STATUS = new Set(["yes", "designated", "permissive", "official"]);
const CLOSED_STATUS = new Set(["no", "private", "closed"]);

const MONTHS = {
  jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5,
  jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11
};

function tag(tags, key) {
  if (!tags || tags[key] == null) return "";
  return String(tags[key]).trim();
}

function parseStatus(token) {
  const v = String(token || "").toLowerCase().trim();
  if (OPEN_STATUS.has(v)) return "open";
  if (CLOSED_STATUS.has(v)) return "closed";
  if (v === "destination") return "destination";
  return null;
}

/**
 * Very small opening_hours subset: `no @ (Jan-Mar)`, `yes @ winter`,
 * `no @ (Mo-Fr 07:00-09:00)`.
 */
function parseConditionalExpression(raw) {
  const text = String(raw || "").trim();
  if (!text) return { evaluable: false, reason: "empty" };
  const at = text.split("@");
  if (at.length < 2) return { evaluable: false, reason: "missing_at" };
  const status = parseStatus(at[0]);
  if (!status) return { evaluable: false, reason: "unsupported_status" };
  const spec = at.slice(1).join("@").trim().replace(/^\(|\)$/g, "").toLowerCase();
  if (!spec) return { evaluable: false, reason: "empty_spec" };
  if (/\bph\b/.test(spec) || spec.includes("sunrise") || spec.includes("sunset")) {
    return { evaluable: false, reason: "unsupported_spec" };
  }
  return { evaluable: true, status, spec };
}

function monthInRange(month, spec) {
  const m = spec.match(/^([a-z]{3})(?:-([a-z]{3}))?$/);
  if (!m) return null;
  const a = MONTHS[m[1]];
  const b = m[2] ? MONTHS[m[2]] : a;
  if (a == null || b == null) return null;
  if (a <= b) return month >= a && month <= b;
  return month >= a || month <= b;
}

function isWinterMonth(month) {
  return month === 11 || month === 0 || month === 1;
}

/**
 * @param {object} rule
 * @param {Date} at
 * @returns {"open"|"closed"|"fail_closed"}
 */
function evaluateNormalizedRule(rule, at = new Date()) {
  if (!rule || rule.evaluable === false) return "fail_closed";
  const month = at.getUTCMonth();
  const spec = rule.spec || "";
  if (spec === "winter") {
    const inWinter = isWinterMonth(month);
    if (rule.status === "closed") return inWinter ? "closed" : "open";
    if (rule.status === "open") return inWinter ? "open" : "closed";
  }
  if (spec === "summer") {
    const inSummer = month >= 5 && month <= 7;
    if (rule.status === "closed") return inSummer ? "closed" : "open";
    if (rule.status === "open") return inSummer ? "open" : "closed";
  }
  const monthHit = monthInRange(month, spec);
  if (monthHit != null) {
    if (rule.status === "closed") return monthHit ? "closed" : "open";
    if (rule.status === "open") return monthHit ? "open" : "closed";
  }
  const hm = spec.match(/^([a-z]{2}(?:-[a-z]{2})?)\s+(\d{2}:\d{2})-(\d{2}:\d{2})$/);
  if (hm) {
    const days = hm[1];
    const day = at.getUTCDay(); // 0 Sun
    const map = { su: 0, mo: 1, tu: 2, we: 3, th: 4, fr: 5, sa: 6 };
    let dayOk = true;
    if (days.includes("-")) {
      const [a, b] = days.split("-");
      const da = map[a];
      const db = map[b];
      if (da == null || db == null) return "fail_closed";
      dayOk = da <= db ? day >= da && day <= db : day >= da || day <= db;
    } else {
      const da = map[days];
      if (da == null) return "fail_closed";
      dayOk = day === da;
    }
    const [sh, sm] = hm[2].split(":").map(Number);
    const [eh, em] = hm[3].split(":").map(Number);
    const minutes = at.getUTCHours() * 60 + at.getUTCMinutes();
    const start = sh * 60 + sm;
    const end = eh * 60 + em;
    const inWin = start <= end ? minutes >= start && minutes < end : minutes >= start || minutes < end;
    const hit = dayOk && inWin;
    if (rule.status === "closed") return hit ? "closed" : "open";
    if (rule.status === "open") return hit ? "open" : "closed";
  }
  return "fail_closed";
}

const CONDITIONAL_KEYS = [
  "access:conditional",
  "vehicle:conditional",
  "motor_vehicle:conditional",
  "motorcycle:conditional",
  "access:forward:conditional",
  "access:backward:conditional",
  "motorcycle:forward:conditional",
  "motorcycle:backward:conditional",
  "oneway:conditional",
  "restriction:conditional",
  "restriction:motorcycle:conditional"
];

function seasonalFlags(tags = {}) {
  const seasonal = ["yes", "winter", "summer"].includes(String(tags.seasonal || "").toLowerCase());
  const winterRoad = ["yes", "true", "1"].includes(String(tags.winter_road || "").toLowerCase());
  const iceRoad = ["yes", "true", "1"].includes(String(tags.ice_road || "").toLowerCase());
  return { seasonal, winterRoad, iceRoad, any: seasonal || winterRoad || iceRoad };
}

function collectConditionalRules(tags = {}, timezone = "America/Halifax") {
  const rules = [];
  const rejected = [];
  for (const key of CONDITIONAL_KEYS) {
    const raw = tag(tags, key);
    if (!raw) continue;
    const parsed = parseConditionalExpression(raw);
    if (!parsed.evaluable) {
      rejected.push({ tag: key, raw, reason: parsed.reason });
      rules.push({ tag: key, raw, evaluable: false, timezone, reason: parsed.reason });
      continue;
    }
    rules.push({
      tag: key,
      raw,
      evaluable: true,
      status: parsed.status,
      spec: parsed.spec,
      timezone
    });
  }
  const flags = seasonalFlags(tags);
  if (flags.any) {
    rules.push({
      tag: flags.iceRoad ? "ice_road" : flags.winterRoad ? "winter_road" : "seasonal",
      raw: flags.iceRoad ? tags.ice_road : flags.winterRoad ? tags.winter_road : tags.seasonal,
      // A generic seasonal/winter/ice flag does not say which dates are open,
      // and those dates vary by operator and weather. Keep the evidence but
      // fail closed until a complete conditional expression is available.
      evaluable: false,
      status: null,
      spec: null,
      timezone,
      seasonal: true,
      reason: "season_window_unspecified"
    });
  }
  return { rules, rejected };
}

function accessCodeFromRules(baseCode, rules) {
  if (!rules.length) return baseCode;
  // V4 packs must behave identically offline in JS, Swift and Kotlin. Until
  // the pack carries a shared timezone-aware runtime evaluator, any relevant
  // conditional access makes this direction fail closed. We never freeze a
  // road open merely because it happened to be open at pack-build time.
  return rules.some((rule) =>
    !String(rule.tag || "").startsWith("oneway") &&
    !String(rule.tag || "").startsWith("restriction")
  ) ? 5 : baseCode;
}

module.exports = {
  CONDITIONAL_KEYS,
  parseConditionalExpression,
  evaluateNormalizedRule,
  collectConditionalRules,
  seasonalFlags,
  accessCodeFromRules
};
