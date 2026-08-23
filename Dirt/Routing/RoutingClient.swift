import CoreLocation
import Foundation

/// HTTPS client for the production DIRT routing engine on Vercel.
final class RoutingClient {
    private let session: URLSession

    /// Cross-Canada live chains (NS→ON etc.) load several longhaul packs from R2
    /// and can take 1–3+ minutes. URLSession.shared defaults are too aggressive.
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 300
            cfg.timeoutIntervalForResource = 300
            cfg.waitsForConnectivity = true
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Single-province live hops.
    /// `nonisolated` — referenced from default args / off-main contexts under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor.
    nonisolated static let defaultTimeout: TimeInterval = 90
    /// Multi-province canada-chain (several CDN pack loads + searches).
    nonisolated static let longHaulTimeout: TimeInterval = 240

    nonisolated static func validateServiceContract(_ received: String?, endpoint: String) throws {
        guard received == AppConfig.routingServiceContract else {
            let actual = received ?? "missing"
            throw RoutingError.server(
                "DIRT \(endpoint) service is out of date (expected \(AppConfig.routingServiceContract), received \(actual))."
            )
        }
    }

    nonisolated static func identitySummary(
        contract: String?,
        build: String?,
        packs: [RoutingPackIdentity]?
    ) -> String {
        let packText = (packs ?? []).map { pack in
            let region = pack.regionId ?? "?"
            let release = pack.releaseId ?? "stable-or-local"
            let graph = pack.graphSha256 ?? "-"
            let geometry = pack.geometrySha256 ?? "-"
            let fuel = pack.fuelSha256 ?? "-"
            return "\(region){release=\(release),graph=\(graph),geometry=\(geometry),fuel=\(fuel)}"
        }.joined(separator: ",")
        return "contract=\(contract ?? "missing") build=\(build ?? "missing") packs=[\(packText)]"
    }

    /// POSTs one A→B request (the client always sends exactly two locations;
    /// multi-stage plans issue one call per stage.
    func route(_ request: RouteRequest, timeout: TimeInterval = RoutingClient.defaultTimeout) async throws -> RouteResponse {
        guard request.locations.count >= 2 else { throw RoutingError.invalidEndpoints }
        var urlRequest = URLRequest(url: AppConfig.routeURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = timeout

        let (data, urlResponse) = try await session.data(for: urlRequest)
        let http = urlResponse as? HTTPURLResponse
        guard let response = try? JSONDecoder().decode(RouteResponse.self, from: data) else {
            let status = http?.statusCode ?? 0
            let snippet = String(data: data.prefix(240), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<non-utf8 \(data.count)b>"
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "live decode fail http=\(status) body=\(snippet)"
                )
            }
            throw RoutingError.server("Routing server error (\(status)).")
        }
        try Self.validateServiceContract(response.serviceContract, endpoint: "route")
        Task { @MainActor in
            RoutingDebugLog.shared.event(
                "route identity " + Self.identitySummary(
                    contract: response.serviceContract,
                    build: response.serviceBuild,
                    packs: response.debug?.packIdentity
                )
            )
            RoutingDebugLog.shared.liveRouteDiagnostics(response)
        }
        guard response.isComplete else {
            let msg = response.message ?? response.error ?? "Route unavailable."
            let reason = response.debug?.failureReason
                ?? response.debug?.diagnostics?.failureReason
                ?? "-"
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "live incomplete http=\(http?.statusCode ?? 0) msg=\(msg) failureReason=\(reason)"
                )
            }
            throw RoutingError.server(msg)
        }
        return response
    }

    /// Discovers point 1 → F1 → … → point 2 in one graph operation. Only the
    /// returned final legs are subsequently routed, so candidate count can no
    /// longer multiply complete Dirt searches.
    func fuelChain(
        _ request: FuelChainRequest,
        timeout: TimeInterval = 30
    ) async throws -> FuelChainResponse {
        guard request.locations.count >= 2 else { throw RoutingError.invalidEndpoints }
        var urlRequest = URLRequest(url: AppConfig.liveFuelChainURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        // Long/cross-pack fuel plans are deliberately split into small
        // windows. A stalled window must fail quickly so the client can retry
        // or backtrack without waiting for a platform 504.
        urlRequest.timeoutInterval = request.fuel.windowMaxStops == nil ? timeout : 6

        let (data, urlResponse) = try await session.data(for: urlRequest)
        let http = urlResponse as? HTTPURLResponse
        guard let response = try? JSONDecoder().decode(FuelChainResponse.self, from: data) else {
            let status = http?.statusCode ?? 0
            let snippet = String(data: data.prefix(240), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<non-utf8 \(data.count)b>"
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "fuel chain decode fail http=\(status) body=\(snippet)"
                )
            }
            throw RoutingError.server("Fuel planning server error (\(status)).")
        }
        try Self.validateServiceContract(response.serviceContract, endpoint: "fuel")
        Task { @MainActor in
            RoutingDebugLog.shared.event(
                "fuel identity " + Self.identitySummary(
                    contract: response.serviceContract,
                    build: response.serviceBuild,
                    packs: response.packIdentity
                )
            )
            RoutingDebugLog.shared.liveFuelDiagnostics(response)
        }
        guard response.isUsableFuelResult else {
            let message = response.message ?? response.error ?? "Fuel chain unavailable."
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "fuel chain incomplete http=\(http?.statusCode ?? 0) code=\(response.error ?? "-") msg=\(message) "
                        + "gapReason=\(response.diagnostics?.gapReason ?? "-")"
                )
            }
            throw RoutingError.server(message)
        }
        return response
    }

    /// Resolves whether a rider waypoint itself is a packed fuel stop. This
    /// uses the same live regional fuel sidecar as itinerary planning.
    func fuelStation(
        near point: RouteCoordinate,
        within meters: Double
    ) async throws -> FuelChainStop? {
        let pad = max(0.002, meters / 111_000)
        struct Request: Encodable { let locations: [RouteLocation] }
        var request = URLRequest(url: AppConfig.liveFuelURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(Request(locations: [
            RouteLocation(latitude: point.latitude - pad, longitude: point.longitude - pad, label: "Fuel box 1"),
            RouteLocation(latitude: point.latitude + pad, longitude: point.longitude + pad, label: "Fuel box 2")
        ]))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RoutingError.server("Live fuel data is unavailable.")
        }
        guard let fuelFile = PackedFuel.decodeFile(data) else {
            throw RoutingError.server("Live fuel data returned an unreadable response.")
        }
        try Self.validateServiceContract(fuelFile.serviceContract, endpoint: "fuel data")
        Task { @MainActor in
            RoutingDebugLog.shared.event(
                "fuel data identity " + Self.identitySummary(
                    contract: fuelFile.serviceContract,
                    build: fuelFile.serviceBuild,
                    packs: fuelFile.packIdentity
                )
            )
        }
        return PackedFuel.decode(data).compactMap { station -> (POIFeature, Double)? in
            let distance = CLLocation(latitude: point.latitude, longitude: point.longitude)
                .distance(from: CLLocation(latitude: station.latitude, longitude: station.longitude))
            return distance <= meters ? (station, distance) : nil
        }.min { $0.1 < $1.1 }.map { station, _ in
            FuelChainStop(
                id: station.id, latitude: station.latitude, longitude: station.longitude,
                name: station.name, brand: station.brand, address: station.address,
                graphMeters: 0
            )
        }
    }
}
