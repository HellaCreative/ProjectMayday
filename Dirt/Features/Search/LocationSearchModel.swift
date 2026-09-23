import MapKit
import Observation

@MainActor
@Observable
final class LocationSearchModel {
    var query = "" { didSet { scheduleSearch() } }
    private(set) var results: [LocationSearchSuggestion] = []
    private(set) var isSearching = false
    private(set) var isResolving = false
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
    @ObservationIgnored private var previousQuery = ""
    @ObservationIgnored private var failedSelection: LocationSearchSuggestion?
    @ObservationIgnored private var submitted = false

    init(service: (any LocationSearching)? = nil, debounce: Duration = .milliseconds(150)) {
        self.service = service ?? LocationSearchService()
        self.debounce = debounce
    }

    var hasSearchQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }

    func select(_ suggestion: LocationSearchSuggestion) {
        let ticket = cancelActiveRequest()
        searchError = nil
        failedSelection = nil
        isSearching = false
        isResolving = true
        let region = region
        task = Task { [weak self, service] in
            do {
                let result = try await service.resolve(suggestion, region: region)
                guard !Task.isCancelled, let self, ticket == self.generation else { return }
                self.pendingResult = result
                self.isPresented = false
            } catch {
                guard !Task.isCancelled, let self, ticket == self.generation else { return }
                self.failedSelection = suggestion
                self.searchError = "Couldn't open this place. Try again or choose another result."
                self.isResolving = false
            }
        }
    }

    func reset() { query = "" }

    func retry() {
        if let failedSelection { select(failedSelection) }
        else { scheduleSearch(submit: submitted) }
    }

    /// The keyboard Search button deliberately runs the full query immediately.
    func submit() { scheduleSearch(submit: true) }

    @discardableResult
    private func cancelActiveRequest() -> Int {
        generation += 1
        task?.cancel()
        task = nil
        service.cancel()
        return generation
    }

    private func scheduleSearch(submit: Bool = false) {
        let ticket = cancelActiveRequest()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep useful suggestions on screen while a word is being extended;
        // unrelated queries, clearing, and dismissal clear the old list.
        if trimmed.count < 2 || previousQuery.isEmpty || !trimmed.lowercased().hasPrefix(previousQuery.lowercased()) {
            results = []
        }
        previousQuery = trimmed
        submitted = submit
        failedSelection = nil
        searchError = nil
        isResolving = false
        isSearching = trimmed.count >= 2
        guard isSearching else { return }
        let region = region
        task = Task { [weak self, service, debounce] in
            do {
                if !submit { try await Task.sleep(for: debounce) }
                let found: [LocationSearchSuggestion]
                if submit {
                    found = try await service.search(query: trimmed, region: region).map(LocationSearchSuggestion.init)
                } else {
                    found = try await service.suggest(query: trimmed, region: region)
                }
                guard !Task.isCancelled, let self, ticket == self.generation else { return }
                self.results = LocationSearchSuggestion.unique(found)
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, let self, ticket == self.generation else { return }
                self.searchError = "Search is unavailable. Check your connection and try again."
                self.isSearching = false
            }
        }
    }
}
