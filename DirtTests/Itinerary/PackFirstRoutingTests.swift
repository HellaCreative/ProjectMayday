import CoreLocation
import Foundation
import Testing
@testable import Dirt

@MainActor
@Suite(.serialized)
struct PackFirstRoutingTests {
    private let halifax = RouteCoordinate(longitude: -63.5752, latitude: 44.6488)
    private let sydney = RouteCoordinate(longitude: -60.1942, latitude: 46.1368)
    private let fredericton = RouteCoordinate(longitude: -66.6431, latitude: 45.9636)

    @Test func liveIsSelectedWhileOnlineEvenWhenNSIsInstalled() {
        let live = NamedFakeRoutingSource(name: "live")
        let pack = NamedFakeRoutingSource(name: "pack")
        let policy = RoutingSourcePolicy(
            isOnline: { true },
            installedPacks: FakePackCoverage(installed: ["ns"], published: ["ns"]),
            live: live,
            pack: pack
        )
        let selected = policy.select(for: nsRequest())
        #expect(selected.name == "live")
        #expect(live.routeRequests.isEmpty)
        #expect(pack.routeRequests.isEmpty)
    }

    @Test func installedNSIsSelectedWhileOffline() {
        let live = NamedFakeRoutingSource(name: "live")
        let pack = NamedFakeRoutingSource(name: "pack")
        let policy = RoutingSourcePolicy(
            isOnline: { false },
            installedPacks: FakePackCoverage(installed: ["ns"], published: ["ns"]),
            live: live,
            pack: pack
        )
        #expect(policy.select(for: nsRequest()).name == "pack")
    }

