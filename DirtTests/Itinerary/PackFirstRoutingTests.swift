import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@MainActor
@Suite(.serialized)
struct PackFirstRoutingTests {
    private let halifax = RouteCoordinate(longitude: -63.5752, latitude: 44.6488)
    private let sydney = RouteCoordinate(longitude: -60.1942, latitude: 46.1368)
    private let fredericton = RouteCoordinate(longitude: -66.6431, latitude: 45.9636)

    @Test func installedPacksAreSelectedWhileOnline() {
        let live = NamedFakeRoutingSource(name: "live")
        let pack = NamedFakeRoutingSource(name: "pack")
        let policy = RoutingSourcePolicy(
            isOnline: { true },
            installedPacks: FakePackCoverage(installed: ["ns"], published: ["ns"]),
            live: live,
            pack: pack
        )
        let selected = policy.select(for: nsRequest())
        #expect(selected.name == "pack")
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
        #expect(prompt.message.contains("Download"))
        #expect(prompt.message.contains("without an internet connection"))
    }

    @Test func ontarioPinFallsBackToMonolithicOnWhenHalvesAbsent() {
        let toronto = CLLocationCoordinate2D(latitude: 43.6532, longitude: -79.3832)
        let coverage = FakePackCoverage(installed: [], published: ["on", "ns", "qc"])
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [toronto],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected download consent for legacy on, got \(decision)")
            return
        }
        #expect(prompt.kind == .download)
        #expect(prompt.regionIDs == ["on"])
        #expect(prompt.regionTitles == ["Ontario"])
    }

    @Test func ontarioPinPrefersPublishedHalvesOverParent() {
        let toronto = CLLocationCoordinate2D(latitude: 43.6532, longitude: -79.3832)
        let coverage = FakePackCoverage(installed: [], published: ["on-s", "on-n"])
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [toronto],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected download consent for on-s, got \(decision)")
            return
        }
        #expect(prompt.regionIDs == ["on-s"])
    }

    @Test func pinOutsidePartialONCatalogIsUnavailableNotSilent() {
        let coverage = FakePackCoverage(installed: [], published: ["on-s", "on-n"])
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [halifax.locationCoordinate],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .unavailable(let warning) = decision else {
            Issue.record("expected unavailable for NS on ON-only catalog, got \(decision)")
            return
        }
        #expect(warning.reason == .packUnavailable)
        #expect(warning.regionIDs == ["ns"])
    }

    @Test func resolveCatalogRegionIdMapsHalfToParent() {
        #expect(
            GraphPackStore.resolveCatalogRegionId("on-s", published: ["on", "qc"]) == "on"
        )
        #expect(
            GraphPackStore.resolveCatalogRegionId("on-n", published: ["on-s", "on-n"]) == "on-n"
        )
        #expect(
            GraphPackStore.resolveCatalogRegionId("ns", published: ["on"]) == nil
        )
    }

    @Test func resolveCatalogRegionIdMapsParentToPublishedHalf() {
        let kenora = CLLocationCoordinate2D(latitude: 49.797954, longitude: -94.662943)
        let toronto = CLLocationCoordinate2D(latitude: 43.6532, longitude: -79.3832)
        let published: Set<String> = ["on-s", "on-n", "qc-s", "qc-n"]
        #expect(
            GraphPackStore.resolveCatalogRegionId(
                "on",
                published: published,
                coordinate: kenora
            ) == "on-n"
        )
        #expect(
            GraphPackStore.resolveCatalogRegionId(
                "on",
                published: published,
                coordinate: toronto
            ) == "on-s"
        )
        // Without a coordinate, parent stays unresolved on half-only fabrics.
        #expect(
            GraphPackStore.resolveCatalogRegionId("on", published: published) == nil
        )
    }

    @Test func texasQuarterOwnershipAndCatalogAcquisitionStayTogether() {
        let published: Set<String> = ["tx-ne", "tx-nw", "tx-se", "tx-sw", "nm", "ok", "ar", "la"]
        let examples: [(Double, Double, String)] = [
            (-97.7431, 30.2672, "tx-sw"), (-95.3698, 29.7604, "tx-se"),
            (-96.797, 32.777, "tx-ne"), (-101.831, 35.222, "tx-nw"),
            (-97.25, 31, "tx-ne"), (-97.251, 30.999, "tx-sw"),
            (-97.249, 30.999, "tx-se"), (-97.251, 31.001, "tx-nw")
        ]
        for (lon, lat, expected) in examples {
            let point = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            #expect(GraphPackStore.primaryRegionId(containing: point) == expected)
            #expect(GraphPackStore.resolveCatalogRegionId("tx", published: published, coordinate: point) == expected)
            #expect(GraphPackStore.resolveCatalogRegionId(expected, published: ["tx"], coordinate: point) == "tx")
            #expect(GraphPackStore.provinceFamily(expected) == "tx")
        }
        let points = examples.prefix(2).map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) }
        let required = GraphPackStore.requiredCatalogRoutingRegions(for: points, published: published)
        #expect(required.contains("tx-sw"))
        #expect(required.contains("tx-se"))
        #expect(!required.contains("tx"))
        #expect(!GraphPackStore.endpointsCrossProvince(points))
    }

    @Test func halfOnlyFabricResolvesParentPrimaryAtKenora() {
        let nearHalifax = CLLocationCoordinate2D(latitude: 44.7648, longitude: -63.3402)
        let kenora = CLLocationCoordinate2D(latitude: 49.797954, longitude: -94.662943)
        let published: Set<String> = [
            "ns", "nb", "pe", "qc-s", "qc-n", "on-s", "on-n", "mb"
        ]
        // Force the parent id through resolve even if polygons already return on-n.
        #expect(
            GraphPackStore.resolveCatalogRegionId(
                "on",
                published: published,
                coordinate: kenora
            ) == "on-n"
        )
        let catalog = GraphPackStore.requiredCatalogRoutingRegions(
            for: [nearHalifax, kenora],
            published: published
        )
        #expect(catalog.contains("ns"))
        #expect(catalog.contains("on-n"))
        #expect(catalog.contains("nb"))
        #expect(catalog.contains("qc-s") || catalog.contains("qc-n"))
        #expect(!catalog.contains("on"))
        #expect(!catalog.contains("qc"))

        let coverage = FakePackCoverage(installed: ["ns", "nb", "qc-s"], published: published)
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [nearHalifax, kenora],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected on-n download consent after NS/NB/QC installed, got \(decision)")
            return
        }
        #expect(prompt.regionIDs.contains("on-n"))
        #expect(!prompt.regionIDs.contains("on"))
    }

    @Test func halfOnlyFabricMapsAllSplitParentsToPublishedHalves() {
        let published = fabricV4_20260917_02PublishedIds
        let samples: [(String, CLLocationCoordinate2D, String)] = [
            ("on", CLLocationCoordinate2D(latitude: 49.80, longitude: -94.66), "on-n"),
            ("on", CLLocationCoordinate2D(latitude: 43.65, longitude: -79.38), "on-s"),
            ("qc", CLLocationCoordinate2D(latitude: 45.50, longitude: -73.57), "qc-s"),
            ("qc", CLLocationCoordinate2D(latitude: 58.10, longitude: -68.40), "qc-n"),
            ("ca", CLLocationCoordinate2D(latitude: 32.83, longitude: -117.27), "ca-s"),
            ("ca", CLLocationCoordinate2D(latitude: 40.80, longitude: -124.16), "ca-n"),
            ("nl", CLLocationCoordinate2D(latitude: 47.56, longitude: -52.71), "nl-island"),
            ("nl", CLLocationCoordinate2D(latitude: 53.30, longitude: -60.33), "nl-lab")
        ]
        for (parent, coordinate, half) in samples {
            #expect(
                GraphPackStore.resolveCatalogRegionId(
                    parent,
                    published: published,
                    coordinate: coordinate
                ) == half,
                "\(parent) @ \(coordinate.latitude),\(coordinate.longitude)"
            )
            #expect(published.contains(half))
            #expect(!published.contains(parent))
        }
    }

    @Test func halfOnlyFabricCorridorsForQC_CA_NLNeverUseParents() {
        let published = fabricV4_20260917_02PublishedIds
        let corridors: [([CLLocationCoordinate2D], Set<String>, Set<String>)] = [
            (
                [
                    CLLocationCoordinate2D(latitude: 44.65, longitude: -63.57), // ns
                    CLLocationCoordinate2D(latitude: 58.10, longitude: -68.40)  // qc-n
                ],
                ["ns", "qc-n"],
                ["qc", "on", "nl"]
            ),
            (
                [
                    CLLocationCoordinate2D(latitude: 45.50, longitude: -73.57), // qc-s
                    CLLocationCoordinate2D(latitude: 47.56, longitude: -52.71)  // nl-island
                ],
                ["qc-s", "nl-island"],
                ["qc", "nl", "on"]
            ),
            (
                [
                    CLLocationCoordinate2D(latitude: 32.83, longitude: -117.27), // ca-s
                    CLLocationCoordinate2D(latitude: 40.80, longitude: -124.16)  // ca-n
                ],
                ["ca-s", "ca-n"],
                ["ca"]
            ),
            (
                [
                    CLLocationCoordinate2D(latitude: 36.17, longitude: -115.14), // nv
                    CLLocationCoordinate2D(latitude: 32.83, longitude: -117.27)  // ca-s
                ],
                ["nv", "ca-s"],
                ["ca"]
            )
        ]
        for (points, mustContain, mustExclude) in corridors {
            let catalog = GraphPackStore.requiredCatalogRoutingRegions(
                for: points,
                published: published
            )
            #expect(!catalog.isEmpty)
            for id in mustContain { #expect(catalog.contains(id), "missing \(id) in \(catalog)") }
            for id in mustExclude { #expect(!catalog.contains(id), "parent \(id) leaked in \(catalog)") }

            let decision = PackAcquisitionEvaluator.decide(
                coordinates: points,
                registry: FakePackCoverage(installed: [], published: published),
                declinedDownloads: [],
                declinedUpdates: [],
                protectInstalledRevisions: false
            )
            guard case .requestConsent(let prompt) = decision else {
                Issue.record("expected download consent for \(points), got \(decision)")
                continue
            }
            for id in mustExclude {
                #expect(!prompt.regionIDs.contains(id))
            }
        }
    }

    @Test func remapGeographicRegionIdsDropsCoveringParentsOnHalfOnlyFabric() {
        let published = fabricV4_20260917_02PublishedIds
        let kenora = CLLocationCoordinate2D(latitude: 49.80, longitude: -94.66)
        // Covering bboxes emit both halves and legacy parents.
        let geographic = ["on-n", "on", "mb", "qc", "qc-n"]
        let remapped = GraphPackStore.remapGeographicRegionIds(
            geographic,
            coordinate: kenora,
            published: published
        )
        #expect(remapped.needed.contains("on-n"))
        #expect(remapped.needed.contains("mb"))
        #expect(!remapped.needed.contains("on"))
        #expect(!remapped.needed.contains("qc"))
        #expect(remapped.unpublished.isEmpty)
    }

    @Test func onlinePlanningWaitsForPackConsentThenResumesTheSamePins() async {
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
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "plan"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.packConsent?.regionIDs == ["ns"])
        #expect(model.activeRouteProgressMessage == nil)
        #expect(model.fuelPlanningStatus == nil)
        #expect(model.itinerary.waypoints.count == 2)
        #expect(live.routeRequests.isEmpty)
        #expect(pack.routeRequests.isEmpty)
        #expect(coverage.installCalls.isEmpty)
        await model.acceptPackConsent()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.packConsent == nil)
        #expect(coverage.installCalls == [["ns"]])
        #expect(!pack.routeRequests.isEmpty)
        #expect(live.routeRequests.isEmpty)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [halifax,sydney])
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

    @Test func decliningDownloadPreservesPinsWithoutCallingEitherRouter() async {
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
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "plan"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.packConsent != nil)
        model.declinePackConsent()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.packConsent == nil)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [halifax,sydney])
        #expect(coverage.installCalls.isEmpty)
        #expect(live.routeRequests.isEmpty)
        #expect(pack.routeRequests.isEmpty)
    }

    @Test func unavailableRequiredPackStopsWithoutNetworkRouting() async {
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
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "plan"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.packConsent == nil)
        #expect(model.activeRouteProgressMessage == nil)
        #expect(model.fuelPlanningStatus == nil)
        #expect(model.errorMessage?.contains("not available") == true)
        #expect(live.routeRequests.isEmpty)
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
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "plan"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.packConsent?.kind == .update)
        model.declinePackConsent()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.packConsent == nil)
        #expect(coverage.installed.contains("ns"))
        #expect(coverage.stale.contains("ns"))
        #expect(coverage.installCalls.isEmpty)
        #expect(live.routeRequests.isEmpty)
        #expect(!pack.routeRequests.isEmpty)
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
        #expect(rows.map(\.id) == rows.map { $0.id.lowercased() })
        #expect(rows.allSatisfy { $0.canDelete && $0.canDownload == false })
        #expect(rows.first { $0.id == "pe" }?.revisionState == .stale)
        #expect(rows.first { $0.id == "pe" }?.revisionLabel.contains("installed") == true)
    }

    @Test func decliningDownloadOnlyBlocksUntilPinsChange() {
        let coverage = FakePackCoverage(installed: [], published: ["ns"])
        let coordinator = PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        let decision = coordinator.evaluate(
            coordinates: [halifax.locationCoordinate, sydney.locationCoordinate],
            protectInstalledRevisions: false
        )
        guard case .requestConsent = decision else {
            Issue.record("expected download consent, got \(decision)")
            return
        }
        coordinator.declineConsent()
        #expect(coordinator.declinedDownloads.contains("ns"))

        // New pin set (replaceAll/clear) forgets "Not now".
        coordinator.clearDownloadDeclines()
        #expect(coordinator.declinedDownloads.isEmpty)

        let again = coordinator.evaluate(
            coordinates: [halifax.locationCoordinate, sydney.locationCoordinate],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = again else {
            Issue.record("expected download consent after clear, got \(again)")
            return
        }
        #expect(prompt.regionIDs == ["ns"])
    }

    @Test func deletingPackClearsDownloadDecline() {
        let coverage = FakePackCoverage(installed: [], published: ["ns", "nb"])
        let coordinator = PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        _ = coordinator.evaluate(
            coordinates: [halifax.locationCoordinate, fredericton.locationCoordinate],
            protectInstalledRevisions: false
        )
        coordinator.declineConsent()
        #expect(coordinator.declinedDownloads.contains("ns"))
        #expect(coordinator.declinedDownloads.contains("nb"))

        coordinator.notePackRemoved("ns")
        #expect(!coordinator.declinedDownloads.contains("ns"))
        #expect(coordinator.declinedDownloads.contains("nb"))
    }

    @Test func catalogRefreshPreservesInFlightVerifiedRegions() {
        let busy = Set(["nb", "qc"])
        let scanned = Set(["ns"])
        let live = Set(["nb", "pe"])
        let merged = GraphPackStore.mergeVerifiedRegions(
            scanned: scanned,
            live: live,
            managementInFlight: busy
        )
        #expect(merged == Set(["ns", "nb"]))
    }

    @Test func canadaToCanadaCorridorPrefersCanadianProvincesOverUS() {
        let nearHalifax = CLLocationCoordinate2D(latitude: 44.7648, longitude: -63.3402)
        // Whistler / Duffey Lake area — same west pin Richard used.
        let nearWhistler = CLLocationCoordinate2D(latitude: 50.3463, longitude: -122.8234)
        let published = fabricV4_20260917_02PublishedIds

        let catalog = GraphPackStore.requiredCatalogRoutingRegions(
            for: [nearHalifax, nearWhistler],
            published: published
        )
        #expect(catalog.contains("ns"))
        #expect(catalog.contains("bc"))
        #expect(catalog.contains("mb"))
        #expect(catalog.contains("sk"))
        #expect(catalog.contains("ab"))
        #expect(!catalog.contains("nd"))
        #expect(!catalog.contains("mt"))
        #expect(!catalog.contains("mn"))
        #expect(!catalog.contains("wa"))
        #expect(!catalog.contains("on"))
        #expect(!catalog.contains("qc"))

        let path = GraphPackStore.preferredCorridorPath(
            from: "ns",
            to: "bc",
            allowedRegionIds: published
        )
        #expect(path == ["ns", "nb", "qc-s", "on-n", "mb", "sk", "ab", "bc"])

        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [nearHalifax, nearWhistler],
            registry: FakePackCoverage(
                installed: ["ns", "nb", "qc-s", "on-n"],
                published: published
            ),
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected Canadian corridor download consent, got \(decision)")
            return
        }
        #expect(prompt.regionIDs.contains("bc"))
        #expect(prompt.regionIDs.contains("mb"))
        #expect(prompt.regionIDs.contains("sk"))
        #expect(prompt.regionIDs.contains("ab"))
        #expect(!prompt.regionIDs.contains("nd"))
        #expect(!prompt.regionIDs.contains("mt"))
    }

    @Test func crossBorderCorridorMayStillUseUSNeighbours() {
        let vancouver = CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12)
        let seattle = CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33)
        let published = fabricV4_20260917_02PublishedIds
        let catalog = GraphPackStore.requiredCatalogRoutingRegions(
            for: [vancouver, seattle],
            published: published
        )
        #expect(catalog.contains("bc"))
        #expect(catalog.contains("wa"))
    }

    @Test func PEIBridgeAlternativeRequiresNBDespiteADirectFerry() {
        let halifax = CLLocationCoordinate2D(latitude: 44.696743, longitude: -63.485973)
        let charlottetown = CLLocationCoordinate2D(latitude: 46.2382, longitude: -63.1311)
        let roads: [String:Set<String>] = ["ns":["nb"], "nb":["ns","pe"], "pe":["nb"]]
        for points in [[halifax, charlottetown], [charlottetown, halifax]] {
            let required = GraphPackStore.requiredCatalogRoutingRegions(for: points,
                published: ["ns","nb","pe"], roadNeighbors: roads)
            #expect(Set(required) == ["ns","nb","pe"])
        }
    }

    @Test func MarylandPackCoversDistrictOfColumbiaWithoutClaimingVirginia() {
        let washington = CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365)
        let silverSpring = CLLocationCoordinate2D(latitude: 38.9897, longitude: -77.0261)
        let alexandria = CLLocationCoordinate2D(latitude: 38.8048, longitude: -77.0469)
        #expect(RegionPolygons.polygonOwner(longitude: washington.longitude, latitude: washington.latitude) == "md")
        #expect(GraphPackStore.primaryRegionId(containing: washington) == "md")
        #expect(GraphPackStore.primaryRegionId(containing: alexandria) == "va")
        #expect(Set(GraphPackStore.requiredCatalogRoutingRegions(for: [washington, silverSpring],
            published: ["md", "va"])) == ["md"])
        #expect(Set(GraphPackStore.requiredCatalogRoutingRegions(for: [washington, alexandria],
            published: ["md", "va"])) == ["md", "va"])
    }

    @Test func NewfoundlandIslandAndLabradorFollowAdministrativeGeography() {
        for (longitude, latitude, expected) in [
            (-59.137,47.57,"nl-island"), (-57.95,48.95,"nl-island"),
            (-52.713,47.56,"nl-island"), (-55.59,51.37,"nl-island"),
            (-54.285,49.715,"nl-island"), (-56.43,51.73,"nl-lab"), (-60.33,53.30,"nl-lab")
        ] {
            let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            #expect(GraphPackStore.primaryRegionId(containing: point) == expected)
            #expect(GraphPackStore.resolveCatalogRegionId("nl", published: ["nl-island","nl-lab"], coordinate: point) == expected)
        }
    }

    @Test func halfOnlyFabricUsesPublishedShardsForCrossOntarioCorridor() {
        let toronto = CLLocationCoordinate2D(latitude: 43.6532, longitude: -79.3832)
        let kenora = CLLocationCoordinate2D(latitude: 49.8114, longitude: -94.4781)
        let published: Set<String> = [
            "ns", "nb", "pe", "qc-s", "qc-n", "on-s", "on-n", "mb"
        ]
        let path = GraphPackStore.requiredCatalogRoutingRegions(
            for: [toronto, kenora],
            published: published
        )
        #expect(path == ["on-s", "on-n"])
        #expect(!path.contains("on"))
        #expect(!path.contains("qc"))

        let coverage = FakePackCoverage(installed: [], published: published)
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [toronto, kenora],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected on-s/on-n download consent, got \(decision)")
            return
        }
        #expect(prompt.kind == .download)
        #expect(prompt.regionIDs == ["on-s", "on-n"])
    }

    @Test func halfOnlyFabricDoesNotBlockNSToKenoraOnParentQCHop() {
        // From Here GPS in NS → Kenora. Geographic BFS used to hop ns→nb→qc→on-n
        // and then mark `qc` unpublished when only qc-s/qc-n ship.
        let nearHalifax = CLLocationCoordinate2D(latitude: 44.7648, longitude: -63.3402)
        let kenora = CLLocationCoordinate2D(latitude: 49.8114, longitude: -94.4781)
        let published: Set<String> = [
            "ns", "nb", "pe", "qc-s", "qc-n", "on-s", "on-n", "mb"
        ]
        let geographic = GraphPackStore.requiredRoutingRegions(for: [nearHalifax, kenora])
        #expect(geographic.contains("qc") || geographic.contains("on"))

        let catalog = GraphPackStore.requiredCatalogRoutingRegions(
            for: [nearHalifax, kenora],
            published: published
        )
        #expect(catalog.contains("ns"))
        #expect(catalog.contains("nb"))
        #expect(catalog.contains("on-n"))
        #expect(catalog.contains("qc-s") || catalog.contains("qc-n"))
        #expect(!catalog.contains("qc"))
        #expect(!catalog.contains("on"))

        let coverage = FakePackCoverage(installed: ["ns", "nb", "qc-s"], published: published)
        let decision = PackAcquisitionEvaluator.decide(
            coordinates: [nearHalifax, kenora],
            registry: coverage,
            declinedDownloads: [],
            declinedUpdates: [],
            protectInstalledRevisions: false
        )
        guard case .requestConsent(let prompt) = decision else {
            Issue.record("expected download consent for remaining ON/QC shards, got \(decision)")
            return
        }
        #expect(prompt.kind == .download)
        #expect(prompt.regionIDs.contains("on-n"))
        #expect(!prompt.regionIDs.contains("qc"))
    }

    @Test func replaceInstalledFailsClosedWhenRegionMissingFromCatalog() {
        #expect(
            GraphPackStore.shouldReplaceInstalledRevision(
                hasChecksumValidInstalledRevision: true,
                replaceInstalled: true,
                protectInstalledRevisions: false
            )
        )
        #expect(
            GraphPackStore.shouldReplaceInstalledRevision(
                hasChecksumValidInstalledRevision: true,
                replaceInstalled: true,
                protectInstalledRevisions: true
            ) == false
        )
    }

    @Test func packDeletionRemovesOldAndCurrentRevisionsOnlyForRequestedRegion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["old/ns", "current/ns", "old/nb", "current/nb"] {
            let directory = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("graph.v4.bin"))
        }
        try GraphPackStore.removeInstalledRevisions(regionID: "ns", cacheRoot: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old/ns").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("current/ns").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("old/nb/graph.v4.bin").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("current/nb/graph.v4.bin").path))
    }

    @Test func bulkMapRemovalDeletesAllRevisionsAndReportsFailuresWithoutStopping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["old/ns", "current/ns", "current/nb", "current/pe"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            try Data([1]).write(to: root.appendingPathComponent(path + "/graph.v4.bin"))
        }
        var attempted: [String] = []
        let failures = await DownloadedMapsRemoval.remove(["ns", "nb", "pe"]) { id in
            attempted.append(id)
            if id == "nb" { throw CocoaError(.fileWriteNoPermission) }
            try GraphPackStore.removeInstalledRevisions(regionID: id, cacheRoot: root)
        }
        #expect(attempted == ["ns", "nb", "pe"])
        #expect(failures.count == 1 && failures[0].hasPrefix("nb:"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old/ns").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("current/ns").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("current/pe").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("current/nb/graph.v4.bin").path))
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

    @Test func retainingOlderNativeRevisionVerifiesEveryArtifactRatherThanOnlyItsSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["graph": "graph.v4.bin", "geometry": "geometry.v1.bin",
                     "fuel": "fuel.v1.json", "seams": "cross-pack-seams.v2.json"]
        var manifest: [String: Any] = ["schema": "pack-manifest.v2", "regionId": "ns",
            "fabricReleaseId": "older-immutable-release", "sourceEpoch": "fixture-epoch",
            "timezone": "America/Halifax", "capabilities": ["legal-topology.v1", "cross-pack-seams.v2"]]
        // This test exercises installation identity, not native graph decoding.
        let bytes = Data("original immutable artifact".utf8)
        for (key, name) in files {
            try bytes.write(to: directory.appendingPathComponent(name))
            manifest[key] = ["name": name, "bytes": bytes.count,
                "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("pack-manifest.v2.json"))
        #expect(GraphPackStore.nativeRevisionMatchesIdentity(regionID: "ns", directory: directory))
        #expect(!GraphPackStore.nativeRevisionMatchesIdentity(regionID: "nb", directory: directory))
        for name in files.values {
            let file = directory.appendingPathComponent(name)
            var corrupt = bytes
            corrupt[0] ^= 1
            try corrupt.write(to: file)
            let valid = GraphPackStore.nativeRevisionMatchesIdentity(regionID: "ns", directory: directory)
            #expect(!valid, "same-size corruption in \(name) must not be retained")
            #expect(GraphPackStore.shouldReplaceInstalledRevision(hasChecksumValidInstalledRevision: valid,
                replaceInstalled: false, protectInstalledRevisions: false))
            try bytes.write(to: file)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("cross-pack-seams.v2.json"))
        #expect(!GraphPackStore.nativeRevisionMatchesIdentity(regionID: "ns", directory: directory))
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
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
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
            .replaceAll(waypoints: [halifax, sydney], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "fromHere"
        )
        await planModel.waitForCanonicalBuildForTesting()
        await fromModel.waitForCanonicalBuildForTesting()

        #expect(planModel.packConsent?.regionIDs == ["ns"])
        #expect(fromModel.packConsent?.regionIDs == ["ns"])
        #expect(planLive.routeRequests.isEmpty)
        #expect(fromLive.routeRequests.isEmpty)
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

