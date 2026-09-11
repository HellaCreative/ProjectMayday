import java.nio.file.Path;
import java.util.*;
import com.graphhopper.routing.*;
import com.graphhopper.routing.lm.*;
import com.graphhopper.routing.util.TraversalMode;
import com.graphhopper.util.PMap;

// Compare actual prepared landmark guidance against an independent Dijkstra
// search on real directed roads with interior endpoint projections.
public final class CheckAdditiveGuidance {
 public static void main(String[] args) throws Exception {
  int checked=0,found=0;
  try(var h=new VerifiedHopper(Path.of(args[0]),Path.of(args[1]))) {
   h.importOrLoad();h.indexSourceCopies();
   for(var name:List.of("dirt10","dirt30","paved")) {
    if(h.getLandmarks().get(name).isEmpty()||h.getLandmarks().get("distance").isEmpty())throw new AssertionError("Test requires populated landmark tables");
    for(var q:VerifiedHopper.JSON.readTree(Path.of(args[2]).toFile()))for(double lambda:new double[]{30,300}){
     var w=h.createWeighting(h.getProfile(name),new PMap().putObject("allow_unknown",false).putObject("distance_penalty",lambda));
     var from=h.snaps(q.path("start"),w);var to=h.snaps(q.path("end"),w);var all=new ArrayList<>(from);all.addAll(to);var graph=h.project(all);
     for(var a:from)for(var b:to){
      var reference=new Dijkstra(graph,graph.wrapWeighting(w),TraversalMode.EDGE_BASED);reference.setMaxVisitedNodes(500000);reference.setTimeoutMillis(5000);
      long began=System.nanoTime();var expected=reference.calcPath(a.getClosestNode(),b.getClosestNode());
      if(reference.getVisitedNodes()>=500000||(System.nanoTime()-began)>4900000000L)throw new AssertionError("Reference search exceeded test bound");
      var fast=new LMRoutingAlgorithmFactory(h.getLandmarks().get(name)).createAlgo(graph,w,new AlgorithmOptions().setAlgorithm("astar").setTraversalMode(TraversalMode.EDGE_BASED).setMaxVisitedNodes(500000).setTimeoutMillis(5000));
      h.strengthenAdditiveGuidance(fast,graph,name,lambda);
      var actual=fast.calcPath(a.getClosestNode(),b.getClosestNode());
      if(actual.isFound()!=expected.isFound()||actual.isFound()&&Math.abs(actual.getWeight()-expected.getWeight())>1e-6*Math.max(1,expected.getWeight()))throw new AssertionError("Search cost mismatch: "+name+" "+lambda+" "+q+" "+actual.getWeight()+" != "+expected.getWeight());
      checked++;if(actual.isFound())found++;
     }
    }
   }
  }
  System.out.println("CHECK_RESULT "+VerifiedHopper.JSON.writeValueAsString(Map.of("checked",checked,"found",found,"state","passed","reference","edge-based Dijkstra","populatedLandmarks",true)));
 }
}
