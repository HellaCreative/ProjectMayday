import CoreLocation
import MapKit

struct LocationSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
}

/// Suggestions retain Apple's completion so selection resolves the place the
/// rider actually tapped, rather than searching its display name again.
struct LocationSearchSuggestion: Identifiable {
    let name: String
    let address: String
    let completion: MKLocalSearchCompletion?
    let resolvedResult: LocationSearchResult?

    var id: String {
        if let result = resolvedResult {
            return "\(name)|\(address)|\(result.coordinate.latitude)|\(result.coordinate.longitude)"
        }
        return "\(name)|\(address)"
    }

    init(completion: MKLocalSearchCompletion) {
        name = completion.title
        address = completion.subtitle
        self.completion = completion
        resolvedResult = nil
    }

    init(result: LocationSearchResult) {
        name = result.name
        address = result.address
        completion = nil
        resolvedResult = result
    }

    static func unique(_ suggestions: [Self]) -> [Self] {
        var seen = Set<String>()
        return suggestions.filter { seen.insert($0.id).inserted }
    }
}

@MainActor
protocol LocationSearching {
    func suggest(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchSuggestion]
    func search(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult]
    func resolve(_ suggestion: LocationSearchSuggestion, region: MKCoordinateRegion?) async throws -> LocationSearchResult
    func cancel()
}

/// Apple place lookup only. Selected coordinates still use DIRT's pack router.
@MainActor
final class LocationSearchService: LocationSearching {
    private var activeSearch: MKLocalSearch?
    private var activeCompletion: PlaceCompletionRequest?

    func cancel() {
        activeCompletion?.cancel()
        activeCompletion = nil
        activeSearch?.cancel()
        activeSearch = nil
    }

    func suggest(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchSuggestion] {
        cancel()
        // Each request owns its delegate and continuation. A late callback from
        // an older fragment cannot be mistaken for results for the new fragment.
        let request = PlaceCompletionRequest()
        activeCompletion = request
        defer { if activeCompletion === request { activeCompletion = nil } }
        let completions = try await request.suggestions(query: query, region: region)
        try Task.checkCancellation()
        let suggestions = LocationSearchSuggestion.unique(completions.map(LocationSearchSuggestion.init))
        if !suggestions.isEmpty { return Array(suggestions.prefix(10)) }
        // A complete address or uncommon name can resolve even without completions.
        return try await search(query: query, region: region).map(LocationSearchSuggestion.init)
    }

    func search(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult] {
        cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        return try await perform(request, region: region)
    }

    func resolve(_ suggestion: LocationSearchSuggestion, region: MKCoordinateRegion?) async throws -> LocationSearchResult {
        if let result = suggestion.resolvedResult { return result }
        guard let completion = suggestion.completion else { throw MKError(.placemarkNotFound) }
        cancel()
        let results = try await perform(MKLocalSearch.Request(completion: completion), region: region)
        guard let result = results.first else { throw MKError(.placemarkNotFound) }
        return result
    }

    private func perform(_ request: MKLocalSearch.Request, region: MKCoordinateRegion?) async throws -> [LocationSearchResult] {
        request.resultTypes = [.address, .pointOfInterest, .physicalFeature]
        // A relevance hint, not a geographic fence: explicit distant place
        // names still work when the rider is planning away from home.
        request.regionPriority = .default
        if let region { request.region = region }
        let search = MKLocalSearch(request: request)
        activeSearch = search
        defer { if activeSearch === search { activeSearch = nil } }
        let response = try await search.start()
        try Task.checkCancellation()
        return response.mapItems.prefix(10).compactMap { item in
            let coordinate = item.location.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return LocationSearchResult(
                name: item.name ?? "Selected place",
                address: item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? "",
                coordinate: coordinate
            )
        }
    }
}

@MainActor
private final class PlaceCompletionRequest: NSObject, @MainActor MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private var continuation: CheckedContinuation<[MKLocalSearchCompletion], Error>?
    private var timeout: Task<Void, Never>?

    func suggestions(query: String, region: MKCoordinateRegion?) async throws -> [MKLocalSearchCompletion] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                completer.delegate = self
                completer.resultTypes = [.address, .pointOfInterest, .physicalFeature]
                completer.regionPriority = .default
                if let region { completer.region = region }
                completer.queryFragment = query
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        finish(.success(completer.results))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<[MKLocalSearchCompletion], Error>) {
        let pending = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        completer.delegate = nil
        completer.cancel()
        pending?.resume(with: result)
    }
}

#if DEBUG
/// Deterministic UI coverage; never used in a rider's normal search session.
@MainActor
final class FixtureLocationSearchService: LocationSearching {
    func cancel() {}
    func suggest(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchSuggestion] {
        try await search(query: query, region: region).map(LocationSearchSuggestion.init)
    }
    func resolve(_ suggestion: LocationSearchSuggestion, region: MKCoordinateRegion?) async throws -> LocationSearchResult {
        guard let result = suggestion.resolvedResult else { throw MKError(.placemarkNotFound) }
        return result
    }
    func search(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult] {
        try await Task.sleep(for: .milliseconds(100))
        if query == "Unavailable" { throw URLError(.notConnectedToInternet) }
        if query == "Nothing" { return [] }
        return [LocationSearchResult(name: "Porters Lake", address: "Nova Scotia, Canada",
            coordinate: .init(latitude: 44.74, longitude: -63.3))]
    }
}
#endif
