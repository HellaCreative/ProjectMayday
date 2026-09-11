import Foundation
import CoreLocation
import CryptoKit
import Darwin

func resourceMetrics() -> [String: Any] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let rc = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    var usage = rusage(); let cpuRC = getrusage(RUSAGE_SELF, &usage)
    var row: [String: Any] = ["memoryReadSucceeded": rc == KERN_SUCCESS]
    if rc == KERN_SUCCESS {
        row["physicalFootprintMiB"] = Double(info.phys_footprint)/1_048_576
        row["residentMiB"] = Double(info.resident_size)/1_048_576
    }
    if cpuRC == 0 {
        row["peakResidentMiB"] = Double(usage.ru_maxrss)/1_048_576 // Darwin reports bytes.
        row["cpuSeconds"] = Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
        row["pageFaults"] = usage.ru_majflt; row["pageReclaims"] = usage.ru_minflt
        row["inputBlocks"] = usage.ru_inblock; row["outputBlocks"] = usage.ru_oublock
    }
    return row
}

func coordinate(_ location: RouteLocation) -> RouteCoordinate {
    RouteCoordinate(longitude: location.longitude, latitude: location.latitude)
}
// Metadata shim for a deliberately single-installed-region diagnostic.
enum GraphPackStore {
    static func regionIds(containingAny: [CLLocationCoordinate2D]) -> [String] { ["ns"] }
}
func emit(_ value: [String: Any]) {
    var measured = value
    if value["stage"] as? String != "match" { measured["resources"] = resourceMetrics() }
    let data = try! JSONSerialization.data(withJSONObject: measured, options: .sortedKeys)
    FileHandle.standardOutput.write(data + Data([10]))
}
func encoded<T: Encodable>(_ value: T) -> Any {
    try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
func ll(_ point: CLLocationCoordinate2D) -> [Double] { [point.longitude, point.latitude] }

final class FuelProbeBudget: @unchecked Sendable {
    let deadline: UInt64
    init(seconds: Double) {
        precondition(seconds.isFinite && seconds > 0 && seconds <= 300)
        deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + UInt64(seconds * 1_000_000_000)
    }
    var expired: Bool { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) >= deadline }
}

