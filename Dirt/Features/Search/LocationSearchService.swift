import CoreLocation
import MapKit

struct LocationSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
}

@MainActor
protocol LocationSearching {
    func search(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult]
    func cancel()
}

/// Apple place lookup only. Selected coordinates still use DIRT's pack router.
@MainActor
final class LocationSearchService: LocationSearching {
    private var activeSearch: MKLocalSearch?

    func cancel() {
        activeSearch?.cancel()
        activeSearch = nil
    }

    func search(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult] {
        cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let region { request.region = region }
        let search = MKLocalSearch(request: request)
        activeSearch = search
        defer { if activeSearch === search { activeSearch = nil } }
        let response = try await search.start()
        try Task.checkCancellation()
        return response.mapItems.prefix(8).compactMap { item in
            let coordinate = item.location.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return LocationSearchResult(
                name: item.name ?? "Selected place",
                address: item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true) ?? "",
                coordinate: coordinate
            )
        }
    }
}

#if DEBUG
/// Deterministic UI coverage; never used in a rider's normal search session.
@MainActor
final class FixtureLocationSearchService: LocationSearching {
    func cancel() {}
    func search(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult] {
        try await Task.sleep(for: .milliseconds(100))
        if query == "Unavailable" { throw URLError(.notConnectedToInternet) }
        if query == "Nothing" { return [] }
        return [LocationSearchResult(name: "Porters Lake", address: "Nova Scotia, Canada",
            coordinate: .init(latitude: 44.74, longitude: -63.3))]
    }
}
#endif
