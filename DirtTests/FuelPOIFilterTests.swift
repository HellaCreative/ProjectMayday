import Foundation
import Testing
@testable import Dirt

struct FuelPOIFilterTests {
    @Test func bareStationIsKept() {
        #expect(FuelPOIFilter.isMotorcycleUsable(.init(name: "Esso")))
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["amenity": "fuel"])) == nil)
    }

    @Test func hgvYesKeptDesignatedDropped() {
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["hgv": "yes"])) == nil)
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["hgv": "designated"])) == .truckOnly)
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["hgv": "only"])) == .truckOnly)
    }

    @Test func cardlockAndBulkNamesDropped() {
        #expect(FuelPOIFilter.rejection(for: .init(name: "UFA Cardlock")) == .bulkOrCardlock)
        #expect(FuelPOIFilter.rejection(for: .init(name: "Petro-Canada Card Lock")) == .bulkOrCardlock)
        #expect(FuelPOIFilter.rejection(for: .init(brand: "Fas Gas Cardlock")) == .bulkOrCardlock)
        #expect(FuelPOIFilter.rejection(for: .init(name: "Bulk Fuel Depot")) == .bulkOrCardlock)
        #expect(FuelPOIFilter.rejection(for: .init(name: "Bulkley Valley Co-op")) == nil)
    }

    @Test func privateAccessDropped() {
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["access": "private"])) == .privateAccess)
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["access": "customers"])) == .privateAccess)
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["access": "yes"])) == nil)
    }

    @Test func knownClosedDropped() {
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["disused": "yes"])) == .closed)
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["abandoned:amenity": "fuel"])) == .closed)
        #expect(FuelPOIFilter.rejection(for: .init(openingHours: "closed")) == .closed)
    }

    @Test func dieselOnlyRequiresExplicitNoGasoline() {
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["fuel:diesel": "yes"])) == nil)
        #expect(
            FuelPOIFilter.rejection(for: .init(tags: [
                "fuel:diesel": "yes",
                "fuel:gasoline": "no"
            ])) == .dieselOnly
        )
        #expect(
            FuelPOIFilter.rejection(for: .init(tags: [
                "fuel:diesel": "yes",
                "fuel:gasoline": "no",
                "fuel:octane_91": "yes"
            ])) == nil
        )
        #expect(FuelPOIFilter.rejection(for: .init(tags: ["fuel:HGV_diesel": "yes"])) == .truckOnly)
    }
}
