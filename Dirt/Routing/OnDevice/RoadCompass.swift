import Foundation

/// Exact reverse distances on legal turn states, including partial endpoint
/// arcs. Lockstep: routing/lib/road-compass.js. No geometric projection.
nonisolated enum RoadCompass {
    struct Result {
        let status: String
        var remaining: [Double] = []
        var nextState: [Int32] = []
        var nextEdge: [Int32] = []
        var pops: Int = 0
    }
    struct Arc {
        let to: Int
        let edge: Int
        let meters: Double
    }
    static func build(stateCount: Int, destination: Int,
                      reverse: Bool = true,
                      recordSuccessors: Bool = true,
                      streamForward: Bool = true,
                      maximumOutgoingArcs: Int = 65_536,
                      deadline: Date = .distantFuture,
                      cancelled: @escaping () -> Bool = { false },
                      outgoing: (Int, (Arc) -> Void) -> Void) -> Result {
        func expired() -> Bool { cancelled() || Date() >= deadline }
        func interrupted() -> Result { Result(status: cancelled() ? "cancelled" : "timeCap") }
        if expired() { return interrupted() }
        if !reverse && streamForward {
            return buildForward(stateCount: stateCount, destination: destination,
                recordSuccessors: recordSuccessors, maximumOutgoingArcs: maximumOutgoingArcs,
                deadline: deadline, cancelled: cancelled, outgoing: outgoing)
        }
        var offsets = [Int](repeating: 0, count: stateCount + 1)
        for state in 0..<stateCount {
            if state & 255 == 0, expired() { return interrupted() }
            outgoing(state) { arc in
                if arc.to >= 0, arc.to < stateCount, arc.meters.isFinite, arc.meters >= 0 { offsets[(reverse ? arc.to : state) + 1] += 1 }
            }
        }
        for state in 0..<stateCount { offsets[state + 1] += offsets[state] }
        var sources = [Int32](repeating: 0, count: offsets[stateCount])
        // Distances-only callers never consume arc IDs; keep them out of
        // the full-region transpose allocation entirely.
        var edges = [Int32](repeating: 0, count: recordSuccessors ? sources.count : 0)
        var lengths = [Double](repeating: 0, count: sources.count)
        var cursors = offsets
        for state in 0..<stateCount {
            if state & 255 == 0, expired() { return interrupted() }
            outgoing(state) { arc in
                guard arc.to >= 0, arc.to < stateCount, arc.meters.isFinite, arc.meters >= 0 else { return }
                let bucket = reverse ? arc.to : state
                let index = cursors[bucket]
                cursors[bucket] += 1
                sources[index] = Int32(reverse ? state : arc.to)
                if recordSuccessors { edges[index] = Int32(arc.edge) }
                lengths[index] = arc.meters
            }
        }
        var remaining = [Double](repeating: .infinity, count: stateCount)
        var nextState = [Int32](repeating: -1, count: recordSuccessors ? stateCount : 0)
        var nextEdge = [Int32](repeating: -1, count: recordSuccessors ? stateCount : 0)
        var heap: [(state: Int, meters: Double)] = []
        func less(_ a: (state: Int, meters: Double), _ b: (state: Int, meters: Double)) -> Bool {
            a.meters < b.meters || (a.meters == b.meters && a.state < b.state)
        }
        func push(_ item: (state: Int, meters: Double)) {
            var index = heap.count
            heap.append(item)
            while index > 0 {
                let parent = (index - 1) / 2
                if !less(item, heap[parent]) { break }
                heap[index] = heap[parent]; index = parent
            }
            heap[index] = item
        }
        func pop() -> (state: Int, meters: Double) {
            let first = heap[0], last = heap.removeLast()
            if !heap.isEmpty {
                var index = 0
                while index * 2 + 1 < heap.count {
                    var child = index * 2 + 1
                    if child + 1 < heap.count, less(heap[child + 1], heap[child]) { child += 1 }
                    if !less(heap[child], last) { break }
                    heap[index] = heap[child]; index = child
                }
                heap[index] = last
            }
            return first
        }
        remaining[destination] = 0
        push((destination, 0))
        var pops = 0
        while !heap.isEmpty {
            if pops & 255 == 0, expired() { return interrupted() }
            pops += 1
            let current = pop()
            if current.meters != remaining[current.state] { continue }
            for arc in offsets[current.state]..<offsets[current.state + 1] {
                let from = Int(sources[arc]), candidate = current.meters + lengths[arc]
                if candidate >= remaining[from] { continue }
                remaining[from] = candidate
                if recordSuccessors {
                    nextState[from] = Int32(current.state); nextEdge[from] = edges[arc]
                }
                push((from, candidate))
            }
        }
        return Result(status: "complete", remaining: remaining, nextState: nextState, nextEdge: nextEdge, pops: pops)
    }

    /// Forward traversal needs no transpose. The reusable bounded scratch holds
    /// one node's outgoing arcs so labels and heap are never captured/mutated by
    /// the producer callback. Source topology/order, IDs and duplicate arcs stay
    /// unchanged. Only reached nodes are enumerated; this does not certify an
    /// entire file, replace source validation, or bound the remaining/heap arrays.
    private static func buildForward(stateCount: Int, destination: Int,
        recordSuccessors: Bool, maximumOutgoingArcs: Int, deadline: Date,
        cancelled: @escaping () -> Bool, outgoing: (Int, (Arc) -> Void) -> Void) -> Result {
        func expired() -> Bool { cancelled() || Date() >= deadline }
        func interrupted() -> Result { Result(status: cancelled() ? "cancelled" : "timeCap") }
        guard stateCount > 0, destination >= 0, destination < stateCount,
              maximumOutgoingArcs > 0, maximumOutgoingArcs <= 65_536 else {
            return Result(status: "resourceLimit")
        }
        // At most 1.5 MiB at the default (24-byte Arc stride on 64-bit).
        // Fixed allocation avoids geometric Array growth beyond the row cap.
        var scratch = [Arc](repeating: .init(to: 0, edge: 0, meters: 0), count: maximumOutgoingArcs)
        var remaining = [Double](repeating: .infinity, count: stateCount)
        var nextState = [Int32](repeating: -1, count: recordSuccessors ? stateCount : 0)
        var nextEdge = [Int32](repeating: -1, count: recordSuccessors ? stateCount : 0)
        var heap: [(state: Int, meters: Double)] = []
        func less(_ a: (state: Int, meters: Double), _ b: (state: Int, meters: Double)) -> Bool {
            a.meters < b.meters || (a.meters == b.meters && a.state < b.state)
        }
        func push(_ item: (state: Int, meters: Double)) {
            var index = heap.count
            heap.append(item)
            while index > 0 {
                let parent = (index - 1) / 2
                if !less(item, heap[parent]) { break }
                heap[index] = heap[parent]; index = parent
            }
            heap[index] = item
        }
        func pop() -> (state: Int, meters: Double) {
            let first = heap[0], last = heap.removeLast()
            if !heap.isEmpty {
                var index = 0
                while index * 2 + 1 < heap.count {
                    var child = index * 2 + 1
                    if child + 1 < heap.count, less(heap[child + 1], heap[child]) { child += 1 }
                    if !less(heap[child], last) { break }
                    heap[index] = heap[child]; index = child
                }
                heap[index] = last
            }
            return first
        }
        remaining[destination] = 0
        push((destination, 0))
        var pops = 0
        while !heap.isEmpty {
            if pops & 255 == 0, expired() { return interrupted() }
            pops += 1
            let current = pop()
            if current.meters != remaining[current.state] { continue }
            var count = 0
            var emitted = 0
            var limited = false
            var stopped = false
            outgoing(current.state) { arc in
                if limited || stopped { return }
                if emitted & 255 == 0, expired() { stopped = true; return }
                emitted += 1
                guard arc.to >= 0, arc.to < stateCount, arc.meters.isFinite, arc.meters >= 0 else { return }
                guard count < scratch.count else { limited = true; return }
                scratch[count] = arc
                count += 1
            }
            if stopped || expired() { return interrupted() }
            if limited { return Result(status: "resourceLimit") }
            for index in 0..<count {
                let arc = scratch[index]
                let from = arc.to, candidate = current.meters + arc.meters
                if candidate >= remaining[from] { continue }
                remaining[from] = candidate
                if recordSuccessors {
                    nextState[from] = Int32(current.state); nextEdge[from] = Int32(arc.edge)
                }
                push((from, candidate))
            }
        }
        return Result(status: "complete", remaining: remaining, nextState: nextState, nextEdge: nextEdge, pops: pops)
    }
}
