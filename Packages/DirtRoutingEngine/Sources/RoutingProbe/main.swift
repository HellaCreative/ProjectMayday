import CryptoKit
import Foundation
import DirtRoutingEngine

// A local-file-only qualification entry point, independent of the app and simulator.
// Optional environment:
//   DIRT_ALLOW_UNKNOWN=1           allow roads with unknown motor access
//   DIRT_ARRIVAL_EDGE=<edge id>    arrival road carried from a previous leg
//   DIRT_PRIOR_EDGES=<file>        edge IDs already ridden, one per line
//   DIRT_FUEL_MIN_STOPS=<n>, DIRT_FUEL_MAX_STOPS=<n>, DIRT_FUEL_ALLOW_PARTIAL=1,
//   DIRT_FUEL_ESCAPE=0             fuel window options (escape defaults to on)
//   DIRT_PROBE_COMPACT=1           omit geometry and edge IDs; their hash is always printed
//   DIRT_DIRT_PAVEMENT_AWAY=<n>    Dirt pavement away multiplier at full wander (10/4/2/1)
//   DIRT_WANDER=<0..1>             detour appetite (default 1)
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
guard (8...12).contains(arguments.count),
      let lonA = Double(arguments[2]), let latA = Double(arguments[3]),
      let lonB = Double(arguments[4]), let latB = Double(arguments[5]),
      let style = RidingStyle(rawValue: arguments[6]), let seconds = Double(arguments[7]) else {
    print("Usage: dirt-routing-probe GRAPH GEOMETRY FROM_LON FROM_LAT TO_LON TO_LAT STYLE SECONDS [SEED [MAP_ZOOM|- [FUEL_USABLE [FUEL_FIRST]]]]")
    exit(2)
}
let seed = arguments.count > 8 ? UInt64(arguments[8]) : 1
let zoomArgument = arguments.count > 9 && arguments[9] != "-" ? arguments[9] : nil
let zoom = zoomArgument.flatMap(Double.init)
let fuelUsable = arguments.count > 10 ? Double(arguments[10]) : nil
let fuelFirst = arguments.count > 11 ? Double(arguments[11]) : fuelUsable
guard let seed, zoomArgument == nil || (zoom?.isFinite == true),
      fuelUsable.map({ $0.isFinite && $0 > 0 }) ?? true,
      fuelFirst.map({ $0.isFinite && $0 >= 0 }) ?? true else {
    print("Invalid seed, map zoom or fuel range"); exit(2)
}
let compact = environment["DIRT_PROBE_COMPACT"] == "1"
let started = ContinuousClock.now
let budget = ComputationBudget(seconds: seconds)
let counter = SearchCounter()
func elapsed() -> Double {
    let d = started.duration(to: .now).components
    return Double(d.seconds)+Double(d.attoseconds)/1e18
}
func sha256(_ lines: [String]) -> String {
    var hasher = SHA256()
    for line in lines { hasher.update(data: Data((line + "\n").utf8)) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
func searchFields(since prepared: Double) -> [String:Any] {
    let pops = counter.pops
    return ["searches":counter.searches,"totalPops":pops,"peakLabels":counter.peakLabels,
            "searchMilliseconds":counter.searchMilliseconds.rounded(),"stages":counter.stageSummary,
            "microsecondsPerPop": pops > 0 ? ((elapsed()-prepared)*1e6/Double(pops)).rounded() : NSNull()]
}
var prepared = 0.0
do {
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: arguments[0],isDirectory: &isDirectory)
    let graph: any RoadGraph
    var identities: [[String:String]] = []
    var fuelStations: [FuelStation] = []
    if isDirectory.boolValue {
        let regions = arguments[1].split(separator: ",").map(String.init)
        let root = URL(fileURLWithPath: arguments[0],isDirectory: true)
        let repository = try PackRepository(installedDirectories: Dictionary(uniqueKeysWithValues: regions.map { ($0,root.appendingPathComponent($0)) }))
        let packs = try regions.map { try repository.open($0,requireSeams: regions.count > 1,budget: budget) }
        guard let first = packs.first else { throw RoutingFailure.missingPacks([]) }
        graph = packs.count == 1 ? first.graph : try RegionalGraph(packs: packs,budget: budget)
        identities = packs.map { ["region":$0.manifest.regionId,"graph":$0.graph.graphSHA256,"geometry":$0.graph.geometrySHA256] }
        var seen = Set<String>()
        for item in packs {
            struct File: Decodable { struct Station: Decodable { let id: String; let lat: Double; let lon: Double; let name: String?; let brand: String?; let address: String? }; let stations: [Station] }
            guard let decoded = try? JSONDecoder().decode(File.self,from: item.fuelData) else { throw RoutingFailure.invalidPack("fuel data") }
            for station in decoded.stations where seen.insert(station.id).inserted {
                fuelStations.append(.init(id: station.id,coordinate: .init(longitude: station.lon,latitude: station.lat),
                                          name: station.name,brand: station.brand,address: station.address))
            }
        }
    } else {
        let pack = try GraphPack(graphURL: URL(fileURLWithPath: arguments[0]),geometryURL: URL(fileURLWithPath: arguments[1]),budget: budget)
        graph = pack
        identities = [["region":pack.metadata.regionId ?? "","graph":pack.graphSHA256,"geometry":pack.geometrySHA256]]
    }
    let indexed = try IndexedGraph(graph,budget: budget)
    prepared = elapsed()
    let allowUnknown = environment["DIRT_ALLOW_UNKNOWN"] == "1"
    var request = RoutingRequest(start: .init(longitude: lonA,latitude: latA),end: .init(longitude: lonB,latitude: latB),
                                 style: style,allowUnknown: allowUnknown,seed: seed)
    if let scale = environment["DIRT_DIRT_PAVEMENT_AWAY"].flatMap(Double.init), scale.isFinite, scale > 0 {
        request.profile.dirtPavementAwayAtFullWander = scale
    }
    if let wander = environment["DIRT_WANDER"].flatMap(Double.init), wander.isFinite {
        request.profile.wander = min(1, max(0, wander))
    }
    request.mapZoom = zoom
    request.options.counter = counter
    request.options.arrivalEdgeID = environment["DIRT_ARRIVAL_EDGE"]
    if let path = environment["DIRT_PRIOR_EDGES"] {
        request.options.priorEdges = Set(try String(contentsOfFile: path,encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init))
    }
    var output: [String:Any] = ["seconds":0,"prepareSeconds":prepared,"packIdentities":identities,"seed":seed,
        "mapZoom":zoom as Any? ?? NSNull(),"allowUnknown":request.access.allowUnknown,
        "requestedStart":[lonA,latA],"requestedEnd":[lonB,latB]]
    if let fuelUsable, let fuelFirst {
        var fuel = FuelRequirements(usableRangeMeters: fuelUsable, firstLegMaxMeters: fuelFirst)
        fuel.ensureDestinationEscape = environment["DIRT_FUEL_ESCAPE"] != "0"
        fuel.minimumStops = environment["DIRT_FUEL_MIN_STOPS"].flatMap(Int.init) ?? 0
        fuel.maximumStops = environment["DIRT_FUEL_MAX_STOPS"].flatMap(Int.init)
        fuel.allowPartialResult = environment["DIRT_FUEL_ALLOW_PARTIAL"] == "1"
        let plan = try FuelPlanner(graph: indexed,stations: fuelStations).plan(request,requirements: fuel,budget: budget)
        let total = plan.routes.reduce(0) { $0+$1.distanceMeters }
        let known = plan.routes.flatMap(\.segments).filter { $0.structure != "ferry" && ($0.surface == .gravel || $0.surface == .loose) }.reduce(0) { $0+$1.meters }
        output.merge(["status": plan.complete ? "complete" : "fuel-incomplete",
            "distanceMeters":total,"knownDirtPercent": total > 0 ? (known/total*1000).rounded()/10 : 0,
            "fuelComplete":plan.complete,"fuelStops":plan.stops.map(\.id),"fuelLimit":plan.limit as Any? ?? NSNull(),
            "hopMeters":plan.routes.map(\.distanceMeters),
            "hopDirtPercent":plan.routes.map { route -> Double in
                let dirt = route.segments.filter { $0.structure != "ferry" && ($0.surface == .gravel || $0.surface == .loose) }.reduce(0) { $0+$1.meters }
                return route.distanceMeters > 0 ? (dirt/route.distanceMeters*1000).rounded()/10 : 0
            },
            "hopEdgeSHA256":sha256(plan.routes.map { $0.segments.map(\.edgeID).joined(separator: ",") }),
            "styleSummary":plan.styleSummary as Any? ?? NSNull(),
            "destinationEscapeMeters":plan.destinationEscapeMeters as Any? ?? NSNull(),
            "foundationMeters":plan.foundation?.distanceMeters as Any? ?? NSNull(),
            "pops":plan.routes.reduce(0) { $0+$1.poppedLabels},"limit":plan.limit as Any? ?? NSNull()]) { $1 }
    } else {
        // The app keeps one compass store per routing session; mirror it.
        let result = try RoutingEngine(pack: indexed,compassStore: RoadCompassStore()).route(request,budget: budget)
        let quality = RouteQuality(route: result)
        let edgeIDs = result.segments.map(\.edgeID)
        var classMeters: [String:Double] = [:]
        for segment in result.segments {
            classMeters[ProfilePolicy.tier(segment.roadClass), default: 0] += segment.meters
        }
        output.merge(["status":"complete",
            "matchedStart":[result.start.coordinate.longitude,result.start.coordinate.latitude],
            "matchedEnd":[result.end.coordinate.longitude,result.end.coordinate.latitude],
            "matchedStartEdge":indexed.edgeID(result.start.edge),"matchedEndEdge":indexed.edgeID(result.end.edge),
            "distanceMeters":result.distanceMeters,"knownDirtPercent":quality.knownDirtPercent,
            "minimumSectionDirtPercent":quality.minimumSectionDirtPercent,
            "unknownSurfacePercent":quality.unknownPercent,
            "backwardMeters":quality.backwardMeters,"lateralMeters":quality.lateralMeters,
            "longestPavedRunMeters":quality.longestPavedRunMeters,"edgeIDsSHA256":sha256(edgeIDs),
            "searchSummary":result.searchSummary as Any? ?? NSNull(),
            "roadClassMeters":classMeters,
            "pops":result.poppedLabels,"limit":result.limit as Any? ?? NSNull()]) { $1 }
        if !compact {
            output["edgeIDs"] = edgeIDs
            output["geometry"] = result.geometry.map { [$0.longitude,$0.latitude] }
        }
    }
    output.merge(searchFields(since: prepared)) { $1 }
    output["seconds"] = elapsed()
    print(String(decoding: try JSONSerialization.data(withJSONObject: output,options: [.sortedKeys]),as: UTF8.self))
} catch {
    var output: [String:Any] = ["status":"failed","seconds":elapsed(),"prepareSeconds":prepared,"error":String(describing: error)]
    output.merge(searchFields(since: prepared)) { $1 }
    print(String(decoding: try JSONSerialization.data(withJSONObject: output,options: [.sortedKeys]),as: UTF8.self))
    exit(1)
}
