package dirt.routing.v4

import java.nio.file.Files
import java.nio.file.Path

fun main(args: Array<String>) {
    val graphPath = args.getOrNull(0) ?: error("graph path required")
    val geomPath = args.getOrNull(1)
    val graph = Files.readAllBytes(Path.of(graphPath))
    val geom = geomPath?.let { Files.readAllBytes(Path.of(it)) }
    val pack = GraphV4Pack.decode(graph, geom)
    check(pack.capabilities.contains(GraphV4Pack.CAPABILITY))
    check(pack.version == 4)
    check(pack.nodeOffsets.size == pack.nodeCount + 1)
    check(pack.edgeAccess.size == pack.undirectedEdgeCount * 2)
    pack.applyCrossPackSeams(
        GraphV4Pack.SeamSidecar(
            schemaVersion = "dirt-cross-pack-seams.v2",
            fabricReleaseId = "fixture-v4",
            sourceEpoch = pack.sourceEpoch,
            regionId = pack.regionId,
            neighbors = mapOf(
                "nb" to listOf(
                    GraphV4Pack.SeamAnchor(-64.25, 45.85, "100", "100:1:2", "100:1:2", 0.0)
                )
            )
        )
    )
    check(pack.crossPackSeams["nb"]?.size == 1)
    try {
        pack.applyCrossPackSeams(
            GraphV4Pack.SeamSidecar(
                "dirt-cross-pack-seams.v2", "fixture-v4", "wrong-epoch", pack.regionId, emptyMap()
            )
        )
        error("expected mismatched seam epoch rejection")
    } catch (_: IllegalArgumentException) {
    }
    println("ok nodes=${pack.nodeCount} edges=${pack.undirectedEdgeCount} arcs=${pack.directedArcCount}")

    val west = FindPathV4.findPath(
        pack,
        LatLon(45.80779, -64.191),
        LatLon(45.80779, -64.209),
        startHeadingDeg = 270.0,
        intentBearingDeg = 270.0
    )
    check(west.ok) { "westbound V4 search failed: ${west.reason}" }
    check(west.osmWayIds.contains(537982310L)) { "westbound missed 537982310: ${west.osmWayIds}" }
    check(!west.osmWayIds.contains(537982311L)) { "westbound used eastbound carriageway" }

    val east = FindPathV4.findPath(
        pack,
        LatLon(45.80731, -64.209),
        LatLon(45.80731, -64.191),
        startHeadingDeg = 90.0,
        intentBearingDeg = 90.0
    )
    check(east.ok) { "eastbound V4 search failed: ${east.reason}" }
    check(east.osmWayIds.contains(537982311L)) { "eastbound missed 537982311: ${east.osmWayIds}" }
    check(!east.osmWayIds.contains(537982310L)) { "eastbound used westbound carriageway" }
    val mid = LatLon(45.80755, -64.2)
    val westSnap = LegalSnap.legalSnapDetailed(pack, mid, headingDeg = 270.0, intentBearingDeg = 270.0)
    val eastSnap = LegalSnap.legalSnapDetailed(pack, mid, headingDeg = 90.0, intentBearingDeg = 90.0)
    check(westSnap.candidates.isNotEmpty()) { "west snap empty" }
    check(westSnap.candidates[0].osmWayId == 537982310L) { "west snap lost heading score: ${westSnap.candidates[0].osmWayId}" }
    check(eastSnap.candidates[0].osmWayId == 537982311L) { "east snap lost heading score: ${eastSnap.candidates[0].osmWayId}" }
    val yarmouth = TapRadius.meters(zoom = 10.0, latitude = 43.65, graphBinaryVersion = 4)
    check(yarmouth >= 1700 && yarmouth <= TapRadius.V4_CAP_METERS) { "yarmouth radius $yarmouth" }
    check(TapRadius.meters(requestedMeters = 5000.0, latitude = 43.65, graphBinaryVersion = 4) == TapRadius.V4_CAP_METERS)
    check(TapRadius.meters(requestedMeters = 5000.0, latitude = 43.65, graphBinaryVersion = 3) == TapRadius.V3_CAP_METERS)
    println("ok snap heading west=${westSnap.candidates[0].osmWayId} east=${eastSnap.candidates[0].osmWayId} radius=$yarmouth")

    val yarmouthGraph = args.getOrNull(2)
    val yarmouthGeom = args.getOrNull(3)
    if (yarmouthGraph != null && yarmouthGeom != null) {
        val yPack = GraphV4Pack.decode(
            Files.readAllBytes(Path.of(yarmouthGraph)),
            Files.readAllBytes(Path.of(yarmouthGeom))
        )
        val radius = TapRadius.meters(zoom = 10.0, latitude = 43.648606, graphBinaryVersion = 4)
        val startCands = LegalSnap.legalSnap(
            yPack,
            LatLon(45.390440, -63.201514),
            intentBearingDeg = 240.0,
            maxMeters = radius
        )
        val endCands = LegalSnap.legalSnap(
            yPack,
            LatLon(43.648606, -65.774864),
            intentBearingDeg = 60.0,
            maxMeters = radius
        )
        val picked = LegalSnap.selectConnectedSnapPair(yPack, startCands, endCands, allowUnknown = false)
        check(picked.ok) { "yarmouth pair failed: ${picked.reason}" }
        val pickedEnd = checkNotNull(picked.end)
        check(pickedEnd.osmWayId != 100L) { "yarmouth snapped to disconnected pier" }
        check(pickedEnd.osmWayId == 200L || pickedEnd.osmWayId == 400L) {
            "yarmouth picked unexpected ${pickedEnd.osmWayId}"
        }
        println("ok yarmouth harbour way=${pickedEnd.osmWayId} radius=$radius")
    }

    val restrictionGraph = args.getOrNull(4)
    val restrictionGeom = args.getOrNull(5)
    if (restrictionGraph != null && restrictionGeom != null) {
        val legalPack = GraphV4Pack.decode(
            Files.readAllBytes(Path.of(restrictionGraph)),
            Files.readAllBytes(Path.of(restrictionGeom))
        )
        fun edge(way: Long) = legalPack.osmWayIds.indexOf(way).also {
            check(it >= 0) { "fixture missing OSM way $way" }
        }
        fun node(osm: Long) = legalPack.osmNodeIds.indexOf(osm).also {
            check(it >= 0) { "fixture missing OSM node $osm" }
        }
        val from = edge(10)
        val via = legalPack.osmWayIds.withIndex().filter { it.value == 11L }.map { it.index }
        val to = edge(12)
        check(via.size == 2) { "via-way fixture was not split into two edges: $via" }
        var state = legalPack.advanceRestrictionState(emptyList(), from, via[0], node(2))
        check(state.allowed)
        state = legalPack.advanceRestrictionState(state.active, via[0], via[1], node(3))
        check(state.allowed)
        check(!legalPack.advanceRestrictionState(state.active, via[1], to, node(4)).allowed) {
            "complete forbidden via-way turn was allowed"
        }
        check(legalPack.advanceRestrictionState(emptyList(), via[1], to, node(4)).allowed) {
            "unrelated approach inherited a via-way restriction"
        }

        val destination = edge(20)
        val customers = edge(21)
        val unknown = edge(22)
        check(legalPack.accessAllowed(destination, node(20), node(21), false, true))
        check(!legalPack.accessAllowed(destination, node(20), node(21), false, true, "customers"))
        check(!legalPack.accessAllowed(customers, node(22), node(23), false, true))
        check(legalPack.accessAllowed(customers, node(22), node(23), false, true, "customers"))
        check(!legalPack.accessAllowed(unknown, node(23), node(24), false, false))
        check(legalPack.accessAllowed(unknown, node(23), node(24), true, false))
        println("ok exact via-way and endpoint access parity")
    }

    GraphV4Pack.rejectMixedContract(listOf("epoch-1", "epoch-1"))
    try {
        GraphV4Pack.decode(ByteArray(140) { 0 }, null)
        error("expected reject")
    } catch (_: IllegalArgumentException) {
    }
    try {
        GraphV4Pack.rejectMixedContract(listOf("a", "b"))
        error("expected mixed reject")
    } catch (_: IllegalArgumentException) {
    }
}
