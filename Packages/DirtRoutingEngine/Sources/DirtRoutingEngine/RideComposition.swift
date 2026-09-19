import Foundation

/// Proposes another riding area, then proves both sides using the ordinary
/// legal router. Proposals are optional: neither their coordinates nor a failed
/// attempt establish connectivity or replace the rider's destination.
extension RoutingEngine {
    func composedDirtRide(_ request: RoutingRequest, start: RoadMatch, end: RoadMatch,
                          budget: ComputationBudget) throws -> ComputedRoute? {
        guard request.options.composeDirtRide, request.profile.style == .dirt,
              request.options.extentCenter == nil, request.options.maximumMeters == .infinity,
              request.options.additionalEnds.isEmpty, !request.options.collectEveryGoal else { return nil }
        let span = start.coordinate.distance(to: end.coordinate)
        guard span >= request.profile.minimumUsefulDirtMeters * 4 else { return nil }
        let started = ContinuousClock.now
        defer { request.options.counter?.recordStage("rideComposition", since: started) }
        let proposals = try ridingAreas(request, start: start, end: end, budget: budget)
        let attemptBudget = budget.limited(to: min(24, budget.remainingSeconds * 0.5))
        for pin in proposals.prefix(2) {
            try budget.check()
            guard attemptBudget.remainingSeconds > 0 else { break }
            let attemptStarted = ContinuousClock.now
            defer { request.options.counter?.recordStage("rideArea:\(pin.coordinate.longitude),\(pin.coordinate.latitude)", since: attemptStarted) }
            do {
                var firstRequest = request.with(start: start.coordinate, end: pin.coordinate)
                firstRequest.options.composeDirtRide = false
                firstRequest.access.endIsCustomer = false
                let first = try route(firstRequest, start: start, end: pin, budget: attemptBudget)
                guard first.limit == nil, let last = first.segments.last else { continue }
                let incoming = try exactContinuation(first)
                var secondRequest = request.with(start: first.end.coordinate, end: end.coordinate)
                secondRequest.options.composeDirtRide = false
                secondRequest.access.startIsCustomer = false
                secondRequest.options.arrival = .init(edge: pack.restrictionEdge(last.edge),
                    coordinate: first.end.coordinate, restrictions: first.arrivalRestrictions)
                secondRequest.options.arrivalEdgeID = nil
                secondRequest.options.precedingMeters += first.distanceMeters
                secondRequest.options.precedingDirtMeters += first.segments.filter { $0.surface == .gravel || $0.surface == .loose }.reduce(0) { $0 + $1.meters }
                secondRequest.options.priorEdges.formUnion(first.segments.map(\.edgeID))
                let second = try route(secondRequest, start: incoming, end: end, budget: attemptBudget)
                guard second.limit == nil else { continue }
                var result = ComputedRoute(start: first.start, end: second.end,
                    segments: first.segments + second.segments,
                    distanceMeters: first.distanceMeters + second.distanceMeters,
                    searchCost: first.searchCost + second.searchCost,
                    poppedLabels: first.poppedLabels + second.poppedLabels,
                    arrivalRestrictions: second.arrivalRestrictions)
                let quality = RouteQuality(route: result, urbanBoxes: UrbanCores.boxes(in: pack))
                request.options.counter?.recordStage("rideQuality:dirt=\(quality.knownDirtPercent),repeat=\(Int(quality.reriddenMeters)),return=\(Int(quality.returnMeters)),scrap=\(Int(quality.shortDirtScrapMeters))", since: .now)
                // Owner's Dirt qualification floor; never buy it with repeated
                // spurs or a circuit returning to a place already ridden.
                guard quality.knownDirtPercent >= 70, quality.reriddenMeters == 0,
                      quality.returnMeters == 0, quality.shortDirtScrapMeters == 0 else { continue }
                result.searchSummary = "composed-dirt/\(Int(quality.knownDirtPercent))%/\(pack.identity(of: pin.edge))"
                result.maneuvers = NavigationCues.make(route: result, graph: pack, access: request.access, arrival: request.options.arrival)
                return result
            } catch is CancellationError { throw CancellationError() }
            catch RoutingFailure.noPath { continue }
            catch RoutingFailure.noMatch { continue }
            catch RoutingFailure.resourceLimit { continue }
        }
        return nil
    }