@MainActor final class NativePackFacade {
    let pack: GraphV2Pack
    let stations: [POIFeature]
    let budget: FuelProbeBudget
    var sequence = 0
    init(pack: GraphV2Pack, stations: [POIFeature], budget: FuelProbeBudget) {
        self.pack = pack; self.stations = stations; self.budget = budget
    }
    func fuelStations(from start: RouteCoordinate, to end: RouteCoordinate) -> [POIFeature] {
        let pad = 150_000.0 / 111_000.0 // Same prefilter as the installed-pack store.
        return stations.filter {
            $0.latitude >= min(start.latitude, end.latitude) - pad && $0.latitude <= max(start.latitude, end.latitude) + pad
            && $0.longitude >= min(start.longitude, end.longitude) - pad && $0.longitude <= max(start.longitude, end.longitude) + pad
        }
    }
    func fuelAvoidanceBoxes(from: CLLocationCoordinate2D, toward: CLLocationCoordinate2D) async -> [UrbanCore.Box] {
        UrbanCore.fuelAvoidanceBoxes(embeddedCores: pack.urbanCores, embeddedSettlements: pack.settlements, regionId: pack.regionId)
    }
    func shortestGraphMeters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, maxMeters: Double,
                             profile: RouteProfile, allowUnknown: Bool) async -> Double? {
        guard !budget.expired else { return nil }
        let began = ProcessInfo.processInfo.systemUptime, pack = pack, budget = budget
        let result = await Task.detached {
            var router = OnDeviceRouter(pack: pack); router.executionCancelled = { budget.expired }
            return router.shortestGraphMeters(from: from, to: to, maxMeters: maxMeters, profile: profile, allowUnknown: allowUnknown)
        }.value
        emit(["stage": "shortest", "seconds": ProcessInfo.processInfo.systemUptime-began,
              "from": ll(from), "to": ll(to), "meters": result as Any? ?? NSNull(), "expired": budget.expired])
        return budget.expired ? nil : result
    }
    func reachableFuelMeters(from: CLLocationCoordinate2D, toward: CLLocationCoordinate2D, pumps: [POIFeature], maxMeters: Double,
                             profile: RouteProfile, allowUnknown: Bool) async -> [String: Double] {
        guard !budget.expired else { return [:] }
        let began = ProcessInfo.processInfo.systemUptime, pack = pack, budget = budget
        let result = await Task.detached {
            var router = OnDeviceRouter(pack: pack); router.executionCancelled = { budget.expired }
            return router.reachableGraphMeters(from: from, toward: toward, pumps: pumps, maxMeters: maxMeters, profile: profile, allowUnknown: allowUnknown)
        }.value
        emit(["stage": "reachability", "seconds": ProcessInfo.processInfo.systemUptime-began,
              "from": ll(from), "pumps": pumps.count, "reachable": result, "expired": budget.expired,
              "preparation": NativeFuelPreparation.metrics()])
        return budget.expired ? [:] : result
    }
    func routeOnDeviceDetailed(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
        profile: RouteProfile, allowUnknown: Bool, avoidEdgeIds: [String], priorEdgeIds: Set<String>, arrivalEdgeId: String?,
        backtrackFactor: Double, sessionSeed: UInt64, maxRouteMeters: Double?, regionalHopMinimumMeters: [Double],
        cleanMetroMultiplier: Double?, avoidMotorways: Bool, preferBackRoads: Bool,
        startEndpointKind: String?, endEndpointKind: String?) async -> Swift.Result<OnDeviceRouter.Result, OnDeviceRouter.Failure> {
        guard !budget.expired else { return .failure(.searchLimit("probe_time_budget")) }
        // This diagnostic cannot silently ignore a requested multi-region budget.
        guard regionalHopMinimumMeters.isEmpty else { return .failure(.searchLimit("unsupported_regional_minima")) }
        let began = ProcessInfo.processInfo.systemUptime, pack = pack, budget = budget
        let result = await Task.detached {
            var router = OnDeviceRouter(pack: pack)
            router.executionCancelled = { budget.expired }
            router.sessionSeed = sessionSeed
            router.startEndpointKind = startEndpointKind; router.endEndpointKind = endEndpointKind
            return router.routeDetailed(from: from, to: to, profile: profile, allowUnknown: allowUnknown,
                avoidEdgeIds: Set(avoidEdgeIds), priorEdgeIds: priorEdgeIds, arrivalEdgeId: arrivalEdgeId,
                backtrackFactor: backtrackFactor, sessionSeed: sessionSeed, maxRouteMeters: maxRouteMeters,
                cleanMetroMultiplier: cleanMetroMultiplier, avoidMotorways: avoidMotorways, preferBackRoads: preferBackRoads)
        }.value
        sequence += 1
        var row: [String: Any] = ["stage": "road", "trace": sequence, "searchSeconds": ProcessInfo.processInfo.systemUptime-began,
            "query": ["start": ll(from), "end": ll(to), "profile": profile.rawValue, "allowUnknown": allowUnknown,
                      "priorEdgeIds": priorEdgeIds.sorted(), "arrivalEdgeId": arrivalEdgeId as Any? ?? NSNull(),
                      "startEndpointKind": startEndpointKind as Any? ?? NSNull(), "endEndpointKind": endEndpointKind as Any? ?? NSNull(),
                      "maxMeters": maxRouteMeters as Any? ?? NSNull()]]
        switch result {
        case .failure(let reason): row["state"] = "native_failure"; row["reason"] = String(describing: reason)
        case .success(let route):
            row["state"] = "found"; row["distanceMeters"] = route.distanceMeters; row["knownDirtPercent"] = route.reportedDirtPercent
            row["searchTimedOut"] = route.searchMeta.timedOut
            row["legs"] = route.legs.map { leg -> [String: Any] in
                ["edgeId": leg.edgeId, "edgeIndex": leg.edgeIndex as Any? ?? NSNull(),
                 "fromNode": leg.fromNode as Any? ?? NSNull(), "toNode": leg.toNode as Any? ?? NSNull(),
                 "meters": leg.distanceMeters, "surface": leg.surfaceName,
                 "coordinates": leg.coordinates.map { [$0.longitude, $0.latitude] }]
            }
        }
        if budget.expired { row["state"] = "incomplete"; row["reason"] = "time_budget"; row.removeValue(forKey: "legs") }
        emit(row)
        return budget.expired ? .failure(.searchLimit("probe_time_budget")) : result
    }
}

