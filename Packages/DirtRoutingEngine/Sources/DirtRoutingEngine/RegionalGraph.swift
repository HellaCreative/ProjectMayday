import Foundation

struct SeamDocument: Decodable, Sendable {
    struct EdgeProof: Decodable, Hashable, Sendable {
        let osmWayId: String
        let fromOsmNodeId: String
        let toOsmNodeId: String
        let accessForward: UInt8
        let accessReverse: UInt8
        let layer: Int
        let structureLeaf: String?
        /// Ranking metadata only. Old seam sidecars omit this field.
        /// Excluded from Equatable/Hashable so timing drift cannot reject a
        /// legally reciprocal seam during RegionalGraph join.
        let crossingSeconds: UInt32?

        init(osmWayId: String, fromOsmNodeId: String, toOsmNodeId: String,
             accessForward: UInt8, accessReverse: UInt8, layer: Int,
             structureLeaf: String?, crossingSeconds: UInt32? = nil) {
            self.osmWayId = osmWayId
            self.fromOsmNodeId = fromOsmNodeId
            self.toOsmNodeId = toOsmNodeId
            self.accessForward = accessForward
            self.accessReverse = accessReverse
            self.layer = layer
            self.structureLeaf = structureLeaf
            self.crossingSeconds = crossingSeconds
        }

        static func == (lhs: EdgeProof, rhs: EdgeProof) -> Bool {
            lhs.osmWayId == rhs.osmWayId
                && lhs.fromOsmNodeId == rhs.fromOsmNodeId
                && lhs.toOsmNodeId == rhs.toOsmNodeId
                && lhs.accessForward == rhs.accessForward
                && lhs.accessReverse == rhs.accessReverse
                && lhs.layer == rhs.layer
                && lhs.structureLeaf == rhs.structureLeaf
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(osmWayId)
            hasher.combine(fromOsmNodeId)
            hasher.combine(toOsmNodeId)
            hasher.combine(accessForward)
            hasher.combine(accessReverse)
            hasher.combine(layer)
            hasher.combine(structureLeaf)
        }
    }
    struct Anchor: Decodable, Sendable {
        let coordinate: [Double]
        let gapMeters: Double
        let osmNodeId: String
        let osmWayId: String
        let proof: String
        let edge: EdgeProof
        let barrierDecision: UInt8
    }
    let schemaVersion: String
    let fabricReleaseId: String
    let sourceEpoch: String
    let regionId: String
    let neighbors: [String:[Anchor]]
}

/// One continuous search over separately mapped regional files. Only independently
/// reproved OSM seams connect nodes; neither coordinate proximity nor a straight
/// connector creates an arc. Incoming turn/via-way state remains in the search.
public final class RegionalGraph: RoadGraph {
    private let packs: [GraphPack]
    private let nodeBases: [Int]
    private let edgeBases: [Int]
    private let nodeAliases: [Int:Int]
    private let nodeMembers: [Int:[Int]]
    private let edgeAliases: [Int:Int]
    public let nodeCount: Int
    public let edgeCount: Int
    public let urbanCores: [GeographicBox]
    public let restrictionIndex: RestrictionIndex

    public convenience init(packs installed: [InstalledRoutingPack], budget: ComputationBudget = .init(seconds: 60)) throws {
        guard !installed.isEmpty else { throw RoutingFailure.missingPacks([]) }
        let release = installed[0].manifest.fabricReleaseId, epoch = installed[0].manifest.sourceEpoch
        var documents: [SeamDocument] = []
        for item in installed {
            guard item.manifest.fabricReleaseId == release, item.manifest.sourceEpoch == epoch else {
                throw RoutingFailure.invalidPack("regional release/epoch mismatch")
            }
            guard let data = item.seamsData else { throw RoutingFailure.invalidPack("regional seam data missing") }
            let document = try JSONDecoder().decode(SeamDocument.self,from: data)
            guard document.schemaVersion == "dirt-cross-pack-seams.v2", document.regionId == item.manifest.regionId,
                  document.sourceEpoch == epoch, document.fabricReleaseId == release else {
                throw RoutingFailure.invalidPack("regional seam identity mismatch")
            }
            documents.append(document)
        }
        try self.init(graphs: installed.map(\.graph),documents: documents,budget: budget)
    }

