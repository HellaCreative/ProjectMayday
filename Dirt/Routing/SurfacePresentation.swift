import Foundation

/// Shared presentation values for live, saved, and native routes.
nonisolated enum SurfaceFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case paved
    case gravel
    case loose
    case unknown
}

/// One rider-facing surface composition shared by map paint and every route
/// summary. Known Dirt is gravel plus loose material; unknown is reported separately.
struct RouteSurfaceComposition: Equatable, Sendable {
    var pavedMeters = 0.0
    var gravelMeters = 0.0
    var looseMeters = 0.0
    var unknownMeters = 0.0

    var totalMeters: Double { pavedMeters + gravelMeters + looseMeters + unknownMeters }
    var dirtMeters: Double { gravelMeters + looseMeters }

    var dirtPercent: Int { percent(dirtMeters) }
    var pavedPercent: Int { percent(pavedMeters) }
    var gravelPercent: Int { percent(gravelMeters) }
    var loosePercent: Int { percent(looseMeters) }
    var unknownPercent: Int { percent(unknownMeters) }

    func meters(for family: SurfaceFamily) -> Double {
        switch family {
        case .paved: pavedMeters
        case .gravel: gravelMeters
        case .loose: looseMeters
        case .unknown: unknownMeters
        }
    }

    mutating func add(meters: Double, family: SurfaceFamily) {
        guard meters.isFinite, meters > 0 else { return }
        switch family {
        case .paved: pavedMeters += meters
        case .gravel: gravelMeters += meters
        case .loose: looseMeters += meters
        case .unknown: unknownMeters += meters
        }
    }

    static func from(responses: [RouteResponse]) -> RouteSurfaceComposition {
        var result = RouteSurfaceComposition()
        for response in responses {
            let segments = response.segments ?? []
            if !segments.isEmpty {
                var segmentResult = RouteSurfaceComposition()
                let usesLeaves = response.stats?.surfaceFamilyMode == "leaf-v3"
                for segment in segments where segment.structureType != "ferry" {
                    let meters = segment.distanceMeters ?? GeoMath.lineMeters(segment.coordinates)
                    segmentResult.add(
                        meters: meters,
                        family: segment.presentationSurfaceFamily(usesSurfaceLeaves: usesLeaves)
                    )
                }
                if segmentResult.totalMeters > 0 {
                    result.pavedMeters += segmentResult.pavedMeters
                    result.gravelMeters += segmentResult.gravelMeters
                    result.looseMeters += segmentResult.looseMeters
                    result.unknownMeters += segmentResult.unknownMeters
                    continue
                }
            }

            // Legacy saved routes have only their two-bucket summary. Preserve
            // the numbers but do not invent a specific non-paved material.
            let meters = response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)
            let paved = max(0, min(100, response.pavedPercent))
            result.add(meters: meters * Double(paved) / 100, family: .paved)
            result.add(meters: meters * Double(100 - paved) / 100, family: .unknown)
        }
        return result
    }

    private func percent(_ meters: Double) -> Int {
        guard totalMeters > 0 else { return 0 }
        return Int((meters / totalMeters * 100).rounded())
    }
}

/// Ferry travel is route distance but not a road surface. Count continuous
/// ferry runs for rider-facing notices while preserving the existing surface
/// denominator exactly.
struct RouteFerrySummary: Equatable, Sendable {
    var crossingCount = 0
    var distanceMeters = 0.0

    var hasCrossing: Bool { crossingCount > 0 }

    static func from(responses: [RouteResponse]) -> RouteFerrySummary {
        var result = RouteFerrySummary()
        for response in responses {
            var isInsideCrossing = false
            for segment in response.segments ?? [] {
                let isFerry = segment.structureType?.lowercased() == "ferry"
                if isFerry {
                    if !isInsideCrossing { result.crossingCount += 1 }
                    let meters = segment.distanceMeters ?? GeoMath.lineMeters(segment.coordinates)
                    if meters.isFinite, meters > 0 { result.distanceMeters += meters }
                }
                isInsideCrossing = isFerry
            }
        }
        return result
    }
}

