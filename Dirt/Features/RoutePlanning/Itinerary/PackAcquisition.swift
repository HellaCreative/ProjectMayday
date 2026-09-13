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
    case catalogNotReady

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let regionID):
            return "Downloaded \(regionID) did not match the approved catalog identity."
        case .downloadFailed(let regionID, let message):
            return "Could not install \(regionID): \(message)"
        case .catalogNotReady:
            return "Routing pack information is not ready. Check your connection and try again; your pins have been kept."
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
    var downloadBytes: Int64? = nil

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
            let size = downloadBytes.map { " Download size: " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + "." } ?? ""
            return "Download \(names) to calculate this ride on your phone and keep the routing data available offline." + size
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
    func requiresRoutingCatalogReadiness(for regionIDs: [String]) -> Bool
    func prepareRoutingCatalog(for regionIDs: [String]) async throws
    func isRoutingPackPublished(_ regionID: String) -> Bool
    func packRevisionState(_ regionID: String) -> PackRevisionState
    func displayTitle(forRegionId: String) -> String
    func routingPackDownloadBytes(_ regionID: String) -> Int64?
}

extension PackCoverageInspecting {
    func requiresRoutingCatalogReadiness(for regionIDs: [String]) -> Bool { false }
    func prepareRoutingCatalog(for regionIDs: [String]) async throws { try Task.checkCancellation() }
    func routingPackDownloadBytes(_ regionID: String) -> Int64? { nil }
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
        GraphPackStore.requiredRoutingRegionIDs(for: coordinates)
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

        let unpublished = needed.filter { !registry.isRoutingPackInstalled($0) && !registry.isRoutingPackPublished($0) }
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
                downloadBytes: pendingDownload.compactMap { registry.routingPackDownloadBytes($0) }.count == pendingDownload.count
                    ? pendingDownload.compactMap { registry.routingPackDownloadBytes($0) }.reduce(0, +) : nil
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

    private(set) var installationPrompt: PackConsentPrompt?
    @ObservationIgnored private var installationTask: Task<Void, Error>?
    @ObservationIgnored private var installationID: UUID?
    var isInstalling: Bool { installationPrompt != nil }

    private let inspect: any PackCoverageInspecting
    private let installer: any PackInstalling

    init(inspect: any PackCoverageInspecting, installer: any PackInstalling) {
        self.inspect = inspect
        self.installer = installer
    }

    convenience init(store: GraphPackStore) {
        self.init(inspect: store, installer: store)
    }

    func requiresCatalogReadiness(for coordinates: [CLLocationCoordinate2D]) -> Bool {
        inspect.requiresRoutingCatalogReadiness(for: PackAcquisitionEvaluator.requiredRegionIDs(for: coordinates))
    }

    func prepareCatalog(for coordinates: [CLLocationCoordinate2D]) async throws {
        try await inspect.prepareRoutingCatalog(for: PackAcquisitionEvaluator.requiredRegionIDs(for: coordinates))
        try Task.checkCancellation()
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
        guard installationTask == nil, let prompt = consent else { return }
        let id = UUID()
        consent = nil
        installationID = id
        installationPrompt = prompt
        let task = Task { @MainActor [installer] in
            try Task.checkCancellation()
            try await installer.installVerifiedPacks(prompt.regionIDs, replaceInstalled: prompt.kind == .update)
            try Task.checkCancellation()
        }
        installationTask = task
        RoutingDebugLog.shared.event("pack install accepted regions=\(prompt.regionIDs.joined(separator: ","))")
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard installationID == id else { throw CancellationError() }
            installationTask = nil
            installationPrompt = nil
            installationID = nil
            RoutingDebugLog.shared.event("pack install complete regions=\(prompt.regionIDs.joined(separator: ","))")
        } catch {
            guard installationID == id else { throw CancellationError() }
            installationTask = nil
            installationPrompt = nil
            installationID = nil
            // Cancellation and failed verification preserve the request for retry.
            consent = prompt
            RoutingDebugLog.shared.event("pack install incomplete regions=\(prompt.regionIDs.joined(separator: ",")) message=\(error.localizedDescription)")
            throw error
        }
    }

    func cancelInstallation(offerRetry: Bool = true) {
        let prompt = installationPrompt
        installationTask?.cancel()
        installationTask = nil
        installationID = nil
        installationPrompt = nil
        if offerRetry, let prompt { consent = prompt }
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
        cancelInstallation(offerRetry: false)
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
