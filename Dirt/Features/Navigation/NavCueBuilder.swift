import CoreLocation
import Foundation

/// Geometry-derived navigation cues
///.
///
/// Roadbook numbers (do not invert):
///   6 = fast / easy … 1 = hairpin
///
/// Junction cues are decision turns (Turn left / Turn right) — never numbered.
/// Without live graph degree on-device, decisive geometry turns (≥70° or
/// roadbook ≤3) stand in for network junctions.
/// Pure geometry — opted out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// so `map`/`compactMap` method refs and callers off the main actor stay clean.
nonisolated enum NavCueBuilder {
    private static let densifyMeters = 15.0
    private static let smoothWindow = 3
    private static let minTurnDeg = 15.0
    private static let startRateDeg = 1.0
    private static let continueRateDeg = 0.4
    private static let minCurveLengthM = 18.0
    private static let minSeparationM = 40.0
    private static let mergeJunctionM = 70.0
    private static let endQuietSamples = 2

    /// Build cue list for the active mode from the ride polyline.
    static func build(
        coordinates: [RouteCoordinate],
        cueMode: NavigationCueMode
    ) -> [RouteManeuver] {
        guard coordinates.count >= 2 else { return [] }
        let curves = buildCurveEvents(coordinates)
        let totalM = GeoMath.lineMeters(coordinates)
        let arrive = RouteManeuver(
            instruction: "Arrive at destination",
            type: "arrive",
            kind: "arrive",
            side: nil,
            number: nil,
            degrees: 0,
            distanceMeters: 0,
            alongMeters: totalM
        )

        switch cueMode {
        case .rally:
            return curves.map(asRallyManeuver) + [arrive]
        case .junctions:
            return curves.compactMap(asJunctionIfDecisive) + [arrive]
        }
    }

    // MARK: - Curve detection (RoadbookCurves.buildCurveEvents)

    struct CurveEvent {
        let alongMeters: Double
        let side: String
        let number: Int
        let degrees: Double
        let lengthM: Double
        let radiusM: Double
    }

    static func buildCurveEvents(_ coordinates: [RouteCoordinate]) -> [CurveEvent] {
        let dense = densify(coordinates, stepM: densifyMeters)
        guard dense.count >= 6 else { return [] }

        var alongM = Array(repeating: 0.0, count: dense.count)
        for i in 1..<dense.count {
            alongM[i] = alongM[i - 1] + GeoMath.meters(dense[i - 1], dense[i])
        }

        var rawBearings: [Double] = []
        rawBearings.reserveCapacity(dense.count)
        for i in 0..<(dense.count - 1) {
            rawBearings.append(bearingDeg(dense[i], dense[i + 1]))
        }
        rawBearings.append(rawBearings.last ?? 0)
        let bearings = smoothCircular(rawBearings, window: smoothWindow)

        var rates = Array(repeating: 0.0, count: bearings.count)
        for i in 1..<bearings.count {
            rates[i] = angleDeltaDeg(bearings[i - 1], bearings[i])
        }

        var events: [CurveEvent] = []
        var i = 1
        while i < rates.count {
            let rate = rates[i]
            if abs(rate) < startRateDeg {
                i += 1
                continue
            }
            let sign: Double = rate > 0 ? 1 : -1
            let startI = i
            var totalDeg = 0.0
            var quiet = 0
            var endI = i

            while i < rates.count {
                let r = rates[i]
                let same = r == 0 ? false : (r > 0) == (sign > 0)
                if same && abs(r) >= continueRateDeg {
                    totalDeg += abs(r)
                    endI = i
                    quiet = 0
                    i += 1
                    continue
                }
                if same && abs(r) >= continueRateDeg * 0.45 {
                    totalDeg += abs(r)
                    endI = i
                    quiet = 0
                    i += 1
                    continue
                }
                quiet += 1
                if quiet > endQuietSamples { break }
                i += 1
            }

            var coreStart = startI
            var coreEnd = endI
            var acc = 0.0
            let targetLo = totalDeg * 0.08
            let targetHi = totalDeg * 0.92
            for k in startI...endI {
                let r = abs(rates[k])
                if r >= continueRateDeg {
                    if acc < targetLo { coreStart = k }
                    acc += r
                    coreEnd = k
                    if acc >= targetHi { break }
                }
            }

            let lengthM = max(minCurveLengthM * 0.5, alongM[coreEnd] - alongM[coreStart])
            let spanM = alongM[endI] - alongM[startI]
            guard let classified = classifyCurve(totalAbsDeg: totalDeg, lengthM: lengthM),
                  spanM >= minCurveLengthM,
                  totalDeg >= minTurnDeg
            else { continue }

            let side = sign > 0 ? "right" : "left"
            events.append(
                CurveEvent(
                    alongMeters: alongM[startI],
                    side: side,
                    number: classified.number,
                    degrees: totalDeg.rounded(),
                    lengthM: lengthM.rounded(),
                    radiusM: Double(classified.radiusM)
                )
            )
        }

        // Drop duplicates within min separation (keep tighter / lower number).
        var pruned: [CurveEvent] = []
        for ev in events {
            if let prev = pruned.last,
               (ev.alongMeters - prev.alongMeters) < minSeparationM {
                if ev.number < prev.number {
                    pruned[pruned.count - 1] = ev
                }
                continue
            }
            pruned.append(ev)
        }
        return pruned
    }

    // MARK: - Classification

    private struct ClassifiedCurve {
        let number: Int
        let radiusM: Int
    }

    private static func classifyCurve(totalAbsDeg: Double, lengthM: Double) -> ClassifiedCurve? {
        guard totalAbsDeg >= minTurnDeg, lengthM > 0 else { return nil }
        let angleRad = totalAbsDeg * .pi / 180
        let radiusM = lengthM / max(angleRad, 0.08)

        var number: Int
        if radiusM >= 220 { number = 6 }
        else if radiusM >= 140 { number = 5 }
        else if radiusM >= 85 { number = 4 }
        else if radiusM >= 50 { number = 3 }
        else if radiusM >= 28 { number = 2 }
        else { number = 1 }

        if totalAbsDeg >= 75 && radiusM >= 160 { number = max(number, 5) }
        if totalAbsDeg >= 75 && radiusM >= 240 { number = 6 }

        if totalAbsDeg >= 55 && lengthM < 55 && radiusM < 45 {
            number = min(number, 3)
        }
        if totalAbsDeg >= 70 && lengthM < 45 && radiusM < 32 {
            number = min(number, 2)
        }

        if number == 1 {
            let hairpin = totalAbsDeg >= 120 && radiusM < 36
            if !hairpin { number = 2 }
        } else if totalAbsDeg >= 140 && radiusM < 28 {
            number = 1
        }

        if totalAbsDeg < 35 && number <= 3 { number = 6 }

        return ClassifiedCurve(number: number, radiusM: Int(radiusM.rounded()))
    }

    /// Geometry stand-in for network junctions.
    private static func asJunctionIfDecisive(_ event: CurveEvent) -> RouteManeuver? {
        guard event.number <= 3 || event.degrees >= 70 else { return nil }
        return RouteManeuver(
            instruction: "Turn \(event.side)",
            type: "turn",
            kind: "junction",
            side: event.side,
            number: nil,
            degrees: event.degrees,
            distanceMeters: 0,
            alongMeters: event.alongMeters
        )
    }

    private static func asRallyManeuver(_ event: CurveEvent) -> RouteManeuver {
        let hairpin = event.number == 1
        let instruction = hairpin
            ? "\(event.side.capitalized) 1 hairpin"
            : "\(event.side.capitalized) \(event.number)"
        return RouteManeuver(
            instruction: instruction,
            type: "bend",
            kind: "curve",
            side: event.side,
            number: event.number,
            degrees: event.degrees,
            distanceMeters: 0,
            alongMeters: event.alongMeters
        )
    }

    private static func merge(curves: [RouteManeuver], junctions: [RouteManeuver]) -> [RouteManeuver] {
        var items = (curves + junctions).sorted {
            ($0.alongMeters ?? 0) < ($1.alongMeters ?? 0)
        }
        var merged: [RouteManeuver] = []
        for item in items {
            guard let prev = merged.last,
                  let a = prev.alongMeters,
                  let b = item.alongMeters,
                  abs(a - b) < mergeJunctionM
            else {
                merged.append(item)
                continue
            }
            let prevJ = prev.isJunctionCue
            let itemJ = item.isJunctionCue
            if itemJ && !prevJ {
                merged[merged.count - 1] = item
            } else if !itemJ && prevJ {
                // Keep junction.
            } else if itemJ && prevJ {
                if (item.degrees ?? 0) > (prev.degrees ?? 0) {
                    merged[merged.count - 1] = item
                }
            } else if (item.number ?? 99) < (prev.number ?? 99) {
                merged[merged.count - 1] = item
            }
        }
        // Extra curve-vs-curve separation.
        items = merged
        merged = []
        for item in items {
            guard let prev = merged.last,
                  let a = prev.alongMeters,
                  let b = item.alongMeters,
                  (b - a) < minSeparationM,
                  !item.isJunctionCue
            else {
                merged.append(item)
                continue
            }
            if (item.number ?? 99) < (prev.number ?? 99) {
                merged[merged.count - 1] = item
            }
        }
        return merged
    }

    // MARK: - Geometry helpers

    private static func densify(_ coords: [RouteCoordinate], stepM: Double) -> [RouteCoordinate] {
        guard coords.count >= 2 else { return coords }
        var out: [RouteCoordinate] = [coords[0]]
        for i in 1..<coords.count {
            let a = coords[i - 1]
            let b = coords[i]
            let segM = GeoMath.meters(a, b)
            let steps = max(1, Int(ceil(segM / stepM)))
            for s in 1...steps {
                let t = Double(s) / Double(steps)
                out.append(
                    RouteCoordinate(
                        longitude: a.longitude + (b.longitude - a.longitude) * t,
                        latitude: a.latitude + (b.latitude - a.latitude) * t
                    )
                )
            }
        }
        return out
    }

    private static func bearingDeg(_ a: RouteCoordinate, _ b: RouteCoordinate) -> Double {
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func angleDeltaDeg(_ a: Double, _ b: Double) -> Double {
        var d = b - a
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private static func smoothCircular(_ values: [Double], window: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let half = max(1, window)
        var out = Array(repeating: 0.0, count: values.count)
        for i in 0..<values.count {
            var sx = 0.0
            var sy = 0.0
            var n = 0.0
            for j in (i - half)...(i + half) {
                guard j >= 0, j < values.count else { continue }
                let rad = values[j] * .pi / 180
                sx += cos(rad)
                sy += sin(rad)
                n += 1
            }
            out[i] = (atan2(sy / n, sx / n) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }
        return out
    }
}
