package dirt.routing.v4

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

class GraphV4Pack private constructor(
    val version: Int,
    val nodeCount: Int,
    val undirectedEdgeCount: Int,
    val directedArcCount: Int,
    val capabilities: List<String>,
    val regionId: String,
    val sourceEpoch: String,
    val osmNodeIds: List<Long>,
    val osmWayIds: List<Long>,
    val nodeOffsets: IntArray,
    val edgeTargets: IntArray,
    val edgeUndirectedIndex: IntArray,
    val edgeFrom: IntArray,
    val edgeTo: IntArray,
    val edgeMeters: IntArray,
    val nodeCoords: FloatArray,
    val edgeAccess: ByteArray,
    val restrictions: List<Restriction>
) {
    data class SeamAnchor(
        val longitude: Double,
        val latitude: Double,
        val osmWayId: String,
        val localEdgeId: String,
        val remoteEdgeId: String,
        val gapMeters: Double
    )

    data class SeamSidecar(
        val schemaVersion: String,
        val fabricReleaseId: String,
        val sourceEpoch: String,
        val regionId: String,
        val neighbors: Map<String, List<SeamAnchor>>
    )

    var crossPackSeams: Map<String, List<SeamAnchor>> = emptyMap()
        private set

    data class Restriction(
        val fromEdge: Int,
        val toEdge: Int,
        val viaNode: Int,
        val only: Boolean,
        val vehicleMask: Int,
        val viaEdges: List<Int>
    )

    data class RestrictionProgress(val restrictionId: Int, val progress: Int)

    data class TurnAdvance(
        val allowed: Boolean,
        val active: List<RestrictionProgress> = emptyList()
    )

    private data class TurnKey(val viaNode: Int, val fromEdge: Int)

    private data class ViaPattern(
        val fromEdge: Int,
        val toEdge: Int,
        val viaEdges: List<Int>,
        val entryNode: Int,
        val only: Boolean
    )

    private data class RestrictionIndex(
        val blockedNodeTurns: Map<TurnKey, Set<Int>>,
        val onlyNodeTurns: Map<TurnKey, Set<Int>>,
        val viaPatterns: List<ViaPattern>,
        val viaStarters: Map<Int, List<Int>>
    )

    private val restrictionIndex = compileRestrictionIndex(restrictions)

    fun applyCrossPackSeams(sidecar: SeamSidecar) {
        if (sidecar.schemaVersion != "dirt-cross-pack-seams.v2" ||
            sidecar.fabricReleaseId.isBlank() ||
            sidecar.regionId.lowercase() != regionId.lowercase() ||
            sidecar.sourceEpoch != sourceEpoch
        ) {
            throw IllegalArgumentException("seam sidecar does not match graph identity")
        }
        for ((neighbor, anchors) in sidecar.neighbors) {
            if (!Regex("^[a-z]{2}$").matches(neighbor.lowercase())) {
                throw IllegalArgumentException("invalid seam neighbor")
            }
            for (anchor in anchors) {
                if (anchor.gapMeters < 0 || anchor.gapMeters > 2 ||
                    anchor.osmWayId.isBlank() || anchor.localEdgeId.isBlank() ||
                    anchor.remoteEdgeId.isBlank()
                ) throw IllegalArgumentException("invalid seam proof")
            }
        }
        crossPackSeams = sidecar.neighbors.mapKeys { it.key.lowercase() }
    }

    fun hasDirectedArc(from: Int, to: Int, edge: Int): Boolean {
        if (from < 0 || from >= nodeCount || edge < 0) return false
        val start = nodeOffsets[from]
        val end = nodeOffsets[from + 1]
        for (i in start until end) {
            if (edgeTargets[i] == to && edgeUndirectedIndex[i] == edge) return true
        }
        return false
    }

    fun accessCode(ei: Int, from: Int, to: Int): Int {
        if (ei < 0 || ei * 2 + 1 >= edgeAccess.size) return 0
        val forward = edgeFrom[ei] == from && edgeTo[ei] == to
        return edgeAccess[ei * 2 + if (forward) 0 else 1].toInt() and 0xff
    }

    fun turnAllowed(fromEdge: Int, toEdge: Int, viaNode: Int): Boolean {
        val key = TurnKey(viaNode, fromEdge)
        val only = restrictionIndex.onlyNodeTurns[key]
        if (only != null && !only.contains(toEdge)) return false
        if (restrictionIndex.blockedNodeTurns[key]?.contains(toEdge) == true) return false
        return true
    }

    fun accessAllowed(
        ei: Int,
        from: Int,
        to: Int,
        allowUnknown: Boolean,
        isEndpoint: Boolean,
        endpointKind: String? = null
    ): Boolean {
        val code = accessCode(ei, from, to)
        return when (code) {
            0 -> true
            1 -> allowUnknown
            3 -> isEndpoint && endpointKind != "customers"
            4 -> isEndpoint && endpointKind == "customers"
            else -> false
        }
    }

    /**
     * Advance the exact ordered via-way state for one turn. A via-way rule is
     * active only after its own from-edge and complete ordered via sequence;
     * arriving at the final via edge from another road remains legal.
     */
    fun advanceRestrictionState(
        active: List<RestrictionProgress>,
        fromEdge: Int,
        toEdge: Int,
        viaNode: Int
    ): TurnAdvance {
        if (!turnAllowed(fromEdge, toEdge, viaNode)) return TurnAdvance(false)

        val patterns = restrictionIndex.viaPatterns
        val current = active.filter { it.restrictionId in patterns.indices }
        val activeOnly = current.filter { patterns[it.restrictionId].only }
        if (activeOnly.isNotEmpty() && activeOnly.none { row ->
                val pattern = patterns[row.restrictionId]
                val sequence = listOf(pattern.fromEdge) + pattern.viaEdges + pattern.toEdge
                row.progress + 1 < sequence.size && sequence[row.progress + 1] == toEdge
            }
        ) {
            return TurnAdvance(false)
        }

        val next = ArrayList<RestrictionProgress>()
        for (row in current) {
            val pattern = patterns[row.restrictionId]
            val sequence = listOf(pattern.fromEdge) + pattern.viaEdges + pattern.toEdge
            if (row.progress + 1 >= sequence.size || sequence[row.progress + 1] != toEdge) continue
            val completes = row.progress + 1 == sequence.lastIndex
            if (completes) {
                if (!pattern.only) return TurnAdvance(false)
            } else {
                next.add(RestrictionProgress(row.restrictionId, row.progress + 1))
            }
        }

        val starters = restrictionIndex.viaStarters[fromEdge].orEmpty().filter { id ->
            val entry = patterns[id].entryNode
            entry < 0 || entry == viaNode
        }
        val starterOnly = starters.filter { patterns[it].only }
        if (starterOnly.isNotEmpty() && starterOnly.none { patterns[it].viaEdges.firstOrNull() == toEdge }) {
            return TurnAdvance(false)
        }
        for (id in starters) {
            if (patterns[id].viaEdges.firstOrNull() == toEdge) {
                next.add(RestrictionProgress(id, 1))
            }
        }
        return TurnAdvance(
            true,
            next.distinct().sortedWith(compareBy({ it.restrictionId }, { it.progress }))
        )
    }

    companion object {
        const val MAGIC = 0x34545244
        const val VERSION = 4
        const val HEADER = 140
        const val FLAG_LEGAL = 8
        const val CAPABILITY = "legal-topology.v1"

        private fun compileRestrictionIndex(restrictions: List<Restriction>): RestrictionIndex {
            val blockedNode = HashMap<TurnKey, MutableSet<Int>>()
            val onlyNode = HashMap<TurnKey, MutableSet<Int>>()
            val viaPatterns = ArrayList<ViaPattern>()
            val viaStarters = HashMap<Int, MutableList<Int>>()
            for (restriction in restrictions) {
                if (restriction.vehicleMask and 1 == 0) continue
                if (restriction.viaEdges.isNotEmpty()) {
                    val id = viaPatterns.size
                    viaPatterns.add(
                        ViaPattern(
                            restriction.fromEdge,
                            restriction.toEdge,
                            restriction.viaEdges,
                            restriction.viaNode,
                            restriction.only
                        )
                    )
                    viaStarters.getOrPut(restriction.fromEdge) { ArrayList() }.add(id)
                    continue
                }
                val key = TurnKey(restriction.viaNode, restriction.fromEdge)
                val target = if (restriction.only) onlyNode else blockedNode
                target.getOrPut(key) { HashSet() }.add(restriction.toEdge)
            }
            return RestrictionIndex(blockedNode, onlyNode, viaPatterns, viaStarters)
        }

        fun decode(graph: ByteArray, geometry: ByteArray? = null): GraphV4Pack {
            if (graph.size < HEADER) throw IllegalArgumentException("truncated")
            val buf = ByteBuffer.wrap(graph).order(ByteOrder.LITTLE_ENDIAN)
            if (buf.int != MAGIC) throw IllegalArgumentException("unsupported graph version")
            val ver = buf.short.toInt() and 0xffff
            if (ver != VERSION) throw IllegalArgumentException("unsupported graph version")
            val flags = buf.short.toInt() and 0xffff
            if (flags and FLAG_LEGAL == 0) {
                throw IllegalArgumentException("missing required capability legal-topology.v1")
            }
            buf.position(20)
            if (buf.int < HEADER) {
                throw IllegalArgumentException("missing or corrupt restriction, barrier, or access sections")
            }
            buf.position(8)
            val nodeCount = buf.int
            val edgeCount = buf.int
            val arcCount = buf.int
            for (off in intArrayOf(104, 108, 112, 116, 120, 124, 128, 132, 136)) {
                buf.position(off)
                if (buf.int == 0) {
                    throw IllegalArgumentException("missing or corrupt restriction, barrier, or access sections")
                }
            }
            buf.position(132)
            val capAt = buf.int
            buf.position(136)
            val shaAt = buf.int
            val capsJson = String(graph.copyOfRange(capAt, shaAt), Charsets.UTF_8)
            if (!capsJson.contains(CAPABILITY)) {
                throw IllegalArgumentException("missing required capability legal-topology.v1")
            }
            if (geometry != null) {
                val digest = MessageDigest.getInstance("SHA-256").digest(geometry)
                val expected = graph.copyOfRange(shaAt, shaAt + 32)
                if (!digest.contentEquals(expected)) {
                    throw IllegalArgumentException("graph/geometry identity mismatch")
                }
            }
            buf.position(128)
            val provenanceAt = buf.int
            if (provenanceAt >= capAt) throw IllegalArgumentException("invalid V4 provenance")
            val provenanceJson = String(graph.copyOfRange(provenanceAt, capAt), Charsets.UTF_8)
            fun requiredJsonString(key: String): String {
                val match = Regex("\\\"" + Regex.escape(key) + "\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"")
                    .find(provenanceJson)
                return match?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
                    ?: throw IllegalArgumentException("missing V4 provenance $key")
            }
            val regionId = requiredJsonString("regionId")
            val sourceEpoch = requiredJsonString("sourceEpoch")

            fun ints(offsetField: Int, count: Int): IntArray {
                buf.position(offsetField)
                val at = buf.int
                val view = ByteBuffer.wrap(graph, at, count * 4).order(ByteOrder.LITTLE_ENDIAN)
                return IntArray(count) { view.int }
            }

            val nodeOffsets = ints(24, nodeCount + 1)
            val edgeTargets = ints(28, arcCount)
            val edgeUndirectedIndex = ints(32, arcCount)
            val edgeFrom = ints(64, edgeCount)
            val edgeTo = ints(68, edgeCount)
            val edgeMeters = ints(40, edgeCount)
            buf.position(44)
            val coordAt = buf.int
            val coordBuf = ByteBuffer.wrap(graph, coordAt, nodeCount * 8).order(ByteOrder.LITTLE_ENDIAN)
            val nodeCoords = FloatArray(nodeCount * 2) { coordBuf.float }

            buf.position(112)
            val accessAt = buf.int
            val edgeAccess = graph.copyOfRange(accessAt, accessAt + edgeCount * 2)

            buf.position(104)
            val nodeAt = buf.int
            val nbuf = ByteBuffer.wrap(graph, nodeAt, nodeCount * 8).order(ByteOrder.LITTLE_ENDIAN)
            val osmNodeIds = List(nodeCount) { nbuf.long }

            buf.position(108)
            val wayAt = buf.int
            val wbuf = ByteBuffer.wrap(graph, wayAt, edgeCount * 8).order(ByteOrder.LITTLE_ENDIAN)
            val osmWayIds = List(edgeCount) { wbuf.long }

            buf.position(120)
            val restAt = buf.int
            val restBuf = ByteBuffer.wrap(graph).order(ByteOrder.LITTLE_ENDIAN)
            restBuf.position(restAt)
            val restCount = restBuf.int
            val restrictions = ArrayList<Restriction>(restCount)
            var cursor = restAt + 4
            repeat(restCount) {
                restBuf.position(cursor + 10)
                val viaWayCount = restBuf.short.toInt() and 0xffff
                restBuf.position(cursor + 8)
                val kindFlags = graph[cursor + 9].toInt() and 0xff
                restBuf.position(cursor + 12)
                val fromEdge = restBuf.int
                val toEdge = restBuf.int
                val viaNode = restBuf.int
                restBuf.position(cursor + 26)
                val vehicleMask = restBuf.short.toInt() and 0xffff
                val viaEdges = ArrayList<Int>()
                for (v in 0 until viaWayCount) {
                    restBuf.position(cursor + 32 + v * 12 + 8)
                    val edge = restBuf.int
                    if (edge >= 0) viaEdges.add(edge)
                }
                restrictions.add(
                    Restriction(
                        fromEdge = fromEdge,
                        toEdge = toEdge,
                        viaNode = viaNode,
                        only = kindFlags and 2 != 0,
                        vehicleMask = vehicleMask,
                        viaEdges = viaEdges
                    )
                )
                cursor += 32 + viaWayCount * 12
            }

            return GraphV4Pack(
                ver,
                nodeCount,
                edgeCount,
                arcCount,
                listOf(CAPABILITY),
                regionId,
                sourceEpoch,
                osmNodeIds,
                osmWayIds,
                nodeOffsets,
                edgeTargets,
                edgeUndirectedIndex,
                edgeFrom,
                edgeTo,
                edgeMeters,
                nodeCoords,
                edgeAccess,
                restrictions
            )
        }

        fun rejectMixedContract(epochs: List<String>) {
            if (epochs.toSet().size > 1) throw IllegalArgumentException("mixed-contract cross-region routing")
        }
    }
}
