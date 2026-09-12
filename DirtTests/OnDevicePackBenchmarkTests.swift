import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Real V4 on-device benchmark")
struct OnDevicePackBenchmarkTests {
    private var root: URL {
        if let value = ProcessInfo.processInfo.environment["DIRT_PACK_ROOT"] {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/restriction-release-copy/partial-staging/packs", isDirectory: true)
    }

    private func requireCurrentCandidate(_ regionID: String) throws {
        let url = root.appendingPathComponent("\(regionID)/pack-manifest.v2.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let release = object["fabricReleaseId"] as? String else {
            Issue.record("Missing local pack manifest for \(regionID)")
            return
        }
        #if DIRT_DEVELOPMENT
        #expect(release == AppConfig.v4CandidateReleaseId)
        #endif
    }

    @Test("NS Dirt seam envelope records bounded cancellations")
    func nsDirtSeamEnvelope() throws {
        let graphURL = root.appendingPathComponent("ns/graph.v4.bin")
        let geomURL = root.appendingPathComponent("ns/geometry.v1.bin")
        guard FileManager.default.fileExists(atPath: graphURL.path),
              FileManager.default.fileExists(atPath: geomURL.path) else {
            print("[RealV4] skipped: \(root.path)")
            return
        }
        try requireCurrentCandidate("ns")
        let pack = try GraphV2Pack(data: Data(contentsOf: graphURL))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: geomURL))
        let seamsURL = root.appendingPathComponent("ns/cross-pack-seams.v2.json")
        if FileManager.default.fileExists(atPath: seamsURL.path) {
            try pack.applyCrossPackSeams(data: Data(contentsOf: seamsURL))
        }
        let start = CLLocationCoordinate2D(latitude: 44.764804, longitude: -63.340199)
        let end = CLLocationCoordinate2D(latitude: 47.013162, longitude: -65.244265)
        let candidates = CrossPackSeam.operationalCandidates(
            from: start, to: end,
            anchors: pack.crossPackSeams["nb"] ?? [],
            urbanCores: pack.urbanCores,
            pack: pack
        )
        guard let seam = candidates.first else {
            Issue.record("NS pack has no NB seams")
            return
        }
        print("[RealV4] seam anchor lat=\(seam.latitude) lon=\(seam.longitude) way=\(seam.osmWayId) gap=\(seam.gapMeters)")
        let snapProbe = OnDeviceRouter(pack: pack)
        let seamPoint = CLLocationCoordinate2D(latitude: seam.latitude, longitude: seam.longitude)
        let startSnapText = snapProbe.distanceToNearestRoad(from: start, allowUnknown: false, profile: .dirt).map { String(format: "%.1f", $0) } ?? "nil"
        let seamSnapText = snapProbe.distanceToNearestRoad(from: seamPoint, allowUnknown: false, profile: .dirt).map { String(format: "%.1f", $0) } ?? "nil"
        print("[RealV4] snap start=\(startSnapText)m seam=\(seamSnapText)m")
        // The production path currently supplies a 1.8 s deadline, while the
        // Dirt search itself is allowed a larger bounded envelope. Measure
        // both so a cancellation is not mistaken for a disconnected graph.
        for seconds in [0.4, 0.8, 1.2, 1.8, 3.0, 5.0, 7.0] {
            var router = OnDeviceRouter(pack: pack)
            router.fastSearch = true
            let began = ProcessInfo.processInfo.systemUptime
            router.executionCancelled = {
                ProcessInfo.processInfo.systemUptime - began >= seconds
            }
            let result = router.routeDetailed(
                from: start, to: CLLocationCoordinate2D(latitude: seam.latitude, longitude: seam.longitude),
                profile: .dirt, allowUnknown: false, sessionSeed: 1
            )
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let elapsedText = String(format: "%.3f", elapsed)
            switch result {
            case .success(let route):
                print("[RealV4] dirt-seam budget=\(seconds) result=success elapsed=\(elapsedText) meters=\(Int(route.distanceMeters)) dirt=\(route.reportedDirtPercent)")
            case .failure(let failure):
                print("[RealV4] dirt-seam budget=\(seconds) result=failure elapsed=\(elapsedText) reason=\(failure)")
            }
        }
        for profile in [RouteProfile.cleanest, .balanced, .dirt] {
            var router = OnDeviceRouter(pack: pack)
            router.fastSearch = true
            let began = ProcessInfo.processInfo.systemUptime
            router.executionCancelled = {
                ProcessInfo.processInfo.systemUptime - began >= 7.0
            }
            let result = router.routeDetailed(
                from: start,
                to: CLLocationCoordinate2D(latitude: seam.latitude, longitude: seam.longitude),
                profile: profile,
                allowUnknown: false,
                sessionSeed: 1
            )
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let elapsedText = String(format: "%.3f", elapsed)
            switch result {
            case .success(let route):
                print("[RealV4] profile=\(profile.rawValue) seam7 result=success elapsed=\(elapsedText) meters=\(Int(route.distanceMeters)) dirt=\(route.reportedDirtPercent)")
            case .failure(let failure):
                print("[RealV4] profile=\(profile.rawValue) seam7 result=failure elapsed=\(elapsedText) reason=\(failure)")
            }
        }
    }

    @Test("NS seam candidates expose a legal on-device hop")
    func nsSeamCandidateProbe() throws {
        let graphURL = root.appendingPathComponent("ns/graph.v4.bin")
        let geomURL = root.appendingPathComponent("ns/geometry.v1.bin")
        guard FileManager.default.fileExists(atPath: graphURL.path),
              FileManager.default.fileExists(atPath: geomURL.path) else { return }
        try requireCurrentCandidate("ns")
        let pack = try GraphV2Pack(data: Data(contentsOf: graphURL))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: geomURL))
        let seamsURL = root.appendingPathComponent("ns/cross-pack-seams.v2.json")
        if FileManager.default.fileExists(atPath: seamsURL.path) {
            try pack.applyCrossPackSeams(data: Data(contentsOf: seamsURL))
        }
        let start = CLLocationCoordinate2D(latitude: 44.764804, longitude: -63.340199)
        let end = CLLocationCoordinate2D(latitude: 47.013162, longitude: -65.244265)
        let candidates = CrossPackSeam.operationalCandidates(
            from: start, to: end,
            anchors: pack.crossPackSeams["nb"] ?? [],
            urbanCores: pack.urbanCores,
            pack: pack
        )
        let probe = OnDeviceRouter(pack: pack)
        for (index, anchor) in candidates.prefix(4).enumerated() {
            let point = CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude)
            let snap = probe.distanceToNearestRoad(from: point, allowUnknown: false, profile: .cleanest)
                .map { String(format: "%.1f", $0) } ?? "nil"
            let way = Int64(anchor.osmWayId) ?? -1
            let edgeIndices = pack.osmWayIds.indices.filter { pack.osmWayIds[$0] == way }
            let edgeSummary = edgeIndices.prefix(3).map { ei in
                let a = Int(pack.edgeFrom?[ei] ?? 0)
                let b = Int(pack.edgeTo?[ei] ?? 0)
                let degreeA = a + 1 < pack.nodeOffsets.count ? Int(pack.nodeOffsets[a + 1] - pack.nodeOffsets[a]) : -1
                let degreeB = b + 1 < pack.nodeOffsets.count ? Int(pack.nodeOffsets[b + 1] - pack.nodeOffsets[b]) : -1
                let roadClass = pack.roadClassLeaf(ei) ?? "?"
                return "ei=\(ei) cls=\(roadClass) deg=\(degreeA)/\(degreeB)"
            }.joined(separator: ",")
            print("[RealV4] candidate=\(index) lat=\(anchor.latitude) lon=\(anchor.longitude) way=\(anchor.osmWayId) edges=[\(edgeSummary)]")
            for profile in [RouteProfile.cleanest, .dirt] {
                var router = OnDeviceRouter(pack: pack)
                router.fastSearch = true
                let began = ProcessInfo.processInfo.systemUptime
                router.executionCancelled = {
                    ProcessInfo.processInfo.systemUptime - began >= 1.8
                }
                let result = router.routeDetailed(
                    from: start, to: point, profile: profile, allowUnknown: false, sessionSeed: 1
                )
                let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - began)
                switch result {
                case .success(let route):
                    print("[RealV4] candidate=\(index) profile=\(profile.rawValue) snap=\(snap)m success=\(elapsed)s meters=\(Int(route.distanceMeters))")
                case .failure(let failure):
                    print("[RealV4] candidate=\(index) profile=\(profile.rawValue) snap=\(snap)m failure=\(elapsed)s reason=\(failure)")
                }
            }
        }
    }

    @Test("NS Yarmouth endpoint envelope records profile behavior")
    func nsYarmouthEndpointEnvelope() throws {
        let graphURL = root.appendingPathComponent("ns/graph.v4.bin")
        let geomURL = root.appendingPathComponent("ns/geometry.v1.bin")
        guard FileManager.default.fileExists(atPath: graphURL.path),
              FileManager.default.fileExists(atPath: geomURL.path) else { return }
        try requireCurrentCandidate("ns")
        let pack = try GraphV2Pack(data: Data(contentsOf: graphURL))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: geomURL))
        let start = CLLocationCoordinate2D(latitude: 44.764794, longitude: -63.340257)
        let end = CLLocationCoordinate2D(latitude: 43.807616, longitude: -66.016108)
        for profile in [RouteProfile.cleanest, .balanced, .dirt] {
            for seconds in [1.8, 3.0, 7.0] {
                var router = OnDeviceRouter(pack: pack)
                router.fastSearch = true
                let began = ProcessInfo.processInfo.systemUptime
                router.executionCancelled = {
                    ProcessInfo.processInfo.systemUptime - began >= seconds
                }
                let result = router.routeDetailed(
                    from: start, to: end, profile: profile, allowUnknown: false, sessionSeed: 7
                )
                let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - began)
                switch result {
                case .success(let route):
                    let objective = route.searchMeta.rideObjective ?? "-"
                    let corridor = route.searchMeta.corridorMeters.map { Int($0) } ?? -1
                    print("[RealV4] yarmouth profile=\(profile.rawValue) budget=\(seconds) success=\(elapsed)s meters=\(Int(route.distanceMeters)) dirt=\(route.reportedDirtPercent) pops=\(route.searchMeta.pops) objective=\(objective) corridor=\(corridor)")
                case .failure(let failure):
                    print("[RealV4] yarmouth profile=\(profile.rawValue) budget=\(seconds) failure=\(elapsed)s reason=\(failure)")
                }
            }
        }

        // Sweep the bounded Dirt envelope once. This is the diagnostic that
        // distinguishes a disconnected corridor from a corridor that is
        // simply too narrow; production remains pinned to the selected policy
        // value after the sweep.
        for width in [30_000.0, 40_000.0, 50_000.0, 60_000.0] {
            var router = OnDeviceRouter(pack: pack)
            router.fastSearch = true
            router.fastDirtCorridorMetersOverride = width
            let began = ProcessInfo.processInfo.systemUptime
            router.executionCancelled = {
                ProcessInfo.processInfo.systemUptime - began >= 7.0
            }
            let result = router.routeDetailed(
                from: start, to: end, profile: .dirt, allowUnknown: false, sessionSeed: 7
            )
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - began)
            switch result {
            case .success(let route):
                print("[RealV4] yarmouth corridor=\(Int(width / 1000))km success=\(elapsed)s meters=\(Int(route.distanceMeters)) dirt=\(route.reportedDirtPercent) pops=\(route.searchMeta.pops)")
            case .failure(let failure):
                print("[RealV4] yarmouth corridor=\(Int(width / 1000))km failure=\(elapsed)s reason=\(failure)")
            }
        }
    }

    @Test("NS to NB cross-region route loads a bounded seam proof")
    @MainActor
    func nsToNBCrossRegionUsesCanonicalSeamBeforeDeadline() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("dirt-cross-region-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }
        let versionRoot = tempRoot.appendingPathComponent(
            AppConfig.v4CandidateReleaseId,
            isDirectory: true
        )
        for region in ["ns", "nb"] {
            let destination = versionRoot.appendingPathComponent(region, isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in ["graph.v4.bin", "geometry.v1.bin", "cross-pack-seams.v2.json"] {
                let source = root.appendingPathComponent("\(region)/\(name)")
                guard fm.fileExists(atPath: source.path) else {
                    Issue.record("Missing \(region) \(name) fixture")
                    continue
                }
                try fm.copyItem(at: source, to: destination.appendingPathComponent(name))
            }
        }

        let store = GraphPackStore(cacheRoot: tempRoot)
        let from = CLLocationCoordinate2D(latitude: 44.764830, longitude: -63.340243)
        let to = CLLocationCoordinate2D(latitude: 47.903181, longitude: -66.074515)
        let began = ProcessInfo.processInfo.systemUptime
        let result = await store.routeOnDeviceDetailed(
            from: from,
            to: to,
            profile: .dirt,
            allowUnknown: false,
            fastSearch: true,
            deadline: Date().addingTimeInterval(20)
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        switch result {
        case .success(let route):
            print("[RealV4] NS→NB chained success=\(String(format: "%.3f", elapsed))s meters=\(Int(route.distanceMeters)) dirt=\(route.reportedDirtPercent)")
            #expect(route.distanceMeters > 0)
            #expect(route.coordinates.count > 2)
        case .failure(let failure):
            Issue.record("NS→NB chained route failed after \(String(format: "%.3f", elapsed))s: \(failure)")
        }
    }
}
