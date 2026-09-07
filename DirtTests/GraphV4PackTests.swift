import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Graph V4 legal topology")
struct GraphV4PackTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        Issue.record("missing fixture \(name)")
        throw GraphV2Pack.PackError.truncated
    }

    @Test("truncated V4 header is rejected")
    func truncatedV4Rejected() throws {
        var bytes = [UInt8](repeating: 0, count: 140)
        bytes[0] = 0x44
        bytes[1] = 0x52
        bytes[2] = 0x54
        bytes[3] = 0x34
        bytes[4] = 4
        bytes[5] = 0
        let data = Data(bytes)
        #expect(throws: GraphV2Pack.PackError.self) {
            _ = try GraphV2Pack(data: data)
        }
    }

    @Test("V4 reader rejects V3 magic")
    func v4RejectsV3() {
        var bytes = [UInt8](repeating: 0, count: 140)
        bytes[0] = 0x44
        bytes[1] = 0x32
        bytes[2] = 0x47
        bytes[3] = 0x32
        bytes[4] = 3
        bytes[5] = 0
        #expect(throws: GraphV4Pack.PackError.unsupportedVersion) {
            _ = try GraphV4Pack(data: Data(bytes))
        }
    }

    @Test("golden V4 fixture decodes with legal-topology.v1")
    func goldenFixture() throws {
        let graph = try Data(contentsOf: fixtureURL("legal-topology-canary.graph.v4.bin"))
        let geom = try Data(contentsOf: fixtureURL("legal-topology-canary.geometry.v1.bin"))
        let identity = try GraphV4Pack(data: graph, geometry: geom)
        #expect(identity.capabilities.contains("legal-topology.v1"))
        #expect(identity.version == 4)
        #expect(identity.osmNodeIds.count == identity.nodeCount)

        let pack = try GraphV2Pack(data: graph)
        pack.geometry = try GeometryV1Pack(data: geom)
        #expect(pack.version == 4)
        #expect(pack.legalTopology)
        #expect(pack.capabilities.contains("legal-topology.v1"))
        #expect(pack.undirectedEdgeCount == 2)
        #expect(pack.osmWayIds.contains(537982310))
        #expect(pack.osmWayIds.contains(537982311))
    }

    @Test("on-device V4 search stays on the legal carriageway")
    func onDeviceTurnAwareCarriageways() throws {
        let graph = try Data(contentsOf: fixtureURL("legal-topology-canary.graph.v4.bin"))
        let geom = try Data(contentsOf: fixtureURL("legal-topology-canary.geometry.v1.bin"))
        let pack = try GraphV2Pack(data: graph)
        pack.geometry = try GeometryV1Pack(data: geom)
        let router = OnDeviceRouter(pack: pack)

        let westStart = CLLocationCoordinate2D(latitude: 45.80779, longitude: -64.191)
        let westEnd = CLLocationCoordinate2D(latitude: 45.80779, longitude: -64.209)
        switch router.routeDetailed(from: westStart, to: westEnd, profile: .balanced, allowUnknown: false) {
        case .success(let result):
            let ways = Set(result.edgeIds.compactMap { Int($0) })
            #expect(ways.contains(537982310) || result.coordinates.count >= 2)
            #expect(!result.edgeIds.contains("537982311"))
        case .failure(let error):
            Issue.record("westbound V4 ride failed: \(error)")
        }

        let eastStart = CLLocationCoordinate2D(latitude: 45.80731, longitude: -64.209)
        let eastEnd = CLLocationCoordinate2D(latitude: 45.80731, longitude: -64.191)
        switch router.routeDetailed(from: eastStart, to: eastEnd, profile: .balanced, allowUnknown: false) {
        case .success(let result):
            #expect(!result.edgeIds.contains("537982310"))
        case .failure(let error):
            Issue.record("eastbound V4 ride failed: \(error)")
        }
    }
}
