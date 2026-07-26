import CoreLocation
import Foundation
import Observation

struct RouteDisplaySegment {
    let coordinates: [RouteCoordinate]
    /// Web `trackClass` / `surfaceClass` key used for selected-route paint.
    let surfaceKey: String

    var isDirt: Bool {
        RouteSegment.isAdventureSurface(surfaceKey)
    }
}

/// Single source of truth the SwiftUI layer mutates and the MapLibre
/// representable consumes. Generation counters keep UIKit diffing cheap.
@Observable
final class MapState {
    enum MarkerKind {
        case start
        case stage
        case destination
        case rider
    }

    struct Marker: Identifiable {
        let id: String
        let latitude: Double
        let longitude: Double
        let label: String
        let kind: MarkerKind
        var subtitle: String?
    }

    enum CameraCommand {
        case center(latitude: Double, longitude: Double, zoom: Double)
        case fit([RouteCoordinate])
    }

    private(set) var routeSegments: [RouteDisplaySegment] = []
    private(set) var routeGeneration = 0
    private(set) var markers: [Marker] = []
    private(set) var markerGeneration = 0
    private(set) var camera: (id: UUID, command: CameraCommand)?
    /// Bumps when the basemap style URL changes so MapLibre reloads.
    private(set) var styleGeneration = 0
    private(set) var styleURL: URL = MapStyleCatalog.styleURL()
    var followUser = false
    var onTap: ((CLLocationCoordinate2D) -> Void)?
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onRiderTap: ((String) -> Void)?

    func applySelectedMapStyle() {
        let next = MapStyleCatalog.styleURL()
        guard next != styleURL else { return }
        styleURL = next
        styleGeneration += 1
    }

    func setRoute(_ segments: [RouteDisplaySegment]) {
        routeSegments = segments
        routeGeneration += 1
    }

    func clearRoute() {
        setRoute([])
    }

    func setMarkers(_ new: [Marker]) {
        markers = new
        markerGeneration += 1
    }

    func fly(to coordinate: RouteCoordinate, zoom: Double = 13) {
        camera = (UUID(), .center(latitude: coordinate.latitude, longitude: coordinate.longitude, zoom: zoom))
    }

    func fit(_ coordinates: [RouteCoordinate]) {
        guard coordinates.count > 1 else {
            if let only = coordinates.first { fly(to: only) }
            return
        }
        camera = (UUID(), .fit(coordinates))
    }

    /// Consolidates per-edge segments into continuous same-surface runs, the way
    /// the web POC merges adjacent edges before painting (`routeDisplaySegments`).
    static func displaySegments(from responses: [RouteResponse]) -> [RouteDisplaySegment] {
        var result: [RouteDisplaySegment] = []
        for response in responses {
            let segments = response.segments ?? []
            var currentCoords: [RouteCoordinate] = []
            var currentKey: String?
            func flush() {
                if currentCoords.count > 1, let key = currentKey {
                    result.append(RouteDisplaySegment(coordinates: currentCoords, surfaceKey: key))
                }
                currentCoords = []
                currentKey = nil
            }
            if segments.isEmpty {
                let coords = response.coordinates
                if coords.count > 1 {
                    // Web fallback with no edge geometry: trackClass "connector".
                    result.append(RouteDisplaySegment(coordinates: coords, surfaceKey: "connector"))
                }
                continue
            }
            for segment in segments {
                let coords = segment.coordinates
                guard !coords.isEmpty else { continue }
                let key = segment.paintSurfaceKey
                if currentKey == key {
                    for coordinate in coords where coordinate != currentCoords.last {
                        currentCoords.append(coordinate)
                    }
                } else {
                    flush()
                    currentKey = key
                    currentCoords = coords
                }
            }
            flush()
        }
        return result
    }
}
