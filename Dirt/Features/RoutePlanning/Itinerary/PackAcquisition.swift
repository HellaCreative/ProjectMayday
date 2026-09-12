import CoreLocation
import Foundation
import Observation

enum PackRevisionState: String, Equatable, Sendable {
    case missing
    case current
    case stale
}

enum PackAcquisitionError: LocalizedError, Equatable {
    case checksumMismatch(regionID: String)
    case downloadFailed(regionID: String, message: String)
    case unavailable(regionID: String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let regionID):
            return "Downloaded \(regionID) did not match the approved catalog identity."
        case .downloadFailed(let regionID, let message):
            return "Could not install \(regionID): \(message)"
        case .unavailable(let regionID):
            return "No approved pack is available for \(regionID)."
        }
    }
}

struct PackConsentPrompt: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case home
        case download
        case update
    }

    let kind: Kind
    let regionIDs: [String]
    let regionTitles: [String]
    let downloadBytes: Int64?

    var title: String {
        switch kind {
        case .home:
            return regionIDs.count == 1 ? "Install your home routing pack" : "Install your home routing packs"
        case .download:
            return regionIDs.count == 1 ? "Install routing pack" : "Install routing packs"
        case .update:
            return regionIDs.count == 1 ? "Update routing pack" : "Update routing packs"
        }
    }

    var message: String {
        let names = PackAcquisitionEvaluator.joinedTitles(regionTitles)
        let size = downloadBytes.map { " (\(Self.byteLabel($0)))" } ?? ""
        switch kind {
        case .home:
            return "Download \(names) now\(size) so route planning and offline rerouting stay on this phone."
        case .download:
            let duration = regionIDs.count > 2
                ? " Routes across more than two regions can take about 110 seconds to 3 minutes on this phone."
                : ""
            let count = regionIDs.count > 1 ? "\(regionIDs.count) routing packs: " : ""
            return "Installing \(count)\(names)\(size) improves routing speed and enables offline rerouting.\(duration)"
        case .update:
            return "A newer approved \(names) pack is available\(size). Updating is recommended. You can keep using the installed revision."
        }
    }

    private static func byteLabel(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1_000 {
            return String(format: "%.1f GB", megabytes / 1_000)
        }
        return megabytes >= 10
            ? String(format: "%.0f MB", megabytes)
            : String(format: "%.1f MB", megabytes)
    }
}

struct PackRoutingWarning: Equatable, Identifiable, Sendable {
    enum Reason: Equatable, Sendable {
        case declinedDownload
        case packUnavailable
    }

    let id: String
    let regionIDs: [String]
    let regionTitles: [String]
    let reason: Reason

    init(regionIDs: [String], regionTitles: [String], reason: Reason) {
        self.regionIDs = regionIDs
        self.regionTitles = regionTitles
        self.reason = reason
        id = reason == .declinedDownload
            ? "declined:" + regionIDs.joined(separator: ",")
            : "unavailable:" + regionIDs.joined(separator: ",")
    }

    var message: String {
        let names = PackAcquisitionEvaluator.joinedTitles(regionTitles)
        switch reason {
        case .declinedDownload:
            return "Offline rerouting will not be available for \(names)."
        case .packUnavailable:
            return "\(names) is not available as an approved pack. Offline rerouting will not be available for this region."
        }
    }
}

enum PackAcquisitionDecision: Equatable, Sendable {
    case useInstalledPacks
    case requestConsent(PackConsentPrompt)
    case useLive(PackRoutingWarning)
}

@MainActor
protocol PackCoverageInspecting: RoutingInstalledPackRegistry {
    func isRoutingPackPublished(_ regionID: String) -> Bool
    func packRevisionState(_ regionID: String) -> PackRevisionState
    func displayTitle(forRegionId: String) -> String
    func packDownloadBytes(forRegionId: String) -> Int64?
}

extension PackCoverageInspecting {
    func packDownloadBytes(forRegionId: String) -> Int64? { nil }
}

@MainActor
protocol PackInstalling: AnyObject {
    func installVerifiedPacks(_ regionIDs: [String], replaceInstalled: Bool) async throws
}

