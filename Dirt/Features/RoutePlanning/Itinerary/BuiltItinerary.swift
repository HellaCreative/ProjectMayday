import Foundation

struct FuelStop: Equatable, Sendable {
    let coordinate: RouteCoordinate
    let stationID: String?
    let name: String?
    let afterRiderLegID: UUID
    let resetsTank: Bool

    init(
        coordinate: RouteCoordinate,
        stationID: String?,
        name: String?,
        afterRiderLegID: UUID,
        resetsTank: Bool = true
    ) {
        self.coordinate = coordinate
        self.stationID = stationID
        self.name = name
        self.afterRiderLegID = afterRiderLegID
        self.resetsTank = resetsTank
    }
}

enum LegStatus: Equatable, Sendable {
    case pending
    case built
    case failed(String)
}

struct BuiltLeg: Equatable, Sendable {
    let riderLegID: UUID
    let fromCoordinate: RouteCoordinate
    let toCoordinate: RouteCoordinate
    let endsAtFuelStop: FuelStop?
    let response: RouteResponse
    let fuelUsedOnArrivalMeters: Double

    static func == (lhs: BuiltLeg, rhs: BuiltLeg) -> Bool {
        lhs.riderLegID == rhs.riderLegID
            && lhs.fromCoordinate == rhs.fromCoordinate
            && lhs.toCoordinate == rhs.toCoordinate
            && lhs.endsAtFuelStop == rhs.endsAtFuelStop
            && lhs.fuelUsedOnArrivalMeters == rhs.fuelUsedOnArrivalMeters
            && lhs.response.itineraryValueSignature == rhs.response.itineraryValueSignature
    }
}

struct BuiltItinerary: Equatable, Sendable {
    let generation: Int
    let legs: [BuiltLeg]
    let riderLegStatus: [UUID: LegStatus]

    static func empty(for itinerary: RiderItinerary) -> BuiltItinerary {
        BuiltItinerary(
            generation: itinerary.generation,
            legs: [],
            riderLegStatus: Dictionary(
                uniqueKeysWithValues: itinerary.legs.map { ($0.id, .pending) }
            )
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
