import Foundation

extension RoutingEngine {
    /// Simplify the transfers between substantial dirt runs. A short connector
    /// survives unless a shorter, legally connected paved replacement is proved.
    /// The substantial dirt and rider endpoints are anchors, not suggestions.
    func simplifiedTransfers(_ route: ComputedRoute, request: RoutingRequest,
                             budget: ComputationBudget) throws -> ComputedRoute {
        guard request.options.simplifyTransfers, request.profile.style != .cleanest,
              route.limit == nil, !route.segments.isEmpty, budget.remainingSeconds > 0.1 else { return route }
        let began = ContinuousClock.now
        defer { request.options.counter?.recordStage("transfers", since: began) }
        let allowance = budget.limited(to: min(2, budget.remainingSeconds * 0.2))
        let initial = request.options.arrival?.restrictions ?? request.options.arrivalRestrictions
        guard let boundaries = try EditableRouteBoundary.proven(in: route, graph: pack,
            initialRestrictions: initial, budget: allowance) else { return route }
        let proofs = Dictionary(uniqueKeysWithValues: boundaries.map { ($0.segmentCount, $0) })
        let segments = route.segments
        var protected = Set<Int>()
        var index = 0
        while index < segments.count {
            let first = index
            var meters = 0.0
            while index < segments.count, segments[index].structure != "ferry",
                  segments[index].surface == .gravel || segments[index].surface == .loose {
                meters += segments[index].meters; index += 1
            }
            if meters >= request.profile.minimumMeaningfulDirtMeters {
                protected.formUnion(first..<index)
            }
            if index == first { index += 1 }
        }
        // Restrictions and uncertain-access boundaries are also immutable. A
        // replacement never starts midway through a carried turn sequence.
        var windows: [Range<Int>] = []
        index = 0
        while index < segments.count {
            if protected.contains(index) { index += 1; continue }
            let first = index
            while index < segments.count, !protected.contains(index) { index += 1 }
            var lower = first, upper = index
            while lower < upper, lower != 0, proofs[lower] == nil { lower += 1 }
            while upper > lower, upper != segments.count, proofs[upper] == nil { upper -= 1 }
            if upper > lower { windows.append(lower..<upper) }
        }
        var result = route
        // Reverse order keeps the original segment indices valid after a splice.
        for window in windows.reversed().prefix(32) {
            guard allowance.remainingSeconds > 0.05 else { break }
            let old = Array(segments[window])
            let oldMeters = old.reduce(0) { $0 + $1.meters }
            guard oldMeters > 500 else { continue }
            let start = window.lowerBound == 0 ? route.start : proofs[window.lowerBound]!.match
            let end = window.upperBound == segments.count ? route.end : proofs[window.upperBound]!.match
            var options = request.options
            options.simplifyTransfers = false
            options.objective = .distance
            options.pavedOnly = true
            options.corridorMeters = .infinity
            options.maximumMeters = oldMeters - 50
            options.roadRemaining = nil
            options.preferredCorridorRoads = []
            // A paved transfer may legitimately be the shared lollipop stem.
            // Reuse penalties must not buy a pointless paved U around it.
            options.repeatEdges = []
            options.priorEdges = []
            options.additionalEnds = []
            options.collectEveryGoal = false
            options.arrival = window.lowerBound == 0 ? request.options.arrival : .init(
                edge: pack.restrictionEdge(start.edge), coordinate: start.coordinate, restrictions: [])
            options.arrivalRestrictions = window.lowerBound == 0 ? initial : []
            options.requiredArrivalRoads = window.upperBound == segments.count ? request.options.requiredArrivalRoads : []
            options.requiredArrivalDirections = window.upperBound == segments.count ? request.options.requiredArrivalDirections : []
            // Do not shorten a transfer by cutting across the retained dirt ride.
            options.avoidEdges.formUnion(segments.enumerated().filter { !window.contains($0.offset) }.map { $0.element.edgeID })
            options.avoidEdges.remove(pack.edgeID(start.edge)); options.avoidEdges.remove(pack.edgeID(end.edge))
            var policy = request.profile
            policy.style = .cleanest
            var access = request.access
            access.startIsCustomer = window.lowerBound == 0 && request.access.startIsCustomer
            access.endIsCustomer = window.upperBound == segments.count && request.access.endIsCustomer
            do {
                let replacement = try PathSearch(pack: pack).search(start: start, end: end,
                    policy: policy, access: access, options: options, budget: allowance.limited(to: 0.3))
                guard replacement.limit == nil, replacement.distanceMeters + 50 < oldMeters,
                      replacement.arrivalRestrictions == (window.upperBound == segments.count ? route.arrivalRestrictions : []) else { continue }
                // Distance minimization may not buy a shortcut on a motorway or
                // trunk that the accepted transfer avoided. Rural primary roads
                // (including Trunk 7 in this pack) remain ordinary connections.
                func major(_ values: [RouteSegment]) -> Double {
                    values.filter { ["motorway", "trunk"].contains(ProfilePolicy.tier($0.roadClass)) }.reduce(0) { $0 + $1.meters }
                }
                guard !request.profile.avoidMajorHighways || major(replacement.segments) <= major(old) + 1 else { continue }
                let joined = Array(result.segments[..<window.lowerBound]) + replacement.segments + Array(result.segments[window.upperBound...])
                var candidate = ComputedRoute(start: route.start, end: route.end, segments: joined,
                    distanceMeters: joined.reduce(0) { $0 + $1.meters }, searchCost: result.searchCost,
                    poppedLabels: result.poppedLabels + replacement.poppedLabels, arrivalRestrictions: route.arrivalRestrictions)
                guard try EditableRouteBoundary.proven(in: candidate, graph: pack,
                    initialRestrictions: initial, budget: allowance) != nil else { continue }
                guard RouteTopology.selfCrossings(candidate.segments, graph: pack).count <= RouteTopology.selfCrossings(result.segments, graph: pack).count,
                      RouteQuality.reriddenMeters(candidate.segments) <= RouteQuality.reriddenMeters(result.segments) + 1 else { continue }
                candidate.qualityUrbanBoxes = route.qualityUrbanBoxes
                candidate.startRoadIdentity = joined.first.map { pack.identity(of: $0.edge) }
                candidate.endRoadIdentity = joined.last.map { pack.identity(of: $0.edge) }
                candidate.searchSummary = (route.searchSummary ?? "") + ",transfers"
                result = candidate
            } catch is CancellationError { throw CancellationError() }
            catch RoutingFailure.noPath { }
            catch RoutingFailure.resourceLimit { }
        }
        if result.segments.count != route.segments.count || result.distanceMeters != route.distanceMeters {
            result.maneuvers = NavigationCues.make(route: result, graph: pack, access: request.access, arrival: request.options.arrival)
        }
        return result
    }
}
