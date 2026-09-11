import Foundation
import CoreLocation

// Diagnostic driver using actual native routing source.
// This first probe covers roads only. Full native fuel orchestration is an
// independent integration gate; road reachability must not be called a fuel proof.
@main
struct NativeWorkloadProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw NSError(domain: "Supply pack directory, region, JSON queries", code: 1) }
        let root = URL(fileURLWithPath: args[1])
        guard Bundle.main.url(forResource: "UrbanSettlements", withExtension: "json") != nil else {
            throw NSError(domain: "Missing native urban metadata", code: 4)
        }
        let began = ProcessInfo.processInfo.systemUptime
        let graphData = try Data(contentsOf: root.appendingPathComponent("graph.v4.bin"), options: .mappedIfSafe)
        let geometryData = try Data(contentsOf: root.appendingPathComponent("geometry.v1.bin"), options: .mappedIfSafe)
        _ = try GraphV4Pack(data: graphData, geometry: geometryData)
        let pack = try GraphV2Pack(data: graphData)
        pack.regionId = args[2]
        pack.geometry = try GeometryV1Pack(data: geometryData)
        let loaded = ProcessInfo.processInfo.systemUptime
        let queries = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [[String: Any]]
        emit(["stage": "loaded", "decodeSeconds": loaded-began,
              "nodes": pack.nodeCount, "edges": pack.undirectedEdgeCount,
              "graphBytes": graphData.count, "geometryBytes": geometryData.count,
              "scope": "macOS diagnostic, not iPhone performance"])
        for q in queries {
            guard q["fuel"] == nil, q["preferences"] == nil, q["waypoints"] == nil, q["arrivalHistory"] == nil else {
                throw NSError(domain: "Road probe does not implement full itinerary contract", code: 2)
            }
            let start = q["start"] as! [Double], end = q["end"] as! [Double], name = q["profile"] as! String
            guard let profile = RouteProfile(rawValue: name == "clean" ? "cleanest" : name) else { throw NSError(domain: "Unknown profile", code: 3) }
            let t = ProcessInfo.processInfo.systemUptime
            let allowUnknown = q["allowUnknown"] as? Bool ?? false
            let deadline = (q["searchBudgetMillis"] as? Double).map { t + $0 / 1000 } ?? .infinity
            let task = Task.detached {
                var router = OnDeviceRouter(pack: pack)
                #if DEVICE_CANCELLATION_PROTOTYPE
                router.executionCancelled = { Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }
                #endif
                return router.routeDetailed(
                    from: CLLocationCoordinate2D(latitude: start[1], longitude: start[0]),
                    to: CLLocationCoordinate2D(latitude: end[1], longitude: end[0]),
                    profile: profile, allowUnknown: allowUnknown, sessionSeed: 1)
            }
            var cancellationAt: Double?
            if let cancelMillis = q["cancelAfterMillis"] as? Double {
                try await Task.sleep(for: .milliseconds(cancelMillis))
                cancellationAt = ProcessInfo.processInfo.systemUptime
                task.cancel()
            }
            let result = await task.value
            var row: [String: Any] = ["query": q, "searchSeconds": ProcessInfo.processInfo.systemUptime-t]
            if let cancellationAt {
                row["cancellationToCompletionSeconds"] = ProcessInfo.processInfo.systemUptime-cancellationAt
                row["taskCancelledFlag"] = task.isCancelled
            }
            #if DEVICE_CANCELLATION_PROTOTYPE
            if task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                // Interrupted search is never a no-path claim or a usable route.
                row["state"] = "incomplete"
                row["reason"] = task.isCancelled ? "cancelled" : "time_budget"
                emit(row)
                continue
            }
            #endif
            switch result {
            case .failure(let reason): row["state"] = "native_failure"; row["reason"] = String(describing: reason)
            case .success(let route):
                row["state"] = "found"; row["distanceMeters"] = route.distanceMeters
                row["knownDirtPercent"] = route.reportedDirtPercent
                row["searchTimedOut"] = route.searchMeta.timedOut
                row["legs"] = route.legs.map { leg -> [String: Any] in
                    ["edgeId": leg.edgeId, "edgeIndex": leg.edgeIndex as Any? ?? NSNull(),
                     "fromNode": leg.fromNode as Any? ?? NSNull(), "toNode": leg.toNode as Any? ?? NSNull(),
                     "meters": leg.distanceMeters, "surface": leg.surfaceName,
                     "coordinates": leg.coordinates.map { [$0.longitude, $0.latitude] }]
                }
            }
            emit(row)
        }
    }
    static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
