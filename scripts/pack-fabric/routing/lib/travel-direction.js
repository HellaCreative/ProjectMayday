"use strict";

/**
 * OSM travel direction for pack encoding.
 *
 * Independent of surface, road preference, and routing profile.
 * Missing or ambiguous tags default to bidirectional.
 * Motorway / motorway_link and roundabouts imply forward unless
 * oneway explicitly marks two-way.
 */
const FORWARD_ONEWAY = new Set(["yes", "true", "1"]);
const REVERSE_ONEWAY = new Set(["-1", "reverse"]);
const EXPLICIT_BOTH = new Set(["no", "false", "0"]);

function tagValue(value) {
  if (value == null || value === "") return "";
  return String(value).toLowerCase().trim();
}

function travelDirectionFromOsmTags(props = {}) {
  const oneway = tagValue(props.oneway);
  const highway = tagValue(props.highway);
  const junction = tagValue(props.junction);

  if (EXPLICIT_BOTH.has(oneway)) return "both";
  if (FORWARD_ONEWAY.has(oneway)) return "forward";
  if (REVERSE_ONEWAY.has(oneway)) return "reverse";
  if (oneway) return "both";

  if (junction === "roundabout" || junction === "circular") return "forward";
  if (highway === "motorway" || highway === "motorway_link") return "forward";
  return "both";
}

function legalDirectedArcs(direction) {
  if (direction === "forward") return { forward: true, reverse: false };
  if (direction === "reverse") return { forward: false, reverse: true };
  return { forward: true, reverse: true };
}

function packHasDirectedArc(pack, fromNode, toNode, edgeIndex) {
  if (!pack || fromNode == null || toNode == null || fromNode < 0) return false;
  const offsets = pack.nodeOffsets;
  const targets = pack.edgeTargets;
  const undirected = pack.edgeUndirectedIndex;
  if (!offsets || !targets || !undirected) return false;
  const start = offsets[fromNode];
  const end = offsets[fromNode + 1];
  if (!Number.isFinite(start) || !Number.isFinite(end)) return false;
  for (let i = start; i < end; i += 1) {
    if (targets[i] === toNode && undirected[i] === edgeIndex) return true;
  }
  return false;
}

module.exports = {
  travelDirectionFromOsmTags,
  legalDirectedArcs,
  packHasDirectedArc
};
