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
    data class Restriction(
        val fromEdge: Int,
        val toEdge: Int,
        val viaNode: Int,
        val only: Boolean,
        val vehicleMask: Int,
        val viaEdges: List<Int>
    )

    private data class TurnKey(val viaNode: Int, val fromEdge: Int)

    private data class RestrictionIndex(
        val blockedNodeTurns: Map<TurnKey, Set<Int>>,
        val onlyNodeTurns: Map<TurnKey, Set<Int>>,
        val blockedViaWayExits: Map<Int, Set<Int>>,
        val onlyViaWayEntries: Map<Int, Set<Int>>
    )

    private val restrictionIndex = compileRestrictionIndex(restrictions)

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
        if (restrictionIndex.blockedViaWayExits[fromEdge]?.contains(toEdge) == true) return false
        val onlyVia = restrictionIndex.onlyViaWayEntries[fromEdge]
        if (onlyVia != null && !onlyVia.contains(toEdge)) return false
        return true
    }

    fun hopIllegal(ei: Int, from: Int, to: Int, startEi: Int, endEi: Int, incomingEi: Int): Boolean {
        val code = accessCode(ei, from, to)
        if (code == 2 || code == 5) return true
        if ((code == 3 || code == 4) && ei != startEi && ei != endEi) return true
        if (incomingEi < 0 || restrictions.isEmpty()) return false
        return !turnAllowed(fromEdge = incomingEi, toEdge = ei, viaNode = from)
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
            val blockedVia = HashMap<Int, MutableSet<Int>>()
            val onlyVia = HashMap<Int, MutableSet<Int>>()
            for (restriction in restrictions) {
                if (restriction.vehicleMask and 1 == 0) continue
                if (restriction.viaEdges.isNotEmpty()) {
                    val first = restriction.viaEdges.first()
                    val last = restriction.viaEdges.last()
                    if (restriction.only) {
                        onlyVia.getOrPut(restriction.fromEdge) { HashSet() }.add(first)
                    } else {
                        blockedVia.getOrPut(last) { HashSet() }.add(restriction.toEdge)
                    }
                    continue
                }
                val key = TurnKey(restriction.viaNode, restriction.fromEdge)
                val target = if (restriction.only) onlyNode else blockedNode
                target.getOrPut(key) { HashSet() }.add(restriction.toEdge)
            }
            return RestrictionIndex(blockedNode, onlyNode, blockedVia, onlyVia)
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
