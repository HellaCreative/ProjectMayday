package dirt.routing.v4

data class LatLon(val lat: Double, val lon: Double)

data class PathV4Result(
    val ok: Boolean,
    val distanceMeters: Double = 0.0,
    val edgeIndexes: List<Int> = emptyList(),
    val osmWayIds: List<Long> = emptyList(),
    val reason: String? = null
)

object FindPathV4 {
    fun findPath(
        pack: GraphV4Pack,
        origin: LatLon,
        dest: LatLon,
        startHeadingDeg: Double? = null,
        intentBearingDeg: Double? = null,
        allowUnknown: Boolean = false,
        maxMeters: Double? = null,
        zoom: Double? = null
    ): PathV4Result {
        val startDetailed = LegalSnap.legalSnapDetailed(
            pack,
            origin,
            startHeadingDeg,
            intentBearingDeg,
            maxMeters,
            zoom,
            allowUnknown
        )
        val endIntent = intentBearingDeg?.let { (it + 180) % 360 }
        val endDetailed = LegalSnap.legalSnapDetailed(
            pack,
            dest,
            null,
            endIntent,
            maxMeters,
            zoom,
            allowUnknown
        )
        val picked = LegalSnap.selectConnectedSnapPair(
            pack,
            startDetailed.candidates,
            endDetailed.candidates,
            allowUnknown
        )
        if (!picked.ok || picked.start == null || picked.end == null) {
            return PathV4Result(ok = false, reason = picked.reason ?: "no_snap")
        }
        val startSnaps = listOf(picked.start)
        val endSnaps = listOf(picked.end)
        val destEdges = endSnaps.map { it.edgeIndex }.toSet()
        data class State(val node: Int, val incomingEdge: Int, val cost: Double, val pathEdges: List<Int>)
        val dist = HashMap<String, Double>()
        val heap = ArrayList<State>()
        fun key(node: Int, incoming: Int) = "$node:$incoming"
        fun push(node: Int, incomingEdge: Int, cost: Double, pathEdges: List<Int>) {
            val k = key(node, incomingEdge)
            val old = dist[k]
            if (old != null && old <= cost) return
            dist[k] = cost
            heap.add(State(node, incomingEdge, cost, pathEdges))
        }

        for (snap in startSnaps) {
            val from = if (snap.forward) pack.edgeFrom[snap.edgeIndex] else pack.edgeTo[snap.edgeIndex]
            val to = if (snap.forward) pack.edgeTo[snap.edgeIndex] else pack.edgeFrom[snap.edgeIndex]
            val remain = if (snap.forward) {
                (1 - snap.fraction) * pack.edgeMeters[snap.edgeIndex]
            } else {
                snap.fraction * pack.edgeMeters[snap.edgeIndex]
            }
            val code = pack.accessCode(snap.edgeIndex, from, to)
            val isDest = destEdges.contains(snap.edgeIndex)
            if (code != 0 && !(code == 3 || code == 4) && code != 1) {
                if (code == 2 || code == 5) continue
            }
            if (code == 2 || code == 5) continue
            if ((code == 3 || code == 4) && !isDest) continue
            push(to, snap.edgeIndex, maxOf(1.0, remain.toDouble()), listOf(snap.edgeIndex))
            if (isDest) {
                return PathV4Result(
                    ok = true,
                    distanceMeters = maxOf(1.0, remain.toDouble()),
                    edgeIndexes = listOf(snap.edgeIndex),
                    osmWayIds = listOf(pack.osmWayIds[snap.edgeIndex])
                )
            }
        }

        while (heap.isNotEmpty()) {
            heap.sortBy { it.cost }
            val cur = heap.removeAt(0)
            val k = key(cur.node, cur.incomingEdge)
            if (dist[k] != cur.cost) continue
            if (cur.cost > 1e9) break
            val start = pack.nodeOffsets[cur.node]
            val end = pack.nodeOffsets[cur.node + 1]
            for (i in start until end) {
                val to = pack.edgeTargets[i]
                val ei = pack.edgeUndirectedIndex[i]
                if (ei == cur.incomingEdge) continue
                val code = pack.accessCode(ei, cur.node, to)
                val isDest = destEdges.contains(ei)
                if (pack.hopIllegal(
                        ei,
                        cur.node,
                        to,
                        startEi = cur.pathEdges.firstOrNull() ?: -1,
                        endEi = if (isDest) ei else -1,
                        incomingEi = cur.incomingEdge
                    )
                ) {
                    continue
                }
                if (code == 1 && !allowUnknown) continue
                val nextCost = cur.cost + pack.edgeMeters[ei]
                val pathEdges = cur.pathEdges + ei
                if (isDest) {
                    return PathV4Result(
                        ok = true,
                        distanceMeters = nextCost,
                        edgeIndexes = pathEdges,
                        osmWayIds = pathEdges.map { pack.osmWayIds[it] }
                    )
                }
                push(to, ei, nextCost, pathEdges)
            }
        }
        return PathV4Result(ok = false, reason = "no_route")
    }
}
