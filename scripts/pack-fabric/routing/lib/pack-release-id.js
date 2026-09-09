"use strict";
// Candidate and promoted objects retain one immutable release identity.
function packReleaseId(source) {
  let pathname;
  try { pathname = new URL(String(source || ""), "https://packs.invalid").pathname; }
  catch { return null; }
  const match = pathname.match(/\/(?:candidates|releases)\/([a-z0-9][a-z0-9._-]{2,80})\/[^/]+\/[^/]+$/i);
  return match ? match[1] : null;
}
module.exports = { packReleaseId };