enum PackAcquisitionEvaluator {
    static func joinedTitles(_ titles: [String]) -> String {
        switch titles.count {
        case 0: return "this region"
        case 1: return titles[0]
        case 2: return "\(titles[0]) and \(titles[1])"
        default:
            return titles.dropLast().joined(separator: ", ") + ", and \(titles.last ?? "")"
        }
    }

    static func requiredRegionIDs(
        for coordinates: [CLLocationCoordinate2D]
    ) -> [String] {
        var ordered = GraphPackStore.regionIds(containingAny: coordinates)
        func append(_ ids: [String]) {
            for id in ids where !ordered.contains(id) {
                ordered.append(id)
            }
        }
        guard coordinates.count >= 2 else { return ordered }

        // Waypoints are not the route geometry yet. Sample each straight
        // waypoint span so a long plan asks for the regional packs along its
        // corridor instead of only the endpoint packs. The eventual route
        // build remains authoritative for road continuity and detours.
        for pair in zip(coordinates, coordinates.dropFirst()) {
            let from = pair.0
            let to = pair.1
            let span = GeoMath.meters(from, to)
            let steps = min(64, max(2, Int(ceil(span / 100_000))))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let point = CLLocationCoordinate2D(
                    latitude: from.latitude + (to.latitude - from.latitude) * t,
                    longitude: from.longitude + (to.longitude - from.longitude) * t
                )
                append(GraphPackStore.regionIds(containingAny: [point]))
            }
        }
        return ordered
    }

    static func decide(
        coordinates: [CLLocationCoordinate2D],
        registry: any PackCoverageInspecting,
        declinedDownloads: Set<String>,
        declinedUpdates: Set<String>,
        protectInstalledRevisions: Bool
    ) -> PackAcquisitionDecision {
        let needed = requiredRegionIDs(for: coordinates)
        let titles = { (ids: [String]) in ids.map { registry.displayTitle(forRegionId: $0) } }
        let bytes = { (ids: [String]) -> Int64? in
            let values = ids.compactMap { registry.packDownloadBytes(forRegionId: $0) }
            guard values.count == ids.count else { return nil }
            return values.reduce(0, +)
        }

        if needed.isEmpty {
            return .useLive(PackRoutingWarning(
                regionIDs: [],
                regionTitles: ["this pin"],
                reason: .packUnavailable
            ))
        }

        let unpublished = needed.filter { !registry.isRoutingPackPublished($0) }
        let missingApproved = needed.filter {
            registry.isRoutingPackPublished($0)
                && registry.packRevisionState($0) == .missing
        }
        let stale = needed.filter {
            registry.packRevisionState($0) == .stale
                && !declinedUpdates.contains($0)
        }

        let pendingDownload = missingApproved.filter { !declinedDownloads.contains($0) }
        if !pendingDownload.isEmpty {
            return .requestConsent(PackConsentPrompt(
                kind: .download,
                regionIDs: pendingDownload,
                regionTitles: titles(pendingDownload),
                downloadBytes: bytes(pendingDownload)
            ))
        }

        if !unpublished.isEmpty {
            return .useLive(PackRoutingWarning(
                regionIDs: unpublished,
                regionTitles: titles(unpublished),
                reason: .packUnavailable
            ))
        }

        if !missingApproved.isEmpty {
            return .useLive(PackRoutingWarning(
                regionIDs: missingApproved,
                regionTitles: titles(missingApproved),
                reason: .declinedDownload
            ))
        }

        if !stale.isEmpty, !protectInstalledRevisions {
            return .requestConsent(PackConsentPrompt(
                kind: .update,
                regionIDs: stale,
                regionTitles: titles(stale),
                downloadBytes: bytes(stale)
            ))
        }

        let covered = needed.allSatisfy { registry.isRoutingPackInstalled($0) }
        if covered { return .useInstalledPacks }
        return .useLive(PackRoutingWarning(
            regionIDs: needed,
            regionTitles: titles(needed),
            reason: .packUnavailable
        ))
    }
}

@Observable
@MainActor
final class PackAcquisitionCoordinator {
    private(set) var consent: PackConsentPrompt?
    private(set) var warnings: [PackRoutingWarning] = []
    private(set) var declinedDownloads: Set<String> = []
    private(set) var declinedUpdates: Set<String> = []
    private var offeredHomeRegionIDs: Set<String> = []

