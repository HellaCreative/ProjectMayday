import CoreLocation
import Testing
@testable import Dirt

@MainActor
struct InitialFuelStationOwnershipTests {
    private func station(_ id: String, latitude: Double, longitude: Double) -> POIFeature {
        .init(id: id, category: "fuel", latitude: latitude, longitude: longitude,
            name: id, address: nil, brand: nil, openingHours: nil, phone: nil, website: nil)
    }
    @Test func haloStationKeepsItsInstalledSidecarOwner() {
        let halo = station("halo", latitude: 45.5, longitude: -69)
        #expect(GraphPackStore.primaryRegionId(containing:
            .init(latitude: halo.latitude, longitude: halo.longitude)) == "me")
        let groups = PackRoutingSource.initialStationGroups(["nb": [halo]], excluded: [])
        #expect(Set(groups.keys) == ["nb"])
        #expect(groups["nb"]?.map(\.id) == ["halo"])
        #expect(groups["me"] == nil)
    }
    @Test func overlappingSidecarsRemainIndependentMatchingOpportunities() {
        let shared = station("shared", latitude: 45.85, longitude: -64.27)
        let removed = station("removed", latitude: 45.9, longitude: -64.3)
        let groups = PackRoutingSource.initialStationGroups(
            ["ns": [shared, removed], "nb": [shared]], excluded: ["removed"])
        #expect(groups["ns"]?.map(\.id) == ["shared"])
        #expect(groups["nb"]?.map(\.id) == ["shared"])
        // A station matched in either installed source can supply the minimum;
        // dropping the duplicate before preparation would lose that possibility.
    }
}
