import Foundation

/// One compact completed proof vector. Never owns a graph, index or search field.
nonisolated final class InitialFuelBoundMemo: @unchecked Sendable {
    struct Point: Equatable, Sendable { let latitude: Double, longitude: Double, meters: Double }
    struct Input: Equatable, Sendable {
        let sourceIdentity: String
        let origin: Point
        let stations: [Point]
        let incumbentMeters: Double
        let maximumStates: Int, maximumQueueEntries: Int, maximumBorderNodes: Int
    }
    static let maximumStations = 4096
    static let maximumIdentityBytes = 16_384
    static let maximumPayloadBytes = 256 * 1024
    private final class Entry {
        weak var owner: AnyObject?
        weak var index: AnyObject?
        let input: Input
        let bounds: [Double]
        init(owner: AnyObject, index: AnyObject, input: Input, bounds: [Double]) {
            self.owner = owner; self.index = index; self.input = input; self.bounds = bounds
        }
    }
    private let lock = NSLock()
    private var entry: Entry?

    func value(owner: AnyObject, index: AnyObject, input: Input,
        validate: () throws -> Void, compute: () throws -> [Double]?) throws -> [Double]? {
        try validate()
        guard input.stations.count <= Self.maximumStations,
              input.sourceIdentity.utf8.count <= Self.maximumIdentityBytes else {
            return try compute()
        }
        lock.lock()
        let hit = entry.flatMap { existing -> [Double]? in
            existing.owner === owner && existing.index === index && existing.input == input
                ? existing.bounds : nil
        }
        lock.unlock()
        if let hit {
            try validate()
            RoutingWorkContext.measurement?.increment(.initialFuelBoundMemoHits)
            return hit
        }
        RoutingWorkContext.measurement?.increment(.initialFuelBoundMemoMisses)
        let computed = try compute()
        try validate()
        guard let result = computed else { return nil }
        guard result.count == input.stations.count,
              result.allSatisfy({ !$0.isNaN && $0 >= 0 }) else { return result }
        // Capacity, not merely count, bounds the actual retained Array storage.
        let payload = input.stations.capacity * MemoryLayout<Point>.stride
            + result.capacity * MemoryLayout<Double>.stride + input.sourceIdentity.utf8.count
        guard payload <= Self.maximumPayloadBytes else { return result }
        lock.lock()
        entry = Entry(owner: owner, index: index, input: input, bounds: result)
        lock.unlock()
        return result
    }
}
