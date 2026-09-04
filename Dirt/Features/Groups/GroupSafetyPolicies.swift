import CoreLocation
import Foundation

enum GroupPresencePolicy {
    static let localFixMaxAge: TimeInterval = 45
    static let remoteFixMaxAge: TimeInterval = 120
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 200

    static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
        // (0,0) is the common uninitialized sentinel and must never be presented
        // as a rider's current position.
        return abs(latitude) > 0.000_001 || abs(longitude) > 0.000_001
    }

    static func canPublish(_ location: CLLocation?, now: Date = .now) -> Bool {
        guard let location,
              isValidCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
              ),
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maximumHorizontalAccuracy,
              now.timeIntervalSince(location.timestamp) >= 0,
              now.timeIntervalSince(location.timestamp) <= localFixMaxAge
        else { return false }
        return true
    }

    static func isLive(
        sharingEnabled: Bool,
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?,
        lastSeenAt: Date?,
        now: Date = .now
    ) -> Bool {
        guard sharingEnabled,
              let latitude,
              let longitude,
              isValidCoordinate(latitude: latitude, longitude: longitude),
              let accuracyMeters,
              accuracyMeters.isFinite,
              accuracyMeters >= 0,
              accuracyMeters <= maximumHorizontalAccuracy,
              let lastSeenAt
        else { return false }
        let age = now.timeIntervalSince(lastSeenAt)
        return age >= 0 && age < remoteFixMaxAge
    }
}

/// Battery-aware persistence cadence. Distress stays close to live while
/// ordinary sharing uses the existing ten-second persisted-presence fallback.
enum GroupPresenceCadencePolicy {
    static let distressSeconds: Double = 5
    static let ordinarySeconds: Double = 10

    static func intervalSeconds(forStatus status: String) -> Double {
        switch status {
        case "breakdown", "injured", "stuck":
            distressSeconds
        default:
            ordinarySeconds
        }
    }
}

/// A distress event belongs to the group the rider selected. Persistence and
/// Realtime must use the same group id so a rider in multiple groups never
/// leaks their alert onto unrelated channels.
enum GroupAlertPolicy {
    static func broadcastGroupIDs(
        targetGroupID: String,
        connectedGroupIDs: some Sequence<String>
    ) -> [String] {
        connectedGroupIDs.contains(targetGroupID) ? [targetGroupID] : []
    }
}

struct GroupMemberRouteTarget: Identifiable, Equatable {
    let groupID: String
    let userID: String
    let displayName: String
    let coordinate: RouteCoordinate
    let lastSeenAt: Date
    let accuracyMeters: Double?
    let isLive: Bool

    var id: String { "\(groupID):\(userID)" }

    func withDisplayName(_ displayName: String) -> GroupMemberRouteTarget {
        GroupMemberRouteTarget(
            groupID: groupID,
            userID: userID,
            displayName: displayName,
            coordinate: coordinate,
            lastSeenAt: lastSeenAt,
            accuracyMeters: accuracyMeters,
            isLive: isLive
        )
    }
}

struct GroupNavigationNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case updated
        case lastKnown
        case needsReview
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

enum StopTriggeredTrackingPolicy {
    static let movingSpeedMetersPerSecond = 1.5
    static let stoppedSpeedMetersPerSecond = 0.8
    static let stoppedHoldSeconds: TimeInterval = 8
    static let meaningfulTargetMoveMeters = 100.0

    enum Motion: Equatable {
        case moving
        case stopped
        case uncertain
    }

    static func motion(for location: CLLocation) -> Motion {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= GroupPresencePolicy.maximumHorizontalAccuracy,
              location.speed >= 0
        else { return .uncertain }
        if location.speed >= movingSpeedMetersPerSecond { return .moving }
        if location.speed <= stoppedSpeedMetersPerSecond { return .stopped }
        return .uncertain
    }

    static func targetMovedMeaningfully(
        from old: RouteCoordinate,
        to new: RouteCoordinate
    ) -> Bool {
        let start = CLLocation(latitude: old.latitude, longitude: old.longitude)
        let end = CLLocation(latitude: new.latitude, longitude: new.longitude)
        return end.distance(from: start) >= meaningfulTargetMoveMeters
    }

    static func targetIsFresh(_ target: GroupMemberRouteTarget, now: Date = .now) -> Bool {
        GroupPresencePolicy.isLive(
            sharingEnabled: target.isLive,
            latitude: target.coordinate.latitude,
            longitude: target.coordinate.longitude,
            accuracyMeters: target.accuracyMeters,
            lastSeenAt: target.lastSeenAt,
            now: now
        )
    }

    static func hasBeenStoppedLongEnough(since: Date?, now: Date = .now) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= stoppedHoldSeconds
    }
}
