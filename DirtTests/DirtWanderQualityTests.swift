import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct DirtWanderQualityTests {
    private func bytes(_ suffix: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety"+suffix))
    }
    private func pack() throws -> GraphV2Pack {
        let pack = try GraphV2Pack(data: bytes(".graph.v4.bin"))
        pack.geometry = try GeometryV1Pack(data: bytes(".geometry.v1.bin")); return pack
    }
    private func candidate(_ dirt: Int,_ length: Double,_ name: String) -> OnDeviceRouter.Result {
        .init(coordinates: [.init(latitude: 0,longitude: 0),.init(latitude: 0,longitude: 0.1)],
            distanceMeters: length,edgeIds: [name],legs: [
                .init(coordinates: [],distanceMeters: length*Double(100-dirt)/100,surfaceName: "paved",edgeId: name,roadClassName: "unclassified")
            ],dirtPercent: dirt,pavedPercent: 100-dirt,unknownAccessPercent: 0,
            reportedDirtPercent: dirt,reportedPavedPercent: 100-dirt,unknownSurfacePercent: 0)
    }
    @Test func highwayToggleDoesNotPreferLessDirtAmongHighwayFreeRides() throws {
        var router = try fixtureRouter(pack: pack())
        let short = candidate(47,40_000,"short"),rich = candidate(80,120_000,"rich")
        for highways in [false,true] {
            router.ridePreferences = .init(wander: 1,avoidHighways: highways)
            let winner = try #require(try router.chooseDirtEnvelopeCandidate([(short,60_000,"pavement"),(rich,120_000,"pavement")]))
            #expect(winner.route.edgeIds == ["rich"])
        }
        // The same-binary reference reproduces the diagnosed ordering defect.
        router.ridePreferences = .init(wander: 1,avoidHighways: true)
        router.useFullWanderDirtQuality = false
        let reference = try #require(try router.chooseDirtEnvelopeCandidate([(short,60_000,"pavement"),(rich,120_000,"pavement")]))
        #expect(reference.route.edgeIds == ["short"])
    }
    @Test func fullWanderDoesNotFilterAValidAwayMeanderAsRetrace() throws {
        var router = try fixtureRouter(pack: pack());router.ridePreferences = .init(wander: 1)
        let straight = candidate(75,100_000,"straight")
        var meander = candidate(80,130_000,"meander")
        meander.coordinates = [.init(latitude: 0,longitude: 0),.init(latitude: 0.15,longitude: -0.12),.init(latitude: 0.15,longitude: 0.12),.init(latitude: 0,longitude: 0.1)]
        let winner = try #require(try router.chooseDirtEnvelopeCandidate([(straight,60_000,"pavement"),(meander,60_000,"pavement")]))
        #expect(winner.route.edgeIds == ["meander"])
    }
    private func obstaclePack() throws -> GraphV2Pack {
        var graph = try bytes(".graph.v4.bin"),geometry = try bytes(".geometry.v1.bin")
        func u(_ data: Data,_ at: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at,as: UInt32.self))) } }
        func put<T: FixedWidthInteger>(_ data: inout Data,_ at: Int,_ value: T) {
            var value = value.littleEndian;withUnsafeBytes(of: &value) { data.replaceSubrange(at..<at+$0.count,with: $0) }
        }
        let coordinates = u(graph,44),attrs = u(graph,36),lengths = u(graph,40),surface = u(graph,72)
        let west = CLLocationCoordinate2D(latitude: 0.1,longitude: -0.12)
        put(&graph,coordinates+2*8,Float(west.longitude).bitPattern)
        put(&graph,coordinates+2*8+4,Float(west.latitude).bitPattern)
        // Existing branch 0→2→1 now follows an obstacle's connected dirt rim.
        // The graph and shape agree; no connector or invented successful snap.
        let gravelAttr = graph.subdata(in: attrs+3*2..<attrs+4*2)
        graph.replaceSubrange(attrs+4*2..<attrs+5*2,with: gravelAttr)
        graph[surface+4] = graph[surface+3]
        let pavedAttr = graph.subdata(in: attrs+2*2..<attrs+3*2)
        graph.replaceSubrange(attrs+5*2..<attrs+6*2,with: pavedAttr)
        graph[surface+5] = graph[surface+2]
        let westLocation = CLLocation(latitude: west.latitude,longitude: west.longitude)
        put(&graph,lengths+3*4,UInt32(ceil(westLocation.distance(from: CLLocation(latitude: 0,longitude: 0)))))
        put(&graph,lengths+4*4,UInt32(ceil(westLocation.distance(from: CLLocation(latitude: 0,longitude: 0.08)))))
        let scalarStart = 16+(u(geometry,8)+1)*4
        for scalar in [u(geometry,16+3*4)+2,u(geometry,16+4*4)] {
            put(&geometry,scalarStart+scalar*4,Float(west.longitude).bitPattern)
            put(&geometry,scalarStart+(scalar+1)*4,Float(west.latitude).bitPattern)
        }
        let result = try GraphV2Pack(data: graph);result.geometry = try GeometryV1Pack(data: geometry);return result
    }
    @Test func actualNativeDirtRimCanInitiallyTravelAwayFromDestination() throws {
        let source = try obstaclePack()
        let reference = try realRoute(source,preferences: .init(wander: 1),shared: false,quality: false)
        for shared in [false,true] {
            let route = try realRoute(source,preferences: .init(wander: 1),shared: shared)
            #expect(route.edgeIds.contains { $0.hasPrefix("w30:") })
            #expect(route.edgeIds.contains { $0.hasPrefix("w31:") })
            #expect(!route.edgeIds.contains { $0.hasPrefix("w20:") })
            #expect(route.coordinates.contains { $0.longitude < -0.1 })
            #expect(route.dirtPercent > 90)
            #expect(route.dirtPercent >= reference.dirtPercent)
            print("Dirt obstacle AB reference=\(reference.dirtPercent)% corrected=\(route.dirtPercent)% referenceMeters=\(reference.distanceMeters) correctedMeters=\(route.distanceMeters)")
            #expect(route.backtrackMeters == 0)
            #expect(route.legs.allSatisfy { $0.accessName == "motorized_verified" })
        }
    }
    private func realRoute(_ pack: GraphV2Pack,preferences: RidePreferences?,shared: Bool,quality: Bool = true) throws -> OnDeviceRouter.Result {
        var router = try fixtureRouter(pack: pack);router.ridePreferences = preferences
        router.useExtractedFullRoadCost = shared
        router.useFullWanderDirtQuality = quality
        let a = try #require(pack.osmNodeIds.firstIndex(of: 1)),b = try #require(pack.osmNodeIds.firstIndex(of: 4))
        router.recordedStartNode = a;router.recordedEndNode = b
        func point(_ n: Int) -> CLLocationCoordinate2D { .init(latitude: Double(pack.nodeCoords[n*2+1]),longitude: Double(pack.nodeCoords[n*2])) }
        switch router.routeDetailed(from: point(a),to: point(b),profile: .dirt,allowUnknown: false,sessionSeed: 17) {
        case .success(let route): return route
        case .failure(let error): throw TestFailure.route(String(describing: error))
        }
    }
    @Test func actualNativeMeanderingKnownDirtKeepsAccessRangeAndNoRetrace() throws {
        let source = try pack()
        let plain = try realRoute(source,preferences: nil,shared: false)
        let shared = try realRoute(source,preferences: .init(wander: 1),shared: true)
        #expect(plain.edgeIds == shared.edgeIds)
        #expect(plain.distanceMeters == shared.distanceMeters)
        #expect(shared.edgeIds.contains { $0.hasPrefix("w40:") })
        #expect(!shared.edgeIds.contains { $0.hasPrefix("w20:") })
        #expect(shared.dirtPercent > 90)
        #expect(shared.backtrackMeters == 0)
        #expect(shared.coordinates.contains { $0.latitude > 0.13 })
        #expect(shared.legs.allSatisfy { $0.accessName == "motorized_verified" })
        let compact = try realRoute(source,preferences: .init(wander: 0),shared: true)
        // Lower Wander's riding-quality order remains a separate open repair.
        #expect(compact.backtrackMeters == 0)
        #expect(compact.legs.allSatisfy { $0.accessName == "motorized_verified" })
    }
    private enum TestFailure: Error { case route(String) }
}
