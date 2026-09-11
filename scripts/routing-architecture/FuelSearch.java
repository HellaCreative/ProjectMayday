// Bounded resource search over GraphHopper's prepared graph and turn-state expansion.
// This is an integration prototype, not yet a qualified DIRT fuel implementation.
import com.graphhopper.storage.Graph;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.util.EdgeIterator;
import java.util.*;

final class FuelSearch {
 record Step(int edge,int from,int to,double meters,String refill) {}
 static final class Label {
  final int node,in,stops;final double remaining,cost,meters;final Label parent;final Step step;boolean live=true;double priority;
  Label(int n,int i,double r,double c,double m,int stops,Label p,Step s){node=n;in=i;remaining=r;cost=c;meters=m;this.stops=stops;parent=p;step=s;priority=c;}
 }
 record Result(String state,String reason,List<Step> steps,double meters,double cost,double remaining,List<Step> escape,String escapeStation,int labels,int expanded) {}
 static Result certify(Graph graph,Weighting raw,com.graphhopper.routing.Path road,Map<Integer,String> stations,double full,double initial,long deadline,int maxLabels){
  if(!road.isFound())return null;
  var edges=road.calcEdges();List<Step> steps=new ArrayList<>();record Pump(int after,double at,String id){}List<Pump> pumps=new ArrayList<>();double meters=0;
  int start=road.getFromNode(),end=road.getEndNode(),incoming=-1;
  if(stations.containsKey(start))pumps.add(new Pump(0,0,stations.get(start)));
  for(var edge:edges){steps.add(new Step(edge.getEdge(),edge.getBaseNode(),edge.getAdjNode(),edge.getDistance(),null));meters+=edge.getDistance();incoming=edge.getEdge();if(stations.containsKey(edge.getAdjNode()))pumps.add(new Pump(steps.size(),meters,stations.get(edge.getAdjNode())));}
  Escape escape=escape(graph,graph.wrapWeighting(raw),end,incoming,full,stations,deadline,maxLabels);
  if(escape.incomplete||escape.station==null)return null;
  double escapeMeters=escape.path.stream().mapToDouble(Step::meters).sum(),target=meters+escapeMeters,reach=initial;int index=0;List<Pump> chosen=new ArrayList<>();
  while(reach+1e-6<target){Pump last=null;while(index<pumps.size()&&pumps.get(index).at<=reach+1e-6)last=pumps.get(index++);if(last==null||last.at+full<=reach+1e-6)return null;chosen.add(last);reach=last.at+full;}
  List<Step> withRefills=new ArrayList<>();int pump=0;
  for(int i=0;i<=steps.size();i++){
   while(pump<chosen.size()&&chosen.get(pump).after==i){Pump p=chosen.get(pump++);int node=i==0?start:steps.get(i-1).to;withRefills.add(new Step(-1,node,node,0,p.id));}
   if(i<steps.size())withRefills.add(steps.get(i));
  }
  return new Result("found","minimum_road_objective_fixed_path_fuel_certificate",withRefills,meters,road.getWeight(),Math.max(0,reach-meters),escape.path,escape.station,0,0);
 }
 static Result search(Graph graph,Weighting raw,List<Integer> starts,Set<Integer> goals,Map<Integer,String> stations,double full,double initial,long deadline,int maxLabels,java.util.function.IntToDoubleFunction lowerBound) {
  if(!Double.isFinite(full)||full<=0||!Double.isFinite(initial)||initial<0||initial>full)throw new IllegalArgumentException("Invalid usable fuel range");
  Weighting w=graph.wrapWeighting(raw);
  PriorityQueue<Label> queue=new PriorityQueue<>(Comparator.comparingDouble((Label l)->l.priority).thenComparingInt(l->l.stops).thenComparingDouble(l->l.meters));
  Map<Long,List<Label>> frontier=new HashMap<>();int labels=0,expanded=0;
  for(int node:starts){Label l=new Label(node,-1,initial,0,0,0,null,null);l.priority=l.cost+lowerBound.applyAsDouble(node);queue.add(l);frontier.computeIfAbsent(state(node,-1),k->new ArrayList<>()).add(l);labels++;}
  var explorer=graph.createEdgeExplorer();
  while(!queue.isEmpty()){
   if(Thread.currentThread().isInterrupted()||System.nanoTime()>=deadline)return failed("time_budget",labels,expanded);
   Label l=queue.poll();if(!l.live)continue;expanded++;
   if(goals.contains(l.node)){
    Escape e=escape(graph,w,l.node,l.in,l.remaining,stations,deadline,maxLabels);
    if(e.incomplete)return failed("escape_incomplete",labels,expanded);
    if(e.station!=null)return new Result("found",null,path(l),l.meters,l.cost,l.remaining,e.path,e.station,labels,expanded);
   }
   // A refill retains the exact incoming edge/turn state and creates no connector.
   if(stations.containsKey(l.node)&&l.remaining<full-1e-6){
    Label next=new Label(l.node,l.in,full,l.cost,l.meters,l.stops+1,l,new Step(-1,l.node,l.node,0,stations.get(l.node)));
    if(offer(frontier,queue,next,lowerBound)&&++labels>maxLabels)return failed("label_budget",labels,expanded);
   }
   EdgeIterator it=explorer.setBaseNode(l.node);
   while(it.next()){
    double meters=it.getDistance();if(meters>l.remaining+1e-6)continue;
    double edge=w.calcEdgeWeight(it,false),turn=w.calcTurnWeight(l.in,l.node,it.getEdge());if(!Double.isFinite(edge+turn))continue;
    Label next=new Label(it.getAdjNode(),it.getEdge(),Math.max(0,l.remaining-meters),l.cost+edge+turn,l.meters+meters,l.stops,l,new Step(it.getEdge(),l.node,it.getAdjNode(),meters,null));
    if(offer(frontier,queue,next,lowerBound)&&++labels>maxLabels)return failed("label_budget",labels,expanded);
   }
  }
  return new Result("unreachable","no_feasible_chain",List.of(),0,0,0,List.of(),null,labels,expanded);
 }
 static boolean offer(Map<Long,List<Label>> fronts,PriorityQueue<Label> queue,Label n,java.util.function.IntToDoubleFunction lowerBound){
  List<Label> set=fronts.computeIfAbsent(state(n.node,n.in),k->new ArrayList<>());
  for(Label old:set)if(old.live&&dominates(old,n))return false;
  for(Iterator<Label> i=set.iterator();i.hasNext();){Label old=i.next();if(!old.live||dominates(n,old)){old.live=false;i.remove();}}
  n.priority=n.cost+lowerBound.applyAsDouble(n.node);set.add(n);queue.add(n);return true;
 }
 static boolean dominates(Label a,Label b){return a.remaining+1e-6>=b.remaining&&(a.cost<b.cost-1e-6||(a.cost<=b.cost+1e-6&&a.stops<=b.stops&&a.meters<=b.meters+1e-6));}
 static long state(int node,int in){return ((long)node<<32)|Integer.toUnsignedLong(in+1);}
 static List<Step> path(Label l){List<Step> p=new ArrayList<>();for(;l!=null&&l.step!=null;l=l.parent)p.add(l.step);Collections.reverse(p);return p;}
 static Result failed(String why,int labels,int expanded){return new Result("incomplete",why,List.of(),0,0,0,List.of(),null,labels,expanded);}
 record Escape(String station,List<Step> path,boolean incomplete){}
 static Escape escape(Graph g,Weighting w,int start,int incoming,double range,Map<Integer,String> stations,long deadline,int max){
  PriorityQueue<Label> q=new PriorityQueue<>(Comparator.comparingDouble(l->l.meters));Map<Long,Double> best=new HashMap<>();q.add(new Label(start,incoming,0,0,0,0,null,null));best.put(state(start,incoming),0.0);var exp=g.createEdgeExplorer();int count=0;
  while(!q.isEmpty()){
   if(++count>max||Thread.currentThread().isInterrupted()||System.nanoTime()>=deadline)return new Escape(null,List.of(),true);
   Label l=q.poll();if(l.meters>best.get(state(l.node,l.in))+1e-6)continue;
   if(stations.containsKey(l.node))return new Escape(stations.get(l.node),path(l),false);
   var it=exp.setBaseNode(l.node);while(it.next()){
    if(!Double.isFinite(w.calcEdgeWeight(it,false)+w.calcTurnWeight(l.in,l.node,it.getEdge())))continue;
    double distance=l.meters+it.getDistance();long key=state(it.getAdjNode(),it.getEdge());if(distance>range+1e-6||distance>=best.getOrDefault(key,Double.POSITIVE_INFINITY)-1e-6)continue;
    best.put(key,distance);q.add(new Label(it.getAdjNode(),it.getEdge(),0,0,distance,0,l,new Step(it.getEdge(),l.node,it.getAdjNode(),it.getDistance(),null)));
   }
  }
  return new Escape(null,List.of(),false);
 }
}
