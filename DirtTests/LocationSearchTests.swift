import MapKit
import Testing
@testable import Dirt

@MainActor
@Suite(.serialized)
struct LocationSearchTests {
    @Test func debounceOnlySendsLatestQueryAndRegion() async throws {
        let service = ControlledPlaceSearch()
        let model = LocationSearchModel(service: service, debounce: .milliseconds(30))
        model.region = .init(center: .init(latitude: 44.7, longitude: -63.3),
            span: .init(latitudeDelta: 0.2, longitudeDelta: 0.2))
        model.query = "Hal"
        model.query = "  Halifax\n"
        try await Task.sleep(for: .milliseconds(70))
        #expect(service.queries == ["Halifax"])
        #expect(service.region?.center.latitude == 44.7)
        service.finish("Halifax", names: ["Halifax"])
        await waitForCompletion(model)
        #expect(model.results.first?.name == "Halifax")
    }

    @Test func lateSearchCannotReplaceNewResultsOrReappearAfterDismissal() async throws {
        let service = ControlledPlaceSearch()
        let model = LocationSearchModel(service: service, debounce: .zero)
        model.isPresented = true
        model.query = "Old"
        await waitForQuery("Old", service)
        model.query = "New"
        await waitForQuery("New", service)
        service.finish("New", names: ["New result"])
        await waitForCompletion(model)
        service.finish("Old", names: ["Stale result"])
        await Task.yield()
        #expect(model.results.first?.name == "New result")
        model.query = "Pending"
        await waitForQuery("Pending", service)
        model.isPresented = false
        service.finish("Pending", names: ["Dismissed result"])
        await Task.yield()
        #expect(model.results.isEmpty)
        #expect(!model.isSearching)
        #expect(model.query.isEmpty)
    }

    @Test func errorCanRetryAndShortQueryClearsError() async {
        let service = ControlledPlaceSearch()
        let model = LocationSearchModel(service: service, debounce: .zero)
        model.query = "Halifax"
        await waitForQuery("Halifax", service)
        service.fail("Halifax")
        await waitForCompletion(model)
        #expect(model.searchError != nil)
        #expect(!model.isSearching)
        model.retry()
        await waitForQuery("Halifax", service)
        service.finish("Halifax", names: [])
        await waitForCompletion(model)
        #expect(model.searchError == nil)
        #expect(model.results.isEmpty)
        #expect(model.hasSearchQuery)
        model.query = " a \n"
        #expect(!model.hasSearchQuery)
        #expect(!model.isSearching)
        #expect(model.searchError == nil)
    }

    @Test func selectionSurvivesSearchDismissalWithoutAddingAnItineraryPoint() async throws {
        let service = ControlledPlaceSearch()
        let model = LocationSearchModel(service: service, debounce: .zero)
        model.isPresented = true
        model.query = "Halifax"
        await waitForQuery("Halifax", service)
        service.finish("Halifax", names: ["Halifax"])
        await waitForCompletion(model)
        let result = try #require(model.results.first)
        model.select(result)
        for _ in 0..<1000 {
            if !model.isResolving { break }
            await Task.yield()
        }
        #expect(!model.isPresented)
        #expect(model.results.isEmpty)
        #expect(model.pendingResult?.name == result.name)
        #expect(service.cancelCount > 0)
    }

    @Test func typingUsesSuggestionsAndSubmitImmediatelyUsesFullSearch() async throws {
        let service = ControlledPlaceSearch()
        let model = LocationSearchModel(service: service, debounce: .milliseconds(10))
        model.query = "Port"
        try await Task.sleep(for: .milliseconds(30))
        #expect(service.suggestionQueries == ["Port"])
        #expect(service.fullQueries.isEmpty)
        service.finish("Port", names: ["Porters Lake"])
        await waitForCompletion(model)
        model.query = "Porters"
        #expect(model.results.first?.name == "Porters Lake", "Keep suggestions visible while extending a name")
        model.submit()
        await waitForQuery("Porters", service)
        #expect(service.suggestionQueries == ["Port"])
        #expect(service.fullQueries == ["Porters"])
        service.finish("Porters", names: ["Porters Lake"])
        await waitForCompletion(model)
        model.query = "Ottawa"
        #expect(model.results.isEmpty, "Do not show unrelated old suggestions")
        model.reset()
    }

    @Test func changingQueryOrDismissingDuringResolutionCannotOpenStalePlace() async throws {
        let service = ControlledPlaceSearch()
        service.holdResolution = true
        let model = LocationSearchModel(service: service, debounce: .zero)
        model.isPresented = true
        let place = LocationSearchSuggestion(result: .init(name: "Porters Lake", address: "NS",
            coordinate: .init(latitude: 44.75, longitude: -63.32)))
        model.select(place)
        await waitForResolution(service)
        #expect(model.isResolving)
        model.query = "Sheet"
        await waitForQuery("Sheet", service)
        service.finishResolution(place.resolvedResult!)
        service.finish("Sheet", names: ["Sheet Harbour"])
        await waitForCompletion(model)
        #expect(model.pendingResult == nil)
        #expect(model.isPresented)
        #expect(model.results.first?.name == "Sheet Harbour")
        model.select(place)
        await waitForResolution(service)
        model.isPresented = false
        service.finishResolution(place.resolvedResult!)
        for _ in 0..<10 { await Task.yield() }
        #expect(model.pendingResult == nil)
        #expect(!model.isResolving)
        #expect(model.results.isEmpty)
    }

