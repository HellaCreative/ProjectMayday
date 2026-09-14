#if DEBUG
import Foundation
import CoreLocation

/// Explicitly enabled diagnostic replay only. Writing full geometry perturbs
/// timing, so these runs must not be presented as performance qualification.
@MainActor
enum FuelCandidateEvidence {
    static func capture(request: FuelChainRequest, station: POIFeature,
        approach: OnDeviceRouter.Result, exit: OnDeviceRouter.Result,
        priorEdgeIDs: Set<String>, exitRetraceMeters: Double, exitCapMeters: Double) {
        guard ProcessInfo.processInfo.environment["DIRT_CAPTURE_REJECTED_FUEL"] == "1",
              RoutingWorkContext.measurement != nil else { return }
        do {
            func object<T: Encodable>(_ value: T) throws -> Any {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            }
            func route(_ value: OnDeviceRouter.Result) throws -> [String: Any] {
                var record: [String: Any] = ["distanceMeters": value.distanceMeters,
                    "reportedBacktrackMeters": value.backtrackMeters,
                    "geometry": value.coordinates.map { [$0.longitude, $0.latitude] },
                    "timedOut": value.searchMeta.timedOut, "debugNote": value.debugNote,
                    "legs": value.legs.map { leg -> [String: Any] in
                        ["edgeID": leg.edgeId, "edgeIndex": leg.edgeIndex as Any? ?? NSNull(),
                         "fromNode": leg.fromNode as Any? ?? NSNull(), "toNode": leg.toNode as Any? ?? NSNull(),
                         "meters": leg.distanceMeters, "surface": leg.surfaceName,
                         "access": leg.accessName, "roadClass": leg.roadClassName,
                         "geometry": leg.coordinates.map { [$0.longitude, $0.latitude] }]
                    }]
                if let token = value.terminalContinuation { record["terminalContinuation"] = try object(token) }
                return record
            }
            let history = priorEdgeIDs.union(approach.edgeIds)
            let output: [String: Any] = ["schema": "dirt-rejected-fuel-evidence.v1",
                "capturedUTC": ISO8601DateFormatter().string(from: Date()),
                "request": try object(request), "stationID": station.id,
                "stationCoordinate": [station.longitude, station.latitude],
                "priorEdgeIDs": priorEdgeIDs.sorted(), "approach": try route(approach), "exit": try route(exit),
                "exitCapMeters": exitCapMeters, "reportedExitRetraceMeters": exitRetraceMeters,
                "collisionLegs": exit.legs.enumerated().compactMap { index, leg -> [String: Any]? in
                    guard history.contains(leg.edgeId) else { return nil }
                    return ["exitLegIndex": index, "edgeID": leg.edgeId, "chargedMeters": leg.distanceMeters,
                        "inPriorHistory": priorEdgeIDs.contains(leg.edgeId),
                        "approachLegIndices": approach.legs.indices.filter { approach.legs[$0].edgeId == leg.edgeId }]
                },
                "caution": "Current rejection measures entire matching-ID legs; this export does not certify exact physical overlap. Diagnostic I/O affects timing."]
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routing-rejected-fuel-evidence")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: file, options: .atomic)
            RoutingDebugLog.shared.event("rejected fuel evidence=\(file.path) station=\(station.id) diagnosticTiming=true")
        } catch {
            RoutingDebugLog.shared.event("rejected fuel evidence export failed: \(error)")
        }
    }
}
#endif
