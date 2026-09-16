import Foundation

public struct PackManifest: Decodable, Sendable {
    public struct Artifact: Decodable, Sendable {
        public let name: String
        public let bytes: Int
        public let sha256: String
        func validate(name expected: String) throws {
            guard name == expected, bytes > 0, sha256.count == 64,
                  sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  sha256.contains(where: { $0 != "0" }) else {
                throw RoutingFailure.invalidPack("invalid \(expected) identity")
            }
        }
    }
    public let schema: String
    public let fabricReleaseId: String
    public let regionId: String
    public let capabilities: [String]
    public let sourceEpoch: String
    public let timezone: String
    public let graph: Artifact
    public let geometry: Artifact
    public let fuel: Artifact
    public let seams: Artifact?
    public func validate(requireSeams: Bool = false) throws {
        guard schema == "pack-manifest.v2", capabilities.contains("legal-topology.v1"),
              !fabricReleaseId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              regionId.count == 2, regionId.allSatisfy({ $0.isASCII && $0.isLowercase }),
              !sourceEpoch.isEmpty, timezone.contains("/"), TimeZone(identifier: timezone) != nil else {
            throw RoutingFailure.invalidPack("manifest contract")
        }
        try graph.validate(name: "graph.v4.bin")
        try geometry.validate(name: "geometry.v1.bin")
        try fuel.validate(name: "fuel.v1.json")
        if let seams {
            try seams.validate(name: "cross-pack-seams.v2.json")
            guard capabilities.contains("cross-pack-seams.v2") else { throw RoutingFailure.invalidPack("seam capability") }
        } else if requireSeams { throw RoutingFailure.invalidPack("missing seam identity") }
    }
}

public struct InstalledRoutingPack: Sendable {
    public let manifest: PackManifest
    public let graph: GraphPack
    public let fuelData: Data
    public let seamsData: Data?
}

/// Explicit local inputs. The acquisition UI supplies directories after installation;
/// missing data is returned as data demand, never translated into a server request.
public struct PackRepository: Sendable {
    private let directories: [String:URL]
    public init(installedDirectories: [String:URL]) throws {
        guard installedDirectories.values.allSatisfy(\.isFileURL) else { throw RoutingFailure.invalidPack("local directories required") }
        directories = installedDirectories
    }
    public func missing(_ regions: [String]) -> [String] {
        Array(Set(regions.filter { directories[$0] == nil })).sorted()
    }
    public func open(_ region: String, requireSeams: Bool = false, budget: ComputationBudget = .init(seconds: 60)) throws -> InstalledRoutingPack {
        try budget.check()
        guard let root = directories[region] else { throw RoutingFailure.missingPacks([region]) }
        let manifestURL = root.appendingPathComponent("pack-manifest.v2.json")
        let manifest: PackManifest
        do { manifest = try JSONDecoder().decode(PackManifest.self,from: Data(contentsOf: manifestURL)) }
        catch { throw RoutingFailure.invalidPack("manifest unreadable: \(region)") }
        try manifest.validate(requireSeams: requireSeams)
        guard manifest.regionId == region else { throw RoutingFailure.invalidPack("wrong region") }
        func verified(_ artifact: PackManifest.Artifact) throws -> BinaryFile {
            try budget.check()
            let file = try BinaryFile(url: root.appendingPathComponent(artifact.name))
            guard file.data.count == artifact.bytes, file.sha256 == artifact.sha256 else {
                throw RoutingFailure.invalidPack("\(region)/\(artifact.name) identity mismatch")
            }
            try budget.check()
            return file
        }
        let graphBytes = try verified(manifest.graph), geometryBytes = try verified(manifest.geometry)
        let graph = try GraphPack(graph: graphBytes,geometry: geometryBytes,budget: budget)
        guard graph.metadata.regionId == region else { throw RoutingFailure.invalidPack("graph region mismatch") }
        guard graph.sourceEpoch == manifest.sourceEpoch else { throw RoutingFailure.invalidPack("graph source epoch mismatch") }
        let fuel = try verified(manifest.fuel).data
        let seams = try manifest.seams.map { try verified($0).data }
        return .init(manifest: manifest,graph: graph,fuelData: fuel,seamsData: seams)
    }
    func loadSeams(_ region: String) throws -> SeamDocument {
        guard let root = directories[region] else { throw RoutingFailure.missingPacks([region]) }
        let url = root.appendingPathComponent("cross-pack-seams.v2.json")
        do { return try JSONDecoder().decode(SeamDocument.self, from: Data(contentsOf: url)) }
        catch { throw RoutingFailure.invalidPack("seam unreadable: \(region)") }
    }
    func graphBytes(_ region: String) -> Int {
        guard let root = directories[region] else { return .max }
        let url = root.appendingPathComponent("graph.v4.bin")
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? .max
    }
}

public struct RegionConnectivity: Sendable {
    public let neighbors: [String:Set<String>]
    public init(neighbors: [String:Set<String>]) { self.neighbors = neighbors }
    /// Returns the intermediate downloads as well as endpoint regions. A complete
    /// geographic search may request an alternate chain through the same interface.
    public func chain(from start: String,to end: String) throws -> [String] {
        if start == end { return [start] }
        var queue = [start], parent: [String:String] = [:], seen: Set<String> = [start], head = 0
        while head < queue.count {
            let region = queue[head]; head += 1
            for neighbor in (neighbors[region] ?? []).sorted() where seen.insert(neighbor).inserted {
                parent[neighbor] = region
                if neighbor == end {
                    var result = [end], current = end
                    while current != start { current = parent[current]!; result.append(current) }
                    return result.reversed()
                }
                queue.append(neighbor)
            }
        }
        throw RoutingFailure.noPath
    }
}
