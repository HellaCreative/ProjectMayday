import Testing
@testable import DirtRoutingEngine

struct DirtCandidateQualityTests {
    private func route(_ runs: [(Surface, Double)], ferryAt: Set<Int> = []) -> ComputedRoute {
        let point = Coordinate(longitude: 0, latitude: 0)
        let match = RoadMatch(edge: 0, coordinate: point, distanceMeters: 0,
                              alongMeters: 0, geometryMeters: 1, forward: true)
        let segments = runs.enumerated().map { index, run in
            RouteSegment(edge: index, edgeID: "road-\(index)", forward: true,
                meters: run.1, surface: run.0, surfaceLeaf: run.0.rawValue,
                roadClass: "track", structure: ferryAt.contains(index) ? "ferry" : "", access: 0, geometry: [])
        }
        return ComputedRoute(start: match, end: match, segments: segments,
            distanceMeters: runs.reduce(0) { $0 + $1.1 }, searchCost: 0,
            poppedLabels: 0, arrivalRestrictions: [])
    }

    @Test func incidentalScrapCannotEraseAnOtherwiseMeaningfulDirtRide() {
        // California cold/warm replay: a 1,009 m short section made the
        // comparator discard a ride containing several longer dirt sections
        // in favour of a completed alternative with no known dirt at all.
        let dirt = route([(.paved, 100_000), (.loose, 3_740), (.paved, 10_000),
                          (.loose, 1_009), (.paved, 10_000), (.gravel, 3_945),
                          (.unknown, 140_000), (.paved, 100_000)])
        let noDirt = route([(.paved, 210_000), (.unknown, 120_000)])
        let a = RouteQuality(route: dirt), b = RouteQuality(route: noDirt)
        #expect(a.shortDirtScrapMeters == 1_009)
        #expect(a.meaningfulDirtMeters == 8_694)
        #expect(b.meaningfulDirtMeters == 0)
        #expect(RouteQuality.prefersDirt(a, over: b, widthA: .infinity, widthB: .infinity))
        #expect(!RouteQuality.prefersDirt(b, over: a, widthA: .infinity, widthB: .infinity))
        for routes in [[dirt, noDirt], [noDirt, dirt]] {
            let selected = RoutingEngine.chooseDirt(routes.map {
                .init(route: $0, width: .infinity, quality: RouteQuality(route: $0))
            })
            #expect(selected?.route.segments.map(\.edgeID) == dirt.segments.map(\.edgeID))
        }
    }

    @Test func unknownSurfaceAndIsolatedShortScrapsDoNotBecomeMeaningfulDirt() {
        let scraps = RouteQuality(route: route([
            (.paved, 10_000), (.loose, 450), (.paved, 10_000),
            (.gravel, 450), (.unknown, 30_000), (.paved, 10_000)
        ]))
        let paved = RouteQuality(route: route([(.paved, 40_000)]))
        #expect(scraps.meaningfulDirtMeters == 0)
        #expect(RouteQuality.prefersDirt(paved, over: scraps, widthA: .infinity, widthB: .infinity))
    }

    @Test func meaningfulDirtRequiresAContinuousKnownRun() {
        let continuous = RouteQuality(route: route([(.gravel, 600), (.loose, 600)]))
        let separated = RouteQuality(route: route([(.gravel, 600), (.unknown, 100), (.loose, 600)]))
        #expect(continuous.meaningfulDirtMeters == 1_200)
        #expect(separated.meaningfulDirtMeters == 0)
    }

    @Test func ferryCannotJoinTwoShortDirtPiecesIntoAMeaningfulRun() {
        let quality = RouteQuality(route: route([(.gravel, 600), (.unknown, 5_000), (.loose, 600)], ferryAt: [1]))
        #expect(quality.knownDirtPercent == 100)
        #expect(quality.meaningfulDirtMeters == 0)
    }
}
