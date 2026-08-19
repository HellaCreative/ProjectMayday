import CoreLocation
import Observation

/// Gates `allowsBackgroundLocationUpdates`. Enabling it without
/// `UIBackgroundModes` containing `location` is a fatal Core Location crash.
enum LocationBackgroundPolicy {
    static var bundleHasLocationBackgroundMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
    }

    static func shouldEnable(requested: Bool, hasLocationBackgroundMode: Bool) -> Bool {
        requested && hasLocationBackgroundMode
    }
}

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastLocation: CLLocation?
    var onLocation: ((CLLocation) -> Void)?

    private enum Prefs {
        static let lastLatitude = "dirt.lastUserLatitude"
        static let lastLongitude = "dirt.lastUserLongitude"
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        manager.distanceFilter = 5
        seedLastKnownLocation()
    }

    /// Prefer Core Location’s cached fix, then the last persisted coordinate.
    private func seedLastKnownLocation() {
        if let system = manager.location, CLLocationCoordinate2DIsValid(system.coordinate) {
            lastLocation = system
            persistLastCoordinate(system.coordinate)
            return
        }
        let defaults = UserDefaults.standard
        let lat = defaults.double(forKey: Prefs.lastLatitude)
        let lon = defaults.double(forKey: Prefs.lastLongitude)
        guard defaults.object(forKey: Prefs.lastLatitude) != nil,
              defaults.object(forKey: Prefs.lastLongitude) != nil else { return }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        lastLocation = CLLocation(latitude: lat, longitude: lon)
    }

    private func persistLastCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let defaults = UserDefaults.standard
        defaults.set(coordinate.latitude, forKey: Prefs.lastLatitude)
        defaults.set(coordinate.longitude, forKey: Prefs.lastLongitude)
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var currentCoordinate: RouteCoordinate? {
        guard let coordinate = lastLocation?.coordinate else { return nil }
        return RouteCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude)
    }

    func requestWhenInUse() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Escalate for navigation / background group sharing.
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    func startUpdates() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
    }

    /// Background updates require the `location` UIBackgroundMode. Enabling
    /// without that key is a fatal Core Location exception.
    func setBackgroundUpdates(_ enabled: Bool) {
        guard isAuthorized else { return }
        let allow = LocationBackgroundPolicy.shouldEnable(
            requested: enabled,
            hasLocationBackgroundMode: LocationBackgroundPolicy.bundleHasLocationBackgroundMode
        )
        manager.allowsBackgroundLocationUpdates = allow
        manager.showsBackgroundLocationIndicator = allow
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.isAuthorized {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        // Core Location can deliver off the main actor — hop before touching
        // @Observable nav / cue state (avoids unsafeForcedSync warnings).
        Task { @MainActor in
            self.lastLocation = latest
            self.persistLastCoordinate(latest.coordinate)
            self.onLocation?(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // GPS hiccups are routine while riding; keep the last known fix.
    }
}
