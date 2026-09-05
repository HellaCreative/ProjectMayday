import CryptoKit
import Foundation

/// Separate best-effort cache for Rider Services. It is intentionally outside
/// GraphPackStore: missing campground/lodging/liquor data can never block or
/// invalidate routing, fuel proof, or Start Navigation.
actor RiderServicesStore {
    private struct Catalog: Decodable, Sendable {
        let schema: String
        let regions: [Region]
    }

    private struct Region: Decodable, Sendable {
        let id: String
        let bounds: [Double]
        let file: FileIdentity
    }

    private struct FileIdentity: Decodable, Sendable {
        let name: String
        let bytes: Int
        let sha256: String
    }

    private struct Pack: Decodable, Sendable {
        let schema: String
        let regionId: String
        let elements: [RiderServiceElement]
    }

    private let manifestURL: URL
    private let cacheRoot: URL
    private let session: URLSession
    private var catalog: Catalog?
    private var activeRefresh: (id: UUID, task: Task<Void, Error>)?
    private var lastSuccessfulRefresh: Date?
    private let minimumRefreshInterval: TimeInterval = 15 * 60

    init(
        manifestURL: URL = AppConfig.riderServicesManifestURL,
        cacheRoot: URL? = nil,
        session: URLSession? = nil
    ) {
        self.manifestURL = manifestURL
        let base = cacheRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.cacheRoot = base.appendingPathComponent("dirt-rider-services/v1", isDirectory: true)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Returns a complete cached viewport or nil. A partial/mismatched region
    /// is never presented as a complete offline result.
    func cachedElements(in bounds: MapViewportBounds) -> [RiderServiceElement]? {
        guard let catalog = loadCatalogFromDiskIfNeeded() else { return nil }
        let regions = catalog.regions.filter { Self.intersects(bounds, $0.bounds) }
        guard !regions.isEmpty else { return [] }
        var elements: [RiderServiceElement] = []
        for region in regions {
            let file = localFile(for: region)
            guard Self.fileMatchesIdentity(file, identity: region.file),
                  let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                  let pack = try? JSONDecoder().decode(Pack.self, from: data),
                  pack.schema == "rider-services.v1",
                  pack.regionId == region.id
            else { return nil }
            elements.append(contentsOf: pack.elements.filter { element in
                guard let latitude = element.lat ?? element.center?.lat,
                      let longitude = element.lon ?? element.center?.lon else { return false }
                return latitude >= bounds.minLatitude && latitude <= bounds.maxLatitude
                    && longitude >= bounds.minLongitude && longitude <= bounds.maxLongitude
            })
        }
        return Self.unique(elements)
    }

    /// Downloads the viewport's whole-region sidecars and refreshes any regions
    /// already retained offline. The catalog changes only after they verify.
    func refreshCache(in bounds: MapViewportBounds) async throws {
        if let lastSuccessfulRefresh,
           Date().timeIntervalSince(lastSuccessfulRefresh) < minimumRefreshInterval,
           cachedElements(in: bounds) != nil {
            return
        }
        if let activeRefresh {
            try await activeRefresh.task.value
            if cachedElements(in: bounds) != nil { return }
        }
        let id = UUID()
        let task = Task { try await performRefreshCache(in: bounds) }
        activeRefresh = (id, task)
        defer {
            if activeRefresh?.id == id { activeRefresh = nil }
        }
        try await task.value
        lastSuccessfulRefresh = Date()
    }

    private func performRefreshCache(in bounds: MapViewportBounds) async throws {
        let existing = loadCatalogFromDiskIfNeeded()
        let preservedIDs = Set((existing?.regions ?? []).compactMap { region in
            Self.fileMatchesIdentity(localFile(for: region), identity: region.file) ? region.id : nil
        })
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (manifestData, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        let incoming = try JSONDecoder().decode(Catalog.self, from: manifestData)
        try Self.validate(incoming)
        let required = incoming.regions.filter {
            Self.intersects(bounds, $0.bounds) || preservedIDs.contains($0.id)
        }
        guard !required.isEmpty else { return }
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        for region in required {
            let destination = localFile(for: region)
            if Self.fileMatchesIdentity(destination, identity: region.file) { continue }
            var fileRequest = URLRequest(url: regionURL(for: region))
            fileRequest.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, fileResponse) = try await session.data(for: fileRequest)
            try Self.requireSuccess(fileResponse)
            guard Self.dataMatchesIdentity(data, identity: region.file) else {
                throw StoreError.identityMismatch(region.id)
            }
            let decoded = try JSONDecoder().decode(Pack.self, from: data)
            guard decoded.schema == "rider-services.v1", decoded.regionId == region.id else {
                throw StoreError.invalidPack(region.id)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        }
        try manifestData.write(to: cacheRoot.appendingPathComponent("manifest.json"), options: .atomic)
        catalog = incoming
    }

    nonisolated static func dataMatchesIdentity(_ data: Data, bytes: Int, sha256: String) -> Bool {
        guard bytes > 0, data.count == bytes,
              sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
        else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual.caseInsensitiveCompare(sha256) == .orderedSame
    }

    private func loadCatalogFromDiskIfNeeded() -> Catalog? {
        if let catalog { return catalog }
        let url = cacheRoot.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Catalog.self, from: data),
              (try? Self.validate(decoded)) != nil else { return nil }
        catalog = decoded
        return decoded
    }

    private func localFile(for region: Region) -> URL {
        cacheRoot.appendingPathComponent(region.id, isDirectory: true)
            .appendingPathComponent(region.file.name)
    }

    private func regionURL(for region: Region) -> URL {
        manifestURL.deletingLastPathComponent()
            .appendingPathComponent(region.id)
            .appendingPathComponent(region.file.name)
    }

    private static func fileMatchesIdentity(_ url: URL, identity: FileIdentity) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              values.fileSize == identity.bytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return dataMatchesIdentity(data, bytes: identity.bytes, sha256: identity.sha256)
    }

    private static func dataMatchesIdentity(_ data: Data, identity: FileIdentity) -> Bool {
        dataMatchesIdentity(data, bytes: identity.bytes, sha256: identity.sha256)
    }

    private static func validate(_ catalog: Catalog) throws {
        guard catalog.schema == "rider-services-manifest.v1", !catalog.regions.isEmpty else {
            throw StoreError.invalidCatalog
        }
        var ids = Set<String>()
        for region in catalog.regions {
            guard region.id.range(of: "^[a-z]{2}$", options: .regularExpression) != nil,
                  ids.insert(region.id).inserted,
                  region.bounds.count == 4,
                  region.bounds.allSatisfy(\.isFinite),
                  region.bounds[0] >= -180, region.bounds[2] <= 180,
                  region.bounds[1] >= -90, region.bounds[3] <= 90,
                  region.bounds[0] < region.bounds[2], region.bounds[1] < region.bounds[3],
                  region.file.name.range(
                    of: "^rider-services\\.v1\\.[a-f0-9]{12}\\.json$",
                    options: .regularExpression
                  ) != nil,
                  region.file.bytes > 0,
                  region.file.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
            else { throw StoreError.invalidCatalog }
        }
    }

    private static func intersects(_ viewport: MapViewportBounds, _ region: [Double]) -> Bool {
        region.count == 4
            && viewport.maxLongitude >= region[0]
            && viewport.minLongitude <= region[2]
            && viewport.maxLatitude >= region[1]
            && viewport.minLatitude <= region[3]
    }

    private static func unique(_ elements: [RiderServiceElement]) -> [RiderServiceElement] {
        var seen = Set<String>()
        return elements.filter { seen.insert("\($0.type ?? "node"):\($0.id)").inserted }
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StoreError.requestRejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private enum StoreError: LocalizedError {
        case invalidCatalog
        case invalidPack(String)
        case identityMismatch(String)
        case requestRejected(Int)

        var errorDescription: String? {
            switch self {
            case .invalidCatalog: "The Rider Services catalog is invalid."
            case .invalidPack(let id): "The Rider Services data for \(id.uppercased()) is invalid."
            case .identityMismatch(let id): "The Rider Services data for \(id.uppercased()) did not verify."
            case .requestRejected(let code): "The Rider Services download failed (HTTP \(code))."
            }
        }
    }
}
