import CoreLocation
import Foundation

/// Page-backed search labels. Unwritten pages stay unallocated so a hop search
/// can span a regional pack without resident arrays for every node.
struct SparseDefaultArray<Value> {
    let count: Int
    let defaultValue: Value
    private let pageSize: Int
    private var pages: [Int: [Value]] = [:]

    init(count: Int, default defaultValue: Value, pageSize: Int = 4_096) {
        self.count = max(0, count)
        self.defaultValue = defaultValue
        self.pageSize = max(64, pageSize)
    }

    var residentPageCount: Int { pages.count }

    var chargedBytes: Int {
        pages.count * pageSize * MemoryLayout<Value>.stride
    }

    subscript(index: Int) -> Value {
        get {
            guard index >= 0, index < count else { return defaultValue }
            let page = index / pageSize
            let offset = index % pageSize
            return pages[page]?[offset] ?? defaultValue
        }
        set {
            guard index >= 0, index < count else { return }
            let page = index / pageSize
            let offset = index % pageSize
            if pages[page] == nil {
                pages[page] = Array(repeating: defaultValue, count: pageSize)
            }
            pages[page]![offset] = newValue
        }
    }
}

/// Moving 10–20 km working neighborhood around A, B, and the developing route.
/// The envelope follows the wide tolerance corridor so off-axis dirt stays loadable.
struct FogOfWarNeighborhood {
    var start: CLLocationCoordinate2D
    var end: CLLocationCoordinate2D
    var workingRadiusMeters: Double
    var corridorMeters: Double
    private(set) var seeds: [CLLocationCoordinate2D]
    private(set) var expansions: Int = 0

    init(
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        workingRadiusMeters: Double = HopSearchPolicy.fogWorkingRadiusMeters,
        corridorMeters: Double = HopSearchPolicy.dirtCorridorMeters
    ) {
        self.start = start
        self.end = end
        self.workingRadiusMeters = max(8_000, workingRadiusMeters)
        self.corridorMeters = max(workingRadiusMeters, corridorMeters)
        seeds = [start, end]
    }

    var seedCount: Int { seeds.count }

    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        let radius = workingRadiusMeters
        if GeoMath.meters(point, start) <= radius { return true }
        if GeoMath.meters(point, end) <= radius { return true }
        for seed in seeds where GeoMath.meters(point, seed) <= radius {
            return true
        }
        let xt = abs(GeoMath.crossTrackMeters(point: point, lineFrom: start, to: end))
        guard xt <= corridorMeters else { return false }
        let a = RouteCoordinate(longitude: start.longitude, latitude: start.latitude)
        let b = RouteCoordinate(longitude: end.longitude, latitude: end.latitude)
        let p = RouteCoordinate(longitude: point.longitude, latitude: point.latitude)
        let progress = GeoMath.progressAlongAB(from: a, to: b, point: p)
        let ab = max(1, GeoMath.meters(start, end))
        let along = progress * ab
        return along >= -radius && along <= ab + radius
    }

    mutating func noteVisited(_ point: CLLocationCoordinate2D) {
        let cover = workingRadiusMeters * 0.72
        if seeds.contains(where: { GeoMath.meters(point, $0) <= cover }) {
            return
        }
        seeds.append(point)
        expansions += 1
        if seeds.count > 96 {
            seeds.removeFirst(seeds.count - 96)
        }
    }
}