    @Test func missingNSTriggersConsent() {
        let coverage = FakePackCoverage(installed: [], published: ["ns"])
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [halifax.locationCoordinate, sydney.locationCoordinate],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected download consent, got \(decision)")
            return
        }
        #expect(prompt.kind == .download)
        #expect(prompt.regionIDs == ["ns"])
        #expect(prompt.message.contains("improves routing speed"))
        #expect(prompt.message.contains("offline rerouting"))
    }

    @Test func onlinePlanningUsesLiveWithoutWaitingForPackInstall() async {
        let live = NamedFakeRoutingSource(name: "live")
        let pack = NamedFakeRoutingSource(name: "pack")
        let coverage = FakePackCoverage(installed: [], published: ["ns"])
        let coordinator = PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        let policy = RoutingSourcePolicy(
            isOnline: { true },
            installedPacks: coverage,
            live: live,
            pack: pack
        )
        let model = makePackFirstModel(
            live: live, pack: pack, policy: policy, acquisition: coordinator
        )
        model.selectMode(.plan)
        model.apply(
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false),
            source: "plan"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.packConsent == nil)
        #expect(model.itinerary.waypoints.count == 2)
        #expect(live.routeRequests.isEmpty == false)
        #expect(pack.routeRequests.isEmpty)
        #expect(coverage.installCalls.isEmpty)
    }

    @Test func failedPackInstallKeepsConsentAvailableForRetry() async {
        let coverage = FakePackCoverage(installed: [], published: ["ns"])
        coverage.installError = PackAcquisitionError.downloadFailed(
            regionID: "ns", message: "connection lost"
        )
        let coordinator = PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        _ = coordinator.evaluate(
            coordinates: [halifax.locationCoordinate, sydney.locationCoordinate],
            protectInstalledRevisions: false
        )

        do {
            try await coordinator.acceptConsent()
            Issue.record("expected install failure")
        } catch {
            #expect(coordinator.consent?.regionIDs == ["ns"])
            #expect(coverage.installed.isEmpty)
            #expect(coverage.installCalls == [["ns"]])
        }
    }

    @Test func decliningConsentSelectsLiveAndRecordsOfflineWarning() async {
        let live = NamedFakeRoutingSource(name: "live")
        let pack = NamedFakeRoutingSource(name: "pack")
        let coverage = FakePackCoverage(installed: [], published: ["ns"])
        let coordinator = PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        let policy = RoutingSourcePolicy(
            isOnline: { true },
            installedPacks: coverage,
            live: live,
            pack: pack
        )
        let model = makePackFirstModel(
            live: live, pack: pack, policy: policy, acquisition: coordinator
        )
        model.selectMode(.plan)
        model.apply(
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false),
            source: "plan"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.packConsent == nil)
        #expect(coverage.installCalls.isEmpty)
        #expect(live.routeRequests.isEmpty == false)
        #expect(pack.routeRequests.isEmpty)
    }

    @Test func unavailableRequiredPackSelectsLiveAndRecordsUnavailableWarning() async {
        let live = NamedFakeRoutingSource(name: "live")
        let pack = NamedFakeRoutingSource(name: "pack")
        let coverage = FakePackCoverage(installed: [], published: [])
        let coordinator = PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        let policy = RoutingSourcePolicy(
            isOnline: { true },
            installedPacks: coverage,
            live: live,
            pack: pack
        )
        let model = makePackFirstModel(
            live: live, pack: pack, policy: policy, acquisition: coordinator
        )
        model.selectMode(.plan)
        model.apply(
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false),
            source: "plan"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.packConsent == nil)
        #expect(live.routeRequests.isEmpty == false)
        #expect(pack.routeRequests.isEmpty)
        #expect(coverage.installCalls.isEmpty)
    }

    @Test func staleInstalledNSOffersUpdate() {
        let coverage = FakePackCoverage(installed: ["ns"], published: ["ns"], stale: ["ns"])
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [halifax.locationCoordinate],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected update consent, got \(decision)")
            return
        }
        #expect(prompt.kind == .update)
        #expect(prompt.regionIDs == ["ns"])
        #expect(prompt.message.contains("newer approved"))
        #expect(prompt.message.contains("keep using the installed revision"))
    }

    @Test func decliningUpdateRetainsInstalledRevision() async {
        let live = NamedFakeRoutingSource(name: "live")
        let pack = NamedFakeRoutingSource(name: "pack")
        let coverage = FakePackCoverage(installed: ["ns"], published: ["ns"], stale: ["ns"])
        let coordinator = PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        let policy = RoutingSourcePolicy(
            isOnline: { true },
            installedPacks: coverage,
            live: live,
            pack: pack
        )
        let model = makePackFirstModel(
            live: live, pack: pack, policy: policy, acquisition: coordinator
        )
        model.selectMode(.plan)
        model.apply(
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false),
            source: "plan"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.packConsent == nil)
        #expect(coverage.installed.contains("ns"))
        #expect(coverage.stale.contains("ns"))
        #expect(coverage.installCalls.isEmpty)
        #expect(live.routeRequests.isEmpty == false)
        #expect(pack.routeRequests.isEmpty)
    }

    @Test func multiRegionWaypointCoverageRequestsEachRequiredRegionOnce() {
        let coverage = FakePackCoverage(installed: [], published: ["ns", "nb"])
        let extraHalifax = RouteCoordinate(longitude: -63.58, latitude: 44.66)
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [
                halifax.locationCoordinate,
                extraHalifax.locationCoordinate,
                fredericton.locationCoordinate
            ],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected download consent, got \(decision)")
            return
        }
        #expect(prompt.regionIDs == ["ns", "nb"])
        #expect(Set(prompt.regionIDs).count == prompt.regionIDs.count)
    }

    @Test func packsInterfacePermitsDeletionWithoutManualDownload() {
        #expect(OfflinePacksSheet.allowsManualDownload == false)
        let rows = GraphPackStore.managementRows(from: [
            GraphPackStore.RegionInfo(
                id: "ns",
                title: "Nova Scotia",
                subtitle: "OSM · Canada",
                approxBytes: 12_000_000,
                install: .installed,
                exactBytes: 12_000_000,
                country: .canada,
                revisionState: .current
            ),
            GraphPackStore.RegionInfo(
                id: "nb",
                title: "New Brunswick",
                subtitle: "OSM · Canada",
                approxBytes: 8_000_000,
                install: .available,
                country: .canada
            ),
            GraphPackStore.RegionInfo(
                id: "pe",
                title: "Prince Edward Island",
                subtitle: "OSM · Canada",
                approxBytes: 3_000_000,
                install: .installed,
                exactBytes: 3_000_000,
                country: .canada,
                revisionState: .stale
            )
        ])
        #expect(rows.map(\.id) == ["ns", "pe"])
        #expect(rows.allSatisfy { $0.canDelete && $0.canDownload == false })
        #expect(rows.first { $0.id == "pe" }?.revisionState == .stale)
        #expect(rows.first { $0.id == "pe" }?.revisionLabel.contains("installed") == true)
    }

    @Test func checksumMismatchHandlingRemainsFailClosed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirt-pack-fail-closed-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("approved pack bytes".utf8).write(to: url)
        #expect(!GraphPackStore.fileMatchesIdentity(
            at: url,
            expectedBytes: 19,
            expectedSHA256: String(repeating: "0", count: 64)
        ))
        #expect(
            GraphPackStore.shouldReplaceInstalledRevision(
                hasChecksumValidInstalledRevision: true,
                replaceInstalled: false,
                protectInstalledRevisions: true
            ) == false
        )
    }

    @Test func fromHereAndPlanUseTheSameAcquisitionWorkflow() async {
        let coverage = FakePackCoverage(installed: [], published: ["ns"])
        let planCoordinator = PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        let planLive = NamedFakeRoutingSource(name: "live")
        let planPack = NamedFakeRoutingSource(name: "pack")
        let planModel = makePackFirstModel(
            live: planLive,
            pack: planPack,
            policy: RoutingSourcePolicy(
                isOnline: { true },
                installedPacks: coverage,
                live: planLive,
                pack: planPack
            ),
            acquisition: planCoordinator
        )
        planModel.selectMode(.plan)
        planModel.apply(
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false),
            source: "plan"
        )

        let fromCoverage = FakePackCoverage(installed: [], published: ["ns"])
        let fromCoordinator = PackAcquisitionCoordinator(inspect: fromCoverage, installer: fromCoverage)
        let fromLive = NamedFakeRoutingSource(name: "live")
        let fromPack = NamedFakeRoutingSource(name: "pack")
        let fromModel = makePackFirstModel(
            live: fromLive,
            pack: fromPack,
            policy: RoutingSourcePolicy(
                isOnline: { true },
                installedPacks: fromCoverage,
                live: fromLive,
                pack: fromPack
            ),
            acquisition: fromCoordinator
        )
        fromModel.apply(
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false),
            source: "fromHere"
        )
        await planModel.waitForCanonicalBuildForTesting()
        await fromModel.waitForCanonicalBuildForTesting()

        #expect(planModel.packConsent == nil)
        #expect(fromModel.packConsent == nil)
        #expect(planLive.routeRequests.isEmpty == false)
        #expect(fromLive.routeRequests.isEmpty == false)
        #expect(planPack.routeRequests.isEmpty)
        #expect(fromPack.routeRequests.isEmpty)
        #expect(planModel.itinerary.waypoints.count == 2)
        #expect(fromModel.itinerary.waypoints.count == 2)
    }
}

