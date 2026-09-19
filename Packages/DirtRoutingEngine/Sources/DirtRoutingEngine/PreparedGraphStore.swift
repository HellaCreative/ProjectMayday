import Foundation

/// Process-local prepared graphs keyed by the joined region window.
/// Staged hops and later legs reuse the same IndexedGraph instead of re-hashing
/// and re-indexing a pack that is already resident.
public final class PreparedGraphStore: @unchecked Sendable {
    /// Peak parallel prepare slots. Phone RSS is the real limit on multi-hop.
    public static let maxConcurrentPrepares = 2

    private let lock = NSLock()
    private var graphs: [String: IndexedGraph] = [:]
    private var recency: [String] = []
    private let capacity: Int
    public struct Metrics: Sendable {
        public var builds = 0
        public var hits = 0
        public var openSeconds = 0.0
        public var joinSeconds = 0.0
        public var indexSeconds = 0.0
    }
    private var measurements = Metrics()
    public var metrics: Metrics {
        lock.lock(); defer { lock.unlock() }
        return measurements
    }
    /// Keys currently building — waiters block on the condition instead of double-building.
    private var inflight: Set<String> = []
    private let gate = NSCondition()

    public init(capacity: Int = 2) { self.capacity = max(1, capacity) }

    public func key(for regions: [String]) -> String {
        regions.sorted().joined(separator: "+")
    }

    /// Region order determines local road numbering and is part of the identity.
    public func peek(_ regions: [String], repository: PackRepository) throws -> IndexedGraph? {
        let key = try repository.preparationIdentity(regions)
        lock.lock(); defer { lock.unlock() }
        return graphs[key]
    }

    public func indexed(_ regions: [String], repository: PackRepository,
                        budget: ComputationBudget) throws -> IndexedGraph {
        try budget.check()
        let key = try repository.preparationIdentity(regions)
        while true {
            try budget.check()
            lock.lock()
            if let hit = graphs[key] {
                measurements.hits += 1
                recency.removeAll { $0 == key }; recency.append(key)
                lock.unlock()
                return hit
            }
            if inflight.contains(key) {
                lock.unlock()
                gate.lock()
                while true {
                    lock.lock()
                    let ready = graphs[key]
                    let waiting = inflight.contains(key)
                    lock.unlock()
                    if let ready { gate.unlock(); return ready }
                    if !waiting { break }
                    _ = gate.wait(until: Date(timeIntervalSinceNow: 0.05))
                    do { try budget.check() }
                    catch { gate.unlock(); throw error }
                }
                gate.unlock()
                continue
            }
            inflight.insert(key)
            lock.unlock()
            break
        }
        do {
            let built = try build(regions: regions, repository: repository, budget: budget)
            lock.lock()
            graphs[key] = built
            recency.removeAll { $0 == key }; recency.append(key)
            while recency.count > capacity {
                graphs.removeValue(forKey: recency.removeFirst())
            }
            inflight.remove(key)
            lock.unlock()
            gate.lock(); gate.broadcast(); gate.unlock()
            return built
        } catch {
            lock.lock()
            inflight.remove(key)
            lock.unlock()
            gate.lock(); gate.broadcast(); gate.unlock()
            throw error
        }
    }

    /// Open and index windows with bounded concurrency (default 2).
    public func indexedWindows(_ windows: [[String]], repository: PackRepository,
                               budget: ComputationBudget,
                               maxConcurrent: Int = PreparedGraphStore.maxConcurrentPrepares) throws -> [IndexedGraph] {
        guard !windows.isEmpty else { return [] }
        guard windows.count >= 2 else {
            return try windows.map { try indexed($0, repository: repository, budget: budget) }
        }
        let limit = max(1, maxConcurrent)
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
        let tickets = DispatchSemaphore(value: limit)
        for (index, window) in windows.enumerated() {
            group.enter()
            queue.async {
                tickets.wait()
                defer { tickets.signal(); group.leave() }
                do {
                    let graph = try self.indexed(window, repository: repository, budget: budget)
                    slot.lock.lock(); slot.results[index] = graph; slot.lock.unlock()
                } catch {
                    slot.lock.lock(); slot.errors[index] = error; slot.lock.unlock()
                }
            }
        }
        // Dispatch workers share cancellation with the caller. Polling here
        // propagates a cancelled Swift task instead of waiting a full deadline.
        defer { group.wait() }
        while group.wait(timeout: .now() + 0.05) == .timedOut { try budget.check() }
        try budget.check()
        if let error = slot.errors.compactMap({ $0 }).first { throw error }
        return try slot.results.map { graph in
            guard let graph else { throw RoutingFailure.invalidRequest("prepared window missing") }
            return graph
        }
    }

    /// Kick off the next window on a background queue; safe to ignore the handle.
    @discardableResult
    public func prefetch(_ regions: [String], repository: PackRepository,
                         budget: ComputationBudget) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            _ = try? self?.indexed(regions, repository: repository, budget: budget)
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
        return work
    }

    private func build(regions: [String], repository: PackRepository,
                              budget: ComputationBudget) throws -> IndexedGraph {
        func measured<T>(_ field: WritableKeyPath<Metrics, Double>,
                         _ work: () throws -> T) rethrows -> T {
            let started = ContinuousClock.now
            defer {
                let d = started.duration(to: .now).components
                lock.lock()
                measurements[keyPath: field] += Double(d.seconds) + Double(d.attoseconds) / 1e18
                lock.unlock()
            }
            return try work()
        }
        // Include failed preparation in each phase's elapsed time.
        let packs = try measured(\.openSeconds) {
            try regions.map { try repository.open($0, requireSeams: regions.count > 1, budget: budget) }
        }
        guard let first = packs.first else { throw RoutingFailure.missingPacks(regions) }
        let graph: any RoadGraph = try measured(\.joinSeconds) { () throws -> any RoadGraph in
            packs.count == 1 ? first.graph : try RegionalGraph(packs: packs, budget: budget)
        }
        let indexed = try measured(\.indexSeconds) { try IndexedGraph(graph, budget: budget) }
        lock.lock()
        measurements.builds += 1
        lock.unlock()
        return indexed
    }
}
