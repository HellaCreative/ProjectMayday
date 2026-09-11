import Foundation

// Fixed per process; never change cache semantics midway through a request.
enum NativeFuelPreparation {
    static let mode = ProcessInfo.processInfo.environment["DIRT_FUEL_PREPARATION"] ?? "cached"
    static let indexed = mode != "legacy"
    static let cached = mode == "cached"
    static let verify = mode == "verify"
    static let skipUnusedDirect = ProcessInfo.processInfo.environment["DIRT_FUEL_SKIP_UNUSED_DIRECT"] != "0"
    static let cacheLimit = max(1, min(2048, Int(ProcessInfo.processInfo.environment["DIRT_FUEL_CACHE_LIMIT"] ?? "1024") ?? 1024))
    private static let lock = NSLock()
    nonisolated(unsafe) private static var matches = 0, hits = 0, edges = 0, segments = 0, omitted = 0
    static func recordMatch(edges: Int, segments: Int, omitted: Int) {
        lock.lock(); defer { lock.unlock() }
        matches += 1; self.edges += edges; self.segments += segments
        self.omitted += omitted
    }
    static func recordHit() { lock.lock(); hits += 1; lock.unlock() }
    static func metrics() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["mode": mode, "cacheLimit": cacheLimit, "matches": matches, "hits": hits, "projectedEdges": edges, "projectedSegments": segments, "omittedQualifyingReferenceSegments": omitted]
    }
}
