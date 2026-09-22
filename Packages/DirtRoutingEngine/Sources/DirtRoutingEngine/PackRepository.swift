import CryptoKit
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
    /// Province/state ids are two lowercase letters; subregions append `-<token>` (e.g. `on-s`).
    public static func isValidRegionId(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard let head = parts.first, head.count == 2,
              head.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
        if parts.count == 1 { return true }
        guard parts.count == 2 else { return false }
        let tail = parts[1]
        return !tail.isEmpty && tail.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) })
    }

    public func validate(requireSeams: Bool = false) throws {
        guard schema == "pack-manifest.v2", capabilities.contains("legal-topology.v1"),
              !fabricReleaseId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isValidRegionId(regionId),
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
    let seamsFile: BinaryFile?
    public var seamsData: Data? { seamsFile?.data }
}

final class VerifiedPackReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var receipts: Set<String> = []
    func contains(_ receipt: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return receipts.contains(receipt)
    }
    func insert(_ receipt: String) {
        lock.lock(); defer { lock.unlock() }
        receipts.insert(receipt)
    }
}

/// Compact connectivity preparation survives eviction of detailed road data.
private final class PlanningEnvelopeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, GeographicBox)] = []
    func value(for key: String, build: () throws -> GeographicBox) rethrows -> GeographicBox {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.0 == key }) {
            let hit = entries.remove(at: index); entries.append(hit)
            lock.unlock(); return hit.1
        }
        lock.unlock()
        let value = try build()
        lock.lock(); defer { lock.unlock() }
        entries.append((key, value))
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }
        return value
    }
}

/// Small bounded decoded sidecars; full road data is only weakly referenced.
private final class RoutingInputCache: @unchecked Sendable {
    struct WeakGraph { weak var value: GraphPack? }
    private let lock = NSLock()
    private var graphs: [String: WeakGraph] = [:]
    private var seams: [(String, SeamDocument)] = []
    private var seamMetadata: [(String, SeamJSONReader.Metadata)] = []
    func graph(_ key: String) -> GraphPack? {
        lock.lock(); defer { lock.unlock() }
        return graphs[key]?.value
    }
    func remember(_ graph: GraphPack, key: String) {
        lock.lock(); defer { lock.unlock() }
        graphs = graphs.filter { $0.value.value != nil }
        graphs[key] = WeakGraph(value: graph)
    }
    func document(_ key: String, build: () throws -> SeamDocument) rethrows -> SeamDocument {
        lock.lock()
        if let i = seams.firstIndex(where: { $0.0 == key }) {
            let hit = seams.remove(at: i); seams.append(hit); lock.unlock(); return hit.1
        }
        lock.unlock()
        let document = try build()
        lock.lock(); defer { lock.unlock() }
        seams.append((key, document))
        if seams.count > 2 { seams.removeFirst(seams.count - 2) }
        return document
    }
    func metadata(_ key: String, build: () throws -> SeamJSONReader.Metadata) rethrows -> SeamJSONReader.Metadata {
        lock.lock()
        if let hit = seamMetadata.first(where: { $0.0 == key }) { lock.unlock(); return hit.1 }
        lock.unlock()
        let ids = try build()
        lock.lock(); defer { lock.unlock() }
        seamMetadata.append((key, ids))
        if seamMetadata.count > 128 { seamMetadata.removeFirst(seamMetadata.count - 128) }
        return ids
    }
}

/// Explicit local inputs. The acquisition UI supplies directories after installation;
/// missing data is returned as data demand, never translated into a server request.
public struct PackRepository: Sendable {
    private struct VerificationReceipt: Codable {
        struct Artifact: Codable, Equatable {
            let name: String
            let bytes: Int
            let sha256: String
            let fileNumber: UInt64
            let modifiedAt: TimeInterval
        }
        let version: Int
        let regionId: String
        let manifestSHA256: String
        let artifacts: [Artifact]
        /// Derived during installation after the seam artifact has passed its
        /// checksum. Route-chain discovery can then avoid scanning every proof.
        let seamNeighborIDs: [String]?
        let seamRoadNeighborIDs: [String]?
    }
    private static let verificationReceiptName = ".dirt-pack-verification.v1.json"
    private let directories: [String:URL]
    /// Manifest sha256 receipts already fully validated in this process.
    private static let verified = VerifiedPackReceipts()
    private static let envelopes = PlanningEnvelopeCache()
    private static let inputs = RoutingInputCache()

