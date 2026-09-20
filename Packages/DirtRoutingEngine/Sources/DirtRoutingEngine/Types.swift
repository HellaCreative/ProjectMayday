import Foundation

public struct Coordinate: Codable, Hashable, Sendable {
    public let longitude: Double
    public let latitude: Double
    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }
    public var isValid: Bool {
        longitude.isFinite && latitude.isFinite && abs(longitude) <= 180 && abs(latitude) <= 90
    }
    public func distance(to other: Self) -> Double {
        let r = Double.pi / 180
        let a = latitude * r, b = other.latitude * r
        let h = pow(sin((b - a) / 2), 2)
            + cos(a) * cos(b) * pow(sin((other.longitude - longitude) * r / 2), 2)
        return 12_742_000 * asin(min(1, sqrt(max(0, h))))
    }
    func bearing(to b: Self) -> Double {
        let aLat = latitude * .pi / 180, bLat = b.latitude * .pi / 180
        let dl = (b.longitude - longitude) * .pi / 180
        return atan2(sin(dl) * cos(bLat), cos(aLat) * sin(bLat) - sin(aLat) * cos(bLat) * cos(dl))
    }
    func crossTrack(from a: Self, to b: Self) -> Double {
        guard a.distance(to: b) > 0.006371 else { return 0 }
        return asin(sin(a.distance(to: self) / 6_371_000)
                    * sin(a.bearing(to: self) - a.bearing(to: b))) * 6_371_000
    }
}

public enum RoutingFailure: Error, Equatable, Sendable {
    case invalidRequest(String)
    case invalidPack(String)
    case missingPacks([String])
    case unsupported(String)
    case noMatch
    case noPath
    case ferriesAvoided
    case resourceLimit(String)
}

public enum RidingStyle: String, Codable, Sendable { case dirt, balanced, cleanest }
public enum Surface: String, Codable, Sendable { case paved, gravel, loose, unknown }

/// Cancellation shared with bounded preparation workers, which run outside the
/// calling Swift task. A cancelled calculation can never renew its deadline.
private final class CalculationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func check() throws {
        lock.lock()
        if Task.isCancelled { cancelled = true }
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
    }
}

/// One absolute monotonic deadline covers preparation and every attempt in a
/// window. Only a completed, committed stage may start another window.
public struct ComputationBudget: Sendable {
    let deadline: ContinuousClock.Instant
    public let maximumLabels: Int
    private let windowSeconds: Double
    private let cancellation: CalculationCancellation
    public init(seconds: Double = 18, maximumLabels: Int = 1_600_000) {
        let seconds = seconds.isFinite ? max(0, seconds) : 18
        deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        self.maximumLabels = max(1, maximumLabels)
        windowSeconds = seconds
        cancellation = CalculationCancellation()
    }
    public var remainingSeconds: Double {
        let d = ContinuousClock.now.duration(to: deadline).components
        return max(0,Double(d.seconds)+Double(d.attoseconds)/1e18)
    }
    public func limited(to seconds: Double) -> Self {
        .init(deadline: min(deadline,ContinuousClock.now.advanced(by: .seconds(max(0,seconds)))),
              maximumLabels: maximumLabels, windowSeconds: windowSeconds, cancellation: cancellation)
    }
    func afterCommittedStage() throws -> Self {
        try cancellation.check()
        return .init(deadline: .now.advanced(by: .seconds(windowSeconds)),
                     maximumLabels: maximumLabels, windowSeconds: windowSeconds, cancellation: cancellation)
    }
    private init(deadline: ContinuousClock.Instant, maximumLabels: Int,
                 windowSeconds: Double, cancellation: CalculationCancellation) {
        self.deadline = deadline; self.maximumLabels = maximumLabels
        self.windowSeconds = windowSeconds; self.cancellation = cancellation
    }
    func check() throws {
        try cancellation.check()
        guard ContinuousClock.now < deadline else { throw RoutingFailure.resourceLimit("time") }
    }
}

/// Totals across every search one request runs, including failed and discarded
/// attempts, so diagnostics never divide elapsed time by the selected route alone.
/// Recording only: nothing here influences a routing decision.
public final class SearchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var searchCount = 0
    private var popCount = 0
    private var labelPeak = 0
    private var statePeak = 0
    private var supersededPopCount = 0
    private var searchNanoseconds: UInt64 = 0
    private var stages: [(name: String, nanoseconds: UInt64)] = []
    public init() {}

    func recordSearch(pops: Int, labels: Int, states: Int, supersededPops: Int, since start: ContinuousClock.Instant) {
        let elapsed = Self.nanoseconds(since: start)
        locked {
            searchCount += 1
            popCount += pops
            labelPeak = max(labelPeak, labels)
            statePeak = max(statePeak, states)
            supersededPopCount += supersededPops
            searchNanoseconds += elapsed
        }
    }
    func recordStage(_ name: String, since start: ContinuousClock.Instant) {
        let elapsed = Self.nanoseconds(since: start)
        locked {
            if let index = stages.firstIndex(where: { $0.name == name }) { stages[index].nanoseconds += elapsed }
            else { stages.append((name, elapsed)) }
        }
    }
    public var searches: Int { locked { searchCount } }
    public var pops: Int { locked { popCount } }
    public var peakLabels: Int { locked { labelPeak } }
    public var peakSearchStates: Int { locked { statePeak } }
    public var supersededLabelsPopped: Int { locked { supersededPopCount } }
    public var searchMilliseconds: Double { locked { Double(searchNanoseconds) / 1e6 } }
    /// Stage totals in first-seen order, in whole milliseconds: "match:12,compass:85".
    public var stageSummary: String {
        locked { stages.map { "\($0.name):\(Int((Double($0.nanoseconds) / 1e6).rounded()))" }.joined(separator: ",") }
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
    private static func nanoseconds(since start: ContinuousClock.Instant) -> UInt64 {
        let parts = start.duration(to: .now).components
        return UInt64(max(0, parts.seconds)) * 1_000_000_000 + UInt64(max(0, parts.attoseconds / 1_000_000_000))
    }
}

public struct Traversal: Codable, Equatable, Sendable {
    public let edge: Int
    public let forward: Bool
    public let meters: Double
}

struct BinaryHeap<Element> {
    private var values: [Element] = []
    let ordered: (Element, Element) -> Bool
    init(ordered: @escaping (Element, Element) -> Bool) { self.ordered = ordered }
    var isEmpty: Bool { values.isEmpty }
    mutating func push(_ value: Element) {
        values.append(value)
        var i = values.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if !ordered(values[i], values[parent]) { break }
            values.swapAt(i, parent)
            i = parent
        }
    }
    mutating func pop() -> Element? {
        guard !values.isEmpty else { return nil }
        if values.count == 1 { return values.removeLast() }
        let first = values[0]
        values[0] = values.removeLast()
        var i = 0
        while i * 2 + 1 < values.count {
            let left = i * 2 + 1, right = left + 1
            let best = right < values.count && ordered(values[right], values[left]) ? right : left
            if !ordered(values[best], values[i]) { break }
            values.swapAt(best, i)
            i = best
        }
        return first
    }
}
