import CoreLocation
import MapKit

/// Wraps `MKLocalSearch` for type-ahead location lookup, biased to the
/// rider's visible map region.
enum LocationSearchService {

    struct Result: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let address: String
        let coordinate: CLLocationCoordinate2D
        /// Straight-line distance from a reference point, if available.
        var distanceMeters: Double?

        static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Forward-geocode a natural-language query, biased to `region`.
    static func search(
        query: String,
        region: MKCoordinateRegion?
    ) async throws -> [Result] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        request.resultTypes = [.address, .pointOfInterest]

        let response = try await MKLocalSearch(request: request).start()

        return response.mapItems.prefix(8).map { item in
            let placemark = item.placemark
            let address = [
                placemark.subThoroughfare,
                placemark.thoroughfare,
                placemark.locality,
                placemark.administrativeArea,
                placemark.postalCode,
            ]
            .compactMap { $0 }
            .joined(separator: " ")

            return Result(
                name: item.name ?? placemark.locality ?? "Unknown",
                address: address.isEmpty ? (placemark.title ?? "") : address,
                coordinate: placemark.coordinate
            )
        }
    }

    /// Attach straight-line distances from `origin` to each result.
    static func withDistances(
        results: [Result],
        from origin: CLLocationCoordinate2D
    ) -> [Result] {
        let ref = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        return results.map { r in
            var copy = r
            copy.distanceMeters = ref.distance(
                from: CLLocation(latitude: r.coordinate.latitude, longitude: r.coordinate.longitude)
            )
            return copy
        }
    }
}
