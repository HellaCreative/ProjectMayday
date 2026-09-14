import CoreLocation
import Foundation

/// Progress-directed fuel stop pick — Layer 1 of itinerary planning.
/// Graph reachability is supplied by the caller (pack Dijkstra). This type
/// only chooses among pumps already proven reachable on the hop.
nonisolated enum FuelItinerary {
    struct ProfileFuelCandidate: Sendable {
        let fuel: POIFeature
        let routedMeters: Double
        let chainDirtPercent: Double
        let validForward: Bool
        let cleanFallbackCount: Int
        let cleanMajorRoadMeters: Double
        let cleanRoutedMeters: Double
        let chainBacktrackMeters: Double
        let chainStopCount: Int
        let urbanEntry: Bool
        let progressMeters: Double
        let directionalDetourMeters: Double
        let discoveryRank: Int
    }

    static func cleanQuality(
        _ route: OnDeviceRouter.Result,
        penalizeMajorRoads: Bool
    ) -> (fallbackCount: Int, majorRoadMeters: Double, routedMeters: Double) {
        let fallbackCount = (route.searchMeta.urbanCoreFallbackUsed ? 2 : 0)
            + (route.searchMeta.settlementFallbackUsed ? 1 : 0)
        let major = Set([
            "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
            "freeway", "ramp", "arterial"
        ])
        let majorMeters = penalizeMajorRoads
            ? route.legs.reduce(0.0) { total, leg in
                major.contains(leg.roadClassName.lowercased())
                    ? total + leg.distanceMeters
                    : total
            }
            : 0
        return (fallbackCount, majorMeters, route.distanceMeters)
    }

    /// Safety/continuity is a gate. Then minimize complete-chain stops and
    /// preserve forward travel. Ride character is the final tiebreaker.
    static func prefersProfileFuelCandidate(
        _ a: ProfileFuelCandidate,
        over b: ProfileFuelCandidate,
        profile: RouteProfile,
        tankMeters: Double
    ) -> Bool {
        if a.validForward != b.validForward { return a.validForward }
        if a.chainStopCount != b.chainStopCount { return a.chainStopCount < b.chainStopCount }
        if a.urbanEntry != b.urbanEntry { return !a.urbanEntry }
        let aBacktrack = a.cleanRoutedMeters > 0
            ? a.chainBacktrackMeters / a.cleanRoutedMeters
            : 0
        let bBacktrack = b.cleanRoutedMeters > 0
            ? b.chainBacktrackMeters / b.cleanRoutedMeters
            : 0
        if abs(aBacktrack - bBacktrack) > 0.01 { return aBacktrack < bBacktrack }
        if abs(a.directionalDetourMeters - b.directionalDetourMeters) > 2_000 {
            return a.directionalDetourMeters < b.directionalDetourMeters
        }
        if abs(a.progressMeters - b.progressMeters) > 2_000 {
            return a.progressMeters > b.progressMeters
        }
        let aBand = HopSearchPolicy.tankCommitBand(
            graphMeters: a.routedMeters,
            tankMeters: tankMeters
        )
        let bBand = HopSearchPolicy.tankCommitBand(
            graphMeters: b.routedMeters,
            tankMeters: tankMeters
        )
        if aBand != bBand { return aBand < bBand }
        if abs(a.cleanRoutedMeters - b.cleanRoutedMeters) > 50 {
            return a.cleanRoutedMeters < b.cleanRoutedMeters
        }
        switch profile {
        case .dirt:
            if abs(a.chainDirtPercent - b.chainDirtPercent) > 0.5 {
                return a.chainDirtPercent > b.chainDirtPercent
            }
        case .balanced:
            let aMiss = abs(a.chainDirtPercent - 50)
            let bMiss = abs(b.chainDirtPercent - 50)
            if abs(aMiss - bMiss) > 0.5 { return aMiss < bMiss }
        case .cleanest:
            if a.cleanFallbackCount != b.cleanFallbackCount {
                return a.cleanFallbackCount < b.cleanFallbackCount
            }
            let aMajor = a.cleanRoutedMeters > 0
                ? a.cleanMajorRoadMeters / a.cleanRoutedMeters
                : 0
            let bMajor = b.cleanRoutedMeters > 0
                ? b.cleanMajorRoadMeters / b.cleanRoutedMeters
                : 0
            if abs(aMajor - bMajor) > 0.005 { return aMajor < bMajor }
        }
        _ = tankMeters
        return a.discoveryRank < b.discoveryRank
    }

    static func fuelStopRequiresUrbanEntry(
        _ fuel: POIFeature,
        start: RouteCoordinate,
        destination: RouteCoordinate,
        boxes: [UrbanCore.Box]
    ) -> Bool {
        guard !boxes.isEmpty else { return false }
        return UrbanCore.blocks(
            point: CLLocationCoordinate2D(
                latitude: fuel.latitude,
                longitude: fuel.longitude
            ),
            start: start.locationCoordinate,
            end: destination.locationCoordinate,
            boxes: boxes
        )
    }

    /// Watching begins at 75% consumed. An early pump remains a sparse-corridor
    /// fallback, and an explicit rider pump always remains selectable.
    static func eligibleProfileFuelCandidates(
        _ candidates: [ProfileFuelCandidate],
        firstLegMaxMeters: Double,
        usableRangeMeters: Double,
        requiredFirstStationID: String?
    ) -> [ProfileFuelCandidate] {
        let valid = candidates.filter {
            $0.validForward
                && (requiredFirstStationID == nil || $0.fuel.id == requiredFirstStationID)
        }
        guard requiredFirstStationID == nil else { return valid }
        let searchStart = fuelSearchStartMeters(
            firstLegMaxMeters: firstLegMaxMeters,
            usableRangeMeters: usableRangeMeters
        )
        let watched = valid.filter { $0.routedMeters >= searchStart }
        return watched.isEmpty ? valid : watched
    }

    /// Remaining usable fuel is the hard first-leg ceiling.
    static func comfortCapMeters(
        firstLegMaxMeters: Double,
        usableRangeMeters: Double
    ) -> Double {
        guard usableRangeMeters > 0, firstLegMaxMeters >= 0 else { return 0 }
        return min(firstLegMaxMeters, usableRangeMeters)
    }

    /// Distance from the current departure at which fuel candidate search opens.
    /// Reserve is already reflected in `usableRangeMeters`; partial-tank use is
    /// reflected by a smaller `firstLegMaxMeters`.
    static func fuelSearchStartMeters(
        firstLegMaxMeters: Double,
        usableRangeMeters: Double
    ) -> Double {
        guard usableRangeMeters > 0, firstLegMaxMeters >= 0 else { return 0 }
        let used = max(0, usableRangeMeters - min(firstLegMaxMeters, usableRangeMeters))
        return max(0, usableRangeMeters * HopSearchPolicy.fuelComfortLo - used)
    }

    static func fuelPreferredStartMeters(
        firstLegMaxMeters: Double,
        usableRangeMeters: Double
    ) -> Double {
        guard usableRangeMeters > 0, firstLegMaxMeters >= 0 else { return 0 }
        let used = max(0, usableRangeMeters - min(firstLegMaxMeters, usableRangeMeters))
        return max(0, usableRangeMeters * HopSearchPolicy.fuelComfortHi - used)
    }

    static func fuelStopCountNeeded(
        profileMeters: Double,
        firstLegMaxMeters: Double,
        usableRangeMeters: Double
    ) -> Int {
        guard profileMeters.isFinite, profileMeters >= 0, usableRangeMeters > 0 else { return 0 }
        let firstCap = min(firstLegMaxMeters, usableRangeMeters)
        if profileMeters > firstCap + 1 {
            return Int(ceil((profileMeters - firstCap) / usableRangeMeters))
        }
        // Crossing the watch or preferred zone never manufactures a stop. A
        // reachable destination wins unless its destination-escape requirement
        // proves that a prior refuel is necessary.
        return 0
    }

    /// A numbered rider waypoint is a live refuel only while it sits on a packed
    /// pump. Recompute from coordinates; never persist a flag on the waypoint.
    /// Lockstep: fuel-chain.js deriveWaypointFuelStation.
    static func nearestFuelStation(
        to point: RouteCoordinate,
        stations: [POIFeature],
        within meters: Double = HopSearchPolicy.fuelWaypointSnapMeters
    ) -> (station: POIFeature, meters: Double)? {
        guard meters >= 0, !stations.isEmpty else { return nil }
        var best: (POIFeature, Double)?
        for station in stations {
            let distance = GeoMath.meters(
                point,
                RouteCoordinate(longitude: station.longitude, latitude: station.latitude)
            )
            guard distance <= meters else { continue }
            if best == nil || distance < best!.1 {
                best = (station, distance)
            }
        }
        return best.map { (station: $0.0, meters: $0.1) }
    }

    /// Numbered rider waypoints after the origin, including a final destination.
    /// A final waypoint on a packed pump is a deliberate refuel and needs no
    /// separate destination-escape allowance.
    static func deriveWaypointRefuels(
        waypoints: [RouteCoordinate],
        stations: [POIFeature],
        within meters: Double = HopSearchPolicy.fuelWaypointSnapMeters
    ) -> [(locationIndex: Int, station: POIFeature, meters: Double)] {
        guard waypoints.count >= 2 else { return [] }
        var rows: [(locationIndex: Int, station: POIFeature, meters: Double)] = []
        for index in 1..<waypoints.count {
            if let hit = nearestFuelStation(to: waypoints[index], stations: stations, within: meters) {
                rows.append((locationIndex: index, station: hit.station, meters: hit.meters))
            }
        }
        return rows
    }

    /// Remaining portion of an already-selected ride near the current pump.
    /// This lets live fuel planning reuse one route shape instead of asking the
    /// server for another unconstrained current→B adventure route at every
    /// recursion depth.
    static func routeSuffix(
        from current: RouteCoordinate,
        routeCoordinates: [RouteCoordinate],
        maximumOffRouteMeters: Double = 50_000
    ) -> [RouteCoordinate] {
        guard routeCoordinates.count > 1 else { return [] }
        let cumulative = GeoMath.cumulativeMeters(routeCoordinates)
        let location = CLLocation(latitude: current.latitude, longitude: current.longitude)
        guard let projection = GeoMath.nearestProjection(
            to: location,
            in: routeCoordinates,
            cumulative: cumulative
        ), projection.offMeters <= maximumOffRouteMeters else { return [] }
        let nextVertex = min(routeCoordinates.count - 1, projection.segmentIndex + 1)
        return [current] + Array(routeCoordinates[nextVertex...])
    }

    /// Preserve stations that sit on the selected ride first, then append
    /// forward-progress fallbacks. A bad or disconnected corridor pump must
    /// never erase the next usable town from the search.
    static func mergedCandidateOrder(
        primary: [POIFeature],
        fallback: [POIFeature]
    ) -> [POIFeature] {
        var seen = Set<String>()
        var result: [POIFeature] = []
        result.reserveCapacity(primary.count + fallback.count)
        for fuel in primary + fallback where seen.insert(fuel.id).inserted {
            result.append(fuel)
        }
        return result
    }

    /// Candidate ordering for live planning when no road pack is installed.
    /// Crow-flies distance is only a conservative prefilter/order hint; callers
    /// must verify every returned leg with the live graph before accepting it.
    static func approximateReachableMeters(
        fuels: [POIFeature],
        from: RouteCoordinate,
        tankMeters: Double,
        excluding: Set<String> = []
    ) -> [String: Double] {
        guard tankMeters > 0 else { return [:] }
        var result: [String: Double] = [:]
        result.reserveCapacity(fuels.count)
        for fuel in fuels where !excluding.contains(fuel.id) {
            let at = RouteCoordinate(longitude: fuel.longitude, latitude: fuel.latitude)
            let airMeters = GeoMath.meters(from, at)
            // A road leg cannot be shorter than its endpoints' geodesic distance.
            // Excluding anything outside one tank is therefore safe.
            if airMeters > 8_000, airMeters <= tankMeters {
                result[fuel.id] = airMeters
            }
        }
        return result
    }

    /// Rank live-routing candidates by their position along a graph-produced
    /// route corridor. This is only candidate discovery: every leg still has
    /// to be routed and proven within tank range before it is accepted.
    static func rankedRouteCorridorFuel(
        fuels: [POIFeature],
        from: RouteCoordinate,
        routeCoordinates: [RouteCoordinate],
        tankMeters: Double,
        sessionSeed: UInt64,
        excluding: Set<String> = []
    ) -> [POIFeature] {
        guard tankMeters > 0, routeCoordinates.count > 1 else { return [] }
        let cumulative = GeoMath.cumulativeMeters(routeCoordinates)
        guard let routeMeters = cumulative.last, routeMeters > 13_000 else { return [] }
        let farthestAlong = min(tankMeters, routeMeters - 5_000)

        struct Candidate {
            var fuel: POIFeature
            var alongMeters: Double
            var offMeters: Double
            var airMeters: Double
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(fuels.count)
        for fuel in fuels where !excluding.contains(fuel.id) {
            let point = RouteCoordinate(longitude: fuel.longitude, latitude: fuel.latitude)
            let airMeters = GeoMath.meters(from, point)
            // Safe lower bound: a road route cannot beat geodesic distance.
            guard airMeters > 8_000, airMeters <= tankMeters else { continue }
            let location = CLLocation(latitude: fuel.latitude, longitude: fuel.longitude)
            guard let projection = GeoMath.nearestProjection(
                to: location,
                in: routeCoordinates,
                cumulative: cumulative
            ),
                  projection.alongMeters > 8_000,
                  projection.alongMeters < farthestAlong,
                  projection.offMeters <= 50_000
            else { continue }
            candidates.append(
                Candidate(
                    fuel: fuel,
                    alongMeters: projection.alongMeters,
                    offMeters: projection.offMeters,
                    airMeters: airMeters
                )
            )
        }

        return candidates.sorted { a, b in
            let ba = HopSearchPolicy.tankCommitBand(
                graphMeters: a.alongMeters, tankMeters: tankMeters
            )
            let bb = HopSearchPolicy.tankCommitBand(
                graphMeters: b.alongMeters, tankMeters: tankMeters
            )
            if ba != bb { return ba < bb }
            if abs(a.alongMeters - b.alongMeters) > 1_000 {
                return a.alongMeters > b.alongMeters
            }
            if abs(a.offMeters - b.offMeters) > 1_000 { return a.offMeters < b.offMeters }
            let ha = HopSearchPolicy.hash(
                sessionSeed, Int(a.alongMeters), Int(a.airMeters)
            )
            let hb = HopSearchPolicy.hash(
                sessionSeed, Int(b.alongMeters), Int(b.airMeters)
            )
            return ha < hb
        }.map(\.fuel)
    }

    /// Among pumps reached within tank range, pick the one that makes the most
    /// progress toward B (not nearest-to-a-line, not crow-flies nearest).
    static func pickProgressFuel(
        fuels: [POIFeature],
        from: RouteCoordinate,
        to: RouteCoordinate,
        reachableMeters: [String: Double],
        tankMeters: Double,
        usableRangeMeters: Double? = nil,
        sessionSeed: UInt64,
        excluding: Set<String> = []
    ) -> POIFeature? {
        rankedProgressFuel(
            fuels: fuels, from: from, to: to, reachableMeters: reachableMeters,
            tankMeters: tankMeters, usableRangeMeters: usableRangeMeters,
            sessionSeed: sessionSeed, excluding: excluding
        ).first
    }

    /// Osmium area IDs encode the source way (2*w) or relation (2*r+1).
    /// Keep every original record/coordinate, but try another physical station
    /// before spending the window on duplicate representations of the same one.
    static func physicalStationID(_ id: String) -> String {
        guard id.hasPrefix("osm:a"), let area = UInt64(id.dropFirst(5)) else { return id }
        return "osm:\(area % 2 == 0 ? "w" : "r")\(area / 2)"
    }

    static func distinctStationsFirst(_ stations: [POIFeature]) -> [POIFeature] {
        var seen = Set<String>(), first: [POIFeature] = [], aliases: [POIFeature] = []
        for station in stations {
            if seen.insert(physicalStationID(station.id)).inserted { first.append(station) }
            else { aliases.append(station) }
        }
        return first + aliases
    }

    struct RoadProgress: Sendable {
        let originRemainingMeters: Double
        let stationRemainingMeters: [String: Double]
    }

    /// Ranked pumps toward B. Tank-band first, then more progress, then seed.
    static func rankedProgressFuel(
        fuels: [POIFeature],
        from: RouteCoordinate,
        to: RouteCoordinate,
        reachableMeters: [String: Double],
        tankMeters: Double,
        usableRangeMeters: Double? = nil,
        sessionSeed: UInt64,
        excluding: Set<String> = [],
        roadProgress: RoadProgress? = nil
    ) -> [POIFeature] {
        guard tankMeters.isFinite, tankMeters > 0, !fuels.isEmpty else { return [] }
        let ab = roadProgress?.originRemainingMeters ?? GeoMath.meters(from, to)
        guard ab.isFinite, ab > 0 else { return [] }

        struct Cand {
            var fuel: POIFeature
            var graphMeters: Double
            var progress: Double
            var crossTrack: Double
            var coherent: Bool
        }
        let excludedStations = Set(excluding.map(physicalStationID))
        var cands: [Cand] = []
        cands.reserveCapacity(fuels.count)
        for fuel in fuels {
            if excludedStations.contains(physicalStationID(fuel.id)) { continue }
            guard let graph = reachableMeters[fuel.id], graph.isFinite,
                  graph > 0
            else { continue }
            guard graph <= tankMeters * HopSearchPolicy.fuelMaxTank else { continue }
            let at = RouteCoordinate(longitude: fuel.longitude, latitude: fuel.latitude)
            if let roadProgress, roadProgress.stationRemainingMeters[fuel.id] == nil { continue }
            let progress = roadProgress.map { $0.originRemainingMeters - $0.stationRemainingMeters[fuel.id]! }
                ?? GeoMath.progressAlongAB(from: from, to: to, point: at)
            // Graph reachability is the route corridor. A straight A→B cross-track
            // gate rejects legitimate mountain/highway detours and can erase the
            // only usable fuel chain. Require real progress toward B instead.
            // Range is carried across rider points. A necessary next pump may
            // be nearby or close to the destination; neither creates a new
            // minimum stage length. Ranking still favors useful onward riding,
            // and the caller must prove the actual approach and continuation.
            guard progress.isFinite, progress > 0, progress <= ab
            else { continue }
            let crossTrack = roadProgress == nil ? abs(GeoMath.crossTrackMeters(
                point: at.locationCoordinate,
                lineFrom: from.locationCoordinate,
                to: to.locationCoordinate
            )) : max(0, graph - progress)
            let coherent = roadProgress != nil || !(
                (crossTrack > 50_000 && crossTrack > progress * 0.75)
                    || (progress < max(10_000, ab * 0.18) && crossTrack > 25_000)
            )
            cands.append(Cand(
                fuel: fuel,
                graphMeters: graph,
                progress: progress,
                crossTrack: crossTrack,
                coherent: coherent
            ))
        }
        guard !cands.isEmpty else { return [] }

        return cands.sorted { a, b in
            // Preserve an off-axis pump as a last-resort connectivity fallback,
            // but never rank it above a route-coherent forward pump.
            if a.coherent != b.coherent { return a.coherent }
            let ba = HopSearchPolicy.tankCommitBand(
                graphMeters: a.graphMeters,
                tankMeters: tankMeters,
                usableRangeMeters: usableRangeMeters
            )
            let bb = HopSearchPolicy.tankCommitBand(
                graphMeters: b.graphMeters,
                tankMeters: tankMeters,
                usableRangeMeters: usableRangeMeters
            )
            if ba != bb { return ba < bb }
            if abs(a.crossTrack - b.crossTrack) > 5_000 { return a.crossTrack < b.crossTrack }
            if abs(a.progress - b.progress) > 2_000 { return a.progress > b.progress }
            if abs(a.graphMeters - b.graphMeters) > 2_000 { return a.graphMeters < b.graphMeters }
            let ha = HopSearchPolicy.hash(sessionSeed, Int(a.progress), Int(a.graphMeters))
            let hb = HopSearchPolicy.hash(sessionSeed, Int(b.progress), Int(b.graphMeters))
            if ha != hb { return ha < hb }
            return a.progress > b.progress
        }.map(\.fuel)
    }
}
