package com.graphhopper.routing.lm;
import com.graphhopper.storage.Graph;
import com.graphhopper.routing.weighting.Weighting;
// Private package-level bridge; no upstream source mutation.
public final class DirtLandmarkAccess {
 public static LMApproximator distanceBound(Graph graph,Weighting distance,LandmarkStorage storage,int active){
  return new LMApproximator(graph,distance,distance,storage.getBaseNodes(),storage,active,storage.getFactor(),false);
 }
}
