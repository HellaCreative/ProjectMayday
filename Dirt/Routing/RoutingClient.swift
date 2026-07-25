import Foundation

/// HTTPS client for the production DIRT routing engine on Vercel.
final class RoutingClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// POSTs one A→B request (the client always sends exactly two locations;
    /// multi-stage plans issue one call per stage, matching the web POC).
    func route(_ request: RouteRequest) async throws -> RouteResponse {
        guard request.locations.count >= 2 else { throw RoutingError.invalidEndpoints }
        var urlRequest = URLRequest(url: AppConfig.routeURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 60

        let (data, urlResponse) = try await session.data(for: urlRequest)
        guard let response = try? JSONDecoder().decode(RouteResponse.self, from: data) else {
            let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw RoutingError.server("Routing server error (\(status)).")
        }
        guard response.isComplete else {
            throw RoutingError.server(response.message ?? response.error ?? "Route unavailable.")
        }
        return response
    }
}
