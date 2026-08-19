import CoreLocation
import Foundation

/// Seed for joining two installed region packs. Mirrors Mayday
/// `dynamicSeamForPair`: chord × region split, plus bottleneck-only doors.
/// Not a named mountain-pass list — different A→B lines get different seeds.
enum CrossPackSeam {
    /// Isthmus / bridge / Madawaska — the only legal road, not scenery.
    private static let bottlenecks: [(Set<String>, CLLocationCoordinate2D)] = [
        (["ns", "nb"], CLLocationCoordinate2D(latitude: 45.92, longitude: -64.35)),
        (["nb", "pe"], CLLocationCoordinate2D(latitude: 46.21, longitude: -63.75)),
        (["nb", "qc"], CLLocationCoordinate2D(latitude: 47.55, longitude: -68.65))
    ]

    static func seed(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        left: String,
        right: String
    ) -> CLLocationCoordinate2D {
        candidates(from: from, to: to, left: left, right: right).first
            ?? lerp(from, to, 0.5)
    }

    /// Chord crossing first, then a few points along the shared border so a
    /// missed snap does not fall through to live longhaul. Not a scenic pass list.
    /// Snaps must land on OSM core edges only — provincial capillary (DRA / FTEN /
    /// Access / MNRF) is same-region dirt, not a hop stack.
    static func candidates(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        left: String,
        right: String
    ) -> [CLLocationCoordinate2D] {
        let a = left.lowercased()
        let b = right.lowercased()
        let pair: Set<String> = [a, b]
        if let door = bottlenecks.first(where: { $0.0 == pair }) {
            return [door.1]
        }

        let chord = chordCrossing(from: from, to: to, left: a, right: b)
        let extras = borderLineSamples(left: a, right: b)
            .sorted {
                hypot($0.latitude - chord.latitude, $0.longitude - chord.longitude)
                    < hypot($1.latitude - chord.latitude, $1.longitude - chord.longitude)
            }
        var out: [CLLocationCoordinate2D] = [chord]
        var seen = Set<String>([key(chord)])
        for p in extras.prefix(4) {
            if seen.insert(key(p)).inserted { out.append(p) }
        }
        return out
    }

    private static func key(_ p: CLLocationCoordinate2D) -> String {
        String(format: "%.3f,%.3f", p.latitude, p.longitude)
    }

    private static func chordCrossing(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        left: String,
        right: String
    ) -> CLLocationCoordinate2D {
        let samples = 48
        var prev = from
        var prevFam = GraphPackStore.primaryRegionId(containing: from)
        for i in 1...samples {
            let t = Double(i) / Double(samples)
            let p = lerp(from, to, t)
            let fam = GraphPackStore.primaryRegionId(containing: p)
            if let prevFam, let fam, prevFam != fam,
               (prevFam == left && fam == right) || (prevFam == right && fam == left) {
                return refineCrossing(prev, p)
            }
            if fam != nil {
                prevFam = fam
                prev = p
            }
        }
        return lerp(from, to, 0.5)
    }

    /// Connectivity samples along the legal split — not named mountain passes.
    private static func borderLineSamples(left: String, right: String) -> [CLLocationCoordinate2D] {
        let pair: Set<String> = [left, right]
        if pair == ["bc", "ab"] {
            let lats = [49.05, 49.35, 49.63, 50.05, 50.62, 51.30, 52.20, 53.20, 54.50]
            return lats.map { lat in
                CLLocationCoordinate2D(
                    latitude: lat,
                    longitude: lat >= 54 ? -120.0 : -116.4
                )
            }
        }
        if pair == ["bc", "wa"] {
            return [-123.3, -122.2, -121.0, -119.5, -118.2, -117.3].map { lon in
                CLLocationCoordinate2D(latitude: 49.002, longitude: lon)
            }
        }
        if pair == ["ab", "mt"] {
            return [-114.1, -113.0, -111.8, -110.5].map { lon in
                CLLocationCoordinate2D(latitude: 49.002, longitude: lon)
            }
        }
        return []
    }

    private static func lerp(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        _ t: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    private static func refineCrossing(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        var lo = a
        var hi = b
        for _ in 0..<14 {
            let mid = lerp(lo, hi, 0.5)
            let fam = GraphPackStore.primaryRegionId(containing: mid)
            let loFam = GraphPackStore.primaryRegionId(containing: lo)
            if fam == loFam { lo = mid } else { hi = mid }
        }
        return lerp(lo, hi, 0.5)
    }
}

extension OnDeviceRouter.Result {
    static func concatenating(_ hops: [OnDeviceRouter.Result]) -> OnDeviceRouter.Result? {
        guard let first = hops.first else { return nil }
        if hops.count == 1 { return first }

        var coords = first.coordinates
        var legs = first.legs
        var edgeIds = first.edgeIds
        for hop in hops.dropFirst() {
            if coords.last != nil, let hopFirst = hop.coordinates.first {
                let rest = hop.coordinates.dropFirst()
                let skipDuplicate = CLLocation(latitude: coords[coords.count - 1].latitude, longitude: coords[coords.count - 1].longitude)
                    .distance(from: CLLocation(latitude: hopFirst.latitude, longitude: hopFirst.longitude)) < 8
                if !skipDuplicate {
                    coords.append(hopFirst)
                }
                coords.append(contentsOf: rest)
            } else {
                coords.append(contentsOf: hop.coordinates)
            }
            legs.append(contentsOf: hop.legs)
            edgeIds.append(contentsOf: hop.edgeIds)
        }

        var meters = 0.0
        var dirtMeters = 0.0
        var pavedMeters = 0.0
        var unknownMeters = 0.0
        for leg in legs {
            meters += leg.distanceMeters
            if leg.paintSurfaceName == "paved" {
                pavedMeters += leg.distanceMeters
            } else if OnDeviceProfileCosts.isAdventureSurface(leg.paintSurfaceName) {
                dirtMeters += leg.distanceMeters
            }
            if leg.accessName == "motorized_unknown" {
                unknownMeters += leg.distanceMeters
            }
        }
        guard meters > 0, coords.count >= 2 else { return nil }
        return OnDeviceRouter.Result(
            coordinates: coords,
            distanceMeters: meters,
            edgeIds: edgeIds,
            legs: legs,
            dirtPercent: Int((dirtMeters / meters * 100).rounded()),
            pavedPercent: Int((pavedMeters / meters * 100).rounded()),
            unknownAccessPercent: Int((unknownMeters / meters * 100).rounded())
        )
    }
}
