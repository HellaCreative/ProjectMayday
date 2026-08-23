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
    case unavailable(regionID: String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let regionID):
            return "Downloaded \(regionID) did not match the approved catalog identity."
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
            return "Installing \(names) improves routing speed and enables offline rerouting."
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
        GraphPackStore.regionIds(containingAny: coordinates)
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
                regionTitles: titles(pendingDownload)
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
                regionTitles: titles(stale)
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

    func acceptConsent() async throws {
        guard let prompt = consent else { return }
        consent = nil
        try await installer.installVerifiedPacks(
            prompt.regionIDs,
            replaceInstalled: prompt.kind == .update
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

    private func record(_ warning: PackRoutingWarning) {
        warnings.removeAll { $0.id == warning.id }
        warnings.append(warning)
    }
}