    public init(installedDirectories: [String:URL]) throws {
        guard installedDirectories.values.allSatisfy(\.isFileURL) else { throw RoutingFailure.invalidPack("local directories required") }
        directories = installedDirectories
    }
    public func missing(_ regions: [String]) -> [String] {
        Array(Set(regions.filter { directories[$0] == nil })).sorted()
    }
    /// Immutable installed-byte identity for process-local preparation reuse.
    /// Include local file revisions as well as the entire manifest: replacing a
    /// corrupt artifact under an unchanged manifest must trigger verification.
    func preparationIdentity(_ regions: [String]) throws -> String {
        try regions.map { region in
            guard let root = directories[region] else { throw RoutingFailure.missingPacks([region]) }
            let manifest = try Data(contentsOf: root.appendingPathComponent("pack-manifest.v2.json"))
            let revisions = try ["graph.v4.bin", "geometry.v1.bin", "fuel.v1.json", "cross-pack-seams.v2.json"].map { name in
                let url = root.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { return name + ":missing" }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return "\(name):\(attributes[.systemFileNumber] ?? "-"):\(attributes[.size] ?? "-"):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1):\((attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? -1)"
            }.joined(separator: "|")
            return root.standardizedFileURL.path + ":" + manifest.base64EncodedString() + ":" + revisions
        }.joined(separator: "\n")
    }
    public func open(_ region: String, requireSeams: Bool = false, budget: ComputationBudget = .init(seconds: 60)) throws -> InstalledRoutingPack {
        try budget.check()
        guard let root = directories[region] else { throw RoutingFailure.missingPacks([region]) }
        let manifestURL = root.appendingPathComponent("pack-manifest.v2.json")
        let manifestData: Data
        let manifest: PackManifest
        do {
            manifestData = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
        }
        catch { throw RoutingFailure.invalidPack("manifest unreadable: \(region)") }
        try manifest.validate(requireSeams: requireSeams)
        guard manifest.regionId == region else { throw RoutingFailure.invalidPack("wrong region") }
        let identity = try preparationIdentity([region])
        if let graph = Self.inputs.graph(identity) {
            let fuel = try Data(contentsOf: root.appendingPathComponent(manifest.fuel.name), options: .mappedIfSafe)
            let seams = try manifest.seams.map { try BinaryFile(url: root.appendingPathComponent($0.name)) }
            try budget.check()
            return .init(manifest: manifest, graph: graph, fuelData: fuel, seamsFile: seams)
        }
        let receipt = try Self.verificationKey(region: region, manifest: manifest, directory: root)
        let alreadyVerified = Self.verified.contains(receipt)
            || Self.hasValidVerificationReceipt(region: region, directory: root,
                                                 manifestData: manifestData, manifest: manifest)
        func verifiedArtifact(_ artifact: PackManifest.Artifact) throws -> BinaryFile {
            try budget.check()
            let file = try BinaryFile(url: root.appendingPathComponent(artifact.name))
            guard file.data.count == artifact.bytes else {
                throw RoutingFailure.invalidPack("\(region)/\(artifact.name) identity mismatch")
            }
            if !alreadyVerified, try file.sha256 != artifact.sha256 {
                throw RoutingFailure.invalidPack("\(region)/\(artifact.name) identity mismatch")
            }
            try budget.check()
            return file
        }
        let graphBytes = try verifiedArtifact(manifest.graph), geometryBytes = try verifiedArtifact(manifest.geometry)
        // SOT §8.8: hash/validate once per install identity; re-open trusts the receipt.
        let graph = try GraphPack(graph: graphBytes, geometry: geometryBytes, budget: budget,
                                  structuralValidation: !alreadyVerified,
                                  verifiedIdentity: alreadyVerified ? (manifest.graph.sha256, manifest.geometry.sha256) : nil)
        guard graph.metadata.regionId == region else { throw RoutingFailure.invalidPack("graph region mismatch") }
        guard graph.sourceEpoch == manifest.sourceEpoch else { throw RoutingFailure.invalidPack("graph source epoch mismatch") }
        let fuel = try verifiedArtifact(manifest.fuel).data
        let seams = try manifest.seams.map { try verifiedArtifact($0) }
        Self.verified.insert(receipt)
        Self.inputs.remember(graph, key: identity)
        return .init(manifest: manifest,graph: graph,fuelData: fuel,seamsFile: seams)
    }

