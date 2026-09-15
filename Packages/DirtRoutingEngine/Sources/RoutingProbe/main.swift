import Foundation
import DirtRoutingEngine

// A local-file-only qualification entry point, independent of the app and simulator.
let arguments = Array(CommandLine.arguments.dropFirst())
guard (8...12).contains(arguments.count),
      let lonA = Double(arguments[2]), let latA = Double(arguments[3]),
      let lonB = Double(arguments[4]), let latB = Double(arguments[5]),
      let style = RidingStyle(rawValue: arguments[6]), let seconds = Double(arguments[7]) else {
    print("Usage: dirt-routing-probe GRAPH GEOMETRY FROM_LON FROM_LAT TO_LON TO_LAT STYLE SECONDS [SEED [MAP_ZOOM [FUEL_USABLE [FUEL_FIRST]]]]")
    exit(2)
}
let seed = arguments.count > 8 ? UInt64(arguments[8]) : 1
let zoom = arguments.count > 9 ? Double(arguments[9]) : nil
let fuelUsable = arguments.count > 10 ? Double(arguments[10]) : nil
let fuelFirst = arguments.count > 11 ? Double(arguments[11]) : fuelUsable
guard let seed, arguments.count < 10 || (zoom?.isFinite == true),
      fuelUsable.map({ $0.isFinite && $0 > 0 }) ?? true,
      fuelFirst.map({ $0.isFinite && $0 >= 0 }) ?? true else {
    print("Invalid seed, map zoom or fuel range"); exit(2)
}
let started = ContinuousClock.now
let budget = ComputationBudget(seconds: seconds)
func elapsed() -> Double {
    let d = started.duration(to: .now).components
    return Double(d.seconds)+Double(d.attoseconds)/1e18
}
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
    let prepared = elapsed()
    var request = RoutingRequest(start: .init(longitude: lonA,latitude: latA),end: .init(longitude: lonB,latitude: latB),style: style,seed: seed)
    request.mapZoom = zoom
    let output: [String:Any]
    if let fuelUsable, let fuelFirst {
        var fuel = FuelRequirements(usableRangeMeters: fuelUsable, firstLegMaxMeters: fuelFirst)
        fuel.ensureDestinationEscape = true
        let plan = try FuelPlanner(graph: indexed,stations: fuelStations).plan(request,requirements: fuel,budget: budget)
        let total = plan.routes.reduce(0) { $0+$1.distanceMeters }
        let known = plan.routes.flatMap(\.segments).filter { $0.structure != "ferry" && ($0.surface == .gravel || $0.surface == .loose) }.reduce(0) { $0+$1.meters }
        output = ["status": plan.complete ? "complete" : "fuel-incomplete","seconds":elapsed(),"prepareSeconds":prepared,
            "packIdentities":identities,"seed":seed,"mapZoom":zoom as Any? ?? NSNull(),
            "requestedStart":[lonA,latA],"requestedEnd":[lonB,latB],
            "distanceMeters":total,"knownDirtPercent": total > 0 ? (known/total*1000).rounded()/10 : 0,
            "fuelComplete":plan.complete,"fuelStops":plan.stops.map(\.id),"fuelLimit":plan.limit as Any? ?? NSNull(),
            "destinationEscapeMeters":plan.destinationEscapeMeters as Any? ?? NSNull(),
            "foundationMeters":plan.foundation?.distanceMeters as Any? ?? NSNull(),
            "pops":plan.routes.reduce(0) { $0+$1.poppedLabels},"limit":plan.limit as Any? ?? NSNull()]
    } else {
        let result = try RoutingEngine(pack: indexed).route(request,budget: budget)
        let quality = RouteQuality(route: result)
        output = ["status":"complete","seconds":elapsed(),"prepareSeconds":prepared,
        "packIdentities":identities,"seed":seed,"mapZoom":zoom as Any? ?? NSNull(),
        "requestedStart":[lonA,latA],"requestedEnd":[lonB,latB],
        "matchedStart":[result.start.coordinate.longitude,result.start.coordinate.latitude],
        "matchedEnd":[result.end.coordinate.longitude,result.end.coordinate.latitude],
        "matchedStartEdge":indexed.edgeID(result.start.edge),"matchedEndEdge":indexed.edgeID(result.end.edge),
        "distanceMeters":result.distanceMeters,"knownDirtPercent":quality.knownDirtPercent,
        "unknownSurfacePercent":quality.unknownPercent,"edgeIDs":result.segments.map(\.edgeID),
        "geometry":result.geometry.map { [$0.longitude,$0.latitude] },"pops":result.poppedLabels,"limit":result.limit as Any? ?? NSNull()]
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: output,options: [.sortedKeys]),as: UTF8.self))
} catch {
    let output: [String:Any] = ["status":"failed","seconds":elapsed(),"error":String(describing: error)]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output,options: [.sortedKeys]),as: UTF8.self))
    exit(1)
}
