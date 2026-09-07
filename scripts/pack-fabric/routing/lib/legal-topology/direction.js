"use strict";

/**
 * V4 travel direction. Unevaluable reversible / alternating / conditional
 * direction is closed, not two-way.
 */

const FORWARD = new Set(["yes", "true", "1"]);
const REVERSE = new Set(["-1", "reverse"]);
const BOTH = new Set(["no", "false", "0"]);
const CLOSED_ONEWAY = new Set(["reversible", "alternating"]);

function tag(value) {
  if (value == null || value === "") return "";
  return String(value).toLowerCase().trim();
}

function impliedForward(tags = {}) {
  const highway = tag(tags.highway);
  const junction = tag(tags.junction);
  if (junction === "roundabout" || junction === "circular") return true;
  if (highway === "motorway" || highway === "motorway_link") return true;
  return false;
}

/**
 * @returns {"forward"|"reverse"|"both"|"closed"}
 */
function travelDirectionV4(tags = {}, conditionalDirection = null) {
  const oneway = tag(tags.oneway);
  if (CLOSED_ONEWAY.has(oneway)) return "closed";
  if (tag(tags["oneway:conditional"]) && !conditionalDirection) return "closed";
  if (conditionalDirection === "closed") return "closed";
  if (conditionalDirection === "forward" || conditionalDirection === "reverse" || conditionalDirection === "both") {
    return conditionalDirection;
  }
  if (BOTH.has(oneway)) return "both";
  if (FORWARD.has(oneway)) return "forward";
  if (REVERSE.has(oneway)) return "reverse";
  if (oneway) return "closed";
  if (impliedForward(tags)) return "forward";
  return "both";
}

function legalDirectedArcs(direction) {
  if (direction === "forward") return { forward: true, reverse: false };
  if (direction === "reverse") return { forward: false, reverse: true };
  if (direction === "both") return { forward: true, reverse: true };
  return { forward: false, reverse: false };
}

module.exports = {
  travelDirectionV4,
  legalDirectedArcs,
  impliedForward
};