    /// Persist proof that this exact installed revision has already passed full
    /// checksum verification. File replacement, size, or modification changes
    /// invalidate it and restore the full verification path.
    public func persistVerificationReceipt(for region: String) throws {
        guard let root = directories[region] else { throw RoutingFailure.missingPacks([region]) }
        let manifestURL = root.appendingPathComponent("pack-manifest.v2.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
        try manifest.validate()
        guard manifest.regionId == region else { throw RoutingFailure.invalidPack("wrong region") }
        let key = try Self.verificationKey(region: region, manifest: manifest, directory: root)
        guard Self.verified.contains(key) else {
            throw RoutingFailure.invalidPack("pack must be checksum verified before recording receipt")
        }
        if let existing = Self.validVerificationReceipt(region: region, directory: root,
            manifestData: manifestData, manifest: manifest),
           manifest.seams == nil || existing.seamNeighborIDs != nil {
            return
        }
        let artifacts = [manifest.graph, manifest.geometry, manifest.fuel] + (manifest.seams.map { [$0] } ?? [])
        let records = try artifacts.map { try Self.receiptArtifact($0, in: root) }
        let seamMetadata = try manifest.seams.map { artifact in
            try SeamJSONReader.read(BinaryFile(url: root.appendingPathComponent(artifact.name)),
                                    budget: .init(seconds: 300), metadataOnly: true,
                                    trustedPayload: true).metadata
        }
        let seamRoadNeighborIDs: [String]?
        if let roads = seamMetadata?.roadNeighbors {
            seamRoadNeighborIDs = Array(roads).sorted()
        } else {
            seamRoadNeighborIDs = nil
        }
        let receipt = VerificationReceipt(version: 1, regionId: region,
            manifestSHA256: SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined(),
            artifacts: records, seamNeighborIDs: seamMetadata.map { Array($0.neighborIDs).sorted() },
            seamRoadNeighborIDs: seamRoadNeighborIDs)
        let encoded = try JSONEncoder().encode(receipt)
        try encoded.write(to: root.appendingPathComponent(Self.verificationReceiptName), options: .atomic)
    }

    public static func hasValidVerificationReceipt(region: String, directory: URL) -> Bool {
        let manifestURL = directory.appendingPathComponent("pack-manifest.v2.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: manifestData),
              (try? manifest.validate()) != nil else { return false }
        return hasValidVerificationReceipt(region: region, directory: directory,
            manifestData: manifestData, manifest: manifest)
    }

    private static func hasValidVerificationReceipt(region: String, directory: URL,
                                                     manifestData: Data, manifest: PackManifest) -> Bool {
        validVerificationReceipt(region: region, directory: directory,
            manifestData: manifestData, manifest: manifest) != nil
    }

    private static func validVerificationReceipt(region: String, directory: URL,
                                                  manifestData: Data,
                                                  manifest: PackManifest) -> VerificationReceipt? {
        guard manifest.regionId == region,
              let data = try? Data(contentsOf: directory.appendingPathComponent(verificationReceiptName)),
              let receipt = try? JSONDecoder().decode(VerificationReceipt.self, from: data),
              receipt.version == 1, receipt.regionId == region,
              receipt.manifestSHA256 == SHA256.hash(data: manifestData).map({ String(format: "%02x", $0) }).joined()
        else { return nil }
        let artifacts = [manifest.graph, manifest.geometry, manifest.fuel] + (manifest.seams.map { [$0] } ?? [])
        guard receipt.artifacts.count == artifacts.count,
              zip(receipt.artifacts, artifacts).allSatisfy({ recorded, expected in
            guard recorded.name == expected.name, recorded.bytes == expected.bytes,
                  recorded.sha256 == expected.sha256,
                  let current = try? receiptArtifact(expected, in: directory) else { return false }
            return current == recorded
        }) else { return nil }
        return receipt
    }

    private static func receiptArtifact(_ artifact: PackManifest.Artifact, in directory: URL) throws -> VerificationReceipt.Artifact {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(artifact.name).path)
        guard let bytes = (attributes[.size] as? NSNumber)?.intValue,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else {
            throw RoutingFailure.invalidPack("cannot identify \(artifact.name)")
        }
        return .init(name: artifact.name, bytes: bytes, sha256: artifact.sha256,
                     fileNumber: fileNumber, modifiedAt: modified.timeIntervalSinceReferenceDate)
    }

    private static func verificationKey(region: String, manifest: PackManifest,
                                        directory: URL) throws -> String {
        let artifacts = [manifest.graph, manifest.geometry, manifest.fuel] + (manifest.seams.map { [$0] } ?? [])
        let revisions = try artifacts.map { artifact in
            let record = try receiptArtifact(artifact, in: directory)
            return "\(record.name):\(record.fileNumber):\(record.bytes):\(record.modifiedAt)"
        }
        return ([region] + artifacts.map(\.sha256) + revisions).joined(separator: "|")
    }
    func planningEnvelope(_ region: String, budget: ComputationBudget) throws -> GeographicBox {
        try budget.check()
        let identity = try preparationIdentity([region])
        return try Self.envelopes.value(for: identity) {
            guard let root = directories[region] else { throw RoutingFailure.missingPacks([region]) }
            let manifestData = try Data(contentsOf: root.appendingPathComponent("pack-manifest.v2.json"))
            let manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
            try manifest.validate()
            guard manifest.regionId == region else { throw RoutingFailure.invalidPack("wrong region") }
            let graph = try BinaryFile(url: root.appendingPathComponent(manifest.graph.name))
            guard graph.data.count == manifest.graph.bytes else {
                throw RoutingFailure.invalidPack("planning graph identity mismatch")
            }
            let alreadyVerified = Self.hasValidVerificationReceipt(region: region, directory: root,
                manifestData: manifestData, manifest: manifest)
            if !alreadyVerified, try graph.sha256 != manifest.graph.sha256 {
                throw RoutingFailure.invalidPack("planning graph identity mismatch")
            }
            return try GraphPack.nodeBounds(graph, budget: budget)
        }
    }
    private func seamFile(_ region: String) throws -> BinaryFile {
        guard let root = directories[region] else { throw RoutingFailure.missingPacks([region]) }
        let manifestData = try Data(contentsOf: root.appendingPathComponent("pack-manifest.v2.json"))
        let manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
        try manifest.validate(requireSeams: true)
        guard manifest.regionId == region, let artifact = manifest.seams else {
            throw RoutingFailure.invalidPack("seam manifest identity")
        }
        let file = try BinaryFile(url: root.appendingPathComponent(artifact.name))
        guard file.data.count == artifact.bytes else {
            throw RoutingFailure.invalidPack("seam artifact identity mismatch")
        }
        let alreadyVerified = Self.hasValidVerificationReceipt(region: region, directory: root,
            manifestData: manifestData, manifest: manifest)
        if !alreadyVerified, try file.sha256 != artifact.sha256 {
            throw RoutingFailure.invalidPack("seam artifact identity mismatch")
        }
        return file
    }
    private func metadata(_ region: String, budget: ComputationBudget) throws -> SeamJSONReader.Metadata {
        let key = try preparationIdentity([region])
        return try Self.inputs.metadata(key) {
            if let root = directories[region] {
                let manifestData = try Data(contentsOf: root.appendingPathComponent("pack-manifest.v2.json"))
                let manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
                try manifest.validate(requireSeams: true)
                if let receipt = Self.validVerificationReceipt(region: region, directory: root,
                    manifestData: manifestData, manifest: manifest),
                   let neighborIDs = receipt.seamNeighborIDs {
                    return .init(neighborIDs: Set(neighborIDs),
                                 roadNeighbors: receipt.seamRoadNeighborIDs.map(Set.init))
                }
            }
            return try SeamJSONReader.read(seamFile(region), budget: budget, metadataOnly: true).metadata
        }
    }
    func seamNeighborIDs(_ region: String, budget: ComputationBudget = .init(seconds: 60)) throws -> Set<String> {
        try metadata(region, budget: budget).neighborIDs
    }
    func roadNeighborIDs(_ region: String, budget: ComputationBudget = .init(seconds: 60)) throws -> Set<String>? {
        // Older sidecars have no transport summary; do not invent one from
        // geographic region names. Fresh sidecars bind it to verified bytes.
        return try metadata(region, budget: budget).roadNeighbors
    }
    func loadSeams(_ region: String, retaining neighbors: Set<String>? = nil,
                   budget: ComputationBudget = .init(seconds: 60)) throws -> SeamDocument {
        let key = try preparationIdentity([region]) + "|neighbors=" + (neighbors?.sorted().joined(separator: ",") ?? "*")
        return try Self.inputs.document(key) {
            try SeamJSONReader.read(seamFile(region), budget: budget, retaining: neighbors).document
        }
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
    public static let canadianRegions: Set<String> = [
        "ns", "nb", "pe", "nl", "nl-island", "nl-lab", "qc", "qc-s", "qc-n",
        "on", "on-s", "on-n", "mb", "sk", "ab", "bc", "yt", "nt", "nu"
    ]
    public static let unitedStatesRegions: Set<String> = Set(
        "al ak az ar ca co ct de dc fl ga hi id il in ia ks ky la me md ma mi mn ms mo mt ne nv nh nj nm ny nc nd oh ok or pa ri sc sd tn tx ut vt va wa wv wi wy ca-n ca-s tx-ne tx-nw tx-se tx-sw".split(separator: " ").map(String.init))

    /// Rider endpoints authorize country transitions, independently for each leg.
    /// Same-country legs never acquire an international shortcut. Cross-border
    /// legs may enter the destination country once, without exiting it again.
    /// Unknown synthetic/legacy IDs retain ordinary connectivity semantics.
    public func respectingCountries(from start: String, to end: String) -> RegionConnectivity {
        func country(_ id: String) -> Int? {
            if Self.canadianRegions.contains(id) { return 0 }
            if Self.unitedStatesRegions.contains(id) { return 1 }
            return nil
        }
        guard let origin = country(start), let destination = country(end) else { return self }
        var result: [String: Set<String>] = [:]
        for (region, links) in neighbors {
            guard let current = country(region), origin != destination || current == origin else { continue }
            result[region] = Set(links.filter { next in
                guard let onward = country(next) else { return false }
                if origin == destination { return onward == origin }
                return current == origin || onward == destination
            })
        }
        return RegionConnectivity(neighbors: result)
    }

    /// Keep the ordinary connection as an alternative, but never let a ferry
    /// erase an available land/bridge corridor just because it crosses fewer packs.
    public func chains(from start: String, to end: String,
                       roadNeighbors: [String:Set<String>], avoidFerries: Bool = false) throws -> [[String]] {
        let ordinary = try chain(from: start, to: end)
        let roads = roadNeighbors.map { (key, value) in (key, value.intersection(neighbors[key] ?? [])) }
        if avoidFerries {
            // Unclassified legacy links remain candidates; exact road search
            // still excludes ferries. Missing metadata is not disconnection.
            let landNeighbors = neighbors.mapValues { $0 }
                .map { (id, links) in (id, roadNeighbors[id].map { links.intersection($0) } ?? links) }
            guard let land = try? RegionConnectivity(neighbors: Dictionary(uniqueKeysWithValues: landNeighbors))
                .chain(from: start, to: end) else { throw RoutingFailure.ferriesAvoided }
            return [land]
        }
        var alternatives = [ordinary]
        if let land = try? RegionConnectivity(neighbors: Dictionary(uniqueKeysWithValues: roads))
            .chain(from: start, to: end), land != ordinary {
            alternatives.append(land)
        }
        // A shared seam proves a transfer, not passage through the adjoining
        // pack. Ferry endpoints and overlap stubs may require an intermediate
        // region. Retain the shortest distinct bypass of an ordinary-chain link.
        // This bounded graph-only step opens no road packs or search labels.
        var bypasses: [[String]] = []
        for index in 0..<max(0, ordinary.count - 1) {
            let a = ordinary[index], b = ordinary[index + 1]
            let prefix = Array(ordinary.prefix(index))
            var withoutLink = neighbors
            withoutLink[a]?.remove(b)
            withoutLink[b]?.remove(a)
            // Preserve the prefix up to the deviating link. Starting every
            // bypass at the origin can rediscover the same inland route and
            // hide the useful intermediate landing-region alternative.
            for visited in prefix {
                withoutLink.removeValue(forKey: visited)
                for key in Array(withoutLink.keys) { withoutLink[key]?.remove(visited) }
            }
            if let suffix = try? RegionConnectivity(neighbors: withoutLink).chain(from: a, to: end) {
                let bypass = prefix + suffix
                if !alternatives.contains(bypass), !bypasses.contains(bypass) { bypasses.append(bypass) }
            }
        }
        func fewerRegions(_ a: [String], _ b: [String]) -> Bool {
            a.count == b.count ? a.lexicographicallyPrecedes(b) : a.count < b.count
        }
        if let bypass = bypasses.sorted(by: fewerRegions).first { alternatives.append(bypass) }
        // Known defect: this storage-based ordering can hide a preferable riding
        // connection. It is not product policy; see the routing source of truth.
        return alternatives.sorted(by: fewerRegions)
    }

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
