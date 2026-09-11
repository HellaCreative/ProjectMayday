// Private hybrid candidate: bounded fuel excursions from a fixed legal road route.
// Incomplete repair is not proof that no fuel-feasible itinerary exists.
import com.graphhopper.storage.Graph;
import com.graphhopper.routing.weighting.Weighting;
import java.util.*;

final class FuelRepair {
 record Attempt(FuelSearch.Result result,int attempts,int labels,String reason,double reachedMeters,double remainingMeters,int node) {}
 record Portfolio(Attempt selected,List<Map<String,Object>> trials){}
 static Portfolio refine(Graph graph,Weighting raw,com.graphhopper.routing.Path road,Map<Integer,String> stations,
   double full,double initial,long deadline,int maxLabels,double maxDetour,boolean tryObjective){
  Attempt best=null;List<Map<String,Object>> trials=new ArrayList<>();
  for(int mode=0;mode<4;mode++){
   if(mode==2&&!tryObjective)continue;
   if(mode==3&&best!=null&&best.result()!=null)break;
   if(System.nanoTime()>=deadline&&best!=null)break;
   long started=System.nanoTime();
   var attempt=repair(graph,raw,road,stations,full,initial,deadline,maxLabels,maxDetour,mode==3,mode==2,mode!=0);
   Map<String,Object> row=new LinkedHashMap<>();row.put("policy",switch(mode){case 0->"same_node_distance";case 1->"downstream_distance";case 2->"downstream_objective";default->"early_downstream_retry";});
   row.put("seconds",(System.nanoTime()-started)/1e9);row.put("labels",attempt.labels());row.put("reason",attempt.reason());row.put("fuelVerified",attempt.result()!=null);row.put("cost",attempt.result()==null?null:attempt.result().cost());row.put("distance",attempt.result()==null?null:attempt.result().meters());trials.add(row);
   if(best==null||(attempt.result()!=null&&(best.result()==null||attempt.result().cost()<best.result().cost()))||(attempt.result()==null&&best.result()==null&&attempt.reachedMeters()>best.reachedMeters()))best=attempt;
  }
  return new Portfolio(best,trials);
 }
 static Attempt repair(Graph graph,Weighting raw,com.graphhopper.routing.Path road,
   Map<Integer,String> stations,double full,double initial,long deadline,int maxLabels,double maxDetour) {
  return repair(graph,raw,road,stations,full,initial,deadline,maxLabels,maxDetour,false,false);
 }
 static Attempt repair(Graph graph,Weighting raw,com.graphhopper.routing.Path road,
   Map<Integer,String> stations,double full,double initial,long deadline,int maxLabels,double maxDetour,boolean earlyFuel,boolean objectiveDetours) {
  return repair(graph,raw,road,stations,full,initial,deadline,maxLabels,maxDetour,earlyFuel,objectiveDetours,false);
 }
 static Attempt repair(Graph graph,Weighting raw,com.graphhopper.routing.Path road,
   Map<Integer,String> stations,double full,double initial,long deadline,int maxLabels,double maxDetour,boolean earlyFuel,boolean objectiveDetours,boolean downstream) {
  var w=graph.wrapWeighting(raw);var edges=road.calcEdges();
  List<FuelSearch.Step> steps=new ArrayList<>();double remaining=initial,meters=0,cost=0,lastAttempt=-1e20;
  int incoming=-1,node=road.getFromNode(),attempts=0,labels=0;
  double[] nextPump=new double[edges.size()+1];nextPump[edges.size()]=stations.containsKey(road.getEndNode())?0:Double.POSITIVE_INFINITY;
  for(int i=edges.size()-1;i>=0;i--)nextPump[i]=edges.get(i).getDistance()+(stations.containsKey(edges.get(i).getAdjNode())?0:nextPump[i+1]);
  for(int i=0;i<=edges.size();i++) {
   if(System.nanoTime()>=deadline||Thread.currentThread().isInterrupted())return new Attempt(null,attempts,labels,"time_budget",meters,remaining,node);
   if(stations.containsKey(node)&&remaining<full-1e-6){steps.add(new FuelSearch.Step(-1,node,node,0,stations.get(node)));remaining=full;}
   var next=i<edges.size()?edges.get(i):null;
   if(next==null){
    var escape=FuelSearch.escape(graph,w,node,incoming,remaining,stations,deadline,Math.max(1,maxLabels-labels));
    if(!escape.incomplete()&&escape.station()!=null)return new Attempt(finish(steps,meters,cost,initial,full,escape,labels),attempts,labels,null,meters,remaining,node);
   }
   // Explore near the latter half of a tank, at 10 km intervals, or before an
   // otherwise untraversable edge. This is a bounded candidate policy, not pruning
   // of the engine graph or a claim to exhaust all possible fuel chains.
   double need=next==null?0:next.getDistance();
   if((nextPump[i]>remaining+1e-6&&remaining<(earlyFuel?full-1000:full*0.55)&&meters-lastAttempt>=10000)||remaining+1e-6<need||next==null){
    if(labels>=maxLabels)return new Attempt(null,attempts,labels,"repair_label_budget",meters,remaining,node);
    attempts++;lastAttempt=meters;
    Map<Integer,Rejoin> rejoins=new LinkedHashMap<>();rejoins.put(node,new Rejoin(next==null?-1:next.getEdge(),need,0,i));
    if(downstream){double skipped=0;
     for(int j=i;j<Math.min(edges.size(),i+3);j++){
      skipped+=edges.get(j).getDistance();if(skipped>10000)break;
      var after=j+1<edges.size()?edges.get(j+1):null;
      rejoins.putIfAbsent(edges.get(j).getAdjNode(),new Rejoin(after==null?-1:after.getEdge(),after==null?0:after.getDistance(),skipped,j+1));
     }
    }
    var detour=excursion(graph,w,node,incoming,rejoins,stations,full,remaining,deadline,Math.min(25000,maxLabels-labels),maxDetour,objectiveDetours);
    labels+=detour.labels();
    if(detour.state().equals("found")){
     steps.addAll(detour.steps());remaining=detour.remaining();meters+=detour.meters();cost+=detour.cost();
     for(var s:detour.steps())if(s.refill()==null){incoming=s.edge();node=s.to();}
     i=rejoins.get(node).index();next=i<edges.size()?edges.get(i):null;need=next==null?0:next.getDistance();
     if(next==null){
      var escape=FuelSearch.escape(graph,w,node,incoming,remaining,stations,deadline,Math.max(1,maxLabels-labels));
      if(!escape.incomplete()&&escape.station()!=null)return new Attempt(finish(steps,meters,cost,initial,full,escape,labels),attempts,labels,null,meters,remaining,node);
     }
    }
   }
   if(next==null||remaining+1e-6<need)return new Attempt(null,attempts,labels,"candidate_fuel_gap_unresolved",meters,remaining,node);
   double value=w.calcEdgeWeight(next,false)+w.calcTurnWeight(incoming,node,next.getEdge());
   if(next.getBaseNode()!=node||!Double.isFinite(value))return new Attempt(null,attempts,labels,"candidate_continuation_rejected",meters,remaining,node);
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
  return excursion(graph,w,start,incoming,nextEdge,stations,full,initial,need,deadline,maxLabels,maxMeters,false);
 }
 static FuelSearch.Result excursion(Graph graph,Weighting w,int start,int incoming,int nextEdge,
   Map<Integer,String> stations,double full,double initial,double need,long deadline,int maxLabels,double maxMeters,boolean objectiveDetours){
  return excursion(graph,w,start,incoming,Map.of(start,new Rejoin(nextEdge,need,0,0)),stations,full,initial,deadline,maxLabels,maxMeters,objectiveDetours);
 }
 record Rejoin(int nextEdge,double nextMeters,double skippedMeters,int index){}
 static FuelSearch.Result excursion(Graph graph,Weighting w,int start,int incoming,Map<Integer,Rejoin> rejoins,
   Map<Integer,String> stations,double full,double initial,long deadline,int maxLabels,double maxMeters,boolean objectiveDetours){
  var queue=new PriorityQueue<FuelSearch.Label>(Comparator.comparingDouble((FuelSearch.Label l)->objectiveDetours?l.cost:l.meters).thenComparingDouble(l->l.meters));
  // Preserve distance and fuel feasibility when comparing labels; the optional
  // objective order improves local character without claiming a global optimum.
  Map<Long,List<FuelSearch.Label>> fronts=new HashMap<>();
  var root=new FuelSearch.Label(start,incoming,initial,0,0,0,null,null);queue.add(root);
  fronts.computeIfAbsent(FuelSearch.state(start,incoming),k->new ArrayList<>()).add(root);
  int labels=1,expanded=0;var explorer=graph.createEdgeExplorer();
  while(!queue.isEmpty()){
   if(System.nanoTime()>=deadline||Thread.currentThread().isInterrupted())return FuelSearch.failed("time_budget",labels,expanded);
   var l=queue.poll();if(!l.live)continue;expanded++;
   Rejoin goal=rejoins.get(l.node);
   if(goal!=null&&l.stops>0&&l.remaining>Math.max(0,initial-goal.skippedMeters())+1000&&l.remaining+1e-6>=goal.nextMeters()&&(goal.nextEdge()<0||Double.isFinite(w.calcTurnWeight(l.in,l.node,goal.nextEdge()))))
    return new FuelSearch.Result("found",null,FuelSearch.path(l),l.meters,l.cost,l.remaining,List.of(),null,labels,expanded);
   if(stations.containsKey(l.node)&&l.remaining<full-1e-6){
    var n=new FuelSearch.Label(l.node,l.in,full,l.cost,l.meters,l.stops+1,l,new FuelSearch.Step(-1,l.node,l.node,0,stations.get(l.node)));
    if(offer(fronts,queue,n,objectiveDetours)&&++labels>=maxLabels)return FuelSearch.failed("local_label_budget",labels,expanded);
   }
   var it=explorer.setBaseNode(l.node);
   while(it.next()){
    double d=it.getDistance();if(d>l.remaining+1e-6||l.meters+d>maxMeters)continue;
    double c=w.calcEdgeWeight(it,false)+w.calcTurnWeight(l.in,l.node,it.getEdge());if(!Double.isFinite(c))continue;
    var n=new FuelSearch.Label(it.getAdjNode(),it.getEdge(),Math.max(0,l.remaining-d),l.cost+c,l.meters+d,l.stops,l,new FuelSearch.Step(it.getEdge(),l.node,it.getAdjNode(),d,null));
    if(offer(fronts,queue,n,objectiveDetours)&&++labels>=maxLabels)return FuelSearch.failed("local_label_budget",labels,expanded);
   }
  }
  return FuelSearch.failed("no_local_excursion",labels,expanded);
 }
 static boolean offer(Map<Long,List<FuelSearch.Label>> fronts,PriorityQueue<FuelSearch.Label> queue,FuelSearch.Label n,boolean objectiveDetours){
  var set=fronts.computeIfAbsent(FuelSearch.state(n.node,n.in),k->new ArrayList<>());
  for(var old:set)if(old.live&&old.remaining+1e-6>=n.remaining&&old.meters<=n.meters+1e-6&&(!objectiveDetours||old.cost<=n.cost+1e-6))return false;
  for(var it=set.iterator();it.hasNext();){var old=it.next();if(!old.live||(n.remaining+1e-6>=old.remaining&&n.meters<=old.meters+1e-6&&(!objectiveDetours||n.cost<=old.cost+1e-6))){old.live=false;it.remove();}}
  set.add(n);queue.add(n);return true;
 }
}
