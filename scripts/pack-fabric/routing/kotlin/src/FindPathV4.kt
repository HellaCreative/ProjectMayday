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
        zoom: Double? = null,
        startEndpointKind: String? = null,
        endEndpointKind: String? = null
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
        data class State(
            val node: Int,
            val incomingEdge: Int,
            val restrictionActive: List<GraphV4Pack.RestrictionProgress>,
            val cost: Double,
            val pathEdges: List<Int>
        )
        val dist = HashMap<String, Double>()
        val heap = ArrayList<State>()
        fun activeKey(active: List<GraphV4Pack.RestrictionProgress>) = active.joinToString("|") {
            "${it.restrictionId}:${it.progress}"
        }
        fun key(node: Int, incoming: Int, active: List<GraphV4Pack.RestrictionProgress>) =
            "$node:$incoming:${activeKey(active)}"
        fun push(
            node: Int,
            incomingEdge: Int,
            restrictionActive: List<GraphV4Pack.RestrictionProgress>,
            cost: Double,
            pathEdges: List<Int>
        ) {
            val k = key(node, incomingEdge, restrictionActive)
            val old = dist[k]
            if (old != null && old <= cost) return
            dist[k] = cost
            heap.add(State(node, incomingEdge, restrictionActive, cost, pathEdges))
        }

        for (snap in startSnaps) {
            val from = if (snap.forward) pack.edgeFrom[snap.edgeIndex] else pack.edgeTo[snap.edgeIndex]
            val to = if (snap.forward) pack.edgeTo[snap.edgeIndex] else pack.edgeFrom[snap.edgeIndex]
            val remain = if (snap.forward) {
                (1 - snap.fraction) * pack.edgeMeters[snap.edgeIndex]
            } else {
                snap.fraction * pack.edgeMeters[snap.edgeIndex]
            }
            val isDest = destEdges.contains(snap.edgeIndex)
            val endpointKind = if (isDest) endEndpointKind else startEndpointKind
            if (!pack.accessAllowed(
                    snap.edgeIndex,
                    from,
                    to,
                    allowUnknown,
                    isEndpoint = true,
                    endpointKind = endpointKind
                )
            ) continue
            push(to, snap.edgeIndex, emptyList(), maxOf(1.0, remain), listOf(snap.edgeIndex))
            if (isDest) {
                return PathV4Result(
                    ok = true,
                    distanceMeters = maxOf(1.0, remain),
                    edgeIndexes = listOf(snap.edgeIndex),
                    osmWayIds = listOf(pack.osmWayIds[snap.edgeIndex])
                )
            }
        }

        while (heap.isNotEmpty()) {
            heap.sortBy { it.cost }
            val cur = heap.removeAt(0)
            val k = key(cur.node, cur.incomingEdge, cur.restrictionActive)
            if (dist[k] != cur.cost) continue
            if (cur.cost > 1e9) break
            val start = pack.nodeOffsets[cur.node]
            val end = pack.nodeOffsets[cur.node + 1]
            for (i in start until end) {
                val to = pack.edgeTargets[i]
                val ei = pack.edgeUndirectedIndex[i]
                if (ei == cur.incomingEdge) continue
                val isDest = destEdges.contains(ei)
                if (!pack.accessAllowed(
                        ei,
                        cur.node,
                        to,
                        allowUnknown,
                        isEndpoint = isDest,
                        endpointKind = if (isDest) endEndpointKind else null
                    )
                ) continue
                val restriction = pack.advanceRestrictionState(
                    cur.restrictionActive,
                    cur.incomingEdge,
                    ei,
                    cur.node
                )
                if (!restriction.allowed) continue
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
                push(to, ei, restriction.active, nextCost, pathEdges)
            }
        }
        return PathV4Result(ok = false, reason = "no_route")
    }
}
