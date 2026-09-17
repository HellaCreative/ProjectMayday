import Foundation

/// Process-local prepared graphs keyed by the joined region window.
/// Staged hops and later legs reuse the same IndexedGraph instead of re-hashing
/// and re-indexing a pack that is already resident.
public final class PreparedGraphStore: @unchecked Sendable {
    private let lock = NSLock()
    private var graphs: [String: IndexedGraph] = [:]

    public init() {}

    public func indexed(_ regions: [String], repository: PackRepository,
                        budget: ComputationBudget) throws -> IndexedGraph {
        let key = regions.sorted().joined(separator: "+")
        lock.lock()
        if let hit = graphs[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let built = try Self.build(regions: regions, repository: repository, budget: budget)
        lock.lock()
        graphs[key] = built
        lock.unlock()
        return built
    }

    /// Open and index independent windows concurrently when there are two or more.
    public func indexedWindows(_ windows: [[String]], repository: PackRepository,
                               budget: ComputationBudget) throws -> [IndexedGraph] {
        guard windows.count >= 2 else {
            return try windows.map { try indexed($0, repository: repository, budget: budget) }
        }
        final class Slot: @unchecked Sendable {
            let lock = NSLock()
            var results: [IndexedGraph?]
            var errors: [Error?]
            init(count: Int) {
                results = Array(repeating: nil, count: count)
                errors = Array(repeating: nil, count: count)
            }
        }
        let slot = Slot(count: windows.count)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "dirt.prepared-graph", attributes: .concurrent)
        for (index, window) in windows.enumerated() {
            group.enter()
            queue.async {
                do {
                    let graph = try self.indexed(window, repository: repository, budget: budget)
                    slot.lock.lock(); slot.results[index] = graph; slot.lock.unlock()
                } catch {
                    slot.lock.lock(); slot.errors[index] = error; slot.lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        if let error = slot.errors.compactMap({ $0 }).first { throw error }
        return try slot.results.map { graph in
            guard let graph else { throw RoutingFailure.invalidRequest("prepared window missing") }
            return graph
        }
    }

    private static func build(regions: [String], repository: PackRepository,
                              budget: ComputationBudget) throws -> IndexedGraph {
        let packs = try regions.map {
            try repository.open($0, requireSeams: regions.count > 1, budget: budget)
        }
        guard let first = packs.first else { throw RoutingFailure.missingPacks(regions) }
        let graph: any RoadGraph = packs.count == 1
            ? first.graph
            : try RegionalGraph(packs: packs, budget: budget)
        return try IndexedGraph(graph, budget: budget)
    }
}
