import com.graphhopper.storage.BaseGraph;
import com.graphhopper.routing.util.EncodingManager;
import com.graphhopper.routing.ev.SimpleBooleanEncodedValue;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.util.EdgeIteratorState;
import java.util.*;
public class FuelRepairCheck {
 static void check(boolean ok,String message){if(!ok)throw new AssertionError(message);}
 public static void main(String[] args){
  try(var g=new BaseGraph.Builder(EncodingManager.start().add(new SimpleBooleanEncodedValue("dummy",true)).build()).create()){
   int approach=g.edge(0,1).setDistance(10000).getEdge();
   int onward=g.edge(1,2).setDistance(15000).getEdge();
   int pump=g.edge(1,3).setDistance(2000).getEdge();
   for(int mode=0;mode<3;mode++){
    final int m=mode;
    Weighting w=new Weighting(){
     public double calcMinWeightPerDistance(){return 1;}
     public double calcEdgeWeight(EdgeIteratorState e,boolean reverse){return e.getDistance();}
     public long calcEdgeMillis(EdgeIteratorState e,boolean reverse){return 0;}
     public double calcTurnWeight(int in,int via,int out){return (m==1&&in==pump&&out==pump)||(m==2&&in==approach&&out==pump)?Double.POSITIVE_INFINITY:0;}
     public long calcTurnMillis(int in,int via,int out){return 0;}
     public boolean hasTurnCosts(){return true;}
     public String getName(){return "test";}
    };
    var result=FuelRepair.excursion(g,w,1,approach,onward,Map.of(3,"pump"),30000,10000,15000,System.nanoTime()+1000000000L,1000,6000);
    check(result.state().equals(mode==0?"found":"incomplete"),"restricted arrival/exit accepted: "+mode);
    if(mode==0){
     double remaining=10000;int in=approach,node=1;
     for(var s:result.steps()){
      check(s.from()==node,"disconnected");
      if(s.refill()!=null){check(node==3,"invented station");remaining=30000;}
      else{check(Double.isFinite(w.calcTurnWeight(in,node,s.edge())),"illegal turn");remaining-=s.meters();check(remaining>=0,"fuel exhausted");node=s.to();in=s.edge();}
     }
     check(node==1&&remaining==28000&&result.meters()==4000,"bad returned state");
     var expired=FuelRepair.excursion(g,w,1,approach,onward,Map.of(3,"pump"),30000,10000,15000,0,1000,6000);
     check(expired.state().equals("incomplete")&&expired.reason().equals("time_budget"),"deadline falsely infeasible");
     var absent=FuelRepair.excursion(g,w,1,approach,onward,Map.of(),30000,10000,15000,System.nanoTime()+1000000000L,1000,6000);
     check(absent.state().equals("incomplete"),"invented refill");
    }
   }
  }
  System.out.println("Fuel repair: legal excursion, range accounting, forbidden arrival, forbidden turnaround, deadline and absent station passed.");
 }
}
