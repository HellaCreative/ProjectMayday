import Foundation
import Observation

struct ShortbreadTileSource: Equatable, Hashable, Sendable {
    enum Provider: String, Sendable {
        case dirtR2 = "dirt-r2"
        case publicOSM = "public-osm"
    }

    let provider: Provider
    let releaseID: String
    let shortbreadSchema: String
    let cacheNamespace: String
    let tileTemplate: String

    nonisolated static let publicOSM = ShortbreadTileSource(
        provider: .publicOSM,
        releaseID: "public-osm-shortbread-v1",
        shortbreadSchema: "1",
        cacheNamespace: "shortbread-v1",
        tileTemplate: "https://vector.openstreetmap.org/shortbread_v1/{z}/{x}/{y}.mvt"
    )

    nonisolated var styleCacheKey: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = releaseID.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(cleaned)
    }

    nonisolated func url(for tile: CorridorTilePlanner.Tile) -> URL? {
        url(z: tile.z, x: tile.x, y: tile.y)
    }

    nonisolated func url(z: Int, x: Int, y: Int) -> URL? {
        URL(string: tileTemplate
            .replacingOccurrences(of: "{z}", with: String(z))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y)))
    }
}

struct ShortbreadTileManifest: Decodable, Equatable, Sendable {
    let contract: String
    let releaseID: String
    let shortbreadSchema: String
    let sourceUpdatedAt: String
    let cacheNamespace: String
    let minZoom: Int
    let maxZoom: Int
    let bounds: [Double]
    let tileTemplate: String
    let sampleTile: URL
    let attribution: String

    nonisolated func validatedSource(manifestURL: URL) throws -> ShortbreadTileSource {
        guard contract == "dirt.shortbread-manifest.v1" else {
            throw ShortbreadTileSourceError.invalidManifest("contract")
        }
        guard releaseID.range(of: #"^[a-z0-9][a-z0-9-]{2,63}$"#, options: .regularExpression) != nil else {
            throw ShortbreadTileSourceError.invalidManifest("release")
        }
        guard shortbreadSchema.split(separator: ".").first == "1" else {
            throw ShortbreadTileSourceError.incompatibleSchema(shortbreadSchema)
        }
        guard cacheNamespace == "shortbread-v1" else {
            throw ShortbreadTileSourceError.invalidManifest("cache namespace")
        }
        guard minZoom == 0, maxZoom == 14 else {
            throw ShortbreadTileSourceError.invalidManifest("zoom range")
        }
        guard bounds.count == 4,
              bounds.allSatisfy(\.isFinite),
              bounds[0] >= -180, bounds[2] <= 180,
              bounds[1] >= -90, bounds[3] <= 90,
              bounds[0] < bounds[2], bounds[1] < bounds[3]
        else {
            throw ShortbreadTileSourceError.invalidManifest("bounds")
        }
        guard tileTemplate.contains("{z}"),
              tileTemplate.contains("{x}"),
              tileTemplate.contains("{y}")
        else {
            throw ShortbreadTileSourceError.invalidManifest("tile template")
        }
        let probeTemplate = tileTemplate
            .replacingOccurrences(of: "{z}", with: "0")
            .replacingOccurrences(of: "{x}", with: "0")
            .replacingOccurrences(of: "{y}", with: "0")
        guard let tileURL = URL(string: probeTemplate),
              tileURL.scheme == "https",
              tileURL.host == manifestURL.host,
              sampleTile.scheme == "https",
              sampleTile.host == manifestURL.host
        else {
            throw ShortbreadTileSourceError.invalidManifest("origin")
        }
        guard attribution.localizedCaseInsensitiveContains("OpenStreetMap") else {
            throw ShortbreadTileSourceError.invalidManifest("attribution")
        }
        return ShortbreadTileSource(
            provider: .dirtR2,
            releaseID: releaseID,
            shortbreadSchema: shortbreadSchema,
            cacheNamespace: cacheNamespace,
            tileTemplate: tileTemplate
        )
    }
}

enum ShortbreadTileSourceError: LocalizedError, Equatable {
    case invalidManifest(String)
    case incompatibleSchema(String)
    case unhealthy(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let field): "Invalid Shortbread manifest: \(field)."
        case .incompatibleSchema(let version): "Unsupported Shortbread schema \(version)."
        case .unhealthy(let reason): "Shortbread service is unhealthy: \(reason)."
        }
    }
}

@MainActor
@Observable
final class ShortbreadTileSourceManager {
    static let forcePublicFallbackKey = "dirt.shortbread.forcePublicFallback"

    private(set) var activeSource = ShortbreadTileSource.publicOSM
    private(set) var lastFallbackReason: String?
    private(set) var hasResolved = false

    @ObservationIgnored private let manifestURL: URL
    @ObservationIgnored private let session: URLSession

    init(
        manifestURL: URL = AppConfig.shortbreadManifestURL,
        session: URLSession = ShortbreadTileSourceManager.makeSession()
    ) {
        self.manifestURL = manifestURL
        self.session = session
    }

    func resolve() async -> ShortbreadTileSource {
        if hasResolved { return activeSource }
        defer { hasResolved = true }

        guard !UserDefaults.standard.bool(forKey: Self.forcePublicFallbackKey) else {
            return fallBack(reason: "forced rollback")
        }

        do {
            var request = URLRequest(url: manifestURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ShortbreadTileSourceError.unhealthy("manifest HTTP")
            }
            let manifest = try JSONDecoder().decode(ShortbreadTileManifest.self, from: data)
            let source = try manifest.validatedSource(manifestURL: manifestURL)

            var probe = URLRequest(url: manifest.sampleTile)
            probe.timeoutInterval = 8
            probe.cachePolicy = .reloadIgnoringLocalCacheData
            probe.setValue("application/vnd.mapbox-vector-tile", forHTTPHeaderField: "Accept")
            let (tileData, tileResponse) = try await session.data(for: probe)
            guard let tileHTTP = tileResponse as? HTTPURLResponse,
                  tileHTTP.statusCode == 200,
                  !tileData.isEmpty,
                  tileHTTP.value(forHTTPHeaderField: "Content-Type")?
                    .localizedCaseInsensitiveContains("mapbox-vector-tile") == true,
                  tileHTTP.value(forHTTPHeaderField: "X-Dirt-Shortbread-Release") == source.releaseID,
                  tileHTTP.value(forHTTPHeaderField: "X-Dirt-Shortbread-Source") == "r2"
            else {
                throw ShortbreadTileSourceError.unhealthy("sample tile")
            }

            activeSource = source
            lastFallbackReason = nil
            RoutingDebugLog.shared.event(
                "map shortbread provider=\(source.provider.rawValue) release=\(source.releaseID) "
                    + "schema=\(source.shortbreadSchema) cache=\(source.cacheNamespace)"
            )
            return source
        } catch {
            return fallBack(reason: String(describing: error))
        }
    }

    private func fallBack(reason: String) -> ShortbreadTileSource {
        activeSource = .publicOSM
        lastFallbackReason = reason
        RoutingDebugLog.shared.event(
            "map shortbread provider=public-osm fallback=1 reason=\(Self.compact(reason))"
        )
        return activeSource
    }

    nonisolated private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    nonisolated private static func compact(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ").prefix(180))
    }
}
