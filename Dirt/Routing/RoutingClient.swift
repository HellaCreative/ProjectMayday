import CoreLocation
import Foundation

/// HTTPS client for the production DIRT routing engine on Vercel.
final class RoutingClient {
    private let session: URLSession

    nonisolated private static func diagnosticRequestID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    nonisolated private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    nonisolated private static func coordinateSummary(_ locations: [RouteLocation]) -> String {
        locations.map {
            String(format: "%.5f,%.5f", $0.latitude, $0.longitude)
        }.joined(separator: ">")
    }

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
        let requestID = Self.diagnosticRequestID("route")
        let started = Date()
        var urlRequest = URLRequest(url: AppConfig.routeURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(requestID, forHTTPHeaderField: "X-Dirt-Request-ID")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = timeout

        let beginLine = "route request begin id=\(requestID) profile=\(request.profile.rawValue) "
            + "points=\(Self.coordinateSummary(request.locations)) "
            + "maxPath=\(request.options?.maxPathMeters.map { String(Int($0)) } ?? "-")m "
            + "timeoutMs=\(Int(timeout * 1_000))"
        Task { @MainActor in RoutingDebugLog.shared.event(beginLine) }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch {
            let ns = error as NSError
            let failureLine = "route request transport-fail id=\(requestID) "
                + "elapsedMs=\(Self.elapsedMilliseconds(since: started)) "
                + "cancelled=\(Task.isCancelled ? 1 : 0) "
                + "domain=\(ns.domain) code=\(ns.code) msg=\(error.localizedDescription)"
            Task { @MainActor in RoutingDebugLog.shared.event(failureLine) }
            throw error
        }
        let http = urlResponse as? HTTPURLResponse
        let responseLine = "route request response id=\(requestID) "
            + "http=\(http?.statusCode ?? 0) bytes=\(data.count) "
            + "elapsedMs=\(Self.elapsedMilliseconds(since: started))"
        Task { @MainActor in RoutingDebugLog.shared.event(responseLine) }
        guard let response = try? JSONDecoder().decode(RouteResponse.self, from: data) else {
            let status = http?.statusCode ?? 0
            let snippet = String(data: data.prefix(240), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<non-utf8 \(data.count)b>"
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "live decode fail id=\(requestID) http=\(status) body=\(snippet)"
                )
            }
            throw RoutingError.server("Routing server error (\(status)).")
        }
        try Self.validateServiceContract(response.serviceContract, endpoint: "route")
        Task { @MainActor in
            RoutingDebugLog.shared.event(
                "route identity request=\(requestID) " + Self.identitySummary(
                    contract: response.serviceContract,
                    build: response.serviceBuild,
                    packs: response.debug?.packIdentity
                )
            )
            RoutingDebugLog.shared.liveRouteDiagnostics(response, requestID: requestID)
        }
        guard response.isComplete else {
            let msg = response.message ?? response.error ?? "Route unavailable."
            let reason = response.debug?.failureReason
                ?? response.debug?.diagnostics?.failureReason
                ?? "-"
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "live incomplete id=\(requestID) http=\(http?.statusCode ?? 0) "
                        + "msg=\(msg) failureReason=\(reason)"
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
        let requestID = Self.diagnosticRequestID("fuel")
        let started = Date()
        var urlRequest = URLRequest(url: AppConfig.liveFuelChainURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(requestID, forHTTPHeaderField: "X-Dirt-Request-ID")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        // Long/cross-pack fuel plans are deliberately split into small
        // windows. A stalled window must fail quickly so the client can retry
        // or backtrack without waiting for a platform 504.
        let requestedBudget = request.fuel.windowTimeBudgetMs.map {
            max(1, Double($0) / 1_000 + 1.5)
        }
        let defaultWindowTimeout = request.fuel.windowMaxStops == nil ? timeout : 6
        // The server owns the planning deadline. Leave enough transport grace
        // for it to return a proven partial window instead of cancelling the
        // request at the same six-second boundary.
        urlRequest.timeoutInterval = requestedBudget ?? defaultWindowTimeout

        let beginLine = "fuel request begin id=\(requestID) riderLeg=\(request.fuel.riderLegId) "
            + "profile=\(request.profile.rawValue) points=\(Self.coordinateSummary(request.locations)) "
            + "usable=\(Int(request.fuel.usableRangeMeters))m "
            + "first=\(Int(request.fuel.firstLegMaxMeters))m "
            + "minimumStops=\(request.fuel.minimumFuelStops) "
            + "routeFirst=\(request.fuel.routeFirstPlan == true ? 1 : 0) "
            + "escape=\(request.fuel.ensureDestinationFuelEscape == true ? 1 : 0) "
            + "windowStops=\(request.fuel.windowMaxStops.map(String.init) ?? "-") "
            + "budgetMs=\(request.fuel.windowTimeBudgetMs.map(String.init) ?? "-") "
            + "transportTimeoutMs=\(Int(urlRequest.timeoutInterval * 1_000))"
        Task { @MainActor in RoutingDebugLog.shared.event(beginLine) }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch {
            let ns = error as NSError
            let failureLine = "fuel request transport-fail id=\(requestID) "
                + "riderLeg=\(request.fuel.riderLegId) "
                + "elapsedMs=\(Self.elapsedMilliseconds(since: started)) "
                + "cancelled=\(Task.isCancelled ? 1 : 0) "
                + "domain=\(ns.domain) code=\(ns.code) msg=\(error.localizedDescription)"
            Task { @MainActor in RoutingDebugLog.shared.event(failureLine) }
            throw error
        }
        let http = urlResponse as? HTTPURLResponse
        let responseLine = "fuel request response id=\(requestID) riderLeg=\(request.fuel.riderLegId) "
            + "http=\(http?.statusCode ?? 0) bytes=\(data.count) "
            + "elapsedMs=\(Self.elapsedMilliseconds(since: started))"
        Task { @MainActor in RoutingDebugLog.shared.event(responseLine) }
        guard let response = try? JSONDecoder().decode(FuelChainResponse.self, from: data) else {
            let status = http?.statusCode ?? 0
            let snippet = String(data: data.prefix(240), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<non-utf8 \(data.count)b>"
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "fuel chain decode fail id=\(requestID) http=\(status) body=\(snippet)"
                )
            }
            throw RoutingError.server("Fuel planning server error (\(status)).")
        }
        try Self.validateServiceContract(response.serviceContract, endpoint: "fuel")
        Task { @MainActor in
            RoutingDebugLog.shared.event(
                "fuel identity request=\(requestID) " + Self.identitySummary(
                    contract: response.serviceContract,
                    build: response.serviceBuild,
                    packs: response.packIdentity
                )
            )
            RoutingDebugLog.shared.liveFuelDiagnostics(response, requestID: requestID)
        }
        guard response.isUsableFuelResult else {
            let message = response.message ?? response.error ?? "Fuel chain unavailable."
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "fuel chain incomplete id=\(requestID) http=\(http?.statusCode ?? 0) "
                        + "code=\(response.error ?? "-") msg=\(message) "
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
        let requestID = Self.diagnosticRequestID("fueldata")
        let started = Date()
        let pad = max(0.002, meters / 111_000)
        struct Request: Encodable { let locations: [RouteLocation] }
        var request = URLRequest(url: AppConfig.liveFuelURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-Dirt-Request-ID")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(Request(locations: [
            RouteLocation(latitude: point.latitude - pad, longitude: point.longitude - pad, label: "Fuel box 1"),
            RouteLocation(latitude: point.latitude + pad, longitude: point.longitude + pad, label: "Fuel box 2")
        ]))
        let beginLine = "fuel data request begin id=\(requestID) "
            + "point=\(String(format: "%.5f,%.5f", point.latitude, point.longitude)) "
            + "within=\(Int(meters))m timeoutMs=30000"
        Task { @MainActor in RoutingDebugLog.shared.event(beginLine) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let ns = error as NSError
            let failureLine = "fuel data request transport-fail id=\(requestID) "
                + "elapsedMs=\(Self.elapsedMilliseconds(since: started)) "
                + "cancelled=\(Task.isCancelled ? 1 : 0) "
                + "domain=\(ns.domain) code=\(ns.code) msg=\(error.localizedDescription)"
            Task { @MainActor in RoutingDebugLog.shared.event(failureLine) }
            throw error
        }
        let http = response as? HTTPURLResponse
        let responseLine = "fuel data request response id=\(requestID) "
            + "http=\(http?.statusCode ?? 0) bytes=\(data.count) "
            + "elapsedMs=\(Self.elapsedMilliseconds(since: started))"
        Task { @MainActor in RoutingDebugLog.shared.event(responseLine) }
        guard let http, (200..<300).contains(http.statusCode) else {
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "fuel data request incomplete id=\(requestID) http=\(http?.statusCode ?? 0)"
                )
            }
            throw RoutingError.server("Live fuel data is unavailable.")
        }
        guard let fuelFile = PackedFuel.decodeFile(data) else {
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "fuel data decode fail id=\(requestID) http=\(http.statusCode) bytes=\(data.count)"
                )
            }
            throw RoutingError.server("Live fuel data returned an unreadable response.")
        }
        try Self.validateServiceContract(fuelFile.serviceContract, endpoint: "fuel data")
        Task { @MainActor in
            RoutingDebugLog.shared.event(
                "fuel data identity request=\(requestID) " + Self.identitySummary(
                    contract: fuelFile.serviceContract,
                    build: fuelFile.serviceBuild,
                    packs: fuelFile.packIdentity
                )
            )
        }
        return FuelItinerary.nearestFuelStation(
            to: point,
            stations: PackedFuel.decode(data),
            within: meters
        ).map { hit in
            FuelChainStop(
                id: hit.station.id, latitude: hit.station.latitude, longitude: hit.station.longitude,
                name: hit.station.name, brand: hit.station.brand, address: hit.station.address,
                graphMeters: 0
            )
        }
    }
}
