package dirt.routing.v4

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

object TapRadius {
    const val MIN_METERS = 80.0
    const val DEFAULT_METERS = 550.0
    const val V3_CAP_METERS = 750.0
    const val V4_CAP_METERS = 2000.0
    const val FINGER_POINTS = 28.0
    const val MERCATOR_M_PER_POINT_AT_ZOOM_0 = 156543.03392

    fun capMeters(graphBinaryVersion: Int): Double =
        if (graphBinaryVersion >= 4) V4_CAP_METERS else V3_CAP_METERS

    fun meters(
        zoom: Double? = null,
        latitude: Double,
        requestedMeters: Double? = null,
        graphBinaryVersion: Int,
        defaultMeters: Double = DEFAULT_METERS
    ): Double {
        val cap = capMeters(graphBinaryVersion)
        if (requestedMeters != null && requestedMeters.isFinite() && requestedMeters > 0) {
            return min(cap, max(MIN_METERS, requestedMeters))
        }
        if (zoom != null && zoom.isFinite() && latitude.isFinite()) {
            val metersPerPoint = MERCATOR_M_PER_POINT_AT_ZOOM_0 *
                cos(Math.toRadians(latitude)) /
                2.0.pow(zoom)
            return min(cap, max(MIN_METERS, FINGER_POINTS * metersPerPoint))
        }
        val base = if (defaultMeters.isFinite() && defaultMeters > 0) defaultMeters else DEFAULT_METERS
        return min(cap, max(MIN_METERS, base))
    }
}

data class SnapCandidate(
    val edgeIndex: Int,
    val osmWayId: Long?,
    val distanceM: Double,
    val fraction: Double,
    val forward: Boolean,
    val tangent: Double,
    val score: Double,
    val lon: Double,
    val lat: Double,
    val accessCode: Int,
    val accessClass: String,
    var component: Int = -1
)

data class SnapRejection(
    val reason: String,
    val osmWayId: Long? = null,
    val distanceM: Double? = null
)

data class LegalSnapResult(
    val candidates: List<SnapCandidate>,
    val rejections: List<SnapRejection>,
    val radiusMeters: Double
)

data class ConnectedSnapPair(
    val ok: Boolean,
    val start: SnapCandidate? = null,
    val end: SnapCandidate? = null,
    val reason: String? = null,
    val rejections: List<SnapRejection> = emptyList(),
    val allowUnknown: Boolean = false
)

object LegalSnap {
    fun accessName(code: Int): String = when (code) {
        0 -> "motorized_verified"
        1 -> "motorized_unknown"
        2 -> "motorized_denied"
        3 -> "motorized_endpoint"
        4 -> "motorized_destination"
        5 -> "motorized_impassable"
        else -> "motorized_unknown"
    }

    fun legalSnap(
        pack: GraphV4Pack,
        location: LatLon,
        headingDeg: Double? = null,
        intentBearingDeg: Double? = null,
        maxMeters: Double? = null,
        zoom: Double? = null,
        allowUnknown: Boolean = false
    ): List<SnapCandidate> = legalSnapDetailed(
        pack, location, headingDeg, intentBearingDeg, maxMeters, zoom, allowUnknown
    ).candidates

    fun legalSnapDetailed(
        pack: GraphV4Pack,
        location: LatLon,
        headingDeg: Double? = null,
        intentBearingDeg: Double? = null,
        maxMeters: Double? = null,
        zoom: Double? = null,
        allowUnknown: Boolean = false
    ): LegalSnapResult {
        val radius = maxMeters ?: TapRadius.meters(
            zoom = zoom,
            latitude = location.lat,
            graphBinaryVersion = 4
        )
        val candidates = ArrayList<SnapCandidate>()
        val rejections = ArrayList<SnapRejection>()
        for (ei in 0 until pack.undirectedEdgeCount) {
            val a = nodeLatLon(pack, pack.edgeFrom[ei])
            val b = nodeLatLon(pack, pack.edgeTo[ei])
            val proj = project(location, a, b)
            if (proj.distanceM > radius) {
                rejections.add(SnapRejection("outside_tap_radius", pack.osmWayIds.getOrNull(ei), proj.distanceM))
                continue
            }
            val tangent = bearing(a, b)
            val dirs = listOf(true to tangent, false to ((tangent + 180) % 360))
            val edgeM = pack.edgeMeters[ei].toDouble().coerceAtLeast(1.0)
            for ((forward, dirTangent) in dirs) {
                val from = if (forward) pack.edgeFrom[ei] else pack.edgeTo[ei]
                val to = if (forward) pack.edgeTo[ei] else pack.edgeFrom[ei]
                val legal = directionLegal(pack, ei, from, to, allowUnknown)
                if (legal.reason != null) {
                    rejections.add(SnapRejection(legal.reason, pack.osmWayIds.getOrNull(ei), proj.distanceM))
                    continue
                }
                var score = proj.distanceM
                if (headingDeg != null) score += angleDiff(headingDeg, dirTangent) * 0.4
                if (intentBearingDeg != null) score += angleDiff(intentBearingDeg, dirTangent) * 0.25
                candidates.add(
                    SnapCandidate(
                        edgeIndex = ei,
                        osmWayId = pack.osmWayIds.getOrNull(ei),
                        distanceM = proj.distanceM,
                        fraction = proj.along / edgeM,
                        forward = forward,
                        tangent = dirTangent,
                        score = score,
                        lon = proj.lon,
                        lat = proj.lat,
                        accessCode = legal.code,
                        accessClass = accessName(legal.code)
                    )
                )
            }
        }
        candidates.sortBy { it.score }
        val kept = ArrayList<SnapCandidate>()
        for (cand in candidates) {
            val heading = headingDeg ?: intentBearingDeg
            if (heading != null) {
                val opposite = kept.find {
                    it.edgeIndex != cand.edgeIndex &&
                        it.distanceM < 80 &&
                        cand.distanceM < 80 &&
                        angleDiff(it.tangent, cand.tangent) > 140
                }
                if (opposite != null &&
                    angleDiff(heading, cand.tangent) > 70 &&
                    angleDiff(heading, opposite.tangent) < 40
                ) {
                    rejections.add(SnapRejection("median_opposite_carriageway", cand.osmWayId, cand.distanceM))
                    continue
                }
            }
            kept.add(cand)
            if (kept.size >= 12) break
        }
        return LegalSnapResult(kept, rejections, radius)
    }

