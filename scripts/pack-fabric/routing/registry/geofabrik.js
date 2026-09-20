"use strict";

/**
 * Geofabrik extract identity per Dirt catalog region id.
 * The v3 pack stamp uses this map. Every live catalog id has a row.
 *
 * Subregions (on-s / on-n) share a parent Geofabrik extract via `sourceSlug`
 * while using their own `slug` for legal/work directories and clip polygons.
 * `legacy: true` keeps the parent id for source lookup without publishing it
 * as a phone pack once subregions replace it.
 */
const OSM_REGION = {
  ab: { slug: "alberta", country: "canada" },
  bc: { slug: "british-columbia", country: "canada" },
  mb: { slug: "manitoba", country: "canada" },
  nb: { slug: "new-brunswick", country: "canada" },
  nl: { slug: "newfoundland-and-labrador", country: "canada", legacy: true },
  "nl-island": {
    slug: "newfoundland-island",
    country: "canada",
    sourceSlug: "newfoundland-and-labrador"
  },
  "nl-lab": {
    slug: "labrador",
    country: "canada",
    sourceSlug: "newfoundland-and-labrador"
  },
  ns: { slug: "nova-scotia", country: "canada" },
  nt: { slug: "northwest-territories", country: "canada" },
  nu: { slug: "nunavut", country: "canada" },
  on: { slug: "ontario", country: "canada", legacy: true },
  "on-s": { slug: "ontario-south", country: "canada", sourceSlug: "ontario" },
  "on-n": { slug: "ontario-north", country: "canada", sourceSlug: "ontario" },
  pe: { slug: "prince-edward-island", country: "canada" },
  qc: { slug: "quebec", country: "canada", legacy: true },
  "qc-s": { slug: "quebec-south", country: "canada", sourceSlug: "quebec" },
  "qc-n": { slug: "quebec-north", country: "canada", sourceSlug: "quebec" },
  sk: { slug: "saskatchewan", country: "canada" },
  yt: { slug: "yukon", country: "canada" },
  ak: { slug: "alaska", country: "us" },
  al: { slug: "alabama", country: "us" },
  ar: { slug: "arkansas", country: "us" },
  az: { slug: "arizona", country: "us" },
  ca: { slug: "california", country: "us", legacy: true },
  "ca-s": { slug: "california-south", country: "us", sourceSlug: "california" },
  "ca-n": { slug: "california-north", country: "us", sourceSlug: "california" },
  co: { slug: "colorado", country: "us" },
  ct: { slug: "connecticut", country: "us" },
  de: { slug: "delaware", country: "us" },
  fl: { slug: "florida", country: "us" },
  ga: { slug: "georgia", country: "us" },
  hi: { slug: "hawaii", country: "us" },
  ia: { slug: "iowa", country: "us" },
  id: { slug: "idaho", country: "us" },
  il: { slug: "illinois", country: "us" },
  in: { slug: "indiana", country: "us" },
  ks: { slug: "kansas", country: "us" },
  ky: { slug: "kentucky", country: "us" },
  la: { slug: "louisiana", country: "us" },
  ma: { slug: "massachusetts", country: "us" },
  md: { slug: "maryland", country: "us" },
  me: { slug: "maine", country: "us" },
  mi: { slug: "michigan", country: "us" },
  mn: { slug: "minnesota", country: "us" },
  mo: { slug: "missouri", country: "us" },
  ms: { slug: "mississippi", country: "us" },
  mt: { slug: "montana", country: "us" },
  nc: { slug: "north-carolina", country: "us" },
  nd: { slug: "north-dakota", country: "us" },
  ne: { slug: "nebraska", country: "us" },
  nh: { slug: "new-hampshire", country: "us" },
  nj: { slug: "new-jersey", country: "us" },
  nm: { slug: "new-mexico", country: "us" },
  nv: { slug: "nevada", country: "us" },
  ny: { slug: "new-york", country: "us" },
  oh: { slug: "ohio", country: "us" },
  ok: { slug: "oklahoma", country: "us" },
  or: { slug: "oregon", country: "us" },
  pa: { slug: "pennsylvania", country: "us" },
  ri: { slug: "rhode-island", country: "us" },
  sc: { slug: "south-carolina", country: "us" },
  sd: { slug: "south-dakota", country: "us" },
  tn: { slug: "tennessee", country: "us" },
  tx: { slug: "texas", country: "us", legacy: true },
  "tx-ne": { slug: "texas-northeast", country: "us", sourceSlug: "texas" },
  "tx-nw": { slug: "texas-northwest", country: "us", sourceSlug: "texas" },
  "tx-se": { slug: "texas-southeast", country: "us", sourceSlug: "texas" },
  "tx-sw": { slug: "texas-southwest", country: "us", sourceSlug: "texas" },
  ut: { slug: "utah", country: "us" },
  va: { slug: "virginia", country: "us" },
  vt: { slug: "vermont", country: "us" },
  wa: { slug: "washington", country: "us" },
  wi: { slug: "wisconsin", country: "us" },
  wv: { slug: "west-virginia", country: "us" },
  wy: { slug: "wyoming", country: "us" }
};

function geofabrikSource(regionId) {
  const id = String(regionId || "").toLowerCase();
  const source = OSM_REGION[id];
  if (!source) {
    throw new Error(
      `no Geofabrik source for '${id}'; add it to scripts/pack-fabric/routing/registry/geofabrik.js`
    );
  }
  return { id, ...source };
}

function geofabrikDownloadSlug(regionId) {
  const source = geofabrikSource(regionId);
  return source.sourceSlug || source.slug;
}

function geofabrikPbfUrl(regionId) {
  const source = geofabrikSource(regionId);
  const slug = geofabrikDownloadSlug(regionId);
  return `https://download.geofabrik.de/north-america/${source.country}/${slug}-latest.osm.pbf`;
}

function catalogRegionIds() {
  return Object.keys(OSM_REGION)
    .filter((id) => !OSM_REGION[id].legacy)
    .sort();
}

module.exports = {
  OSM_REGION,
  catalogRegionIds,
  geofabrikSource,
  geofabrikDownloadSlug,
  geofabrikPbfUrl
};
