import Foundation
import CoreLocation

// Experimental publication gate over the actual, ordered source walk. Fuel is
// an event along that walk and NEVER resets the turn automaton. A failed check
// means this candidate is unverified, not that no feasible itinerary exists.
enum NativeFuelContinuity {
    private struct Span {
        let edge: Int, from: Int, to: Int
        let meters: Double
        let first: [Double], last: [Double]
        let routeIndex: Int
    }
    private static func separation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == 2, b.count == 2, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return .infinity }
        return CLLocation(latitude: a[1], longitude: a[0]).distance(from: CLLocation(latitude: b[1], longitude: b[0]))
    }
    // Bind reported partial spans to the immutable source geometry. A shorter
    // reported distance must not manufacture fuel feasibility.
    private static func position(_ point: [Double], on poly: [CLLocationCoordinate2D]) -> (meters: Double, total: Double)? {
        guard poly.count >= 2 else { return nil }
        let scale = cos(point[1] * .pi / 180)
        var offset = 0.0, best = Double.infinity, hits: [Double] = []
        for i in 1..<poly.count {
            let a = poly[i-1], b = poly[i], length = GeoMath.meters(a, b)
            let dx = (b.longitude-a.longitude)*scale, dy = b.latitude-a.latitude
            let squared = dx*dx + dy*dy
            let t = squared > 0 ? min(1, max(0, ((point[0]-a.longitude)*scale*dx + (point[1]-a.latitude)*dy)/squared)) : 0
            let projected = [a.longitude+(b.longitude-a.longitude)*t, a.latitude+(b.latitude-a.latitude)*t]
            let gap = separation(point, projected), along = offset+length*t
            if gap < best - 0.01 { best = gap; hits = [along] }
            else if abs(gap-best) <= 0.01 { hits.append(along) }
            offset += length
        }
        guard best <= 1, offset > 0, let first = hits.first, hits.allSatisfy({ abs($0-first) <= 0.1 }) else { return nil }
        return (first, offset)
    }
    static func check(pack: GraphV2Pack, identity: String, fuelIdentity: String, payload: [String: Any]) -> [String: Any] {
        // The pinned native and JS readers only apply the motorcycle bit. Do
        // not certify a pack with another vehicle-specific restriction scope
        // until that shared interpretation has been qualified. All 2,112 NS
        // restrictions in this experiment use the supported generic mask 7.
        let unsupportedMasks = pack.restrictions.filter { ($0.vehicleMask & 1) == 0 }.map { Int($0.vehicleMask) }
        guard unsupportedMasks.isEmpty else {
            return ["state": "incomplete", "errors": ["unsupported_restriction_vehicle_scope"], "accepted": false,
                    "restrictionCount": pack.restrictions.count, "unsupportedVehicleMasks": unsupportedMasks]
        }
        var errors: [String] = [], unverifiedFuelApproaches: [[String: Any]] = []
        var spans: [Span] = [], fuelDistances: [Double] = []
        var startApproachMeters = 0.0, endApproachMeters = 0.0
        let keys: Set<String> = ["packIdentity", "fuelIdentity", "routes", "refills", "start", "end", "profile", "allowUnknown", "rangeMeters", "firstMeters", "knownFuel", "excludedStationIds", "minimumStops", "requiredFirstStationId"]
        guard Set(payload.keys).isSubset(of: keys), payload["packIdentity"] as? String == identity,
              payload["fuelIdentity"] as? String == fuelIdentity,
              let routes = payload["routes"] as? [[String: Any]], !routes.isEmpty,
              let refills = payload["refills"] as? [[String: Any]], routes.count == refills.count + 1,
              let expectedStart = payload["start"] as? [Double], let expectedEnd = payload["end"] as? [Double],
              let profile = payload["profile"] as? String, RouteProfile(rawValue: profile) != nil,
              let allowUnknown = payload["allowUnknown"] as? Bool, !(profile == "cleanest" && allowUnknown),
              let range = payload["rangeMeters"] as? Double, range.isFinite, range > 0,
              let firstRange = payload["firstMeters"] as? Double, firstRange.isFinite, firstRange > 0, firstRange <= range,
              let knownFuel = payload["knownFuel"] as? [[String: Any]],
              pack.version >= 4, pack.legalTopology,
              let graphFrom = pack.edgeFrom, let graphTo = pack.edgeTo, let geometry = pack.geometry else {
            return ["state": "incomplete", "errors": ["invalid_identity_or_unsupported_contract"], "accepted": false]
        }
        let excluded = Set(payload["excludedStationIds"] as? [String] ?? [])
        if let minimum = payload["minimumStops"] as? Int, refills.count < minimum { errors.append("missing_required_stop") }
        if let required = payload["requiredFirstStationId"] as? String, refills.first?["id"] as? String != required { errors.append("required_first_station_changed") }
        var visited: Set<String> = []
        for refill in refills {
            guard let id = refill["id"] as? String, let point = refill["point"] as? [Double],
                  !excluded.contains(id), visited.insert(id).inserted,
                  knownFuel.contains(where: { $0["id"] as? String == id && ($0["point"] as? [Double]).map { separation($0, point) <= 0.01 } == true }) else {
                errors.append("unknown_excluded_or_repeated_fuel"); continue
            }
        }
        func nodePoint(_ node: Int) -> [Double] { [Double(pack.nodeCoords[node * 2]), Double(pack.nodeCoords[node * 2 + 1])] }
        let byID = Dictionary(uniqueKeysWithValues: (0..<pack.undirectedEdgeCount).map { (pack.edgeId($0), $0) })
        for (r, route) in routes.enumerated() {
            guard route["state"] as? String == "found", route["searchTimedOut"] as? Bool != true,
                  let query = route["query"] as? [String: Any], query["profile"] as? String == profile,
                  query["allowUnknown"] as? Bool == allowUnknown,
                  let start = query["start"] as? [Double], let end = query["end"] as? [Double],
                  let legs = route["legs"] as? [[String: Any]], !legs.isEmpty,
                  let distance = route["distanceMeters"] as? Double, distance.isFinite, distance >= 0 else {
                errors.append("invalid_or_unfinished_leg_\(r)"); continue
            }
            let wantedStart = r == 0 ? expectedStart : (refills[r-1]["point"] as? [Double] ?? [])
            let wantedEnd = r == refills.count ? expectedEnd : (refills[r]["point"] as? [Double] ?? [])
            if separation(start, wantedStart) > 0.01 || separation(end, wantedEnd) > 0.01 { errors.append("endpoint_or_stop_changed_\(r)") }
            if distance > (r == 0 ? firstRange : range) + 0.01 { errors.append("fuel_range_exceeded_\(r)") }
            var local: [Span] = [], total = 0.0, conservativeMeters = 0.0
            var previousCoordinate = start
            for (j, leg) in legs.enumerated() {
                guard let id = leg["edgeId"] as? String, let meters = leg["meters"] as? Double,
                      meters.isFinite, meters >= 0, let coords = leg["coordinates"] as? [[Double]],
                      coords.count >= 2, let first = coords.first, let last = coords.last,
                      coords.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) && abs($0[0]) <= 180 && abs($0[1]) <= 90 }) else { errors.append("invalid_geometry_\(r)_\(j)"); continue }
                total += meters
                if separation(previousCoordinate, first) > (j == 0 ? 1 : 0.1) { errors.append("disconnected_display_geometry_\(r)_\(j)") }
                previousCoordinate = last
                if id.hasPrefix("soft-stitch") {
                    let geometryMeters = zip(coords, coords.dropFirst()).reduce(0.0) { $0 + GeoMath.meters(CLLocationCoordinate2D(latitude: $1.0[1], longitude: $1.0[0]), CLLocationCoordinate2D(latitude: $1.1[1], longitude: $1.1[0])) }
                    conservativeMeters += max(meters, geometryMeters)
                    if j != 0 && j != legs.count - 1 { errors.append("interior_synthetic_connection_\(r)_\(j)") }
                    if r == 0 && j == 0 { startApproachMeters += meters }
                    else if r == routes.count - 1 && j == legs.count - 1 { endApproachMeters += meters }
                    else { unverifiedFuelApproaches.append(["route": r, "leg": j, "meters": meters]) }
                    continue
                }
                guard let edge = (leg["edgeIndex"] as? Int) ?? byID[id], edge >= 0, edge < pack.undirectedEdgeCount,
                      pack.edgeId(edge) == id, meters <= Double(pack.edgeMeters[edge]) + 2 else {
                    errors.append("source_identity_or_distance_\(r)_\(j)"); continue
                }
                let a = Int(graphFrom[edge]), b = Int(graphTo[edge])
                var from = leg["fromNode"] as? Int, to = leg["toNode"] as? Int
                if from == nil || to == nil {
                    if let previous = local.last, previous.to == a || previous.to == b { from = previous.to; to = from == a ? b : a }
                    else if j + 1 < legs.count, let next = legs[j+1]["fromNode"] as? Int, next == a || next == b { to = next; from = to == a ? b : a }
                    else if separation(first, nodePoint(a)) <= 0.1 && separation(last, nodePoint(b)) <= 0.1 { from = a; to = b }
                    else if separation(first, nodePoint(b)) <= 0.1 && separation(last, nodePoint(a)) <= 0.1 { from = b; to = a }
                }
                guard let from, let to, (from == a && to == b) || (from == b && to == a),
                      pack.hasDirectedArc(from: from, to: to, edge: edge) else { errors.append("ambiguous_or_illegal_direction_\(r)_\(j)"); continue }
                let poly = geometry.polyline(edgeIndex: edge)
                guard let p0 = position(first, on: poly), let p1 = position(last, on: poly),
                      (from == a && p1.meters >= p0.meters) || (from == b && p1.meters <= p0.meters) else { errors.append("source_geometry_mismatch_\(r)_\(j)"); continue }
                let full = leg["fromNode"] as? Int != nil && leg["toNode"] as? Int != nil
                let sourceMeters = full ? Double(pack.edgeMeters[edge]) : abs(p1.meters-p0.meters)/p0.total*Double(pack.edgeMeters[edge])
                if full && (separation(first, nodePoint(from)) > 1 || separation(last, nodePoint(to)) > 1) { errors.append("full_source_geometry_mismatch_\(r)_\(j)") }
                conservativeMeters += max(meters, sourceMeters)
                local.append(Span(edge: edge, from: from, to: to, meters: max(meters, sourceMeters), first: first, last: last, routeIndex: r))
            }
            fuelDistances.append(max(distance, conservativeMeters))
            if conservativeMeters > (r == 0 ? firstRange : range) + 0.01 { errors.append("source_fuel_range_exceeded_\(r)") }
            if abs(total - distance) > 0.01 { errors.append("distance_accounting_\(r)") }
            if separation(previousCoordinate, end) > 1 { errors.append("disconnected_display_endpoint_\(r)") }
            guard let first = local.first, let last = local.last else { errors.append("empty_source_walk_\(r)"); continue }
            let customerIDs = Set(local.filter { pack.v4AccessCode(ei: $0.edge, from: $0.from, to: $0.to) == 4 }.map { pack.edgeId($0.edge) })
            if !CustomerEndpointAccess.validRuns(local.map { (pack.edgeId($0.edge), $0.meters) }, customerIDs: customerIDs, start: r > 0, end: r < refills.count) {
                errors.append("customer_access_outside_fuel_approach_\(r)")
            }
            let customerEdges = Set(local.filter { customerIDs.contains(pack.edgeId($0.edge)) }.map(\.edge))
            for s in local {
                if !pack.v4AccessAllowed(ei: s.edge, from: s.from, to: s.to, startEi: first.edge, endEi: last.edge,
                    allowUnknown: allowUnknown, startEndpointKind: r > 0 ? "customers" : nil, endEndpointKind: r < refills.count ? "customers" : nil,
                    customerStartEdges: r > 0 ? customerEdges : [], customerEndEdges: r < refills.count ? customerEdges : []) { errors.append("illegal_access_\(r)_\(s.edge)") }
            }
            if r > 0, separation(first.first, start) > 1 { unverifiedFuelApproaches.append(["route": r, "startToRoadMeters": separation(first.first, start)]) }
            if r < refills.count, separation(last.last, end) > 1 { unverifiedFuelApproaches.append(["route": r, "roadToFuelMeters": separation(last.last, end)]) }
            spans += local
        }
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        var state: Int?, previous: Span?, combinedMeters = 0.0, transitions = 0, splitContinuations = 0
        for s in spans {
            if let p = previous {
                if p.edge == s.edge && p.from == s.from && p.to == s.to && separation(p.last, s.first) <= 0.1 {
                    // The same source edge split at a refill is still one traversal.
                    combinedMeters += s.meters
                    if combinedMeters > Double(pack.edgeMeters[s.edge]) + 2 { errors.append("overlapping_partial_edge_\(s.edge)") }
                    previous = s; splitContinuations += 1; continue
                }
                if p.to != s.from || separation(p.last, s.first) > 0.1
                    || separation(p.last, nodePoint(p.to)) > 1 || separation(s.first, nodePoint(s.from)) > 1 {
                    errors.append("disconnected_or_unproved_mid_edge_turn_\(s.routeIndex)_\(s.edge)"); break
                }
            }
            let next = turns.transition(state: state ?? s.from, outgoingEdge: s.edge, toNode: s.to)
            if next < 0 { errors.append("illegal_continuation_\(s.routeIndex)_\(s.edge)"); break }
            state = next; previous = s; combinedMeters = s.meters; transitions += 1
        }
        if spans.isEmpty { errors.append("empty_itinerary") }
        let accepted = errors.isEmpty && unverifiedFuelApproaches.isEmpty
        return ["accepted": accepted, "state": accepted ? "graph_fuel_candidate" : "incomplete",
            "errors": errors, "unverifiedFuelApproaches": unverifiedFuelApproaches,
            "restrictionCount": pack.restrictions.count,
            "restrictionVehicleMasks": pack.restrictions.map { Int($0.vehicleMask) },
            "sourceTransitions": transitions, "coalescedPartialEdgeContinuations": splitContinuations,
            "fuelLegMeters": fuelDistances, "turnHistoryResetsAtFuel": 0,
            "riderStartApproachMeters": startApproachMeters, "riderEndApproachMeters": endApproachMeters,
            "scope": "Ordered source-road access/turn and fuel-range witness. Unmapped fuel approaches cannot pass. Rider endpoint approaches are explicit. This does not establish pump availability or route optimality."]
    }
}
