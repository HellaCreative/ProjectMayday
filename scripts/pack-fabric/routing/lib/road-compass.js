"use strict";

// Exact distance-to-destination on the caller's legal turn-state graph.
// The caller includes legal partial endpoint arcs and retains incoming turn
// state. Coordinates never participate in the distance proof.
// Lockstep: Dirt/Routing/OnDevice/RoadCompass.swift.
function buildRoadCompass({stateCount, destination, outgoing, deadlineAtMs = Infinity,
  cancelled = () => false}) {
  const expired = () => cancelled() || Date.now() >= deadlineAtMs;
  const interrupted = () => ({status: cancelled() ? "cancelled" : "timeCap"});
  if (expired()) return interrupted();
  const offsets = new Uint32Array(stateCount + 1);
  for (let state = 0; state < stateCount; state++) {
    if ((state & 255) === 0 && expired()) return interrupted();
    outgoing(state, (to, edge, meters) => {
      if (to >= 0 && to < stateCount && Number.isFinite(meters) && meters >= 0) offsets[to + 1]++;
    });
  }
  for (let state = 0; state < stateCount; state++) offsets[state + 1] += offsets[state];
  const sources = new Int32Array(offsets[stateCount]);
  const edges = new Int32Array(sources.length);
  const lengths = new Float64Array(sources.length);
  const cursors = offsets.slice();
  for (let state = 0; state < stateCount; state++) {
    if ((state & 255) === 0 && expired()) return interrupted();
    outgoing(state, (to, edge, meters) => {
      if (to < 0 || to >= stateCount || !Number.isFinite(meters) || meters < 0) return;
      const index = cursors[to]++;
      sources[index] = state; edges[index] = edge; lengths[index] = meters;
    });
  }
  const remaining = new Float64Array(stateCount).fill(Infinity);
  const nextState = new Int32Array(stateCount).fill(-1);
  const nextEdge = new Int32Array(stateCount).fill(-1);
  const heap = [];
  const less = (a,b) => a.meters < b.meters || (a.meters === b.meters && a.state < b.state);
  function push(item) {
    let index = heap.length; heap.push(item);
    while (index > 0) {
      const parent = (index - 1) >> 1;
      if (!less(item, heap[parent])) break;
      heap[index] = heap[parent]; index = parent;
    }
    heap[index] = item;
  }
  function pop() {
    const first = heap[0], last = heap.pop();
    if (heap.length) {
      let index = 0;
      while (index * 2 + 1 < heap.length) {
        let child = index * 2 + 1;
        if (child + 1 < heap.length && less(heap[child + 1], heap[child])) child++;
        if (!less(heap[child], last)) break;
        heap[index] = heap[child]; index = child;
      }
      heap[index] = last;
    }
    return first;
  }
  remaining[destination] = 0;
  push({state:destination, meters:0});
  let pops = 0;
  while (heap.length) {
    if ((pops++ & 255) === 0 && expired()) return interrupted();
    const current = pop();
    if (current.meters !== remaining[current.state]) continue;
    for (let arc = offsets[current.state]; arc < offsets[current.state + 1]; arc++) {
      const from = sources[arc], candidate = current.meters + lengths[arc];
      if (candidate >= remaining[from]) continue;
      remaining[from] = candidate;
      nextState[from] = current.state; nextEdge[from] = edges[arc];
      push({state:from, meters:candidate});
    }
  }
  return {status:"complete", remaining, nextState, nextEdge, pops};
}
module.exports = {buildRoadCompass};
