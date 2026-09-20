import MapKit
import Observation

@MainActor
@Observable
final class LocationSearchModel {
    var query = "" { didSet { scheduleSearch() } }
    private(set) var results: [LocationSearchResult] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    var pendingResult: LocationSearchResult?
    var region: MKCoordinateRegion?
    var isPresented = false {
        didSet { if !isPresented { reset() } }
    }
    @ObservationIgnored private let service: any LocationSearching
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(service: (any LocationSearching)? = nil, debounce: Duration = .milliseconds(300)) {
        self.service = service ?? LocationSearchService()
        self.debounce = debounce
    }

    var hasSearchQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }

    func select(_ result: LocationSearchResult) {
        pendingResult = result
        isPresented = false
    }

    func reset() {
        query = ""
    }

    func retry() { scheduleSearch() }

    private func scheduleSearch() {
        generation += 1
        let ticket = generation
        task?.cancel()
        service.cancel()
        results = []
        searchError = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = trimmed.count >= 2
        guard isSearching else { return }
        let region = region
        task = Task { [weak self, service, debounce] in
            do {
                try await Task.sleep(for: debounce)
                let found = try await service.search(query: trimmed, region: region)
                guard !Task.isCancelled, let self, ticket == self.generation else { return }
                self.results = found
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, let self, ticket == self.generation else { return }
                self.searchError = "Search is unavailable. Check your connection and try again."
                self.isSearching = false
            }
        }
    }
}
