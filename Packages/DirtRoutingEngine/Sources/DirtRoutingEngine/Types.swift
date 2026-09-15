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
    case resourceLimit(String)
}

public enum RidingStyle: String, Codable, Sendable { case dirt, balanced, cleanest }
public enum Surface: String, Codable, Sendable { case paved, gravel, loose, unknown }

/// One absolute monotonic deadline covers preparation and every search attempt.
/// Cancellation is checked by the worker, independent of the application's UI task.
public struct ComputationBudget: Sendable {
    let deadline: ContinuousClock.Instant
    public let maximumLabels: Int
    public init(seconds: Double = 18, maximumLabels: Int = 1_600_000) {
        deadline = ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))
        self.maximumLabels = max(1, maximumLabels)
    }
    public var remainingSeconds: Double {
        let d = ContinuousClock.now.duration(to: deadline).components
        return max(0,Double(d.seconds)+Double(d.attoseconds)/1e18)
    }
    public func limited(to seconds: Double) -> Self {
        .init(deadline: min(deadline,ContinuousClock.now.advanced(by: .seconds(max(0,seconds)))),maximumLabels: maximumLabels)
    }
    private init(deadline: ContinuousClock.Instant,maximumLabels: Int) {
        self.deadline = deadline; self.maximumLabels = maximumLabels
    }
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw RoutingFailure.resourceLimit("time") }
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