/// Published ids for Dev fabric-v4-20260917-02 (no parent on/qc/ca/nl).
private let fabricV4_20260917_02PublishedIds: Set<String> = [
    "ab", "ak", "al", "ar", "az", "bc", "ca-n", "ca-s", "co", "ct", "de", "fl", "ga", "hi",
    "ia", "id", "il", "in", "ks", "ky", "la", "ma", "mb", "md", "me", "mi", "mn", "mo", "ms",
    "mt", "nb", "nc", "nd", "ne", "nh", "nj", "nl-island", "nl-lab", "nm", "ns", "nt", "nu",
    "nv", "ny", "oh", "ok", "on-n", "on-s", "or", "pa", "pe", "qc-n", "qc-s", "ri", "sc",
    "sd", "sk", "tn", "tx", "ut", "va", "vt", "wa", "wi", "wv", "wy", "yt"
]

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

    func resolveCatalogRegionId(_ regionID: String) -> String? {
        GraphPackStore.resolveCatalogRegionId(regionID, published: published)
    }

    func requiredCatalogRoutingRegions(for coordinates: [CLLocationCoordinate2D]) -> [String] {
        GraphPackStore.requiredCatalogRoutingRegions(for: coordinates, published: published)
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
        case "on": return "Ontario"
        case "on-s": return "Ontario South"
        case "on-n": return "Ontario North"
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