    private let inspect: any PackCoverageInspecting
    private let installer: any PackInstalling

    init(inspect: any PackCoverageInspecting, installer: any PackInstalling) {
        self.inspect = inspect
        self.installer = installer
    }

    convenience init(store: GraphPackStore) {
        self.init(inspect: store, installer: store)
    }

    func decision(
        for coordinates: [CLLocationCoordinate2D],
        protectInstalledRevisions: Bool
    ) -> PackAcquisitionDecision {
        PackAcquisitionEvaluator.decide(
            coordinates: coordinates,
            registry: inspect,
            declinedDownloads: declinedDownloads,
            declinedUpdates: declinedUpdates,
            protectInstalledRevisions: protectInstalledRevisions
        )
    }

    func evaluate(
        coordinates: [CLLocationCoordinate2D],
        protectInstalledRevisions: Bool
    ) -> PackAcquisitionDecision {
        let result = decision(
            for: coordinates,
            protectInstalledRevisions: protectInstalledRevisions
        )
        switch result {
        case .requestConsent(let prompt):
            consent = prompt
        case .useLive(let warning):
            record(warning)
        case .useInstalledPacks:
            break
        }
        return result
    }

    /// Offer the pack for the rider's current region once per app session. The
    /// route planner still asks separately for every additional region in a
    /// multi-region route.
    func offerHomePack(at coordinate: CLLocationCoordinate2D) {
        guard consent == nil,
              let regionID = GraphPackStore.primaryRegionId(containing: coordinate),
              !offeredHomeRegionIDs.contains(regionID),
              inspect.isRoutingPackPublished(regionID),
              inspect.packRevisionState(regionID) == .missing
        else { return }
        offeredHomeRegionIDs.insert(regionID)
        consent = PackConsentPrompt(
            kind: .home,
            regionIDs: [regionID],
            regionTitles: [inspect.displayTitle(forRegionId: regionID)],
            downloadBytes: inspect.packDownloadBytes(forRegionId: regionID)
        )
        RoutingDebugLog.shared.event(
            "home pack offer region=\(regionID) bytes=\(inspect.packDownloadBytes(forRegionId: regionID).map(String.init) ?? "unknown")"
        )
    }

    func acceptConsent() async throws {
        guard let prompt = consent else { return }
        consent = nil
        RoutingDebugLog.shared.event(
            "pack install accepted regions=\(prompt.regionIDs.joined(separator: ",")) " +
                "kind=\(prompt.kind == .home ? "home" : (prompt.kind == .update ? "update" : "download"))"
        )
        do {
            try await installer.installVerifiedPacks(
                prompt.regionIDs,
                replaceInstalled: prompt.kind == .update
            )
        } catch {
            // A failed transfer is not a declined decision. Restore the exact
            // prompt so the rider can retry and the pending route is preserved.
            consent = prompt
            RoutingDebugLog.shared.event(
                "pack install failed regions=\(prompt.regionIDs.joined(separator: ",")) " +
                    "message=\(error.localizedDescription)"
            )
            throw error
        }
        RoutingDebugLog.shared.event(
            "pack install complete regions=\(prompt.regionIDs.joined(separator: ","))"
        )
    }

    func declineConsent() {
        guard let prompt = consent else { return }
        consent = nil
        switch prompt.kind {
        case .home:
            declinedDownloads.formUnion(prompt.regionIDs)
            record(PackRoutingWarning(
                regionIDs: prompt.regionIDs,
                regionTitles: prompt.regionTitles,
                reason: .declinedDownload
            ))
        case .download:
            declinedDownloads.formUnion(prompt.regionIDs)
            record(PackRoutingWarning(
                regionIDs: prompt.regionIDs,
                regionTitles: prompt.regionTitles,
                reason: .declinedDownload
            ))
        case .update:
            declinedUpdates.formUnion(prompt.regionIDs)
        }
    }

    func resetSession() {
        consent = nil
        warnings = []
        declinedDownloads = []
        declinedUpdates = []
    }

    private func record(_ warning: PackRoutingWarning) {
        warnings.removeAll { $0.id == warning.id }
        warnings.append(warning)
    }
}
