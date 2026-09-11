"""Small asserted extension of pinned GraphHopper AStar; upstream stays unchanged."""
def extend(source):
 def replace(old,new):
  nonlocal source
  if source.count(old)!=1:raise RuntimeError('Pinned AStar extension anchor changed: '+old)
  source=source.replace(old,new)
 replace('public class AStar extends','public class DirtMultiEndpointAStar extends')
 replace('public AStar(Graph','public DirtMultiEndpointAStar(Graph')
 replace('public AStar setApproximation','public DirtMultiEndpointAStar setApproximation')
 replace('private int to = -1;','private int to = -1;\n    private java.util.Set<Integer> targets;')
 replace('return currEdge.adjNode == to &&','return (targets == null ? currEdge.adjNode == to : targets.contains(currEdge.adjNode)) &&')
 method='''    // Same edge-state relaxation and path extraction as upstream AStar.
    // Seed all legal departure states and stop at the first optimal arrival.
    public Path calcPaths(java.util.List<Integer> sources,
                          java.util.Map<Integer, WeightApproximator> destinationBounds) {
        if (!traversalMode.isEdgeBased() || sources.isEmpty() || destinationBounds.isEmpty())
            throw new IllegalArgumentException("Nonempty edge-based endpoints required");
        checkAlreadyRun();
        setupFinishTime();
        fromOutEdge = ANY_EDGE;
        toInEdge = ANY_EDGE;
        targets = java.util.Set.copyOf(destinationBounds.keySet());
        destinationBounds.forEach((node, bound) -> bound.setTo(node));
        var bounds = java.util.List.copyOf(destinationBounds.values());
        setApproximation(new WeightApproximator() {
            public double approximate(int node) {
                double best = Double.POSITIVE_INFINITY;
                for (var bound : bounds) best = Math.min(best, bound.approximate(node));
                return best;
            }
            public void setTo(int ignored) { throw new UnsupportedOperationException("Targets already bound"); }
            public WeightApproximator reverse() { throw new UnsupportedOperationException("Forward multi-endpoint search"); }
            public double getSlack() {
                double slack = 0;
                for (var bound : bounds) slack = Math.max(slack, bound.getSlack());
                return slack;
            }
        });
        for (int from : new java.util.LinkedHashSet<>(sources)) {
            double estimate = weightApprox.approximate(from);
            if (Double.isFinite(estimate)) fromHeap.add(new AStarEntry(NO_EDGE, from, estimate, 0));
        }
        runAlgo();
        return extractPath();
    }

'''
 replace('    private void runAlgo() {',method+'    private void runAlgo() {')
 return source
