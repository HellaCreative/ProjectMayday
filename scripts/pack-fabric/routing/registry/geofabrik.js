"use strict";

/**
 * Geofabrik extract identity per Dirt region id.
 * The v3 pack stamp uses this map — add a row before building a new province/state.
 */
const OSM_REGION = {
  nb: { slug: "new-brunswick", country: "canada" },
  qc: { slug: "quebec", country: "canada" },
  ns: { slug: "nova-scotia", country: "canada" },
  pe: { slug: "prince-edward-island", country: "canada" },
  on: { slug: "ontario", country: "canada" },
  mb: { slug: "manitoba", country: "canada" },
  sk: { slug: "saskatchewan", country: "canada" },
  ab: { slug: "alberta", country: "canada" },
  bc: { slug: "british-columbia", country: "canada" },
  nl: { slug: "newfoundland-and-labrador", country: "canada" },
  yt: { slug: "yukon", country: "canada" },
  nt: { slug: "northwest-territories", country: "canada" },
  nu: { slug: "nunavut", country: "canada" },
  wa: { slug: "washington", country: "us" }
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

function geofabrikPbfUrl(regionId) {
  const source = geofabrikSource(regionId);
  return `https://download.geofabrik.de/north-america/${source.country}/${source.slug}-latest.osm.pbf`;
}

module.exports = {
  OSM_REGION,
  geofabrikSource,
  geofabrikPbfUrl
};
