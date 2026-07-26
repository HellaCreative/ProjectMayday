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

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastLocation: CLLocation?
    var onLocation: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        manager.distanceFilter = 5
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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        lastLocation = latest
        onLocation?(latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // GPS hiccups are routine while riding; keep the last known fix.
    }
}
