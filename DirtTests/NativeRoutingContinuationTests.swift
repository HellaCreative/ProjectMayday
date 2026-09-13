import Foundation
import CoreLocation
import Testing
@testable import Dirt

struct NativeRoutingContinuationTests {
    @Test(arguments: [RouteProfile.dirt, .balanced, .cleanest])
    func splitNodeAndViaWayRoutesPreserveLegalOutcome(profile: RouteProfile) throws {
        for nodeRestriction in [false, true] {
            var bytes = try fixture()
            if nodeRestriction {
                let restriction = Int(read32(bytes, 120)) + 4
                write16(&bytes, restriction + 10, 0)
                write32(&bytes, restriction + 16, 1)
            }
            let pack = try GraphV2Pack(data: bytes)
            pack.geometry = try GeometryV1Pack(data: fixture(name: "legal-topology-restrictions.geometry.v1.bin"))
            for reverse in [false, true] {
                let origin = try node(pack, reverse ? 5 : 1)
                let destination = try node(pack, reverse ? 1 : 5)
                let split = try node(pack, nodeRestriction ? 2 : 3)
                var wholeRouter = OnDeviceRouter(pack: pack)
                wholeRouter.matchLimitMeters = 10
                wholeRouter.recordedStartNode = origin
                wholeRouter.recordedEndNode = destination
                let whole = wholeRouter.routeDetailed(from: coordinate(pack, origin), to: coordinate(pack, destination),
                    profile: profile, allowUnknown: false, sessionSeed: 0)
                var firstRouter = wholeRouter
                firstRouter.recordedEndNode = split
                let first = firstRouter.routeDetailed(from: coordinate(pack, origin), to: coordinate(pack, split),
                    profile: profile, allowUnknown: false, sessionSeed: 0)
                guard case .success(let approach) = first else {
                    Issue.record("Legal approach failed: \(first)"); continue
                }
                let token = try #require(approach.terminalContinuation)
                var onwardRouter = wholeRouter
                onwardRouter.recordedStartNode = split
                let onward = onwardRouter.routeDetailed(from: coordinate(pack, split), to: coordinate(pack, destination),
                    profile: profile, allowUnknown: false, arrivalContinuation: token, sessionSeed: 0)
                #expect(succeeded(whole) == reverse)
                #expect(succeeded(onward) == succeeded(whole))
            }
        }
    }

    @Test(arguments: [RouteProfile.dirt, .balanced, .cleanest])
    func fractionalSplitsDoNotRestartViaWayProgress(profile: RouteProfile) throws {
        let pack = try GraphV2Pack(data: fixture())
        pack.geometry = try GeometryV1Pack(data: fixture(name: "legal-topology-restrictions.geometry.v1.bin"))
        for reverse in [false, true] {
            let origin = try node(pack, reverse ? 5 : 1), destination = try node(pack, reverse ? 1 : 5)
            let split = CLLocationCoordinate2D(latitude: 0, longitude: reverse ? 0.0025 : 0.0015)
            var firstRouter = OnDeviceRouter(pack: pack)
            firstRouter.matchLimitMeters = 10
            firstRouter.recordedStartNode = origin
            let first = firstRouter.routeDetailed(from: coordinate(pack, origin), to: split,
                profile: profile, allowUnknown: false, sessionSeed: 0)
            guard case .success(let approach) = first else { Issue.record("Fractional approach failed: \(first)"); continue }
            let token = try #require(approach.terminalContinuation)
            guard case .edge = token.location else { Issue.record("Expected fractional token"); continue }
            var onwardRouter = OnDeviceRouter(pack: pack)
            onwardRouter.matchLimitMeters = 10
            onwardRouter.recordedEndNode = destination
            let onward = onwardRouter.routeDetailed(from: split, to: coordinate(pack, destination),
                profile: profile, allowUnknown: false, arrivalContinuation: token, sessionSeed: 0)
            #expect(succeeded(onward) == reverse)
        }
    }

