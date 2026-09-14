import Foundation

/// One calculation-owned optional accelerator. A positive result still needs
/// the actual legal arrival-aware route; a negative is a completed relaxed
/// graph proof for this station only. Never retains an unbounded station list.
@MainActor
final class DestinationFuelScreen {
    enum Failure: Error { case sourceChanged }
    private let identity: String
    private let currentIdentity: () -> String
    private let examine: (POIFeature) async throws -> Bool

    init(identity: String, currentIdentity: @escaping () -> String,
         examine: @escaping (POIFeature) async throws -> Bool) {
        self.identity = identity
        self.currentIdentity = currentIdentity
        self.examine = examine
    }

    func validate() throws {
        try RoutingWorkContext.check()
        guard identity == currentIdentity() else { throw Failure.sourceChanged }
    }

    func allows(_ station: POIFeature) async throws -> Bool {
        try validate()
        let result = try await examine(station)
        try validate()
        return result
    }
}
