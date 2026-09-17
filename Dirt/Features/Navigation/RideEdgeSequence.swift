import Foundation

/// Snapshot offered after End navigation for opt-in edge-id contribution.
struct RideContributionCandidate: Equatable, Sendable, Identifiable {
    var id: String { "\(edgeIds.count)-\(edgeIds.first ?? "")-\(edgeIds.last ?? "")-\(Int(distanceMeters))" }
    let edgeIds: [String]
    let distanceMeters: Double
    let startedAt: Date?
}

/// GPS line captured during navigation — what the rider actually rode.
struct RiddenRouteSaveCandidate: Equatable, Sendable, Identifiable {
    let id: UUID
    let coordinates: [RouteCoordinate]
    let distanceMeters: Double
    let profile: RouteProfile
    let suggestedName: String

    init(
        id: UUID = UUID(),
        coordinates: [RouteCoordinate],
        distanceMeters: Double,
        profile: RouteProfile,
        suggestedName: String
    ) {
        self.id = id
        self.coordinates = coordinates
        self.distanceMeters = distanceMeters
        self.profile = profile
        self.suggestedName = suggestedName
    }

    static func suggestedName(startedAt: Date? = nil, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return "Ride · \(formatter.string(from: startedAt ?? now))"
    }
}

/// Teardown payload after End this ride. Save and contribute stay independent.
struct NavigationEndPayload: Equatable, Sendable {
    let contribution: RideContributionCandidate?
    let riddenSave: RiddenRouteSaveCandidate?
}

/// Post-ride UI: save the GPS ride, then maybe a Profile contribute nudge.
enum PostRidePrompt: Identifiable, Equatable {
    case save(RiddenRouteSaveCandidate)
    case contributeNudge

    var id: String {
        switch self {
        case let .save(candidate): "save-\(candidate.id.uuidString)"
        case .contributeNudge: "contribute-nudge"
        }
    }
}

/// Pure helpers: ordered network edge sequences from a completed ride.
/// Stitch IDs are never contributed — they are synthetic connectors, not fabric.
enum RideEdgeSequence {
    struct Span: Equatable, Sendable {
        let edgeId: String
        let startMeters: Double
        let endMeters: Double
    }

    static let maxEdges = 5_000
    static let consentVersion = "track_contrib_v1"

    static func isStitchEdgeId(_ id: String) -> Bool {
        id.hasPrefix("soft-stitch-") || id.hasPrefix("perm-stitch-")
    }

    /// Collapse consecutive duplicates and drop stitch / empty ids. Caps length.
    static func sanitize(_ edgeIds: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(min(edgeIds.count, maxEdges))
        for raw in edgeIds {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !isStitchEdgeId(id) else { continue }
            if out.last == id { continue }
            out.append(id)
            if out.count >= maxEdges { break }
        }
        return out
    }

    static func spans(from segments: [RouteSegment]) -> [Span] {
        var along = 0.0
        var out: [Span] = []
        for seg in segments {
            let meters: Double
            if let d = seg.distanceMeters, d > 0 {
                meters = d
            } else {
                meters = GeoMath.lineMeters(seg.coordinates)
            }
            let start = along
            along += max(0, meters)
            guard let id = seg.edgeId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  !isStitchEdgeId(id)
            else { continue }
            out.append(Span(edgeId: id, startMeters: start, endMeters: along))
        }
        return out
    }

    /// Append spans the rider has entered (≥10 m into the span, or past start on short spans).
    /// First-seen order only (no revisit duplicates) — monthly aggregation wants coverage, not loops.
    static func appendRidden(into ridden: inout [String], spans: [Span], traveledMeters: Double) {
        guard ridden.count < maxEdges else { return }
        var seen = Set(ridden)
        for span in spans {
            guard !seen.contains(span.edgeId) else { continue }
            let length = max(0, span.endMeters - span.startMeters)
            let enterAt = span.startMeters + min(10, length * 0.15)
            guard traveledMeters >= enterAt else { continue }
            ridden.append(span.edgeId)
            seen.insert(span.edgeId)
            if ridden.count >= maxEdges { return }
        }
    }
}
