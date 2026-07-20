"use strict";

/**
 * Shared adapter contract for province / national source packers.
 *
 * Every adapter must return a report object with:
 *   adapter, province, sourceName, sourceUrl, license,
 *   features (canonical edges), excluded (count by reason),
 *   classification (surface/access/structure counts),
 *   topology (optional), generatedAt, notes
 */

function emptyCounts() {
  return {
    surface: {},
    access: {},
    structure: {},
    roadTrack: {},
    excluded: {}
  };
}

function bump(map, key, n = 1) {
  const k = key == null ? "null" : String(key);
  map[k] = (map[k] || 0) + n;
}

function makeReport(partial) {
  const report = {
    adapter: partial.adapter || "unknown",
    province: partial.province || "",
    sourceName: partial.sourceName || "",
    sourceUrl: partial.sourceUrl || "",
    downloadUrl: partial.downloadUrl || partial.sourceUrl || "",
    license: partial.license || "",
    sourceDatasetVersion: partial.sourceDatasetVersion || null,
    dateRetrieved: partial.dateRetrieved || new Date().toISOString(),
    status: partial.status || "ok",
    notes: partial.notes || [],
    knownLimitations: partial.knownLimitations || [],
    featureCount: Array.isArray(partial.features) ? partial.features.length : 0,
    excludedCount: 0,
    excludedByReason: partial.excludedByReason || {},
    classification: partial.classification || emptyCounts(),
    topology: partial.topology || null,
    generatedAt: new Date().toISOString()
  };
  report.excludedCount = Object.values(report.excludedByReason).reduce((a, b) => a + b, 0);
  return report;
}

/**
 * Adapter interface documentation helper — not enforced at runtime.
 * Implementations: run(options) -> { features, report }
 */
const ADAPTER_CONTRACT = Object.freeze({
  requiredMethods: ["name", "province", "run"],
  requiredReportFields: [
    "adapter",
    "province",
    "sourceName",
    "sourceUrl",
    "license",
    "featureCount",
    "excludedByReason",
    "classification",
    "generatedAt"
  ]
});

module.exports = {
  emptyCounts,
  bump,
  makeReport,
  ADAPTER_CONTRACT
};
