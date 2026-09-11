// Preserve the actual restriction-state edge when splitting a road at a stop.
// Upstream QueryGraphWeighting minimizes across artificial copies; that is not
// valid for a fuel stop that must retain its incoming restriction state.
import com.graphhopper.routing.querygraph.QueryGraph;
import com.graphhopper.routing.querygraph.VirtualEdgeIteratorState;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.storage.BaseGraph;
import com.graphhopper.storage.index.Snap;
import com.graphhopper.util.EdgeIteratorState;
import java.util.List;
final class ExactQueryGraph extends QueryGraph {
 private final int baseNodes,baseEdges;
 ExactQueryGraph(BaseGraph graph,List<Snap> snaps){super(graph,snaps);baseNodes=graph.getNodes();baseEdges=graph.getEdges();}
 int original(int e){return e<baseEdges?e:((VirtualEdgeIteratorState)getEdgeIteratorStateForKey(e*2)).getOriginalEdgeKey()/2;}
 @Override public Weighting wrapWeighting(Weighting w){return new Weighting(){
  public double calcMinWeightPerDistance(){return w.calcMinWeightPerDistance();}
  public double calcEdgeWeight(EdgeIteratorState e,boolean reverse){return w.calcEdgeWeight(e,reverse);}
  public long calcEdgeMillis(EdgeIteratorState e,boolean reverse){return w.calcEdgeMillis(e,reverse);}
  public double calcTurnWeight(int in,int node,int out){if(in<0||out<0)return 0;if(node>=baseNodes)return in==out?Double.POSITIVE_INFINITY:0;return w.calcTurnWeight(original(in),node,original(out));}
  public long calcTurnMillis(int in,int node,int out){return in<0||out<0||node>=baseNodes?0:w.calcTurnMillis(original(in),node,original(out));}
  public boolean hasTurnCosts(){return w.hasTurnCosts();}
  public String getName(){return w.getName();}
 };}
}
