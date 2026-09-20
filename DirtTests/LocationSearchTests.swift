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
        #expect(!model.isPresented)
        #expect(model.results.isEmpty)
        #expect(model.pendingResult?.id == result.id)
        #expect(service.cancelCount > 0)
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
    func cancel() { cancelCount += 1 }
    func search(query: String, region: MKCoordinateRegion?) async throws -> [LocationSearchResult] {
        queries.append(query)
        self.region = region
        return try await withCheckedThrowingContinuation { pending[query] = $0 }
    }
    func finish(_ query: String, names: [String]) {
        pending.removeValue(forKey: query)?.resume(returning: names.map {
            LocationSearchResult(name: $0, address: "Nova Scotia", coordinate: .init(latitude: 44.7, longitude: -63.3))
        })
    }
    func fail(_ query: String) {
        pending.removeValue(forKey: query)?.resume(throwing: URLError(.notConnectedToInternet))
    }
}
