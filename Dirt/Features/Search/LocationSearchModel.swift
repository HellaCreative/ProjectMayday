import CoreLocation
import MapKit
import Observation

/// Drives the location search overlay: debounced type-ahead, result
/// selection, and the confirm-or-dismiss flow before handing off to
/// the route planner.
@Observable
final class LocationSearchModel {

    // MARK: - Search state

    var query = "" {
        didSet { debounceSearch() }
    }
    var results: [LocationSearchService.Result] = []
    var isSearching = false
    var searchError: String?

    // MARK: - Selection state

    /// The result the rider tapped — drives pin + confirmation card.
    var pendingResult: LocationSearchService.Result?

    /// Region bias for search (kept in sync with the visible map).
    var mapRegion: MKCoordinateRegion?

    /// Rider's current coordinate for distance labels.
    var userCoordinate: CLLocationCoordinate2D?

    // MARK: - UI state

    var isPresented = false {
        didSet {
            if !isPresented { reset() }
        }
    }

    // MARK: - Actions

    func select(_ result: LocationSearchService.Result) {
        pendingResult = result
        isPresented = false
    }

    func dismissPending() {
        pendingResult = nil
    }

    func reset() {
        query = ""
        results = []
        isSearching = false
        searchError = nil
        searchTask?.cancel()
    }

    // MARK: - Debounced search

    private var searchTask: Task<Void, Never>?

    private func debounceSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)

        guard q.count >= 2 else {
            results = []
            isSearching = false
            searchError = nil
            return
        }

        isSearching = true
        searchError = nil

        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            do {
                var hits = try await LocationSearchService.search(
                    query: q,
                    region: mapRegion
                )
                guard !Task.isCancelled else { return }

                if let origin = userCoordinate {
                    hits = LocationSearchService.withDistances(results: hits, from: origin)
                }

                results = hits
                isSearching = false
            } catch is CancellationError {
                // Expected on rapid typing.
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                isSearching = false
                searchError = "Search unavailable"
            }
        }
    }
}
