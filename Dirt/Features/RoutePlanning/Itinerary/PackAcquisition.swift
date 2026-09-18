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
        case download
        case update
    }

    let kind: Kind
    let regionIDs: [String]
    let regionTitles: [String]

    var title: String {
        switch kind {
        case .download:
            return regionIDs.count == 1 ? "Install routing pack" : "Install routing packs"
        case .update:
            return regionIDs.count == 1 ? "Update routing pack" : "Update routing packs"
        }
    }

    var message: String {
        let names = PackAcquisitionEvaluator.joinedTitles(regionTitles)
        switch kind {
        case .download:
            return "Download \(names) once to create and reroute rides on your device without an internet connection."
        case .update:
            return "A newer approved \(names) pack is available. Updating is recommended. You can keep using the installed revision."
        }
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
            return "Download \(names) before calculating this ride. Your rider points are preserved."
        case .packUnavailable:
            return "A routing pack for \(names) is not available. This ride cannot be calculated yet; your points are preserved."
        }
    }
}

enum PackAcquisitionDecision: Equatable, Sendable {
    case useInstalledPacks
    case requestConsent(PackConsentPrompt)
    case unavailable(PackRoutingWarning)
}

@MainActor
protocol PackCoverageInspecting: RoutingInstalledPackRegistry {
    func isRoutingPackPublished(_ regionID: String) -> Bool
    /// Maps a geographic primary (e.g. `on-s`) onto a catalog id that is actually
    /// published (`on-s`, or legacy parent `on` when halves are absent).
    func resolveCatalogRegionId(_ regionID: String) -> String?
    /// Corridor packs for these pins using only published catalog ids (halves,
    /// never an unpublished parent hop like `qc` when only `qc-s`/`qc-n` ship).
    func requiredCatalogRoutingRegions(for coordinates: [CLLocationCoordinate2D]) -> [String]
    func packRevisionState(_ regionID: String) -> PackRevisionState
    func displayTitle(forRegionId: String) -> String
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
        GraphPackStore.requiredRoutingRegions(for: coordinates)
    }

    static func decide(
        coordinates: [CLLocationCoordinate2D],
        registry: any PackCoverageInspecting,
        declinedDownloads: Set<String>,
        declinedUpdates: Set<String>,
        protectInstalledRevisions: Bool
    ) -> PackAcquisitionDecision {
        let titles = { (ids: [String]) in ids.map { registry.displayTitle(forRegionId: $0) } }

        let geographicPrimaries = coordinates.compactMap {
            GraphPackStore.primaryRegionId(containing: $0)
        }
        if geographicPrimaries.isEmpty {
            return .unavailable(PackRoutingWarning(
                regionIDs: [],
                regionTitles: ["this pin"],
                reason: .packUnavailable
            ))
        }

        // Do not resolve primaries in isolation without coordinates: a parent id
        // (`on`) is unpublished on half-only fabrics but still maps to `on-n` /
        // `on-s` for the pin. Corridor mapping below is coordinate-aware.
        let needed = registry.requiredCatalogRoutingRegions(for: coordinates)
        if needed.isEmpty {
            return .unavailable(PackRoutingWarning(
                regionIDs: geographicPrimaries,
                regionTitles: titles(geographicPrimaries),
                reason: .packUnavailable
            ))
        }

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
                regionTitles: titles(pendingDownload)
            ))
        }

        if !missingApproved.isEmpty {
            return .unavailable(PackRoutingWarning(
                regionIDs: missingApproved,
                regionTitles: titles(missingApproved),
                reason: .declinedDownload
            ))
        }

        if !stale.isEmpty, !protectInstalledRevisions {
            return .requestConsent(PackConsentPrompt(
                kind: .update,
                regionIDs: stale,
                regionTitles: titles(stale)
            ))
        }

        let covered = needed.allSatisfy { registry.isRoutingPackInstalled($0) }
        if covered { return .useInstalledPacks }
        return .unavailable(PackRoutingWarning(
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
        case .unavailable(let warning):
            record(warning)
        case .useInstalledPacks:
            break
        }
        return result
    }

    func acceptConsent() async throws {
        guard let prompt = consent else { return }
        consent = nil
        RoutingDebugLog.shared.event(
            "pack install accepted regions=\(prompt.regionIDs.joined(separator: ",")) " +
                "kind=\(prompt.kind == .update ? "update" : "download")"
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

    /// "Not now" only skips the current pending build. A new pin set should
    /// be allowed to ask again for missing packs.
    func clearDownloadDeclines() {
        declinedDownloads = []
        warnings.removeAll { $0.reason == .declinedDownload }
    }

    /// Layers Delete wiped a pack the rider previously declined to download.
    /// Forget that decline so the next route-touch can prompt again.
    func notePackRemoved(_ regionID: String) {
        let id = regionID.lowercased()
        declinedDownloads.remove(id)
        declinedUpdates.remove(id)
        warnings.removeAll { $0.regionIDs.contains(id) }
    }

    private func record(_ warning: PackRoutingWarning) {
        warnings.removeAll { $0.id == warning.id }
        warnings.append(warning)
    }
}
