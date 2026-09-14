import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@MainActor
@Suite("Native long fuel continuation", .serialized)
struct NativeLongFuelContinuationTests {
    private struct Intent: Decodable {
        let origin: [Double], initial: [Double], rider: [Double], destination: [Double], escape: [Double], seam: [Double]
        let stationIDs: [String]
    }
    private func point(_ xy: [Double]) -> RouteCoordinate { .init(longitude: xy[0],latitude: xy[1]) }
    @Test func twentyRefillsPreserveInitialApproachRiderSeamAndReserve() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-long-fuel")
        let intent = try JSONDecoder().decode(Intent.self,from: Data(contentsOf: fixture.appendingPathComponent("native-long-fuel-intent.json")))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("native-long-fuel-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary,withIntermediateDirectories: true)
        var completed = false
        defer {
            if completed { try? FileManager.default.removeItem(at: temporary) }
            else { print("[native-long-fuel] retained failed fixture=\(temporary.path)") }
        }
        for region in ["ns","nb"] {
            let source = fixture.appendingPathComponent(region)
            let target = temporary.appendingPathComponent("v1/"+region)
            try FileManager.default.createDirectory(at: target,withIntermediateDirectories: true)
            let manifestData = try Data(contentsOf: source.appendingPathComponent("native-long-"+region+"-pack-manifest.v2.json"))
            var manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            for key in ["graph","geometry","fuel","seams"] {
                var entry = try #require(manifest[key] as? [String: Any])
                let name = try #require(entry["name"] as? String)
                let bytes = try Data(contentsOf: source.appendingPathComponent(name))
                #expect(bytes.count == entry["bytes"] as? Int)
                #expect(SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined() == entry["sha256"] as? String)
                let installedName = try #require(["graph":"graph.v4.bin","geometry":"geometry.v1.bin",
                    "fuel":"fuel.v1.json","seams":"cross-pack-seams.v2.json"][key])
                try bytes.write(to: target.appendingPathComponent(installedName))
                entry["name"] = installedName; manifest[key] = entry
            }
            try JSONSerialization.data(withJSONObject: manifest,options: [.sortedKeys])
                .write(to: target.appendingPathComponent("pack-manifest.v2.json"))
        }
        // Validate the exact installed bytes before exercising orchestration.
        // Use a separate derivative path so the actual store still prepares cold.
        for region in ["ns","nb"] {
            let target = temporary.appendingPathComponent("v1/"+region)
            let graphURL = target.appendingPathComponent("graph.v4.bin")
            let geometryURL = target.appendingPathComponent("geometry.v1.bin")
            var phase = "graph decode"
            do {
                let pack = try GraphV2Pack(data: Data(contentsOf: graphURL))
                try #require(pack.regionId == region)
                phase = "source identity"
                let identity = try ExactSnapIndexPreparation.sourceIdentity(graphURL: graphURL,geometryURL: geometryURL)
                let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: target.appendingPathComponent("pack-manifest.v2.json"))) as? [String: Any])
                let graphEntry = try #require(manifest["graph"] as? [String: Any])
                let geometryEntry = try #require(manifest["geometry"] as? [String: Any])
                print("[native-long-fuel] identity region=\(region) graph expected=\(graphEntry["sha256"] ?? "missing") actual=\(identity.graphSHA256) geometry expected=\(geometryEntry["sha256"] ?? "missing") actual=\(identity.geometrySHA256)")
                try #require(graphEntry["sha256"] as? String == identity.graphSHA256)
                try #require(geometryEntry["sha256"] as? String == identity.geometrySHA256)
                phase = "geometry identity and edge count"
                _ = try GeometryV1Pack(url: geometryURL,
                    identity: .init(sha256: identity.geometrySHA256,bytes: identity.geometryBytes),
                    expectedEdgeCount: pack.undirectedEdgeCount)
                phase = "exact index preparation"
                _ = try ExactSnapIndexPreparation.prepare(graphURL: graphURL,geometryURL: geometryURL,
                    destination: target.appendingPathComponent(".fixture-validation/snap.v1.bin"),identity: identity)
                phase = "seam application"
                try pack.applyCrossPackSeams(data: Data(contentsOf: target.appendingPathComponent("cross-pack-seams.v2.json")))
                print("[native-long-fuel] preflight region=\(region) edges=\(pack.undirectedEdgeCount) passed")
            } catch {
                Issue.record("Native fixture preflight region=\(region) phase=\(phase) error=\(error)")
                throw error
            }
        }
        // The real station lookup also checks overlapping region bounding
        // boxes. Their optional top-ups must see this fixture catalog, never
        // the public release with different immutable graph identities.
        var catalogRegions: [[String: Any]] = []
        var hostedFiles: [URL: Data] = [:]
        for region in ["ns","nb"] {
            let target = temporary.appendingPathComponent("v1/"+region)
            let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: target.appendingPathComponent("pack-manifest.v2.json"))) as? [String: Any])
            let files = try ["graph","geometry","fuel","seams"].map { key in
                try #require(manifest[key] as? [String: Any])
            }
            catalogRegions.append(["id": region,"files": files])
            for file in files {
                let name = try #require(file["name"] as? String)
                hostedFiles[AppConfig.packFileURL(version: "v1",regionId: region,fileName: name)] = try Data(contentsOf: target.appendingPathComponent(name))
            }
        }
        let catalog = try JSONSerialization.data(withJSONObject: ["version":"v1","regions":catalogRegions],options: [.sortedKeys])
        hostedFiles[AppConfig.packManifestURL] = catalog
        NativeLongFuelCatalogProtocol.configure(files: hostedFiles)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeLongFuelCatalogProtocol.self]
        let fixtureSession = URLSession(configuration: configuration)
        defer { fixtureSession.invalidateAndCancel() }
        let store = GraphPackStore(cacheRoot: temporary,refreshCatalogOnInit: false,session: fixtureSession)
        #expect(store.isInstalled("ns") && store.isInstalled("nb"))
        let origin = point(intent.origin), rider = point(intent.rider), destination = point(intent.destination)
        #expect(GraphPackStore.primaryRegionId(containing: origin.locationCoordinate) == "ns")
        #expect(GraphPackStore.primaryRegionId(containing: destination.locationCoordinate) == "nb")
        let points = [origin,rider,destination].enumerated().map { index,coordinate in
            RiderWaypoint(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d",index+1))!,coordinate: coordinate)
        }
        let legs = zip(points,points.dropFirst()).map { from,to in
            RiderLeg(from: from.id,to: to.id,profile: .cleanest,allowUnknown: false)
        }
        let itinerary = RiderItinerary(waypoints: points,legs: legs,generation: 1,impassableEdgeIDs: [])
        let source = RecordingSource(PackRoutingSource(packs: store,cache: RouteResponseCache()))
        let result = await ItineraryBuilder().build(itinerary,from: 0,reuse: nil,
            fuel: .init(tankMeters: 20_000,usableMeters: 18_000,reservePercent: 10),
            source: .fixed(source),onProgress: { _ in })
        #expect(result.riderLegStatus.values.allSatisfy { $0 == .built })
        #expect(result.legs.last?.toCoordinate == destination)
        let stops = result.legs.compactMap(\.endsAtFuelStop)
        #expect(stops.compactMap(\.stationID) == intent.stationIDs)
        #expect(stops.first?.isInitialFillUp == true)
        #expect(result.legs.filter { $0.riderLegID == legs[1].id && $0.endsAtFuelStop != nil }.count == 20)
        let first = try #require(result.legs.first)
        #expect(first.toCoordinate == point(intent.initial))
        #expect(abs((first.response.distanceMeters ?? -1)-500) < 10)
        #expect(first.fuelUsedOnArrivalMeters == 0)
        // Every connector, rider split and border tail is part of the actual
        // selected response distance. Only an actual planned pump resets usage.
        var used = 0.0
        for (index,leg) in result.legs.enumerated() {
            let distance = try #require(leg.response.distanceMeters)
            #expect(distance >= 0)
            if index > 0 { #expect(used+distance <= 18_001) }
            used = leg.endsAtFuelStop == nil ? used+distance : 0
            #expect(abs(leg.fuelUsedOnArrivalMeters-used) < 0.01)
            #expect(leg.response.terminalContinuation != nil)
        }
        let atRider = try #require(result.legs.first { $0.toCoordinate == rider })
        #expect(atRider.endsAtFuelStop == nil)
        #expect(abs(atRider.fuelUsedOnArrivalMeters-7000) < 20)
        let plans = source.requests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(plans.first?.fuel.initialFillUp == true)
        let afterRider = try #require(plans.first { $0.locations.first?.latitude == rider.latitude && $0.locations.first?.longitude == rider.longitude })
        #expect(abs(afterRider.fuel.firstLegMaxMeters-(18_000-atRider.fuelUsedOnArrivalMeters)) < 0.01)
        #expect(afterRider.options?.arrivalContinuation == atRider.response.terminalContinuation)
        #expect(plans.allSatisfy { $0.fuel.usableRangeMeters == 18_000 })
        #expect(stops.allSatisfy { $0.coordinate != point(intent.seam) })
        let cross = try #require(result.legs.first { leg in
            GraphPackStore.primaryRegionId(containing: leg.fromCoordinate.locationCoordinate) == "ns"
                && GraphPackStore.primaryRegionId(containing: leg.toCoordinate.locationCoordinate) == "nb"
        })
        #expect(abs((cross.response.distanceMeters ?? -1)-15_000) < 30)
        #expect(cross.endsAtFuelStop != nil && cross.fuelUsedOnArrivalMeters == 0)
        let escape = try #require(source.responses.compactMap(\.destinationEscapeMeters).last)
        #expect(abs(escape-5000) < 30)
        #expect(used+escape <= 18_001)
        #expect(source.responses.allSatisfy { $0.status == "complete" })
        // Record exact source and requests without substituting any routing result.
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("native-long-fuel-proof-"+UUID().uuidString+".json")
        try JSONEncoder().encode(result).write(to: evidence)
        print("[native-long-fuel] evidence=\(evidence.path)")
        completed = true
        print("[native-long-fuel] refills=\(stops.count) rider2refills=20 requests=\(plans.count) finalUsed=\(used) escape=\(escape)")
    }
    @MainActor private final class RecordingSource: RoutingSource {
        private let native: PackRoutingSource
        var requests: [FuelChainRequest] = []
        var responses: [FuelChainResponse] = []
        init(_ native: PackRoutingSource) { self.native = native }
        var name: String { native.name }
        var supportsCombinedFuelPlanning: Bool { native.supportsCombinedFuelPlanning }
        func route(_ request: RouteRequest) async throws -> RouteResponse { try await native.route(request) }
        func fuelChain(_ request: FuelChainRequest) async throws -> FuelChainResponse {
            requests.append(request)
            let result = try await native.fuelChain(request);responses.append(result);return result
        }
        func verifiedInitialFuelStation(at point: RouteCoordinate,profile: RouteProfile,allowUnknown: Bool) async throws -> FuelChainStop? {
            try await native.verifiedInitialFuelStation(at: point,profile: profile,allowUnknown: allowUnknown)
        }
        func fuelStation(near point: RouteCoordinate,within meters: Double) async throws -> FuelChainStop? {
            try await native.fuelStation(near: point,within: meters)
        }
    }
}

/// Scoped transport for this serialized integration fixture. Routing and pack
/// validation stay real; only hosted distribution is replaced with owned bytes.
nonisolated private final class NativeLongFuelCatalogProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [URL: Data] = [:]
    nonisolated(unsafe) private static var requests: [URL] = []
    static func configure(files: [URL: Data]) {
        lock.lock();defer { lock.unlock() }
        self.files = files;requests = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self,didFailWithError: URLError(.badURL));return
        }
        Self.lock.lock()
        Self.requests.append(url)
        let data = Self.files[url]
        Self.lock.unlock()
        print("[native-long-fuel] hosted request=\(url.absoluteString) status=\(data == nil ? 404 : 200)")
        guard let response = HTTPURLResponse(url: url,statusCode: data == nil ? 404 : 200,
            httpVersion: nil,headerFields: nil) else {
            client?.urlProtocol(self,didFailWithError: URLError(.badURL));return
        }
        client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self,didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
