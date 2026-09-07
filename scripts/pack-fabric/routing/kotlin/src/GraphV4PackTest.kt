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
        check(picked.end?.osmWayId != 100L) { "yarmouth snapped to disconnected pier" }
        check(picked.end?.osmWayId == 200L || picked.end?.osmWayId == 400L) {
            "yarmouth picked unexpected ${picked.end?.osmWayId}"
        }
        println("ok yarmouth harbour way=${picked.end?.osmWayId} radius=$radius")
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