    @Test func failedSelectionRetriesTheSamePlaceAndKeepsRegion() async throws {
        let service = ControlledPlaceSearch()
        service.holdResolution = true
        let model = LocationSearchModel(service: service, debounce: .zero)
        model.isPresented = true
        model.region = .init(center: .init(latitude: 44.7, longitude: -63.3),
            span: .init(latitudeDelta: 1, longitudeDelta: 1))
        let place = LocationSearchSuggestion(result: .init(name: "Porters Lake", address: "NS",
            coordinate: .init(latitude: 44.75, longitude: -63.32)))
        model.select(place)
        await waitForResolution(service)
        service.failResolution()
        for _ in 0..<1000 {
            if !model.isResolving { break }
            await Task.yield()
        }
        #expect(model.isPresented)
        #expect(model.searchError != nil)
        #expect(model.pendingResult == nil)
        model.retry()
        await waitForResolution(service)
        #expect(service.resolvedIDs == [place.id, place.id])
        #expect(service.region?.center.latitude == 44.7)
        service.finishResolution(place.resolvedResult!)
        for _ in 0..<1000 {
            if !model.isResolving { break }
            await Task.yield()
        }
        #expect(!model.isPresented)
        #expect(model.pendingResult?.coordinate.latitude == 44.75)
    }

    @Test func duplicateResultsDoNotProduceDuplicateRowsButDistinctPlacesSurvive() async {
        let service = ControlledPlaceSearch()
        let model = LocationSearchModel(service: service, debounce: .zero)
        model.query = "Halifax"
        await waitForQuery("Halifax", service)
        service.finish("Halifax", names: ["Halifax", "Halifax", "Halifax Harbour"])
        await waitForCompletion(model)
        #expect(model.results.map(\.name) == ["Halifax", "Halifax Harbour"])
    }

    private func waitForResolution(_ service: ControlledPlaceSearch) async {
        for _ in 0..<1000 {
            if service.pendingResolution != nil { return }
            await Task.yield()
        }
        Issue.record("Place resolution did not start")
    }

    private func waitForCompletion(_ model: LocationSearchModel) async {
        for _ in 0..<1000 {
            if !model.isSearching { return }
            await Task.yield()
        }
        Issue.record("Search did not finish")
    }

    private func waitForQuery(_ query: String, _ service: ControlledPlaceSearch) async {
        for _ in 0..<1000 {
            if service.pending[query] != nil { return }
            await Task.yield()
        }
        Issue.record("Search did not start: \(query)")
    }
}

@MainActor
private final class ControlledPlaceSearch: LocationSearching {
    var pending: [String: CheckedContinuation<[LocationSearchResult], Error>] = [:]
    var queries: [String] = []
    var region: MKCoordinateRegion?
    var cancelCount = 0
    var suggestionQueries: [String] = []
    var fullQueries: [String] = []
    var resolvedIDs: [String] = []
    var holdResolution = false
    var pendingResolution: CheckedContinuation<LocationSearchResult, Error>?
    func cancel() { cancelCount += 1 }
    func suggest(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchSuggestion] {
        suggestionQueries.append(query)
        return try await enqueue(query: query, region: region).map(LocationSearchSuggestion.init)
    }
    func resolve(_ suggestion: LocationSearchSuggestion, region: MKCoordinateRegion?) async throws -> LocationSearchResult {
        resolvedIDs.append(suggestion.id)
        self.region = region
        if holdResolution {
            return try await withCheckedThrowingContinuation { pendingResolution = $0 }
        }
        guard let result = suggestion.resolvedResult else { throw MKError(.placemarkNotFound) }
        return result
    }
    func search(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult] {
        fullQueries.append(query)
        return try await enqueue(query: query, region: region)
    }
    private func enqueue(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult] {
        queries.append(query)
        self.region = region
        return try await withCheckedThrowingContinuation { pending[query] = $0 }
    }
    func finish(_ query: String, names: [String]) {
        pending.removeValue(forKey: query)?.resume(returning: names.map {
            LocationSearchResult(name: $0, address: "Nova Scotia", coordinate: .init(latitude: 44.7, longitude: -63.3))
        })
    }
    func finishResolution(_ result: LocationSearchResult) {
        let pending = pendingResolution
        pendingResolution = nil
        pending?.resume(returning: result)
    }
    func failResolution() {
        let pending = pendingResolution
        pendingResolution = nil
        pending?.resume(throwing: URLError(.notConnectedToInternet))
    }
    func fail(_ query: String) {
        pending.removeValue(forKey: query)?.resume(throwing: URLError(.notConnectedToInternet))
    }
}
