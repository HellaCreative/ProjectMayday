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
        guard response.isComplete else {
            let msg = response.message ?? response.error ?? "Route unavailable."
            Task { @MainActor in
                RoutingDebugLog.shared.event(
                    "live incomplete http=\(http?.statusCode ?? 0) msg=\(msg)"
                )
            }
            throw RoutingError.server(msg)
        }
        return response
    }
}
