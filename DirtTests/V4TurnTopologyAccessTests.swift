import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct V4TurnTopologyAccessTests {
    private func fixture(nodeRestriction: Bool) throws -> Data {
        var bytes = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin"))
        if nodeRestriction {
            let at = bytes.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 120)) }+4
            bytes[at+10] = 0; bytes[at+11] = 0
            var edge = UInt32(1).littleEndian
            Swift.withUnsafeBytes(of: &edge) { bytes.replaceSubrange(at+16..<at+20,with: $0) }
        }
        return bytes
    }
    private func withReader<T>(_ bytes: Data,_ body: (PagedV4Core) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let identity = PagedV4Core.Identity(sha256: SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined(),bytes: bytes.count)
        let reader = try PagedV4Core(url: url,identity: identity); defer { reader.close() }
        return try body(reader)
    }
    private func compare(_ expected: GraphV2Pack.V4TurnStateSpace,_ actual: GraphV2Pack.V4TurnStateSpace,
                         pack: GraphV2Pack) throws {
        #expect(actual.stateCount == expected.stateCount)
        #expect(actual.seedScannedNodes == expected.seedScannedNodes)
        #expect(actual.seedScannedArcs == expected.seedScannedArcs)
        #expect(actual.preparationReservedBytes <= V4TurnPreparationLimits().maximumReservedBytes)
        for state in 0..<expected.stateCount {
            let node = expected.graphNode(of: state)
            #expect(actual.graphNode(of: state) == node)
            guard (0..<pack.nodeCount).contains(node) else { continue }
            for arc in Int(pack.nodeOffsets[node])..<Int(pack.nodeOffsets[node+1]) {
                let edge = Int(pack.edgeUndirectedIndex[arc]), to = Int(pack.edgeTargets[arc])
                let a = expected.transition(state: state,outgoingEdge: edge,toNode: to)
                let b = actual.transition(state: state,outgoingEdge: edge,toNode: to)
                #expect(a == b)
                #expect(expected.allowsExit(state: state,outgoingEdge: edge) == actual.allowsExit(state: state,outgoingEdge: edge))
                if a >= 0 {
                    let first = try expected.exportContinuation(state: a,incomingEdge: edge,arrivedFromNode: node,pack: pack)
                    let second = try actual.exportContinuation(state: b,incomingEdge: edge,arrivedFromNode: node,pack: pack)
                    #expect(first == second)
                }
            }
        }
    }
    @Test(arguments: [false,true]) func pagedAndArrayBuildersMatchNativeStateOrdering(nodeRestriction: Bool) throws {
        let bytes = try fixture(nodeRestriction: nodeRestriction), pack = try GraphV2Pack(data: bytes)
        let expected = pack.makeV4TurnStateSpace(startNode: pack.nodeCount,endNode: pack.nodeCount+1)
        let limits = V4TurnPreparationLimits()
        let array = try ArrayV4TurnTopology(pack: pack,limits: limits)
        let fromArray = try GraphV2Pack.V4TurnStateSpace.build(topology: array,startNode: pack.nodeCount,endNode: pack.nodeCount+1)
        try compare(expected,fromArray,pack: pack)
        try withReader(bytes) { core in
            let fromPages = try core.withQuery { query in
                try core.withLegalQuery { legal in
                    let access = try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: limits)
                    return try GraphV2Pack.V4TurnStateSpace.build(topology: access,startNode: core.nodeCount,endNode: core.nodeCount+1)
                }
            }
            // Prepared state owns no escaped query: use it after descriptor close.
            core.close()
            try compare(expected,fromPages,pack: pack)
        }
    }
    @Test func stateAndMetadataLimitsDoNotBecomeEmptyLegalState() throws {
        let bytes = try fixture(nodeRestriction: false), pack = try GraphV2Pack(data: bytes)
        var limits = V4TurnPreparationLimits(); limits.maximumStates = 1
        let access = try ArrayV4TurnTopology(pack: pack,limits: limits)
        #expect(throws: V4TurnPreparationError.resourceLimit) {
            try GraphV2Pack.V4TurnStateSpace.build(topology: access,startNode: pack.nodeCount,endNode: pack.nodeCount+1,limits: limits)
        }
        limits.maximumRestrictions = 0
        try withReader(bytes) { core in
            #expect(throws: V4TurnPreparationError.resourceLimit) {
                try core.withQuery { query in
                    try core.withLegalQuery { legal in try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: limits) }
                }
            }
        }
    }
    @Test func pagedAccessorCannotMixSourcesOrEscapeScope() throws {
        let bytes = try fixture(nodeRestriction: false)
        try withReader(bytes) { first in
            try withReader(bytes) { second in
                try first.withQuery { query in
                    try first.withLegalQuery { legal in
                        #expect(throws: V4TurnPreparationError.unverifiedTopology) {
                            try PagedV4TurnTopology(core: second,query: query,legal: legal,limits: .init())
                        }
                    }
                }
                var escaped: PagedV4TurnTopology?
                try first.withQuery { query in
                    try first.withLegalQuery { legal in
                        escaped = try PagedV4TurnTopology(core: first,query: query,legal: legal,limits: .init())
                    }
                }
                #expect(throws: PagedV4Core.Failure.queryClosed) { try escaped!.validate() }
            }
        }
    }
    @Test func unknownRestrictionSemanticsRemainRawButCannotEnterEvaluator() throws {
        let original = try fixture(nodeRestriction: false)
        let first = original.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 120)) } + 4
        for (offset,value) in [(8,UInt8(255)),(27,UInt8(128)),(9,UInt8(2)),(24,UInt8(1))] {
            var bytes = original
            // The fixture's first restriction is a no-* kind. Setting only bit
            // contradicts that kind even though both fields are individually known.
            bytes[first+offset] = value
            if offset == 9 { bytes[first+8] = 0 }
            try withReader(bytes) { core in
                try core.withQuery { query in
                    try core.withLegalQuery { legal in
                        var observed = false
                        try legal.forEachRestriction { index,row in
                            if index == 0 { observed = true; if offset == 8 { #expect(row.kind == 255) } }
                        }
                        #expect(observed)
                        #expect(throws: V4TurnPreparationError.unsupportedMetadata) {
                            try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: .init())
                        }
                    }
                }
            }
        }
    }

    private func conditionalFixture(_ text: String, paddedBytes: Int = 0) throws -> Data {
        var bytes = try fixture(nodeRestriction: false)
        let start = bytes.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 124)) }
        let end = bytes.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 128)) }
        var metadata = Data(text.utf8)
        if paddedBytes > metadata.count { metadata.append(Data(repeating: 32,count: paddedBytes-metadata.count)) }
        let delta = metadata.count-(end-start)
        bytes.replaceSubrange(start..<end,with: metadata)
        for offset in [128,132,136] {
            var value = UInt32(bytes.withUnsafeBytes { Int(UInt32.routingDecode($0,at: offset)) }+delta).littleEndian
            Swift.withUnsafeBytes(of: &value) { bytes.replaceSubrange(offset..<offset+4,with: $0) }
        }
        return bytes
    }
    private var conditionalDefinition: String {
        #"{"policy":"fail_closed","rules":[{"osmWayId":"123","policy":"fail_closed","rules":[{"tag":"access:conditional","raw":"no @ (winter)","evaluable":false}]}]}"#
    }
    @Test func nonemptyConditionalDefinitionsPreserveClosedDirectionsAndOrdinaryTurns() throws {
        var bytes = try conditionalFixture(conditionalDefinition,paddedBytes: 143_567)
        let access = bytes.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 112)) }
        bytes[access] = 5; bytes[access+1] = 2
        let pack = try GraphV2Pack(data: bytes)
        try withReader(bytes) { core in
            try core.withQuery { query in
                try core.withLegalQuery { legal in
                    let topology = try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: .init())
                    #expect(topology.restrictions.count == pack.restrictions.count)
                    #expect(try query.edge(0).forwardAccess == 5)
                    #expect(try query.edge(0).reverseAccess == 2)
                    let actual = try GraphV2Pack.V4TurnStateSpace.build(topology: topology,startNode: pack.nodeCount,endNode: pack.nodeCount+1)
                    try compare(pack.makeV4TurnStateSpace(startNode: pack.nodeCount,endNode: pack.nodeCount+1),actual,pack: pack)
                }
            }
        }
    }
    @Test func conditionalMetadataHasExplicitInputAndTemporaryReservationLimits() throws {
        let bytes = try conditionalFixture(conditionalDefinition,paddedBytes: 143_567)
        for reservedLimit in [false,true] {
            var limits = V4TurnPreparationLimits()
            if reservedLimit { limits.maximumReservedBytes = 143_567 }
            else { limits.maximumConditionalMetadataBytes = 65_536 }
            try withReader(bytes) { core in
                #expect(throws: V4TurnPreparationError.resourceLimit) {
                    try core.withQuery { query in try core.withLegalQuery { legal in
                        try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: limits)
                    } }
                }
            }
        }
    }
    @Test func malformedConditionalPoliciesAndActualReferencesRemainUnsupported() throws {
        for json in ["{", #"{"policy":"open","rules":[]}"#, #"{"policy":"fail_closed","rules":[1]}"#,
                     conditionalDefinition.replacingOccurrences(of: "fail_closed",with: "evaluate")] {
            try withReader(conditionalFixture(json)) { core in
                #expect(throws: V4TurnPreparationError.unsupportedMetadata) {
                    try core.withQuery { query in try core.withLegalQuery { legal in
                        try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: .init())
                    } }
                }
            }
        }
        var bytes = try conditionalFixture(conditionalDefinition)
        let first = bytes.withUnsafeBytes { Int(UInt32.routingDecode($0,at: 120)) }+4
        for offset in 28..<32 { bytes[first+offset] = 0 }
        try withReader(bytes) { core in
            #expect(throws: V4TurnPreparationError.unsupportedMetadata) {
                try core.withQuery { query in try core.withLegalQuery { legal in
                    try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: .init())
                } }
            }
        }
    }
    @Test func conditionalMetadataCancellationDoesNotPublishTopology() throws {
        let bytes = try conditionalFixture(conditionalDefinition,paddedBytes: 143_567)
        try withReader(bytes) { core in
            var cancel = false
            #expect(throws: RoutingPageError.cancelled) {
                try core.withQuery { query in try core.withLegalQuery(cancelled: { cancel }) { legal in
                    cancel = true
                    return try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: .init())
                } }
            }
        }
    }
    @Test func conditionalMetadataMutationDoesNotPublishTopology() throws {
        let bytes = try conditionalFixture(conditionalDefinition,paddedBytes: 143_567)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let identity = PagedV4Core.Identity(sha256: SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined(),bytes: bytes.count)
        let core = try PagedV4Core(url: url,identity: identity); defer { core.close() }
        #expect(throws: (any Error).self) {
            try core.withQuery { query in try core.withLegalQuery { legal in
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(bytes.count-1))
                return try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: .init())
            } }
        }
    }

}
