import Foundation

/// Bounded, deterministic preference among similarly useful roads. Unlike JS's
/// history-dependent near-cost label stealing, this is one static cost function
/// for the whole search. It cannot change access, distance budgets or turn rules.
enum RouteVariety {
    static func multiplier(seed: UInt64, edge: Int) -> Double {
        var hash = seed ^ UInt64(UInt(bitPattern: edge)) ^ 0xcbf29ce484222325
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        hash ^= hash >> 31
        let unit = Double(hash >> 11) / 9_007_199_254_740_992
        return 0.96 + 0.08 * unit
    }
    static func multiplier(seed: UInt64, edgeID: String) -> Double {
        // Do not use Swift.Hasher: its process randomization breaks saved seeds.
        var hash = seed ^ 0xcbf29ce484222325
        for byte in edgeID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        hash ^= hash >> 31
        let unit = Double(hash >> 11) / 9_007_199_254_740_992
        return 0.96 + 0.08 * unit
    }
}