    fun selectConnectedSnapPair(
        pack: GraphV4Pack,
        startCands: List<SnapCandidate>,
        endCands: List<SnapCandidate>,
        allowUnknown: Boolean
    ): ConnectedSnapPair {
        val components = weakComponentIds(pack, allowUnknown)
        val starts = startCands.map { it.copy(component = componentOf(pack, it, components)) }
        val ends = endCands.map { it.copy(component = componentOf(pack, it, components)) }
        val rejections = ArrayList<SnapRejection>()
        val pairs = ArrayList<Triple<SnapCandidate, SnapCandidate, Double>>()
        for (start in starts) {
            for (end in ends) {
                pairs.add(Triple(start, end, start.score + end.score))
            }
        }
        pairs.sortBy { it.third }
        for ((start, end, _) in pairs) {
            if (start.component != end.component) {
                rejections.add(SnapRejection("disconnected_component", end.osmWayId))
                continue
            }
            return ConnectedSnapPair(ok = true, start = start, end = end, rejections = rejections, allowUnknown = allowUnknown)
        }
        return ConnectedSnapPair(
            ok = false,
            reason = if (starts.isNotEmpty() && ends.isNotEmpty()) "no_connected_candidate" else "no_legal_snap",
            rejections = rejections,
            allowUnknown = allowUnknown
        )
    }

    fun weakComponentIds(pack: GraphV4Pack, allowUnknown: Boolean): IntArray {
        val n = pack.nodeCount
        val parent = IntArray(n) { it }
        fun find(i: Int): Int {
            var x = i
            while (parent[x] != x) {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        fun union(a: Int, b: Int) {
            if (a < 0 || b < 0 || a >= n || b >= n) return
            val ra = find(a)
            val rb = find(b)
            if (ra != rb) parent[rb] = ra
        }
        fun member(code: Int): Boolean {
            if (code == 0) return true
            if (code == 1) return allowUnknown
            if (code == 3 || code == 4) return true
            return false
        }
        for (ei in 0 until pack.undirectedEdgeCount) {
            val a = pack.edgeFrom[ei]
            val b = pack.edgeTo[ei]
            val fwd = pack.accessCode(ei, a, b)
            val rev = pack.accessCode(ei, b, a)
            if (member(fwd) || member(rev)) union(a, b)
        }
        return IntArray(n) { find(it) }
    }

    private fun componentOf(pack: GraphV4Pack, cand: SnapCandidate, components: IntArray): Int {
        val node = if (cand.forward) pack.edgeFrom[cand.edgeIndex] else pack.edgeTo[cand.edgeIndex]
        if (node < 0 || node >= components.size) return -1
        return components[node]
    }

    private data class Legal(val code: Int, val reason: String?)

    private fun directionLegal(
        pack: GraphV4Pack,
        ei: Int,
        from: Int,
        to: Int,
        allowUnknown: Boolean
    ): Legal {
        if (!pack.hasDirectedArc(from, to, ei)) return Legal(2, "prohibited_direction")
        val code = pack.accessCode(ei, from, to)
        if (code == 2) return Legal(code, "inaccessible")
        if (code == 5) return Legal(code, "impassable")
        if (code == 1 && !allowUnknown) return Legal(code, "unknown_trail")
        return Legal(code, null)
    }

    private fun nodeLatLon(pack: GraphV4Pack, node: Int): LatLon =
        LatLon(pack.nodeCoords[node * 2 + 1].toDouble(), pack.nodeCoords[node * 2].toDouble())

    private data class Proj(val distanceM: Double, val along: Double, val lon: Double, val lat: Double)

    private fun project(point: LatLon, a: LatLon, b: LatLon): Proj {
        val dx = b.lon - a.lon
        val dy = b.lat - a.lat
        val len2 = dx * dx + dy * dy
        val t = if (len2 <= 0) 0.0 else ((point.lon - a.lon) * dx + (point.lat - a.lat) * dy) / len2
        val clamped = t.coerceIn(0.0, 1.0)
        val lon = a.lon + dx * clamped
        val lat = a.lat + dy * clamped
        val along = haversine(a, b) * clamped
        return Proj(haversine(point, LatLon(lat, lon)), along, lon, lat)
    }

    private fun haversine(a: LatLon, b: LatLon): Double {
        val r = 6371000.0
        val dLat = Math.toRadians(b.lat - a.lat)
        val dLon = Math.toRadians(b.lon - a.lon)
        val lat1 = Math.toRadians(a.lat)
        val lat2 = Math.toRadians(b.lat)
        val x = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(x), sqrt(1 - x))
    }

    private fun bearing(a: LatLon, b: LatLon): Double {
        val lat1 = Math.toRadians(a.lat)
        val lat2 = Math.toRadians(b.lat)
        val dLon = Math.toRadians(b.lon - a.lon)
        val y = sin(dLon) * cos(lat2)
        val x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (Math.toDegrees(atan2(y, x)) + 360) % 360
    }

    private fun angleDiff(a: Double, b: Double): Double {
        var d = abs(a - b) % 360
        if (d > 180) d = 360 - d
        return d
    }
}
