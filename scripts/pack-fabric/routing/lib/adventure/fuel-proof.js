"use strict";
const {fuelCovers,validateFuel}=require("./fuel-math");

// Verifies the exact proposed geometry, not station proximity. Station visits
// and destination escape distances must come from legal road proofs tied to
// this candidate. This function neither searches for pumps nor reroutes.
function proveFuel({ segments, visits, usableRangeMeters, initialUsableMeters,
  destinationEscape, budget, allowProvisionalStations=false }) {
  validateFuel({usableRangeMeters,initialUsableMeters});
  if (initialUsableMeters == null) return { state: "unverified", reason: "initial_fuel_unknown" };
  let provisional=false;
  let total = 0;
  for (const segment of segments) {
    if (!budget.consume()) return { state:"unverified", reason:budget.snapshot().reason };
    if (!Number.isFinite(segment.distanceMeters) || segment.distanceMeters < 0) throw new TypeError("Invalid segment length");
    total += segment.distanceMeters;
    if (!Number.isFinite(total)) throw new TypeError("Invalid aggregate distance");
  }
  let remaining = initialUsableMeters, at = 0, destinationArrival = null;
  const arrivals = [];
  for (const visit of visits) {
    if (!budget.consume()) return { state:"unverified", reason:budget.snapshot().reason, arrivals };
    if (!Number.isFinite(visit.atMeters) || visit.atMeters < at || visit.atMeters > total) throw new TypeError("Unordered or off-route visit");
    const distance = visit.atMeters - at;
    if (!fuelCovers(remaining,distance)) return { state:"gap_on_candidate", reason:"unreachable_visit", visitId:visit.id,
      shortfallMeters:distance-remaining, arrivals };
    remaining = Math.max(0,remaining-distance);
    // Capture arrival before any planned refill at the destination. Later
    // departure/escape may use that refill, but arrival must not look full.
    if (visit.atMeters === total && destinationArrival === null) destinationArrival = remaining;
    const arrival = { visitId:visit.id, atMeters:visit.atMeters, arrivalUsableMeters:remaining };
    if (visit.refuel === true) {
      const projectionVisit=visit.accessEvidence==="legal_road_projection";
      const provisionalVisit=allowProvisionalStations===true&&projectionVisit;
      if (!visit.stationId || (projectionVisit?!provisionalVisit:visit.legalStationVisit !== true)) return { state:"unverified", reason:"station_visit_unproved", visitId:visit.id, arrivals };
      provisional ||= provisionalVisit;
      remaining = usableRangeMeters;
    }
    arrivals.push({ ...arrival, departureUsableMeters:remaining, refuel:visit.refuel === true });
    at = visit.atMeters;
  }
  if (!fuelCovers(remaining,total-at)) return { state:"gap_on_candidate", reason:"destination_unreachable", shortfallMeters:total-at-remaining, arrivals };
  remaining = Math.max(0,remaining-(total-at));
  const arrivalUsableMeters = destinationArrival ?? remaining;
  if (!budget.check()) return {state:"unverified",reason:budget.snapshot().reason,arrivals};
  const provisionalEscape=allowProvisionalStations===true&&destinationEscape?.state==="provisional_station_access"&&destinationEscape?.accessEvidence==="legal_road_projection";
  if (!destinationEscape || ((destinationEscape.state !== "verified"||destinationEscape.accessEvidence==="legal_road_projection")&&!provisionalEscape) || !destinationEscape.stationId ||
      !Number.isFinite(destinationEscape.distanceMeters) || destinationEscape.distanceMeters < 0) {
    return {state:"unverified",reason:"destination_escape_unproved",arrivalUsableMeters,departureUsableMeters:remaining,arrivals};
  }
  if (!fuelCovers(remaining,destinationEscape.distanceMeters)) return {state:"gap_on_candidate",reason:"destination_escape_unreachable",
    shortfallMeters:destinationEscape.distanceMeters-remaining,arrivalUsableMeters,departureUsableMeters:remaining,arrivals};
  return {state:provisional||provisionalEscape?"provisional_station_access":"verified",arrivalUsableMeters,departureUsableMeters:remaining,escapeUsableMeters:Math.max(0,remaining-destinationEscape.distanceMeters),arrivals};
}
module.exports = { proveFuel };
