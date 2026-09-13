import Foundation

struct FuelStop: Equatable, Sendable {
    let coordinate: RouteCoordinate
    let stationID: String?
    let name: String?
    let afterRiderLegID: UUID
    let resetsTank: Bool
    let isInitialFillUp: Bool

    init(
        coordinate: RouteCoordinate,
        stationID: String?,
        name: String?,
        afterRiderLegID: UUID,
        resetsTank: Bool = true,
        isInitialFillUp: Bool = false
    ) {
        self.coordinate = coordinate
        self.stationID = stationID
        self.name = name
        self.afterRiderLegID = afterRiderLegID
        self.resetsTank = resetsTank
        self.isInitialFillUp = isInitialFillUp
    }
}

struct FuelGap: Equatable, Sendable {
    let id: String
    let gapMeters: Double
    let overByMeters: Double
    let usableRangeMeters: Double
    let remainingFuelMeters: Double
    let reason: String
    let fromCoordinate: RouteCoordinate
    let toCoordinate: RouteCoordinate

    var message: String {
        let gapKM = Int((gapMeters / 1_000).rounded())
        let overKM = Int((overByMeters / 1_000).rounded())
        return "No pump proven in range · \(gapKM) km gap · \(overKM) km beyond range. Carry extra fuel or reshape this leg."
    }
}

enum LegStatus: Equatable, Sendable {
    case pending
    case built
    case gap(FuelGap)
    case fuelUnknown(String)
    case failed(String)
}

struct BuiltLeg: Equatable, Sendable {
    let riderLegID: UUID
    let fromCoordinate: RouteCoordinate
    let toCoordinate: RouteCoordinate
    let endsAtFuelStop: FuelStop?
    let response: RouteResponse
    let fuelUsedOnArrivalMeters: Double
    /// The effective profile for this generated hop. Nil decodes legacy/test
    /// projections as the rider-leg profile.
    let routeProfile: RouteProfile?
    let validFuelTargets: [FuelStationCandidate]

    init(
        riderLegID: UUID,
        fromCoordinate: RouteCoordinate,
        toCoordinate: RouteCoordinate,
        endsAtFuelStop: FuelStop?,
        response: RouteResponse,
        fuelUsedOnArrivalMeters: Double,
        routeProfile: RouteProfile? = nil,
        validFuelTargets: [FuelStationCandidate] = []
    ) {
        self.riderLegID = riderLegID
        self.fromCoordinate = fromCoordinate
        self.toCoordinate = toCoordinate
        self.endsAtFuelStop = endsAtFuelStop
        self.response = response
        self.fuelUsedOnArrivalMeters = fuelUsedOnArrivalMeters
        self.routeProfile = routeProfile
        self.validFuelTargets = validFuelTargets
    }

    static func == (lhs: BuiltLeg, rhs: BuiltLeg) -> Bool {
        lhs.riderLegID == rhs.riderLegID
            && lhs.fromCoordinate == rhs.fromCoordinate
            && lhs.toCoordinate == rhs.toCoordinate
            && lhs.endsAtFuelStop == rhs.endsAtFuelStop
            && lhs.fuelUsedOnArrivalMeters == rhs.fuelUsedOnArrivalMeters
            && lhs.routeProfile == rhs.routeProfile
            && lhs.validFuelTargets.map(\.id) == rhs.validFuelTargets.map(\.id)
            && lhs.response.itineraryValueSignature == rhs.response.itineraryValueSignature
    }
}

struct BuiltItinerary: Equatable, Sendable {
    let generation: Int
    let legs: [BuiltLeg]
    let riderLegStatus: [UUID: LegStatus]
    /// Unsplit rider routes support rebuilding the affected suffix. Completed
    /// generated legs before that suffix remain visible and preserve fuel carry.
    let riderRoutes: [UUID: RouteResponse]
    /// A rider-created waypoint that currently sits on a packed pump. Derived
    /// from its coordinate on every build; never persisted on RiderWaypoint.
    let waypointFuelStops: [UUID: FuelStop]

    init(
        generation: Int,
        legs: [BuiltLeg],
        riderLegStatus: [UUID: LegStatus],
        riderRoutes: [UUID: RouteResponse] = [:],
        waypointFuelStops: [UUID: FuelStop] = [:]
    ) {
        self.generation = generation
        self.legs = legs
        self.riderLegStatus = riderLegStatus
        self.riderRoutes = riderRoutes
        self.waypointFuelStops = waypointFuelStops
    }

    static func == (lhs: BuiltItinerary, rhs: BuiltItinerary) -> Bool {
        lhs.generation == rhs.generation
            && lhs.legs == rhs.legs
            && lhs.riderLegStatus == rhs.riderLegStatus
            && lhs.waypointFuelStops == rhs.waypointFuelStops
            && lhs.riderRoutes.mapValues(\.itineraryValueSignature)
                == rhs.riderRoutes.mapValues(\.itineraryValueSignature)
    }

    static func empty(for itinerary: RiderItinerary) -> BuiltItinerary {
        BuiltItinerary(
            generation: itinerary.generation,
            legs: [],
            riderLegStatus: Dictionary(
                uniqueKeysWithValues: itinerary.legs.map { ($0.id, .pending) }
            ),
            riderRoutes: [:],
            waypointFuelStops: [:]
        )
    }
}

private extension RouteResponse {
    var itineraryValueSignature: String {
        let points = (geometry ?? []).map {
            "\($0.latitude),\($0.longitude)"
        }.joined(separator: ";")
        let dirt = stats?.dirtPercent ?? dirtPercentValue ?? 0
        let paved = stats?.pavedPercent ?? pavedPercentValue ?? max(0, 100 - dirt)
        return "\(status)|\(distanceMeters ?? -1)|\(dirt)|\(paved)|\(points)"
    }
}