@MainActor
private func makePackFirstModel(
    live: NamedFakeRoutingSource,
    pack: NamedFakeRoutingSource,
    policy: RoutingSourcePolicy,
    acquisition: PackAcquisitionCoordinator
) -> RoutePlannerModel {
    RoutePlannerModel(
        routing: RoutingClient(),
        locationService: LocationService(),
        mapState: MapState(),
        navigation: NavigationSession(),
        offline: OfflineTileManager(),
        graphPacks: GraphPackStore(),
        network: NetworkPathMonitor(),
        routingSourcePolicy: policy,
        itineraryBuilder: ItineraryBuilder(),
        packAcquisition: acquisition
    )
}

private func nsRequest() -> RouteRequest {
    RouteRequest(
        profile: .dirt,
        locations: [
            RouteLocation(latitude: 44.6488, longitude: -63.5752, label: "A"),
            RouteLocation(latitude: 46.1368, longitude: -60.1942, label: "B")
        ],
        allowUnknown: false
    )
}

@MainActor
private final class FakePackCoverage: PackCoverageInspecting, PackInstalling {
    var installed: Set<String>
    var published: Set<String>
    var stale: Set<String>
    var installCalls: [[String]] = []
    var replacedInstalled: [Bool] = []
    var installError: Error?
    let routingManifestVersion = "test-manifest"

    init(installed: Set<String>, published: Set<String>, stale: Set<String> = []) {
        self.installed = installed
        self.published = published
        self.stale = stale
    }

    func isRoutingPackInstalled(_ regionID: String) -> Bool {
        installed.contains(regionID.lowercased())
    }

    func installedRoutingGraphPath(regionID: String) -> String? {
        isRoutingPackInstalled(regionID) ? "/fake/\(regionID)/graph.v2.bin" : nil
    }

    func isRoutingPackPublished(_ regionID: String) -> Bool {
        published.contains(regionID.lowercased())
    }

    func packRevisionState(_ regionID: String) -> PackRevisionState {
        let id = regionID.lowercased()
        if stale.contains(id), installed.contains(id) { return .stale }
        if installed.contains(id) { return .current }
        return .missing
    }

    func displayTitle(forRegionId id: String) -> String {
        switch id.lowercased() {
        case "ns": return "Nova Scotia"
        case "nb": return "New Brunswick"
        case "pe": return "Prince Edward Island"
        default: return id.uppercased()
        }
    }

    func installVerifiedPacks(_ regionIDs: [String], replaceInstalled: Bool) async throws {
        installCalls.append(regionIDs)
        replacedInstalled.append(replaceInstalled)
        if let installError { throw installError }
        for id in regionIDs {
            installed.insert(id.lowercased())
            stale.remove(id.lowercased())
        }
    }
}

@MainActor
private final class NamedFakeRoutingSource: RoutingSource {
    let name: String
    var routeRequests: [RouteRequest] = []

    init(name: String) {
        self.name = name
    }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        routeRequests.append(req)
        let from = req.locations[0]
        let to = req.locations[1]
        let start = RouteCoordinate(longitude: from.longitude, latitude: from.latitude)
        let end = RouteCoordinate(longitude: to.longitude, latitude: to.latitude)
        return RouteResponse(
            status: "complete", error: nil, message: nil,
            distanceMeters: 100_000,
            estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
            geometry: [start, end], segments: nil,
            stats: RouteStats(dirtPercent: 80, pavedPercent: 20, unknownAccessPercent: 0),
            maneuvers: nil, warnings: nil,
            dirtPercentValue: nil, pavedPercentValue: nil,
            backtrackMeters: 0, backtrackPct: 0, backtrackReason: nil,
            restrictedMeters: 0, restrictedReason: nil
        )
    }

    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: ["ns"],
            stops: [], graphMeters: [100_000],
            diagnostics: FuelChainDiagnostics(
                strategy: "fake", states: 1, dijkstraPops: 1, matchedFuel: 0, elapsedMs: 1
            )
        )
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        nil
    }
}
