import Foundation
import Testing
@testable import DirtRoutingEngine

struct SeamJSONReaderTests {
    private var row: String {
        #"{"coordinate":[-63.25,46.125],"gapMeters":0.125,"osmNodeId":"9007199254740993","osmWayId":"123","proof":"shared-osm-node-way-edge-legal-topology.v1","edge":{"osmWayId":"123","fromOsmNodeId":"9007199254740993","toOsmNodeId":"9007199254740995","accessForward":0,"accessReverse":2,"layer":-1,"structureLeaf":"ferry","crossingSeconds":3600},"barrierDecision":0,"unused":{"name":"Québec 🏍 {\"x\"}","array":[null,true,1.2e3]}}"#
    }
    private func file(neighbors: String? = nil, roads: String = #", "roadNeighbors":["bb"]"#) -> BinaryFile {
        let neighbors = neighbors ?? #""bb":["# + row + #"],"cc":["# + row + "]"
        return BinaryFile(data: Data((#"{"schemaVersion":"dirt-cross-pack-seams.v2","fabricReleaseId":"test","sourceEpoch":"epoch","regionId":"aa""# + roads + #", "neighbors":{"# + neighbors + "}}").utf8))
    }

    @Test(arguments: [1, 7, 64, 65_536])
    func arbitraryReadBoundariesPreserveEveryLegalField(_ chunk: Int) throws {
        let source = file()
        let expected = try JSONDecoder().decode(SeamDocument.self, from: source.data)
        let actual = try SeamJSONReader.read(source, budget: .init(seconds: 10), chunkBytes: chunk)
        #expect(actual.metadata.neighborIDs == ["bb", "cc"])
        #expect(actual.metadata.roadNeighbors == ["bb"])
        #expect(actual.document.schemaVersion == expected.schemaVersion)
        #expect(actual.document.fabricReleaseId == expected.fabricReleaseId)
        #expect(actual.document.sourceEpoch == expected.sourceEpoch)
        #expect(actual.document.regionId == expected.regionId)
        for region in ["bb", "cc"] {
            let a = try #require(actual.document.neighbors[region]?.first)
            let b = try #require(expected.neighbors[region]?.first)
            #expect(a.coordinate == b.coordinate)
            #expect(a.coordinate[0] == -63.25)
            #expect(a.coordinate[1] == 46.125)
            #expect(a.gapMeters == b.gapMeters)
            #expect(a.osmNodeId == b.osmNodeId)
            #expect(a.osmWayId == b.osmWayId)
            #expect(a.proof == b.proof)
            #expect(a.barrierDecision == b.barrierDecision)
            #expect(a.edge == b.edge)
            #expect(a.edge.crossingSeconds == b.edge.crossingSeconds)
        }
    }

    @Test func onlyRequestedNeighborsAreRetainedWithoutChangingMetadata() throws {
        let result = try SeamJSONReader.read(file(), budget: .init(seconds: 10), retaining: ["bb"], chunkBytes: 7)
        #expect(Set(result.document.neighbors.keys) == ["bb"])
        #expect(result.document.neighbors["bb"]?.count == 1)
        #expect(result.metadata.neighborIDs == ["bb", "cc"])
        let metadata = try SeamJSONReader.read(file(), budget: .init(seconds: 10), metadataOnly: true)
        #expect(metadata.metadata.neighborIDs == ["bb", "cc"])
        #expect(metadata.document.neighbors.values.allSatisfy { $0.isEmpty })
    }

    @Test func missingAndEmptyRoadMetadataRemainDifferent() throws {
        let legacy = try SeamJSONReader.read(file(neighbors: "", roads: ""), budget: .init(seconds: 10))
        #expect(legacy.metadata.neighborIDs.isEmpty)
        #expect(legacy.metadata.roadNeighbors == nil)
        let null = try SeamJSONReader.read(file(neighbors: "", roads: #", "roadNeighbors":null"#), budget: .init(seconds: 10))
        #expect(null.metadata.roadNeighbors == nil)
        let empty = try SeamJSONReader.read(file(neighbors: "", roads: #", "roadNeighbors":[]"#), budget: .init(seconds: 10))
        #expect(empty.metadata.roadNeighbors == [])
    }

    @Test func largeNeighborRetainsEveryProofInOrderAcrossStorageBoundaries() throws {
        let rows = (0..<8_193).map { index in
            row.replacingOccurrences(of: "9007199254740993", with: String(9_007_199_254_740_993 + index))
        }
        let result = try SeamJSONReader.read(
            file(neighbors: #""bb":["# + rows.joined(separator: ",") + "]"),
            budget: .init(seconds: 10))
        let anchors = try #require(result.document.neighbors["bb"])
        #expect(anchors.count == rows.count)
        for (index, anchor) in anchors.enumerated() {
            #expect(anchor.osmNodeId == String(9_007_199_254_740_993 + index))
            #expect(anchor.edge.fromOsmNodeId == anchor.osmNodeId)
            #expect(anchor.edge.accessForward == 0 && anchor.edge.accessReverse == 2)
            #expect(anchor.edge.crossingSeconds == 3_600)
        }
        var appended = anchors
        appended.append(try #require(anchors.first))
        #expect(anchors.count == 8_193)
        #expect(appended.count == 8_194)
        #expect(appended.last?.osmNodeId == anchors.first?.osmNodeId)
    }

    @Test func malformedSkippedRowsAndTruncatedFilesAreRejected() throws {
        let good = file().data
        let cases = [Data(good.dropLast()), good + Data(" true".utf8),
                     file(neighbors: #""bb":[{"bad":1,}]"#).data,
                     file(neighbors: #""bb":[],"bb":[]"#).data,
                     file(neighbors: #""bb":[],"#).data,
                     file(neighbors: #""bb":[true,]"#).data]
        for (index, bytes) in cases.enumerated() {
            #expect(throws: (any Error).self, "Malformed case \(index)") {
                try SeamJSONReader.read(BinaryFile(data: bytes), budget: .init(seconds: 10), metadataOnly: true, chunkBytes: 7)
            }
        }
    }

    @Test func expiredBudgetStopsBeforeDecoding() throws {
        #expect(throws: RoutingFailure.self) {
            try SeamJSONReader.read(file(), budget: .init(seconds: 0))
        }
    }

    @Test func compactCoordinatesRejectMissingOrExtraValuesAndKeepUnknownProofs() throws {
        for coordinate in ["[]", "[1]", "[1,2,3]", "[null,2]"] {
            let malformed = row.replacingOccurrences(of: "[-63.25,46.125]", with: coordinate)
            #expect(throws: (any Error).self) {
                try SeamJSONReader.read(file(neighbors: #""bb":["# + malformed + "]"), budget: .init(seconds: 10))
            }
        }
        let unsupported = row.replacingOccurrences(of: SeamDocument.Anchor.verifiedProof, with: "unverified")
        let document = try SeamJSONReader.read(file(neighbors: #""bb":["# + unsupported + "]"), budget: .init(seconds: 10)).document
        #expect(document.neighbors["bb"]?.first?.proof == "unverified")
    }

    @Test func cancellationStopsTheReader() async throws {
        let input = file()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SeamJSONReader.read(input, budget: .init(seconds: 10))
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled seam preparation unexpectedly completed")
        } catch is CancellationError {}
    }
}