    /// Seed varies the area explored, not its road scores. Wander expands the
    /// area continuously. Final feasibility always comes from routed roads.
    func ridingAreas(_ request: RoutingRequest, start: RoadMatch, end: RoadMatch,
                     budget: ComputationBudget) throws -> [RoadMatch] {
        let a = start.coordinate, b = end.coordinate
        let span = a.distance(to: b), bearing = a.bearing(to: b)
        let reach = min(120_000, span * (0.08 + 0.65 * request.profile.appetite))
        let urban = UrbanCores.boxes(in: pack)
        let components = WeakComponents.ids(in: pack, allowUnknown: request.access.allowUnknown)
        let originComponent = WeakComponents.of(match: start, pack: pack, ids: components)
        var random = request.options.seed
        func unit() -> Double {
            random &+= 0x9e3779b97f4a7c15
            var value = random
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            return Double(value >> 11) / 9_007_199_254_740_992
        }
        let firstSide = unit() < 0.5 ? -1.0 : 1.0
        var proposals: [RoadMatch] = []
        for side in [firstSide, -firstSide] {
            try budget.check()
            let fraction = 0.40 + unit() * 0.20
            let middle = Coordinate(longitude: a.longitude + (b.longitude - a.longitude) * fraction,
                                    latitude: a.latitude + (b.latitude - a.latitude) * fraction)
            let radius = reach * (0.65 + unit() * 0.35)
            let angle = bearing + side * .pi / 2
            let target = Coordinate(longitude: middle.longitude + sin(angle) * radius / (111_000 * max(0.2, cos(middle.latitude * .pi / 180))),
                                    latitude: middle.latitude + cos(angle) * radius / 111_000)
            var best: (distance: Double, match: RoadMatch)?
            for (index, edge) in pack.candidates(near: target, radius: max(5_000, reach * 0.25)).enumerated() {
                if index & 255 == 0 { try budget.check() }
                let family = ProfilePolicy.family(pack.surfaceLeaf(edge))
                guard family == .gravel || family == .loose,
                      pack.distance(edge) >= request.profile.minimumMeaningfulDirtMeters,
                      pack.accessCode(edge, forward: true) == 0, pack.accessCode(edge, forward: false) == 0,
                      !["motorway", "trunk", "arterial"].contains(ProfilePolicy.tier(pack.roadClass(edge))) else { continue }
                let point = pack.coordinate(node: pack.endpoint(edge, from: true))
                guard !urban.contains(where: { $0.contains(point) }) else { continue }
                let length = pack.polyline(edge).adjacentDistance()
                let match = RoadMatch(edge: edge, coordinate: point, distanceMeters: 0,
                                      alongMeters: 0, geometryMeters: length)
                guard WeakComponents.of(match: match, pack: pack, ids: components) == originComponent else { continue }
                let distance = point.distance(to: target)
                if best == nil || distance < best!.distance { best = (distance, match) }
            }
            if let best, !proposals.contains(where: { $0.edge == best.match.edge }) { proposals.append(best.match) }
        }
        return proposals
    }

    /// At a junction the end match need not be the road actually ridden into
    /// it. Carry that actual incoming road and active turn sequence forward.
    func exactContinuation(_ route: ComputedRoute) throws -> RoadMatch {
        guard let last = route.segments.last else { throw RoutingFailure.noPath }
        let point = route.end.coordinate, line = pack.polyline(last.edge)
        var walked = 0.0, along = 0.0, closest = Double.infinity
        for (a, b) in zip(line, line.dropFirst()) {
            let projection = RoadMatcher.project(point, onto: a, to: b)
            let meters = a.distance(to: b), distance = point.distance(to: projection.point)
            if distance < closest { closest = distance; along = walked + meters * projection.fraction }
            walked += meters
        }
        guard closest < 0.1 else { throw RoutingFailure.invalidRequest("ride continuation is not on its incoming road") }
        return .init(edge: last.edge, coordinate: point, distanceMeters: 0,
                     alongMeters: along, geometryMeters: walked, forward: last.forward)
    }
}

private extension Array where Element == Coordinate {
    func adjacentDistance() -> Double { zip(self, dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
}
