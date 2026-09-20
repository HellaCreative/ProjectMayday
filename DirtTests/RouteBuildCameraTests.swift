import Testing
import MapLibre
import UIKit
@testable import Dirt

struct RouteBuildCameraTests {
    @Test @MainActor func completedOverviewWaitsForMapAndIgnoresInterruptedFits() throws {
        let map = MapState()
        let points = [RouteCoordinate(longitude: -63.34, latitude: 44.76),
                      RouteCoordinate(longitude: -62.1, latitude: 45.7)]
        map.beginRouteBuildCamera(at: points[0])
        map.appendCompletedRouteBuildLeg(points)
        map.fitCompletedRoute(points)
        let firstID = try #require(map.camera?.id)
        #expect(map.routeBuildCameraSequence == nil)
        #expect(map.followMode == .off)
        #expect(map.completedRouteOverviewID == nil)
        map.fly(to: points[1])
        map.completeRouteOverview(cameraID: firstID)
        #expect(map.completedRouteOverviewID == nil)
        map.fitCompletedRoute(points)
        let secondID = try #require(map.camera?.id)
        map.completeRouteOverview(cameraID: firstID)
        #expect(map.completedRouteOverviewID == nil)
        map.completeRouteOverview(cameraID: secondID)
        #expect(map.completedRouteOverviewID == secondID)
    }

    @Test @MainActor func nativeMapFramesWholeLoopBeforeCompletionSignal() async throws {
        let map = MapState()
        let points = [RouteCoordinate(longitude: -63.34, latitude: 44.76),
                      RouteCoordinate(longitude: -64.0, latitude: 45.3),
                      RouteCoordinate(longitude: -62.1, latitude: 45.7),
                      RouteCoordinate(longitude: -63.34, latitude: 44.76)]
        map.overlayContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: 280, right: 0)
        let coordinator = MapLibreMapView.Coordinator(state: map)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let styleURL = FileManager.default.temporaryDirectory.appendingPathComponent("completion-camera-\(UUID()).json")
        try Data(#"{"version":8,"sources":{},"layers":[]}"#.utf8).write(to: styleURL)
        defer { try? FileManager.default.removeItem(at: styleURL) }
        map.applyBasemapStyleURL(styleURL)
        let view = MLNMapView(frame: window.bounds, styleURL: styleURL)
        view.delegate = coordinator
        view.automaticallyAdjustsContentInset = false
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        view.frame = controller.view.bounds
        defer { window.isHidden = true; view.removeFromSuperview(); previousKeyWindow?.makeKey() }
        for _ in 0..<100 {
            if view.style != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        view.setCenter(points[2].locationCoordinate, zoomLevel: 12, animated: false)
        map.beginRouteBuildCamera(at: points[0])
        map.appendCompletedRouteBuildLeg(Array(points.suffix(2)))
        coordinator.sync(mapView: view)
        map.fitCompletedRoute(points)
        coordinator.sync(mapView: view)
        // Simulate the planner growing when the final two leg rows arrive.
        map.overlayContentInsets.bottom = 340
        coordinator.sync(mapView: view)
        for _ in 0..<100 {
            if map.completedRouteOverviewID != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(map.completedRouteOverviewID == map.camera?.id)
        for point in points {
            let pixel = view.convert(point.locationCoordinate, toPointTo: view)
            #expect(pixel.x >= 0 && pixel.x <= view.bounds.width)
            #expect(pixel.y >= 0 && pixel.y <= view.bounds.height - map.overlayContentInsets.bottom)
        }
    }

    @Test @MainActor func switchingPanelsKeepsMapCoordinatesStationary() async throws {
        let state = MapState()
        let coordinator = MapLibreMapView.Coordinator(state: state)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let styleURL = FileManager.default.temporaryDirectory.appendingPathComponent("panel-camera-\(UUID()).json")
        try Data(#"{"version":8,"sources":{},"layers":[]}"#.utf8).write(to: styleURL)
        defer { try? FileManager.default.removeItem(at: styleURL) }
        state.applyBasemapStyleURL(styleURL)
        let view = MLNMapView(frame: window.bounds, styleURL: styleURL)
        view.automaticallyAdjustsContentInset = false
        view.delegate = coordinator
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        view.frame = controller.view.bounds
        defer { window.isHidden = true; view.removeFromSuperview(); previousKeyWindow?.makeKey() }
        for _ in 0..<100 {
            if view.style != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let location = CLLocationCoordinate2D(latitude: 44.7648, longitude: -63.3403)
        for zoom in [7.0, 14.0] {
            view.setCenter(location, zoomLevel: zoom, direction: 28, animated: false, completionHandler: nil)
            coordinator.sync(mapView: view)
            let original = view.convert(location, toPointTo: view)
            // Route opens/resizes, another dock tab opens, then the planner returns.
            // Also cover the landscape drawer's horizontal footprint.
            for insets in [UIEdgeInsets(top: 0, left: 0, bottom: 280, right: 0),
                           UIEdgeInsets(top: 0, left: 0, bottom: 340, right: 0),
                           .zero, .zero,
                           UIEdgeInsets(top: 0, left: 250, bottom: 0, right: 0),
                           .zero] {
                state.overlayContentInsets = insets
                coordinator.sync(mapView: view)
                let pixel = view.convert(location, toPointTo: view)
                #expect(abs(pixel.x - original.x) < 1)
                #expect(abs(pixel.y - original.y) < 1)
                #expect(abs(view.zoomLevel - zoom) < 0.01)
            }
        }
    }

    @Test func routeBuildCameraPreservesEveryCompletedLegInOrder() throws {
        let map = MapState()
        let start = RouteCoordinate(longitude: -63.34, latitude: 44.76)
        let fuel = RouteCoordinate(longitude: -64.56, latitude: 44.31)
        let destination = RouteCoordinate(longitude: -65.64, latitude: 43.61)

        map.beginRouteBuildCamera(at: start)
        map.appendCompletedRouteBuildLeg([start, fuel])
        map.appendCompletedRouteBuildLeg([fuel, destination])

        let sequence = try #require(map.routeBuildCameraSequence)
        #expect(sequence.steps.count == 3)
        guard case .start(let framedStart) = sequence.steps[0] else {
            Issue.record("First camera step must focus the route start")
            return
        }
        #expect(framedStart == start)
        guard case .completedLeg(let firstLeg) = sequence.steps[1],
              case .completedLeg(let secondLeg) = sequence.steps[2]
        else {
            Issue.record("Completed legs must retain build order")
            return
        }
        #expect(firstLeg == [start, fuel])
        #expect(secondLeg == [fuel, destination])
    }

    @Test func deliberateCameraControlCancelsRouteBuildPlayback() {
        let map = MapState()
        let start = RouteCoordinate(longitude: -63.34, latitude: 44.76)
        let destination = RouteCoordinate(longitude: -65.64, latitude: 43.61)

        map.beginRouteBuildCamera(at: start)
        map.appendCompletedRouteBuildLeg([start, destination])
        map.fit([start, destination])

        #expect(map.routeBuildCameraSequence == nil)
    }
}
