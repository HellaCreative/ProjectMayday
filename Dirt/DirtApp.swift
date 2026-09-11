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
                    guard ProcessInfo.processInfo.arguments.contains("--dirt-hybrid-fuel-probe") else { return }
                    await runPrivateHybridFuelProbe(using: appEnvironment)
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
        print("[HybridProbe] begin ns-nb fuel profiles=3 rangeMeters=193121 preparation=active")
        for (profile, profileMeters) in profiles {
            print("[HybridProbe] profile-begin=\(profile.rawValue)")
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
                windowTimeBudgetMs: 20_000,
                mapZoom: 8
            )
            do {
                let response = try await source.fuelChain(request)
                let stops = response.stops?.map(\.id).joined(separator: ",") ?? "-"
                let meters = response.graphMeters?.map { String(format: "%.0f", $0) }.joined(separator: ",") ?? "-"
                let regions = response.regionIds?.joined(separator: ",") ?? "-"
                let window = response.windowComplete.map { $0 ? "complete" : "partial" } ?? "-"
                let gap = response.gapMeters.map { String(format: "%.0f", $0) } ?? "-"
                let seconds = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - began)
                let error = response.error ?? "-"
                print("[HybridProbe] profile=\(profile.rawValue) status=\(response.status) seconds=\(seconds) regions=\(regions) window=\(window) stops=\(stops) graphMeters=\(meters) gapMeters=\(gap) error=\(error)")
            } catch {
                let seconds = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - began)
                print("[HybridProbe] profile=\(profile.rawValue) failure=\(error) seconds=\(seconds)")
            }
        }
        print("[HybridProbe] end")
    }
    #endif
}
