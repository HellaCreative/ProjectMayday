import SwiftData
import SwiftUI

@main
struct DirtApp: App {
    @State private var appEnvironment = AppEnvironment()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([SavedRoute.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            AppGateView()
                .environment(appEnvironment)
                .preferredColorScheme(.light)
                .task {
                    #if DEBUG
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("--dirt-hybrid-fuel-probe") {
                        await runPrivateHybridFuelProbe(using: appEnvironment)
                    }
                    if arguments.contains("--dirt-on-device-direct-probe") {
                        await runPrivateOnDeviceDirectProbe(using: appEnvironment)
                    }
                    #endif
                }
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == "gpx" else { return }
                    let context = sharedModelContainer.mainContext
                    appEnvironment.planner.importGPX(from: url, context: context)
                    appEnvironment.planner.presentRouteCard = true
                }
        }
        .modelContainer(sharedModelContainer)
    }

    #if DEBUG
    @MainActor
    private func runPrivateHybridFuelProbe(using app: AppEnvironment) async {
        // Verified NS→NB corridor used by the routing-engine benchmark.
        // The endpoint is in north-western New Brunswick, so this exercises
        // the installed-pack seam and the cross-region fuel candidate set.
        let start = RouteCoordinate(longitude: -63.340199, latitude: 44.764804)
        let end = RouteCoordinate(longitude: -65.244265, latitude: 47.013162)
        let profiles: [(RouteProfile, Double)] = [
            // The 390 km planning envelope is the verified NS→NB road
            // distance. Each profile must satisfy the same 120-mile usable
            // range; the route profile may choose a longer dirt corridor.
            (.cleanest, 390_138.634),
            (.dirt, 390_138.634),
            (.balanced, 390_138.634)
        ]
        let source = PackRoutingSource(packs: app.graphPacks, cache: RouteResponseCache())
        func emit(_ message: String) {
            RoutingDebugLog.shared.event("hybrid-probe \(message)")
            print("[HybridProbe] \(message)")
        }
        func summary(
            _ response: FuelChainResponse,
            profile: RouteProfile,
            label: String,
            began: TimeInterval,
            fromStop: String? = nil
        ) -> String {
            let stops = response.stops?.map(\.id).joined(separator: ",") ?? "-"
            let meters = response.graphMeters?.map { String(format: "%.0f", $0) }.joined(separator: ",") ?? "-"
            let regions = response.regionIds?.joined(separator: ",") ?? "-"
            let window = response.windowComplete.map { $0 ? "complete" : "partial" } ?? "-"
            let gap = response.gapMeters.map { String(format: "%.0f", $0) } ?? "-"
            let strategy = response.diagnostics?.strategy ?? "-"
            let matched = response.diagnostics.map { String(describing: $0.matchedFuel) } ?? "-"
            let seconds = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - began)
            let error = response.error ?? "-"
            let origin = fromStop.map { " fromStop=\($0)" } ?? ""
            let loopAudit: String
            if let route = response.routes?.first, let segments = route.segments {
                let pieces = segments.compactMap { segment -> OnDevicePathPruning.EdgePiece? in
                    guard let geometry = segment.geometry, geometry.count >= 2 else { return nil }
                    return OnDevicePathPruning.EdgePiece(
                        edgeId: segment.edgeId ?? "",
                        coords: geometry.map(\.locationCoordinate),
                        meters: segment.distanceMeters ?? 0,
                        surfaceName: segment.surfaceClass ?? "unknown"
                    )
                }
                let audit = OnDevicePathPruning.pruneGeographicLoops(
                    pieces,
                    options: OnDevicePathPruning.Options(
                        cellMeters: 40,
                        matchMeters: 60,
                        minLoopMeters: 100
                    )
                )
                loopAudit = " auditLoops=\(audit.prunedLoopCount) auditLoopMeters=\(Int(audit.prunedMeters))"
            } else {
                loopAudit = ""
            }
            return "profile=\(profile.rawValue) \(label) status=\(response.status) seconds=\(seconds)"
                + " regions=\(regions) window=\(window) strategy=\(strategy) matched=\(matched)"
                + " stops=\(stops) graphMeters=\(meters) gapMeters=\(gap) error=\(error)\(loopAudit)\(origin)"
        }
        let warmupBegan = ProcessInfo.processInfo.systemUptime
        await app.graphPacks.warmupActivePack(near: start.locationCoordinate)
        let warmupSeconds = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - warmupBegan)
        emit("begin ns-nb fuel profiles=3 rangeMeters=193121 preparation=active warmupSeconds=\(warmupSeconds)")
        for (profile, profileMeters) in profiles {
            emit("profile-begin=\(profile.rawValue)")
            let began = ProcessInfo.processInfo.systemUptime
            let request = FuelChainRequest(
                profile: profile,
                from: start,
                to: end,
                allowUnknown: false,
                usableRangeMeters: 193_121.28,
                firstLegMaxMeters: 193_121.28,
                requireFuelStopBeforeEnd: true,
                minimumFuelStops: 1,
                profileMeters: profileMeters,
                riderLegId: "private-device-hybrid-probe",
                windowMaxStops: 1,
                allowPartialWindow: true,
                windowTimeBudgetMs: 20_000,
                mapZoom: 8
            )
            do {
                let response = try await source.fuelChain(request)
                emit(summary(response, profile: profile, label: "window1", began: began))

                // The production itinerary should not attempt a destination
                // proof for every fuel hop. Verify the intended contract
                // directly: begin the next bounded search at the committed
                // pump, exclude that pump, and ask only for the next pump.
                if let stop = response.stops?.first {
                    let window2Began = ProcessInfo.processInfo.systemUptime
                    let window2 = FuelChainRequest(
                        profile: profile,
                        from: stop.coordinate,
                        to: end,
                        allowUnknown: false,
                        usableRangeMeters: 193_121.28,
                        firstLegMaxMeters: 193_121.28,
                        requireFuelStopBeforeEnd: true,
                        minimumFuelStops: 1,
                        profileMeters: profileMeters,
                        riderLegId: "private-device-hybrid-probe-window2",
                        excludedStationIds: [stop.id],
                        windowMaxStops: 1,
                        allowPartialWindow: true,
                        windowTimeBudgetMs: 20_000,
                        mapZoom: 8
                    )
                    do {
                        let second = try await source.fuelChain(window2)
                        emit(summary(
                            second,
                            profile: profile,
                            label: "window2",
                            began: window2Began,
                            fromStop: stop.id
                        ))
                    } catch {
                        let seconds = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - window2Began)
                        emit("profile=\(profile.rawValue) window2 failure=\(error) seconds=\(seconds) fromStop=\(stop.id)")
                    }
                }
            } catch {
                let seconds = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - began)
                emit("profile=\(profile.rawValue) failure=\(error) seconds=\(seconds)")
            }
        }
        emit("end")
    }

    /// Direct pack-only diagnostic for the ordinary (fuel-off) route path.
    /// This deliberately runs the same source call the UI uses, with several
    /// deadlines, so a cross-region Dirt cancellation cannot be mistaken for
    /// a fuel-planner failure.
    @MainActor
    private func runPrivateOnDeviceDirectProbe(using app: AppEnvironment) async {
        let start = RouteCoordinate(longitude: -63.340199, latitude: 44.764804)
        let end = RouteCoordinate(longitude: -65.244265, latitude: 47.013162)
        func emit(_ message: String) {
            RoutingDebugLog.shared.event("direct-probe \(message)")
            print("[DirectProbe] \(message)")
        }
        let warmupBegan = ProcessInfo.processInfo.systemUptime
        await app.graphPacks.warmupActivePack(near: start.locationCoordinate)
        emit("begin fixture=ns-nb profiles=3 warmupSeconds=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - warmupBegan))")
        for profile in [RouteProfile.cleanest, .dirt, .balanced] {
            for seconds in [1.8, 3.0, 5.0] {
                let began = ProcessInfo.processInfo.systemUptime
                let result = await app.graphPacks.routeOnDeviceDetailed(
                    from: start.locationCoordinate,
                    to: end.locationCoordinate,
                    profile: profile,
                    allowUnknown: false,
                    sessionSeed: UInt64.random(in: 1...9_007_199_254_740_991),
                    avoidMotorways: profile == .cleanest,
                    mapZoom: 8,
                    fastSearch: true,
                    deadline: Date().addingTimeInterval(seconds)
                )
                let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - began)
                switch result {
                case .success(let route):
                    emit("profile=\(profile.rawValue) deadline=\(String(format: "%.1f", seconds)) result=success seconds=\(elapsed) meters=\(Int(route.distanceMeters)) dirtPct=\(route.reportedDirtPercent) timedOut=\(route.searchMeta.timedOut ? 1 : 0)")
                case .failure(let failure):
                    emit("profile=\(profile.rawValue) deadline=\(String(format: "%.1f", seconds)) result=failure seconds=\(elapsed) reason=\(failure)")
                }
            }
        }
        emit("end")
    }
    #endif
}