    init(graphs: [GraphPack], documents: [SeamDocument], budget: ComputationBudget) throws {
        guard graphs.count == documents.count, !graphs.isEmpty,
              Set(documents.map(\.regionId)).count == documents.count else { throw RoutingFailure.invalidPack("regional inputs") }
        packs = graphs
        var nb = [0], eb = [0]
        for graph in graphs { nb.append(nb.last!+graph.nodeCount); eb.append(eb.last!+graph.edgeCount) }
        nodeBases = nb; edgeBases = eb; nodeCount = nb.last!; edgeCount = eb.last!
        urbanCores = graphs.flatMap(\.urbanCores)
        let regionIndices = Dictionary(uniqueKeysWithValues: documents.enumerated().map { ($0.element.regionId,$0.offset) })
        var located: [[String:Int]] = []
        // The sidecars bound the lookup set. Do not allocate a dictionary of all
        // province nodes merely to find a handful of border anchors.
        for (i,graph) in graphs.enumerated() {
            let wanted = Set(documents[i].neighbors.filter { regionIndices[$0.key] != nil }.values.flatMap { $0.map(\.osmNodeId) })
            var found: [String:Int] = [:]
            for n in 0..<graph.nodeCount {
                if n & 4095 == 0 { try budget.check() }
                let id = String(graph.osmNodeID(n))
                if wanted.contains(id) {
                    guard found[id] == nil else { throw RoutingFailure.invalidPack("ambiguous seam node") }
                    found[id] = n
                }
            }
            located.append(found)
        }
        func proof(_ p: Int,_ edge: Int) -> SeamDocument.EdgeProof {
            let g = graphs[p]
            let structure = g.structure(edge)
            return .init(osmWayId: String(g.osmWayID(edge)),fromOsmNodeId: String(g.osmNodeID(g.endpoint(edge,from: true))),
                         toOsmNodeId: String(g.osmNodeID(g.endpoint(edge,from: false))),
                         accessForward: g.accessCode(edge,forward: true),accessReverse: g.accessCode(edge,forward: false),
                         layer: Int(g.layers[edge]),structureLeaf: structure.isEmpty ? nil : structure)
        }
        /// OSM topology only — access/layer/structure can drift between
        /// independently packed border regions for the same way and must not
        /// reject a seam that the sidecar already proved reciprocal.
        /// Endpoint order is normalized: packs may store the same way reversed.
        struct EdgeTopology: Hashable {
            let osmWayId: String
            let nodeLo: String
            let nodeHi: String
            init(_ edge: SeamDocument.EdgeProof) {
                osmWayId = edge.osmWayId
                let a = edge.fromOsmNodeId, b = edge.toOsmNodeId
                if a <= b { nodeLo = a; nodeHi = b } else { nodeLo = b; nodeHi = a }
            }
        }
        /// OSM identity for turn restrictions at a seam. Endpoint node IDs are
        /// omitted: border ways are often clipped differently in each pack, so
        /// the same OSM restriction can reference different local endpoints
        /// while still being the same legal rule.
        struct RestrictionProof: Hashable {
            let relation: Int64
            let fromWay: String
            let toWay: String
            let viaWays: [String]
            let only: Bool
            let mask: UInt16
            init(relation: Int64, from: SeamDocument.EdgeProof, to: SeamDocument.EdgeProof,
                 via: [SeamDocument.EdgeProof], only: Bool, mask: UInt16) {
                self.relation = relation
                self.fromWay = from.osmWayId
                self.toWay = to.osmWayId
                self.viaWays = via.map(\.osmWayId)
                self.only = only
                self.mask = mask
            }
        }
        func relevant(_ p: Int,_ node: Int) -> Set<RestrictionProof> {
            let incident = Set(graphs[p].outgoing(node).map(\.edge))
            return Set(graphs[p].restrictions.filter { r in
                r.viaNode == node || incident.contains(r.fromEdge) || incident.contains(r.toEdge) || !incident.isDisjoint(with: r.viaEdges)
            }.map { r in
                RestrictionProof(relation: r.relationID,
                                 from: proof(p,r.fromEdge),
                                 to: proof(p,r.toEdge),
                                 via: r.viaEdges.map { proof(p,$0) },
                                 only: r.only, mask: r.vehicleMask)
            })
        }
        var parent: [Int:Int] = [:], linkedRegions: [Int:Set<Int>] = [:]
        func root(_ n: Int) -> Int { var r = n; while let p = parent[r], p != r { r = p }; return r }
        var borderEdges: Set<Int> = []
        for (left,document) in documents.enumerated() {
            for (neighbor,anchors) in document.neighbors.sorted(by: { $0.key < $1.key }) {
                guard let right = regionIndices[neighbor], right > left else { continue }
                for anchor in anchors {
                    try budget.check()
                    guard anchor.proof == "shared-osm-node-way-edge-legal-topology.v1",
                          anchor.osmNodeId != "0", anchor.osmWayId != "0", anchor.osmWayId == anchor.edge.osmWayId,
                          anchor.gapMeters.isFinite, anchor.gapMeters >= 0, anchor.gapMeters <= 2,
                          anchor.coordinate.count == 2,
                          let ln = located[left][anchor.osmNodeId], let rn = located[right][anchor.osmNodeId],
                          documents[right].neighbors[document.regionId]?.contains(where: {
                              $0.osmNodeId == anchor.osmNodeId && $0.edge == anchor.edge && $0.proof == anchor.proof
                          }) == true else { throw RoutingFailure.invalidPack("unreciprocated seam proof") }
                    let lg = graphs[left], rg = graphs[right]
                    let stated = Coordinate(longitude: anchor.coordinate[0],latitude: anchor.coordinate[1])
                    let leftPoint = lg.coordinate(node: ln), rightPoint = rg.coordinate(node: rn)
                    let leftBarrier = lg.barriers[ln,default: 0], rightBarrier = rg.barriers[rn,default: 0]
                    let leftHasEdge = lg.outgoing(ln).contains(where: {
                        EdgeTopology(proof(left,$0.edge)) == EdgeTopology(anchor.edge)
                    })
                    let rightHasEdge = rg.outgoing(rn).contains(where: {
                        EdgeTopology(proof(right,$0.edge)) == EdgeTopology(anchor.edge)
                    })
                    let leftRelevant = relevant(left,ln), rightRelevant = relevant(right,rn)
                    guard stated.isValid else {
                        throw RoutingFailure.invalidPack("seam does not match graph legality: invalid coordinate node=\(anchor.osmNodeId)")
                    }
                    guard leftPoint.distance(to: rightPoint) <= 2 else {
                        throw RoutingFailure.invalidPack("seam does not match graph legality: node gap \(leftPoint.distance(to: rightPoint))m node=\(anchor.osmNodeId)")
                    }
                    guard leftPoint.distance(to: stated) <= 2 else {
                        throw RoutingFailure.invalidPack("seam does not match graph legality: stated gap \(leftPoint.distance(to: stated))m node=\(anchor.osmNodeId)")
                    }
                    guard leftBarrier == anchor.barrierDecision, rightBarrier == anchor.barrierDecision else {
                        throw RoutingFailure.invalidPack("seam does not match graph legality: barrier left=\(leftBarrier) right=\(rightBarrier) seam=\(anchor.barrierDecision) node=\(anchor.osmNodeId)")
                    }
                    guard leftHasEdge, rightHasEdge else {
                        throw RoutingFailure.invalidPack("seam does not match graph legality: missing edge proof way=\(anchor.edge.osmWayId) node=\(anchor.osmNodeId) left=\(leftHasEdge) right=\(rightHasEdge)")
                    }
                    guard leftRelevant == rightRelevant else {
                        let leftDesc = leftRelevant.map {
                            "\($0.relation):\($0.fromWay)>\($0.toWay) only=\($0.only) mask=\($0.mask) via=\($0.viaWays)"
                        }.sorted().joined(separator: ";")
                        let rightDesc = rightRelevant.map {
                            "\($0.relation):\($0.fromWay)>\($0.toWay) only=\($0.only) mask=\($0.mask) via=\($0.viaWays)"
                        }.sorted().joined(separator: ";")
                        throw RoutingFailure.invalidPack("seam does not match graph legality: restriction mismatch node=\(anchor.osmNodeId) left=[\(leftDesc)] right=[\(rightDesc)]")
                    }
                    // A prohibited/conditional barrier cannot become a passage merely
                    // because both regions agree it exists.
                    guard anchor.barrierDecision == 0 else { continue }
                    let a = root(nb[left]+ln), b = root(nb[right]+rn)
                    if a != b { parent[max(a,b)] = min(a,b) }
                    linkedRegions[left,default: []].insert(right); linkedRegions[right,default: []].insert(left)
                    for arc in lg.outgoing(ln) { borderEdges.insert(eb[left]+arc.edge) }
                    for arc in rg.outgoing(rn) { borderEdges.insert(eb[right]+arc.edge) }
                }
            }
        }
        var reached: Set<Int> = [0], queue = [0], head = 0
        while head < queue.count {
            let n = queue[head]; head += 1
            for next in linkedRegions[n,default: []] where reached.insert(next).inserted { queue.append(next) }
        }
        guard reached.count == graphs.count else { throw RoutingFailure.invalidPack("packs have no verified connected seams") }
        var aliases: [Int:Int] = [:], members: [Int:[Int]] = [:]
        for node in Set(parent.keys).union(parent.values) {
            let canonical = root(node)
            aliases[node] = canonical; members[canonical,default: []].append(node)
        }
        nodeAliases = aliases; nodeMembers = members.mapValues { $0.sorted() }
        // Normalize duplicate physical edges only for identity/turn tracking.
        // Their original directed adjacency and geometry stay in their mapped pack.
        for (p,g) in graphs.enumerated() {
            for r in g.restrictions {
                borderEdges.insert(eb[p]+r.fromEdge); borderEdges.insert(eb[p]+r.toEdge)
                for edge in r.viaEdges { borderEdges.insert(eb[p]+edge) }
            }
        }
        func owner(_ value: Int,_ bases: [Int]) -> Int {
            var lo = 0, hi = bases.count-1
            while lo+1 < hi { let mid = (lo+hi)/2; if bases[mid] <= value { lo = mid } else { hi = mid } }
            return lo
        }
        var identities: [SeamDocument.EdgeProof:Int] = [:], edgeMap: [Int:Int] = [:]
        for global in borderEdges.sorted() {
            try budget.check()
            let p = owner(global,eb), local = global-eb[p], key = proof(p,local)
            if let first = identities[key] {
                let q = owner(first,eb), original = first-eb[q]
                guard graphs[q].distance(original) == graphs[p].distance(local),
                      graphs[q].polyline(original) == graphs[p].polyline(local) else {
                    throw RoutingFailure.invalidPack("shared road geometry differs")
                }
                edgeMap[global] = first
            } else { identities[key] = global }
        }
        edgeAliases = edgeMap
        var combined: [TurnRestriction] = []
        for (p,g) in graphs.enumerated() {
            for r in g.restrictions {
                func edge(_ e: Int) -> Int { edgeMap[eb[p]+e] ?? eb[p]+e }
                combined.append(.init(relationID: r.relationID,fromEdge: edge(r.fromEdge),toEdge: edge(r.toEdge),
                    viaNode: r.viaNode < 0 ? -1 : (aliases[nb[p]+r.viaNode] ?? nb[p]+r.viaNode),
                    viaEdges: r.viaEdges.map(edge),only: r.only,vehicleMask: r.vehicleMask))
            }
        }
        restrictionIndex = RestrictionIndex(combined)
        try budget.check()
    }
    private func owner(_ value: Int,_ bases: [Int]) -> Int {
        var lo = 0, hi = bases.count-1
        while lo+1 < hi { let mid = (lo+hi)/2; if bases[mid] <= value { lo = mid } else { hi = mid } }
        return lo
    }
    private func edge(_ e: Int) -> (GraphPack,Int) { let p = owner(e,edgeBases); return (packs[p],e-edgeBases[p]) }
    public func coordinate(node: Int) -> Coordinate {
        let canonical = nodeAliases[node] ?? node
        let p = owner(canonical, nodeBases)
        return packs[p].coordinate(node: canonical - nodeBases[p])
    }
    public func endpoint(_ edge: Int,from: Bool) -> Int {
        let p = owner(edge,edgeBases), n = nodeBases[p]+packs[p].endpoint(edge-edgeBases[p],from: from)
        return nodeAliases[n] ?? n
    }
    public func outgoing(_ node: Int) -> [RoadArc] {
        let canonical = nodeAliases[node] ?? node
        var result: [RoadArc] = []
        for n in nodeMembers[canonical] ?? [canonical] {
            let p = owner(n,nodeBases)
            for arc in packs[p].outgoing(n-nodeBases[p]) {
                let target = nodeBases[p]+arc.target
                result.append(.init(target: nodeAliases[target] ?? target,edge: edgeBases[p]+arc.edge,
                                    forward: arc.forward,meters: arc.meters))
            }
        }
        return result
    }
    public func restrictionEdge(_ edge: Int) -> Int { edgeAliases[edge] ?? edge }
    public func edgeID(_ e: Int) -> String {
        let (g,i) = edge(e)
        return "\(g.osmWayID(i)):\(g.osmNodeID(g.endpoint(i,from: true))):\(g.osmNodeID(g.endpoint(i,from: false)))"
    }
    public func distance(_ e: Int) -> Double { let (g,i) = edge(e); return g.distance(i) }
    public func attributes(_ e: Int) -> UInt16 { let (g,i) = edge(e); return g.attributes(i) }
    public func crossingTime(_ e: Int) -> Double { let (g,i) = edge(e); return g.crossingTime(i) }
    public func accessCode(_ e: Int,forward: Bool) -> UInt8 { let (g,i) = edge(e); return g.accessCode(i,forward: forward) }
    public func surfaceLeaf(_ e: Int) -> String { let (g,i) = edge(e); return g.surfaceLeaf(i) }
    public func roadClass(_ e: Int) -> String { let (g,i) = edge(e); return g.roadClass(i) }
    public func structure(_ e: Int) -> String { let (g,i) = edge(e); return g.structure(i) }
    public func polyline(_ e: Int) -> [Coordinate] { let (g,i) = edge(e); return g.polyline(i) }
    public func osmWayID(_ e: Int) -> Int64 { let (g,i) = edge(e); return g.osmWayID(i) }
    public func osmNodeID(_ n: Int) -> Int64 {
        let canonical = nodeAliases[n] ?? n
        let p = owner(canonical,nodeBases)
        return packs[p].osmNodeID(canonical-nodeBases[p])
    }
}