    private func succeeded(_ result: Swift.Result<OnDeviceRouter.Result, OnDeviceRouter.Failure>) -> Bool {
        if case .success = result { return true }; return false
    }
    private func coordinate(_ pack: GraphV2Pack, _ node: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Double(pack.nodeCoords[node * 2 + 1]), longitude: Double(pack.nodeCoords[node * 2]))
    }

    @Test func viaWayProgressSurvivesCodableAndRenumberedNodes() throws {
        let bytes = try fixture()
        let pack = try GraphV2Pack(data: bytes)
        let receiver = try GraphV2Pack(data: renumberNodes(bytes))
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        let incoming = try edge(pack, way: 10)
        let firstVia = try edge(pack, way: 11, fromOSM: 2)
        let secondVia = try edge(pack, way: 11, fromOSM: 3)
        var state = turns.stateForArrival(node: try node(pack, 2), incomingEdge: incoming)
        state = turns.transition(state: state, outgoingEdge: firstVia, toNode: try node(pack, 3))
        state = turns.transition(state: state, outgoingEdge: secondVia, toNode: try node(pack, 4))
        let token = try turns.exportContinuation(state: state, incomingEdge: secondVia,
            arrivedFromNode: node(pack, 3), pack: pack)
        #expect(token.activeRestrictions.count == 1)
        #expect(token.incoming.fromNodeID == 3 && token.incoming.toNodeID == 4)
        let decoded = try JSONDecoder().decode(NativeRoutingContinuation.self,
            from: JSONEncoder().encode(token))
        #expect(decoded == token)
        let otherTurns = receiver.makeV4TurnStateSpace(startNode: receiver.nodeCount, endNode: receiver.nodeCount + 1)
        let restored = try otherTurns.importContinuation(decoded, pack: receiver)
        #expect(restored.toNode != (try node(pack, 4)))
        #expect(!otherTurns.allowsExit(state: restored.stateAtParentEnd, outgoingEdge: try edge(receiver, way: 12)))
        let fresh = otherTurns.stateForArrival(node: restored.toNode, incomingEdge: restored.incomingEdge)
        #expect(otherTurns.allowsExit(state: fresh, outgoingEdge: try edge(receiver, way: 12)))
    }

    @Test func nodeTurnRestrictionSurvivesRenumberedArrival() throws {
        var bytes = try fixture()
        let restriction = Int(read32(bytes, 120)) + 4
        // Test-only no-straight-on restriction from way 10 to its next way 11.
        write16(&bytes, restriction + 10, 0)
        write32(&bytes, restriction + 16, 1)
        let pack = try GraphV2Pack(data: bytes)
        let receiver = try GraphV2Pack(data: renumberNodes(bytes))
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        let incoming = try edge(pack, way: 10)
        let state = turns.stateForArrival(node: try node(pack, 2), incomingEdge: incoming)
        let token = try turns.exportContinuation(state: state, incomingEdge: incoming,
            arrivedFromNode: node(pack, 1), pack: pack)
        #expect(token.activeRestrictions.isEmpty)
        #expect(token.restrictionContext.count == 1)
        let otherTurns = receiver.makeV4TurnStateSpace(startNode: receiver.nodeCount, endNode: receiver.nodeCount + 1)
        let restored = try otherTurns.importContinuation(token, pack: receiver)
        #expect(!otherTurns.allowsExit(state: restored.stateAtParentEnd,
            outgoingEdge: try edge(receiver, way: 11, fromOSM: 2)))
        let incomplete = NativeRoutingContinuation(version: token.version, sourceEpoch: token.sourceEpoch,
            incoming: token.incoming, location: token.location,
            restrictionContext: [], activeRestrictions: [])
        #expect(throws: NativeRoutingContinuationError.incompatibleRestrictionContext) {
            try otherTurns.importContinuation(incomplete, pack: receiver)
        }
    }

    @Test func fractionalArrivalRetainsParentAndRejectsInvalidContext() throws {
        let pack = try GraphV2Pack(data: fixture())
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        let incoming = try edge(pack, way: 10)
        let state = turns.stateForArrival(node: try node(pack, 2), incomingEdge: incoming)
        let token = try turns.exportContinuation(state: state, incomingEdge: incoming,
            arrivedFromNode: node(pack, 1), pack: pack, location: .edge(fraction: 0.5))
        let restored = try turns.importContinuation(token, pack: pack)
        #expect(restored.location == .edge(fraction: 0.5))
        #expect(restored.fromNode == (try node(pack, 1)))
        #expect(restored.toNode == (try node(pack, 2)))
        #expect(throws: NativeRoutingContinuationError.invalidLocation) {
            try turns.exportContinuation(state: state, incomingEdge: incoming,
                arrivedFromNode: node(pack, 1), pack: pack, location: .edge(fraction: 1.01))
        }
        let wrongEpoch = NativeRoutingContinuation(version: token.version, sourceEpoch: "incompatible",
            incoming: token.incoming, location: token.location,
            restrictionContext: token.restrictionContext, activeRestrictions: token.activeRestrictions)
        #expect(throws: NativeRoutingContinuationError.incompatibleSourceEpoch) {
            try turns.importContinuation(wrongEpoch, pack: pack)
        }
    }

    private func fixture(name: String = "legal-topology-restrictions.graph.v4.bin") throws -> Data {
        let bundle = Bundle(for: ContinuationFixtureBundle.self)
        let url = bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
        return try Data(contentsOf: url)
    }

    private func node(_ pack: GraphV2Pack, _ original: Int64) throws -> Int {
        try #require(pack.osmNodeIds.firstIndex(of: original))
    }
    private func edge(_ pack: GraphV2Pack, way: Int64, fromOSM: Int64? = nil) throws -> Int {
        try #require(pack.osmWayIds.indices.first {
            pack.osmWayIds[$0] == way && (fromOSM == nil || pack.osmNodeIds[Int(pack.edgeFrom![$0])] == fromOSM)
        })
    }

    /// Test-only node permutation changes every local index while preserving
    /// original road identities, directed CSR topology, and legal references.
    private func renumberNodes(_ source: Data) -> Data {
        var data = source
        let count = Int(read32(source, 8)), edges = Int(read32(source, 12))
        let offsets = Int(read32(source, 24)), targets = Int(read32(source, 28))
        let arcEdges = Int(read32(source, 32)), coords = Int(read32(source, 44))
        let from = Int(read32(source, 64)), to = Int(read32(source, 68)), originals = Int(read32(source, 104))
        var cursor = 0
        for newNode in 0..<count {
            let oldNode = count - 1 - newNode
            write32(&data, offsets + newNode * 4, UInt32(cursor))
            for arc in Int(read32(source, offsets + oldNode * 4))..<Int(read32(source, offsets + (oldNode + 1) * 4)) {
                write32(&data, targets + cursor * 4, UInt32(count - 1 - Int(read32(source, targets + arc * 4))))
                write32(&data, arcEdges + cursor * 4, read32(source, arcEdges + arc * 4))
                cursor += 1
            }
            data.replaceSubrange(coords + newNode * 8..<coords + (newNode + 1) * 8,
                with: source[coords + oldNode * 8..<coords + (oldNode + 1) * 8])
            data.replaceSubrange(originals + newNode * 8..<originals + (newNode + 1) * 8,
                with: source[originals + oldNode * 8..<originals + (oldNode + 1) * 8])
        }
        write32(&data, offsets + count * 4, UInt32(cursor))
        for edge in 0..<edges {
            write32(&data, from + edge * 4, UInt32(count - 1 - Int(read32(source, from + edge * 4))))
            write32(&data, to + edge * 4, UInt32(count - 1 - Int(read32(source, to + edge * 4))))
        }
        let barriers = Int(read32(source, 116))
        for row in 0..<Int(read32(source, barriers)) {
            let at = barriers + 4 + row * 16 + 8
            write32(&data, at, UInt32(count - 1 - Int(read32(source, at))))
        }
        let restrictions = Int(read32(source, 120))
        var row = restrictions + 4
        for _ in 0..<Int(read32(source, restrictions)) {
            let old = Int32(bitPattern: read32(source, row + 20))
            if old >= 0 { write32(&data, row + 20, UInt32(count - 1 - Int(old))) }
            row += 32 + 12 * Int(read16(source, row + 10))
        }
        return data
    }
    private func read16(_ data: Data, _ at: Int) -> UInt16 {
        UInt16(data[at]) | UInt16(data[at + 1]) << 8
    }
    private func read32(_ data: Data, _ at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[at + $1]) << ($1 * 8) }
    }
    private func write16(_ data: inout Data, _ at: Int, _ value: UInt16) {
        for i in 0..<2 { data[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    private func write32(_ data: inout Data, _ at: Int, _ value: UInt32) {
        for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
}

private final class ContinuationFixtureBundle: NSObject {}
