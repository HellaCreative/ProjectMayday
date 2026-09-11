// Private hybrid candidate: bounded fuel excursions from a fixed legal road route.
// Incomplete repair is not proof that no fuel-feasible itinerary exists.
import com.graphhopper.storage.Graph;
import com.graphhopper.routing.weighting.Weighting;
import java.util.*;

final class FuelRepair {
 record Attempt(FuelSearch.Result result,int attempts,int labels,String reason) {}
 static Attempt repair(Graph graph,Weighting raw,com.graphhopper.routing.Path road,
   Map<Integer,String> stations,double full,double initial,long deadline,int maxLabels,double maxDetour) {
  var w=graph.wrapWeighting(raw);var edges=road.calcEdges();
  List<FuelSearch.Step> steps=new ArrayList<>();double remaining=initial,meters=0,cost=0,lastAttempt=-1e20;
  int incoming=-1,node=road.getFromNode(),attempts=0,labels=0;
  double[] nextPump=new double[edges.size()+1];nextPump[edges.size()]=stations.containsKey(road.getEndNode())?0:Double.POSITIVE_INFINITY;
  for(int i=edges.size()-1;i>=0;i--)nextPump[i]=edges.get(i).getDistance()+(stations.containsKey(edges.get(i).getAdjNode())?0:nextPump[i+1]);
  for(int i=0;i<=edges.size();i++) {
   if(System.nanoTime()>=deadline||Thread.currentThread().isInterrupted())return new Attempt(null,attempts,labels,"time_budget");
   if(stations.containsKey(node)&&remaining<full-1e-6){steps.add(new FuelSearch.Step(-1,node,node,0,stations.get(node)));remaining=full;}
   var next=i<edges.size()?edges.get(i):null;
   if(next==null){
    var escape=FuelSearch.escape(graph,w,node,incoming,remaining,stations,deadline,Math.max(1,maxLabels-labels));
    if(!escape.incomplete()&&escape.station()!=null)return new Attempt(finish(steps,meters,cost,initial,full,escape,labels),attempts,labels,null);
   }
   // Explore near the latter half of a tank, at 10 km intervals, or before an
   // otherwise untraversable edge. This is a bounded candidate policy, not pruning
   // of the engine graph or a claim to exhaust all possible fuel chains.
   double need=next==null?0:next.getDistance();
   if((nextPump[i]>remaining+1e-6&&remaining<full*0.55&&meters-lastAttempt>=10000)||remaining+1e-6<need||next==null){
    if(labels>=maxLabels)return new Attempt(null,attempts,labels,"repair_label_budget");
    attempts++;lastAttempt=meters;
    var detour=excursion(graph,w,node,incoming,next==null?-1:next.getEdge(),stations,full,remaining,need,deadline,Math.min(25000,maxLabels-labels),maxDetour);
    labels+=detour.labels();
    if(detour.state().equals("found")){
     steps.addAll(detour.steps());remaining=detour.remaining();meters+=detour.meters();cost+=detour.cost();
     for(var s:detour.steps())if(s.refill()==null)incoming=s.edge();
     if(next==null){
      var escape=FuelSearch.escape(graph,w,node,incoming,remaining,stations,deadline,Math.max(1,maxLabels-labels));
      if(!escape.incomplete()&&escape.station()!=null)return new Attempt(finish(steps,meters,cost,initial,full,escape,labels),attempts,labels,null);
     }
    }
   }
   if(next==null||remaining+1e-6<need)return new Attempt(null,attempts,labels,"candidate_fuel_gap_unresolved");
   double value=w.calcEdgeWeight(next,false)+w.calcTurnWeight(incoming,node,next.getEdge());
   if(next.getBaseNode()!=node||!Double.isFinite(value))return new Attempt(null,attempts,labels,"candidate_continuation_rejected");
   steps.add(new FuelSearch.Step(next.getEdge(),node,next.getAdjNode(),need,null));
   remaining=Math.max(0,remaining-need);meters+=need;cost+=value;incoming=next.getEdge();node=next.getAdjNode();
  }
  throw new IllegalStateException("unreachable");
 }
 static FuelSearch.Result finish(List<FuelSearch.Step> input,double meters,double cost,double initial,double full,FuelSearch.Escape escape,int labels){
  // Minimize refills along this fixed, already legal walk. Do not add/remove roads.
  record Pump(int index,double at,FuelSearch.Step step){}
  List<FuelSearch.Step> roads=new ArrayList<>();List<Pump> pumps=new ArrayList<>();double at=0;
  for(var step:input){if(step.refill()!=null)pumps.add(new Pump(roads.size(),at,step));else{roads.add(step);at+=step.meters();}}
  double target=meters+escape.path().stream().mapToDouble(FuelSearch.Step::meters).sum(),reach=initial;int p=0;
  List<Pump> selected=new ArrayList<>();
  while(reach+1e-6<target){Pump last=null;while(p<pumps.size()&&pumps.get(p).at()<=reach+1e-6)last=pumps.get(p++);
   if(last==null||last.at()+full<=reach+1e-6)throw new IllegalStateException("Repair certificate lost fuel reachability");
   selected.add(last);reach=last.at()+full;
  }
  List<FuelSearch.Step> result=new ArrayList<>();p=0;
  for(int i=0;i<=roads.size();i++){while(p<selected.size()&&selected.get(p).index()==i)result.add(selected.get(p++).step());if(i<roads.size())result.add(roads.get(i));}
  return new FuelSearch.Result("found","fixed_road_with_legal_fuel_excursions",result,meters,cost,Math.max(0,reach-meters),escape.path(),escape.station(),labels,0);
 }
 static FuelSearch.Result excursion(Graph graph,Weighting w,int start,int incoming,int nextEdge,
   Map<Integer,String> stations,double full,double initial,double need,long deadline,int maxLabels,double maxMeters){
  var queue=new PriorityQueue<FuelSearch.Label>(Comparator.comparingDouble(l->l.meters));
  // Distance and remaining fuel determine local dominance. Objective cost is
  // recorded separately and never used to claim a globally optimal dirt route.
  Map<Long,List<FuelSearch.Label>> fronts=new HashMap<>();
  var root=new FuelSearch.Label(start,incoming,initial,0,0,0,null,null);queue.add(root);
  fronts.computeIfAbsent(FuelSearch.state(start,incoming),k->new ArrayList<>()).add(root);
  int labels=1,expanded=0;var explorer=graph.createEdgeExplorer();
  while(!queue.isEmpty()){
   if(System.nanoTime()>=deadline||Thread.currentThread().isInterrupted())return FuelSearch.failed("time_budget",labels,expanded);
   var l=queue.poll();if(!l.live)continue;expanded++;
   if(l.node==start&&l.stops>0&&l.remaining>initial+1000&&l.remaining+1e-6>=need&&(nextEdge<0||Double.isFinite(w.calcTurnWeight(l.in,start,nextEdge))))
    return new FuelSearch.Result("found",null,FuelSearch.path(l),l.meters,l.cost,l.remaining,List.of(),null,labels,expanded);
   if(stations.containsKey(l.node)&&l.remaining<full-1e-6){
    var n=new FuelSearch.Label(l.node,l.in,full,l.cost,l.meters,l.stops+1,l,new FuelSearch.Step(-1,l.node,l.node,0,stations.get(l.node)));
    if(offer(fronts,queue,n)&&++labels>=maxLabels)return FuelSearch.failed("local_label_budget",labels,expanded);
   }
   var it=explorer.setBaseNode(l.node);
   while(it.next()){
    double d=it.getDistance();if(d>l.remaining+1e-6||l.meters+d>maxMeters)continue;
    double c=w.calcEdgeWeight(it,false)+w.calcTurnWeight(l.in,l.node,it.getEdge());if(!Double.isFinite(c))continue;
    var n=new FuelSearch.Label(it.getAdjNode(),it.getEdge(),Math.max(0,l.remaining-d),l.cost+c,l.meters+d,l.stops,l,new FuelSearch.Step(it.getEdge(),l.node,it.getAdjNode(),d,null));
    if(offer(fronts,queue,n)&&++labels>=maxLabels)return FuelSearch.failed("local_label_budget",labels,expanded);
   }
  }
  return FuelSearch.failed("no_local_excursion",labels,expanded);
 }
 static boolean offer(Map<Long,List<FuelSearch.Label>> fronts,PriorityQueue<FuelSearch.Label> queue,FuelSearch.Label n){
  var set=fronts.computeIfAbsent(FuelSearch.state(n.node,n.in),k->new ArrayList<>());
  for(var old:set)if(old.live&&old.remaining+1e-6>=n.remaining&&old.meters<=n.meters+1e-6)return false;
  for(var it=set.iterator();it.hasNext();){var old=it.next();if(!old.live||(n.remaining+1e-6>=old.remaining&&n.meters<=old.meters+1e-6)){old.live=false;it.remove();}}
  set.add(n);queue.add(n);return true;
 }
}
