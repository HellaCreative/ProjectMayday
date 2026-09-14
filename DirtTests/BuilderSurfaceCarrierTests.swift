import Foundation
import Testing
@testable import Dirt

@MainActor
struct BuilderSurfaceCarrierTests {
    @Test func initialApproachExcludedFuelCarriesAndRiderBoundaryResetsMixOnly() async throws {
        let points = (0..<5).map { RouteCoordinate(longitude: -63 + Double($0)*0.1,latitude: 45) }
        let source = SurfaceCarrierSource(points: points)
        let itinerary = reduce(RiderItinerary(), .replaceAll(waypoints: [points[0],points[3],points[4]],
            profile: .balanced,allowUnknown: false,avoidMotorways: false,preferBackRoads: false)).itinerary
        let built = await ItineraryBuilder().build(itinerary,from: 0,reuse: nil,
            fuel: .init(tankMeters: 200_000,usableMeters: 180_000,reservePercent: 10),
            source: .fixed(source),onProgress: { _ in })
        let calls = source.requests.filter { $0.fuel.probeFirstReachableStation != true }
        try #require(calls.count == 4)
        #expect(calls[0].fuel.initialFillUp == true)
        #expect(calls[0].options?.owningRideSurfacePrefix?.contribution?.totalMeters == 0)
        #expect(calls[1].options?.owningRideSurfacePrefix?.contribution?.totalMeters == 0)
        #expect(calls[2].options?.owningRideSurfacePrefix?.contribution?.totalMeters == 100_000)
        #expect(calls[2].options?.owningRideSurfacePrefix?.riderLegID == itinerary.legs[0].id)
        #expect(calls[3].options?.owningRideSurfacePrefix?.riderLegID == itinerary.legs[1].id)
        #expect(calls[3].options?.owningRideSurfacePrefix?.contribution?.totalMeters == 0)
        #expect(calls[3].fuel.firstLegMaxMeters == 170_000)
        #expect(built.riderLegStatus[itinerary.legs[0].id] == .built)
        #expect(built.riderLegStatus[itinerary.legs[1].id] == .built)
        #expect(built.legs.last?.toCoordinate == points[4])
    }
}

@MainActor
private final class SurfaceCarrierSource: RoutingSource {
    let name = "pack"
    let supportsCombinedFuelPlanning = true
    let points: [RouteCoordinate]
    var requests: [FuelChainRequest] = []
    private var stage = 0
    init(points: [RouteCoordinate]) { self.points = points }
    func route(_ req: RouteRequest) async throws -> RouteResponse {
        let from = RouteCoordinate(longitude: req.locations[0].longitude,latitude: req.locations[0].latitude)
        let to = RouteCoordinate(longitude: req.locations[1].longitude,latitude: req.locations[1].latitude)
        return response(from,to,meters: 110_000)
    }
    func fuelStation(near point: RouteCoordinate,within meters: Double) async throws -> FuelChainStop? { nil }
    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        requests.append(req)
        if req.fuel.probeFirstReachableStation == true {
            return .init(status: "complete",error: nil,message: nil,regionIds: nil,stops: [],
                graphMeters: nil,diagnostics: nil,firstReachableStationMeters: 10_000)
        }
        guard stage < 4 else { throw RoutingError.server("Unexpected extra fuel stage") }
        let i = stage;stage += 1
        let stops: [FuelChainStop] = i < 2 ? [.init(id: "pump-\(i)",latitude: points[i+1].latitude,
            longitude: points[i+1].longitude,name: "pump",brand: nil,address: nil,graphMeters: nil)] : []
        let meters = [10.0,100_000,10_000,30_000][i]
        return .init(status: "complete",error: nil,message: nil,regionIds: nil,stops: stops,
            graphMeters: [meters],diagnostics: nil,routes: [response(points[i],points[i+1],meters: meters)],
            windowComplete: i >= 2)
    }
    private func response(_ from: RouteCoordinate,_ to: RouteCoordinate,meters: Double) -> RouteResponse {
        .init(status: "complete",error: nil,message: nil,distanceMeters: meters,
            estimatedMovingSeconds: nil,estimatedElapsedSeconds: nil,geometry: [from,to],segments: nil,
            stats: .init(dirtPercent: 100,pavedPercent: 0),maneuvers: nil,warnings: nil,
            dirtPercentValue: nil,pavedPercentValue: nil,
            localSurfaceContribution: .init(pavedMeters: 0,gravelMeters: meters,looseMeters: 0,
                unknownMeters: 0,ferryMeters: 0,stitchMeters: 0,nativeScoredDirtMeters: meters))
    }
}
