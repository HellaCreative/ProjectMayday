import CoreLocation
import MapLibre

/// MapLibre location source with course hold/smoothing.
///
/// Raw GPS course flips wildly when slow or momentarily inaccurate; with
/// `followWithCourse` that spins the whole map. We keep the last stable
/// heading until speed + accuracy say the new course is trustworthy, and
/// ease large jumps instead of snapping.
final class DirtMapLocationManager: NSObject, MLNLocationManager, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var lastStableCourse: CLLocationDirection = -1

    /// Below this, keep the previous course (GPS heading is noise).
    private let minSpeedForCourseUpdate: CLLocationSpeed = 1.5
    /// Ignore updates worse than this when a prior course exists.
    private let maxCourseAccuracyDegrees: CLLocationDirection = 55
    /// Soften turns larger than this in one fix.
    private let softJumpDegrees: CLLocationDirection = 70

    weak var delegate: MLNLocationManagerDelegate?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    var headingOrientation: CLDeviceOrientation {
        get { manager.headingOrientation }
        set { manager.headingOrientation = newValue }
    }

    #if compiler(>=5.3)
    @available(iOS 14.0, *)
    var accuracyAuthorization: CLAccuracyAuthorization {
        manager.accuracyAuthorization
    }
    #endif

    func distanceFilter() -> CLLocationDistance { manager.distanceFilter }
    func setDistanceFilter(_ distanceFilter: CLLocationDistance) {
        manager.distanceFilter = distanceFilter
    }

    func desiredAccuracy() -> CLLocationAccuracy { manager.desiredAccuracy }
    func setDesiredAccuracy(_ desiredAccuracy: CLLocationAccuracy) {
        manager.desiredAccuracy = desiredAccuracy
    }

    func activityType() -> CLActivityType { manager.activityType }
    func setActivityType(_ activityType: CLActivityType) {
        manager.activityType = activityType
    }

    @available(iOS 14.0, *)
    func requestTemporaryFullAccuracyAuthorization(withPurposeKey purposeKey: String) {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey)
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdatingLocation() {
        manager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
    }

    func startUpdatingHeading() {
        manager.startUpdatingHeading()
    }

    #if os(iOS)
    func stopUpdatingHeading() {
        manager.stopUpdatingHeading()
    }
    #endif

    func dismissHeadingCalibrationDisplay() {
        // No-op — we never present the calibration UI.
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        delegate?.locationManagerDidChangeAuthorization(self)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let smoothed = locations.map(stabilizeCourse(for:))
        delegate?.locationManager(self, didUpdate: smoothed)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        delegate?.locationManager(self, didUpdate: newHeading)
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        delegate?.locationManagerShouldDisplayHeadingCalibration(self) ?? false
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        delegate?.locationManager(self, didFailWithError: error)
    }

    // MARK: Course stability

    private func stabilizeCourse(for location: CLLocation) -> CLLocation {
        let rawCourse = location.course
        let hasCourse = rawCourse >= 0
        let accuracyOK =
            location.courseAccuracy < 0
            || location.courseAccuracy <= maxCourseAccuracyDegrees
        let movingFastEnough = location.speed >= minSpeedForCourseUpdate

        var course = rawCourse
        if movingFastEnough, hasCourse, accuracyOK {
            if lastStableCourse >= 0 {
                let delta = abs(Self.shortestDelta(from: lastStableCourse, to: rawCourse))
                if delta > softJumpDegrees {
                    // Ease toward the new heading instead of flipping the map.
                    course = Self.lerpCourse(from: lastStableCourse, to: rawCourse, t: 0.28)
                }
            }
            lastStableCourse = course
        } else if lastStableCourse >= 0 {
            // Stopped / noisy — hold last good course so followWithCourse stays put.
            course = lastStableCourse
        }

        return CLLocation(
            coordinate: location.coordinate,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            course: course,
            courseAccuracy: location.courseAccuracy,
            speed: location.speed,
            speedAccuracy: location.speedAccuracy,
            timestamp: location.timestamp
        )
    }

    private static func shortestDelta(from: CLLocationDirection, to: CLLocationDirection) -> CLLocationDirection {
        var delta = to - from
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private static func lerpCourse(
        from: CLLocationDirection,
        to: CLLocationDirection,
        t: Double
    ) -> CLLocationDirection {
        let delta = shortestDelta(from: from, to: to)
        var result = from + delta * t
        while result < 0 { result += 360 }
        while result >= 360 { result -= 360 }
        return result
    }
}
