import com.graphhopper.storage.BaseGraph;
import com.graphhopper.routing.util.*;
import com.graphhopper.routing.ev.SimpleBooleanEncodedValue;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.util.EdgeIteratorState;
import java.util.*;
public class FuelRejoinCheck {
 static void check(boolean ok,String why){if(!ok)throw new AssertionError(why);}
 public static void main(String[] args){
  try(var g=new BaseGraph.Builder(EncodingManager.start().add(new SimpleBooleanEncodedValue("dummy",true)).build()).create()){
   int in=g.edge(0,1).setDistance(1000).getEdge(),original=g.edge(1,2).setDistance(2000).getEdge(),next=g.edge(2,3).setDistance(2000).getEdge();
   int toPump=g.edge(1,4).setDistance(1000).getEdge(),fromPump=g.edge(4,2).setDistance(1000).getEdge();
   for(boolean blocked:new boolean[]{false,true}){
    Weighting w=new Weighting(){
     public double calcMinWeightPerDistance(){return 1;}
     public double calcEdgeWeight(EdgeIteratorState e,boolean reverse){return ((e.getEdgeKey()&1)==1)!=reverse?Double.POSITIVE_INFINITY:e.getDistance();}
     public long calcEdgeMillis(EdgeIteratorState e,boolean reverse){return 0;}
     public double calcTurnWeight(int incoming,int node,int outgoing){return blocked&&incoming==fromPump&&outgoing==next?Double.POSITIVE_INFINITY:0;}
     public long calcTurnMillis(int i,int n,int o){return 0;}
     public boolean hasTurnCosts(){return true;}
     public String getName(){return "test";}
    };
    var same=FuelRepair.excursion(g,w,1,in,original,Map.of(4,"pump"),10000,5000,2000,System.nanoTime()+1000000000L,1000,30000);
    check(!same.state().equals("found"),"one-way fixture unexpectedly returns to original node");
    var targets=Map.of(1,new FuelRepair.Rejoin(original,2000,0,0),2,new FuelRepair.Rejoin(next,2000,2000,1));
    var joined=FuelRepair.excursion(g,w,1,in,targets,Map.of(4,"pump"),10000,5000,System.nanoTime()+1000000000L,1000,30000,false);
    check(joined.state().equals(blocked?"incomplete":"found"),"downstream continuation restriction lost");
    if(!blocked){check(joined.steps().get(joined.steps().size()-1).to()==2,"imaginary rejoin");check(joined.meters()==2000&&joined.remaining()==9000,"incorrect rejoin fuel");}
   }
  }
  System.out.println("Downstream one-way fuel rejoin and forbidden continuation passed without added connections.");
 }
}
