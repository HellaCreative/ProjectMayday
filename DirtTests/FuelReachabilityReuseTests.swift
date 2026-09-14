import Foundation
import Testing
@testable import Dirt

@MainActor
struct FuelReachabilityReuseTests {
    private func pump(_ id: String = "p",_ latitude: Double = 45) -> POIFeature {
        .init(id:id,category:"fuel",latitude:latitude,longitude:-63,name:nil,address:nil,brand:nil,openingHours:nil,phone:nil,website:nil)
    }
    private func request(pumps: [POIFeature]? = nil,range: Double = 180_000,profile: RouteProfile = .dirt,
        unknown: Bool = false,fromLatitude: Double = 44,toLatitude: Double = 46) -> FuelReachabilityReuse.Request {
        .init(from:.init(longitude:-63,latitude:fromLatitude),toward:.init(longitude:-64,latitude:toLatitude),
            pumps:pumps ?? [pump()],maximumMeters:range,profile:profile,allowUnknown:unknown)
    }
    @Test func exactNextWindowReusesVectorAndEveryIdentityDimensionMatters() async throws {
        let cache = FuelReachabilityReuse(),original = request(pumps:[pump(),pump("q",45.5)])
        var loads = 0
        func fetch(_ r: FuelReachabilityReuse.Request,_ identity: String = "bytes-A") async throws -> [String:Double] {
            try await cache.resolve(r,currentIdentity:{ identity },check:{}) { loads += 1;return ["p":500,"q":900] }
        }
        #expect(try await fetch(original) == ["p":500,"q":900])
        #expect(try await fetch(original) == ["p":500,"q":900])
        #expect(loads == 1 && cache.hits == 1 && cache.retainedPayloadBytes <= cache.maximumPayloadBytes)
        let variants = [request(pumps:[pump("q",45.5),pump()]),request(pumps:[pump(),pump("q",45.6)]),
            request(pumps:original.pumps,range:170_000),request(pumps:original.pumps,profile:.balanced),
            request(pumps:original.pumps,unknown:true),request(pumps:original.pumps,fromLatitude:44.1),
            request(pumps:original.pumps,toLatitude:46.1)]
        for variant in variants { _ = try await fetch(original);let before = loads;_ = try await fetch(variant);#expect(loads == before+1) }
        _ = try await fetch(original);let before = loads;_ = try await fetch(original,"bytes-B");#expect(loads == before+1)
    }
    @Test func CancellationErrorsAndChangedSourceCannotPublish() async throws {
        enum Injected: Error { case cancelled,corrupt }
        let cache = FuelReachabilityReuse(),r = request()
        var cancelled = false,identity = "A",loads = 0
        do {
            _ = try await cache.resolve(r,currentIdentity:{ identity },check:{ if cancelled { throw Injected.cancelled } }) {
                cancelled = true;return ["p":500]
            }
            Issue.record("Cancellation did not propagate")
        } catch Injected.cancelled {}
        #expect(cache.retainedPayloadBytes == 0)
        cancelled = false
        do { _ = try await cache.resolve(r,currentIdentity:{ identity },check:{}) { throw Injected.corrupt };Issue.record("Data error did not propagate") }
        catch Injected.corrupt {}
        _ = try await cache.resolve(r,currentIdentity:{ identity },check:{}) { identity = "B";return ["p":500] }
        #expect(cache.retainedPayloadBytes == 0)
        _ = try await cache.resolve(r,currentIdentity:{ identity },check:{}) { loads += 1;return ["p":500] }
        do { _ = try await cache.resolve(r,currentIdentity:{ identity },check:{ throw Injected.cancelled }) { loads += 1;return [:] };Issue.record("Cancelled cache hit accepted") }
        catch Injected.cancelled {}
        #expect(loads == 1 && cache.hits == 0)
    }
    @Test func TinyBudgetAndAmbiguousEmptyResultsOnlyDisableReuse() async throws {
        for budget in [0,1,32] {
            let cache = FuelReachabilityReuse(maximumPayloadBytes:budget);var loads = 0
            for _ in 0..<2 { #expect(try await cache.resolve(request(),currentIdentity:{ "A" },check:{}) { loads += 1;return ["p":500] } == ["p":500]) }
            #expect(loads == 2 && cache.retainedPayloadBytes == 0)
        }
        let cache = FuelReachabilityReuse();var loads = 0
        for _ in 0..<2 { _ = try await cache.resolve(request(),currentIdentity:{ "A" },check:{}) { loads += 1;return [:] } }
        #expect(loads == 2 && cache.retainedPayloadBytes == 0)
    }
}
