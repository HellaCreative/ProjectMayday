import com.graphhopper.storage.BaseGraph;
import com.graphhopper.routing.util.*;
import com.graphhopper.routing.ev.SimpleBooleanEncodedValue;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.routing.Dijkstra;
import com.graphhopper.util.EdgeIteratorState;
import java.util.*;
public class FuelRepairPolicyCheck {
 static void check(boolean ok,String why){if(!ok)throw new AssertionError(why);}
 static Weighting weighting(Set<Integer> expensive){return new Weighting(){
  public double calcMinWeightPerDistance(){return 1;}
  public double calcEdgeWeight(EdgeIteratorState e,boolean reverse){return e.getDistance()*(expensive.contains(e.getEdge())?50:1);}
  public long calcEdgeMillis(EdgeIteratorState e,boolean reverse){return 0;}
  public double calcTurnWeight(int in,int via,int out){return 0;}
  public long calcTurnMillis(int in,int via,int out){return 0;}
  public boolean hasTurnCosts(){return false;}
  public String getName(){return "test";}
 };}
 static BaseGraph graph(){return new BaseGraph.Builder(EncodingManager.start().add(new SimpleBooleanEncodedValue("dummy",true)).build()).create();}
 public static void main(String[] args){
  try(var g=graph()){
   for(int i=0;i<12;i++)g.edge(i,i+1).setDistance(10000);
   g.edge(2,13).setDistance(2000);var w=weighting(Set.of());var road=new Dijkstra(g,w,TraversalMode.NODE_BASED).calcPath(0,12);
   var old=FuelRepair.repair(g,w,road,Map.of(13,"early",11,"late"),100000,100000,System.nanoTime()+1000000000L,100000,30000,false,false);
   var early=FuelRepair.repair(g,w,road,Map.of(13,"early",11,"late"),100000,100000,System.nanoTime()+1000000000L,100000,30000,true,false);
   check(old.result()==null,"fixture must expose late-refill failure");
   check(early.result()!=null&&early.result().steps().stream().anyMatch(s->"early".equals(s.refill())),"early necessary pump missed");
   check(early.result().meters()==124000,"unnecessary detour");
  }
  try(var g=graph()){
   int in=g.edge(0,1).setDistance(10000).getEdge(),next=g.edge(1,4).setDistance(15000).getEdge();
   int paved=g.edge(1,2).setDistance(1000).getEdge(),dirt=g.edge(1,3).setDistance(3000).getEdge();
   for(boolean objective:new boolean[]{false,true}){
    var r=FuelRepair.excursion(g,weighting(Set.of(paved)),1,in,next,Map.of(2,"paved",3,"dirt"),30000,10000,15000,System.nanoTime()+1000000000L,10000,10000,objective);
    check(r.state().equals("found"),"candidate missing");String wanted=objective?"dirt":"paved";
    check(r.steps().stream().anyMatch(s->wanted.equals(s.refill())),"detour ignored objective");
   }
   var clean=FuelRepair.excursion(g,weighting(Set.of(dirt)),1,in,next,Map.of(2,"paved",3,"dirt"),30000,10000,15000,System.nanoTime()+1000000000L,10000,10000,true);
   check(clean.steps().stream().anyMatch(s->"paved".equals(s.refill())),"paved objective ignored");
  }
  System.out.println("Early necessary fuel and profile-aware excursion selection passed.");
 }
}