@main struct NativeFuelProbe {
    @MainActor static func main() async throws {
        var args = CommandLine.arguments
        let diagnostic = args.count == 5 && ["--matches", "--fixture-matches", "--roads"].contains(args[1]) ? args.remove(at: 1) : nil
        if args.count == 4, args[1] == "--audit" {
            let input = try Data(contentsOf: URL(fileURLWithPath: args[3]))
            var payload = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            let root = URL(fileURLWithPath: args[2])
            let data = try Data(contentsOf: root.appendingPathComponent("graph.v4.bin"))
            let geometry = try Data(contentsOf: root.appendingPathComponent("geometry.v1.bin"))
            let fuelData = try Data(contentsOf: root.appendingPathComponent("fuel.v1.json"))
            _ = try GraphV4Pack(data: data, geometry: geometry)
            let pack = try GraphV2Pack(data: data)
            pack.geometry = try GeometryV1Pack(data: geometry)
            let identity = SHA256.hash(data: data + geometry).map { String(format: "%02x", $0) }.joined()
            let fuelIdentity = SHA256.hash(data: fuelData).map { String(format: "%02x", $0) }.joined()
            payload["knownFuel"] = PackedFuel.decode(fuelData).map { ["id": $0.id, "point": [$0.longitude, $0.latitude]] as [String: Any] }
            let began = ProcessInfo.processInfo.systemUptime
            var result = NativeFuelContinuity.check(pack: pack, identity: identity, fuelIdentity: fuelIdentity, payload: payload)
            result["validationSeconds"] = ProcessInfo.processInfo.systemUptime - began
            emit(result)
            return
        }
        guard args.count == 4 else { throw RoutingError.server("Supply NS pack dir, fixture JSON and seconds") }
        let root = URL(fileURLWithPath: args[1])
        let began = ProcessInfo.processInfo.systemUptime
        let graph = try Data(contentsOf: root.appendingPathComponent("graph.v4.bin"), options: .mappedIfSafe)
        let geometry = try Data(contentsOf: root.appendingPathComponent("geometry.v1.bin"), options: .mappedIfSafe)
        let fuel = try Data(contentsOf: root.appendingPathComponent("fuel.v1.json"))
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard diagnostic == "--fixture-matches" || (sha(graph) == "91a10b490918531de330b9bcd2209de1708a4beb50625bfab4969e59e23d551d" &&
              sha(geometry) == "b4ee898537829666f3825ff50e3bff2a73f9b423a558ffde814a1abdd75649ac" &&
              sha(fuel) == "62b9baf355740619f48f64938bfdfee4d447ed8ba4d2a4d65d3d2ecb513ee549") else { throw RoutingError.server("NS identity mismatch") }
        _ = try GraphV4Pack(data: graph, geometry: geometry)
        let pack = try GraphV2Pack(data: graph); pack.regionId = "ns"; pack.geometry = try GeometryV1Pack(data: geometry)
        let stations = PackedFuel.decode(fuel)
        guard !stations.isEmpty else { throw RoutingError.server("Invalid fuel fixture") }
        if diagnostic == "--matches" || diagnostic == "--fixture-matches" {
            let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
            let profile = RouteProfile(rawValue: spec["profile"] as! String)!
            let budget = FuelProbeBudget(seconds: Double(args[3])!)
            var router = OnDeviceRouter(pack: pack); router.executionCancelled = { budget.expired }
            emit(["stage": "loaded", "decodeSeconds": ProcessInfo.processInfo.systemUptime-began, "stations": stations.count])
            if let cancelSeconds = spec["cancelFirstSeconds"] as? Double {
                let stop = FuelProbeBudget(seconds: cancelSeconds), began = ProcessInfo.processInfo.systemUptime
                router.executionCancelled = { stop.expired }
                for station in stations {
                    _ = router.diagnosticFuelMatches(to: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude), profile: profile, allowUnknown: false)
                    if stop.expired { break }
                }
                emit(["stage": "planned_stop", "state": "incomplete", "seconds": ProcessInfo.processInfo.systemUptime-began,
                      "expired": stop.expired, "preparation": NativeFuelPreparation.metrics()])
                router.executionCancelled = { budget.expired }
            }
            for pass in 0..<(spec["passes"] as? Int ?? 2) {
                let began = ProcessInfo.processInfo.systemUptime
                for station in stations {
                    let matches = router.diagnosticFuelMatches(to: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude), profile: profile, allowUnknown: false)
                    if budget.expired { emit(["stage": "incomplete", "reason": "matching_budget", "preparation": NativeFuelPreparation.metrics()]); return }
                    emit(["stage": "match", "pass": pass, "id": station.id, "matches": matches])
                }
                emit(["stage": "pass", "pass": pass, "seconds": ProcessInfo.processInfo.systemUptime-began, "preparation": NativeFuelPreparation.metrics()])
            }
            return
        }
        if diagnostic == "--roads" {
            let queries = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
            let facade = NativePackFacade(pack: pack, stations: stations, budget: FuelProbeBudget(seconds: Double(args[3])!))
            for query in queries {
                let start = query["start"] as! [Double], end = query["end"] as! [Double], name = query["profile"] as! String
                _ = await facade.routeOnDeviceDetailed(from: CLLocationCoordinate2D(latitude: start[1], longitude: start[0]), to: CLLocationCoordinate2D(latitude: end[1], longitude: end[0]),
                    profile: RouteProfile(rawValue: name == "clean" ? "cleanest" : name)!, allowUnknown: false, avoidEdgeIds: [], priorEdgeIds: [], arrivalEdgeId: nil,
                    backtrackFactor: 1, sessionSeed: 1, maxRouteMeters: nil, regionalHopMinimumMeters: [], cleanMetroMultiplier: nil, avoidMotorways: false,
                    preferBackRoads: false, startEndpointKind: nil, endEndpointKind: nil)
            }
            emit(["stage": "preparation", "metrics": NativeFuelPreparation.metrics()]); return
        }
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
        let start = spec["start"] as! [Double], end = spec["end"] as! [Double]
        let profile = RouteProfile(rawValue: spec["profile"] as! String)!
        let range = spec["rangeMeters"] as! Double, first = spec["firstMeters"] as! Double
        guard Set(spec.keys).isSubset(of: ["start", "end", "profile", "rangeMeters", "firstMeters", "profileMeters", "minimumStops", "excludedStationIds"]),
              range.isFinite, first.isFinite, range > 0, first > 0, first <= range,
              Double(args[3])! > 0, Double(args[3])! <= 90 else { throw RoutingError.server("Unsupported fixture contract") }
        var request = FuelChainRequest(profile: profile,
            from: RouteCoordinate(longitude: start[0], latitude: start[1]), to: RouteCoordinate(longitude: end[0], latitude: end[1]),
            allowUnknown: false, usableRangeMeters: range, firstLegMaxMeters: first,
            requireFuelStopBeforeEnd: true, minimumFuelStops: spec["minimumStops"] as? Int ?? 1,
            profileMeters: spec["profileMeters"] as! Double, riderLegId: "private-ns-fuel-probe",
            excludedStationIds: spec["excludedStationIds"] as? [String] ?? [])
        request.options = RouteRequestOptions(sessionSeed: 1)
        emit(["stage": "loaded", "request": encoded(request), "decodeSeconds": ProcessInfo.processInfo.systemUptime-began,
              "fuelStations": stations.count, "scope": "Actual captured native fuel algorithm in a single-region macOS facade, not phone or certified physical fuel access"])
        let budget = FuelProbeBudget(seconds: Double(args[3])!)
        let facade = NativePackFacade(pack: pack, stations: stations, budget: budget)
        let searchBegan = ProcessInfo.processInfo.systemUptime
        let response = try await CapturedNativeFuelPlanner(packs: facade).fuelChain(request)
        emit(["stage": "result", "nativeResponse": encoded(response), "seconds": ProcessInfo.processInfo.systemUptime-searchBegan,
              "state": budget.expired ? "incomplete" : "candidate_requires_continuity_audit", "timeBudgetExpired": budget.expired,
              "routeCalls": facade.sequence, "preparation": NativeFuelPreparation.metrics()])
    }
}
