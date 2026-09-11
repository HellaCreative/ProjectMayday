// Private architecture experiment. Imports verified immutable DIRT topology into GH.
// Not a product engine or a published pack builder.
import com.graphhopper.*;
import com.graphhopper.config.*;
import com.graphhopper.routing.*;
import java.nio.file.Path;
import com.graphhopper.routing.querygraph.QueryGraph;
import com.graphhopper.routing.querygraph.VirtualEdgeIteratorState;
import com.graphhopper.storage.index.Snap;
import com.graphhopper.routing.lm.LMRoutingAlgorithmFactory;
import com.graphhopper.routing.util.TraversalMode;
import com.graphhopper.routing.ev.*;
import com.graphhopper.routing.weighting.*;
import com.graphhopper.routing.util.parsers.RestrictionSetter;
import com.graphhopper.storage.*;
import com.graphhopper.util.*;
import com.carrotsearch.hppc.IntArrayList;
import com.fasterxml.jackson.databind.*;
import java.nio.*;
import java.nio.channels.*;
import java.nio.file.*;
import java.io.*;
import java.util.*;
import java.security.*;

public class VerifiedHopper extends GraphHopper implements AutoCloseable {
 static final ObjectMapper JSON=new ObjectMapper();
 static final List<String> NAMES=List.of("distance","paved","dirt10","dirt30");
 final JsonNode input;
 final Path descriptor;
 final Path artifactIdentity;
 final String identity;
 final Map<Integer,List<Integer>> sourceCopies=new HashMap<>();
 final Map<Integer,Integer> loopTails=new HashMap<>(),loopOrigins=new HashMap<>();
 final Path loopFile;
 JsonNode stationDataset;
 VerifiedHopper(Path descriptor,Path target) throws Exception {
  this.descriptor=descriptor;input=JSON.readTree(descriptor.toFile());
  loopFile=target.resolve("dirt-loop-tails.json");
  if(Files.exists(loopFile)){JsonNode loops=JSON.readTree(loopFile.toFile());loops.fields().forEachRemaining(e->loopTails.put(Integer.parseInt(e.getKey()),e.getValue().asInt()));}
  artifactIdentity=target.resolve("dirt-input.identity");
  boolean objectiveLandmarks=Boolean.getBoolean("dirt.objectiveLandmarks");
  identity=(objectiveLandmarks?"directed-v2-loop-objective-lm:":"directed-v2-loop-distance-lm:")+HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(descriptor)));
  if(Files.exists(target.resolve("properties"))&&(!Files.exists(artifactIdentity)||!Files.readString(artifactIdentity).equals(identity)))throw new IOException("Existing graph identity mismatch");
  for(String n:List.of("edgeSurfaceLeaf","edgeRoadClassLeaf","edgeAccess"))if(!input.path("sections").path(n).path("type").asText().equals("Uint8Array"))throw new IOException("Unexpected section type "+n);
  if(!input.path("sections").path("edgeMeters").path("type").asText().equals("Uint32Array"))throw new IOException("Unexpected meters type");
  Path stationFile=descriptor.resolveSibling("stations.json");
  if(Files.exists(stationFile)){stationDataset=JSON.readTree(stationFile.toFile());if(!stationDataset.path("sourceManifestSha256").equals(input.path("sourceManifestSha256"))||!stationDataset.path("sourceIdentity").equals(input.path("identity")))throw new IOException("Station source identity mismatch");}
  DefaultImportRegistry defaults=new DefaultImportRegistry();
  setImportRegistry(name -> switch(name) {
   case "canonical_edge" -> ImportUnit.create(name,p->new IntEncodedValueImpl(name,31,false),null);
   case "source_edge" -> ImportUnit.create(name,p->new IntEncodedValueImpl(name,31,false),null);
   case "dirt_access" -> ImportUnit.create(name,p->new IntEncodedValueImpl(name,3,true),null);
   case "surface_kind" -> ImportUnit.create(name,p->new IntEncodedValueImpl(name,2,false),null);
   case "paved_factor" -> ImportUnit.create(name,p->new IntEncodedValueImpl(name,12,false),null);
   case "dirt_factor" -> ImportUnit.create(name,p->new IntEncodedValueImpl(name,4,false),null);
   default -> defaults.createImportUnit(name);
  });
  GraphHopperConfig c=new GraphHopperConfig();
  c.putObject("graph.location",target.toString());c.putObject("datareader.file",descriptor.toString());
  c.putObject("graph.dataaccess.default_type","MMAP");c.putObject("graph.sort",false);
  c.putObject("prepare.min_network_size",0);c.putObject("import.osm.ignored_highways","");
  c.putObject("graph.encoded_values","canonical_edge,source_edge,dirt_access,surface_kind,paved_factor,dirt_factor");
  c.putObject("prepare.ch.threads",1);c.putObject("prepare.lm.threads",1);c.putObject("prepare.lm.landmarks",16);
  c.putObject("routing.max_visited_nodes",12000000);
  c.setProfiles(NAMES.stream().map(n->new Profile(n).setWeighting("custom").setTurnCostsConfig(new TurnCostsConfig(List.of("motorcycle"),0))).toList());
  // LM is prepared on the distance lower bound, with all endpoint/unknown access.
  c.setLMProfiles(NAMES.stream().map(n->objectiveLandmarks||n.equals("distance")?new LMProfile(n):new LMProfile(n).setPreparationProfile("distance")).toList());
  c.setCHProfiles(List.of());
  init(c);
 }
 ByteBuffer map(Path p) throws Exception {try(FileChannel f=FileChannel.open(p)){return f.map(FileChannel.MapMode.READ_ONLY,0,f.size()).order(ByteOrder.LITTLE_ENDIAN);}}
 ByteBuffer section(String name) throws Exception {
  JsonNode s=input.path("sections").path(name);Path p=Path.of(input.path("root").asText(),s.path("file").asText());
  MessageDigest digest=MessageDigest.getInstance("SHA-256");try(InputStream in=Files.newInputStream(p)){byte[] b=new byte[1048576];for(int n;(n=in.read(b))!=-1;)digest.update(b,0,n);}
  if(Files.size(p)!=s.path("bytes").asLong() || !HexFormat.of().formatHex(digest.digest()).equals(s.path("sha256").asText()))throw new IOException("Section identity mismatch: "+name);
  return map(p);
 }
 @Override protected void importOSM() {
  try {
   createBaseGraphAndProperties();BaseGraph g=getBaseGraph();var em=getEncodingManager();
   IntEncodedValue canonical=em.getIntEncodedValue("canonical_edge"),source=em.getIntEncodedValue("source_edge"),access=em.getIntEncodedValue("dirt_access"),surface=em.getIntEncodedValue("surface_kind"),paved=em.getIntEncodedValue("paved_factor"),dirt=em.getIntEncodedValue("dirt_factor");
   ByteBuffer xy=section("nodeCoords"),from=section("edgeFrom"),to=section("edgeTo"),meters=section("edgeMeters"),a=section("edgeAccess"),s=section("edgeSurfaceLeaf"),roads=section("edgeRoadClassLeaf"),regions=section("sourceRegions"),local=section("sourceEdges");
   List<ByteBuffer> geometries=new ArrayList<>();for(JsonNode p:input.path("geometryPaths"))geometries.add(map(Path.of(p.asText())));
   int nodes=input.path("nodeCount").asInt(),edges=input.path("edgeCount").asInt();
   for(int n=0;n<nodes;n++)g.getNodeAccess().setNode(n,xy.getFloat(n*8+4),xy.getFloat(n*8));
   record Tail(int key,int cloneNode,int original,double meters,PointList geometry){}List<Tail> tails=new ArrayList<>();
   for(int e=0;e<edges;e++) for(int direction=0;direction<2;direction++) {
    int kind=input.path("surfaceKinds").get(Byte.toUnsignedInt(s.get(e))).asInt();
    String road=input.path("roadClasses").get(Byte.toUnsignedInt(roads.get(e))).asText();
    int pf=switch(road){case "primary","primary_link"->4;case "trunk","trunk_link"->8;case "motorway","motorway_link","freeway"->32;case "service"->6;default->1;};
    int df=Set.of("motorway","motorway_link","freeway").contains(road)?8:1;
    int src=direction==0?from.getInt(e*4):to.getInt(e*4),dst=direction==0?to.getInt(e*4):from.getInt(e*4);boolean loop=src==dst;
    if(loop){dst=nodes+tails.size();g.getNodeAccess().setNode(dst,g.getNodeAccess().getLat(src),g.getNodeAccess().getLon(src));}
    EdgeIteratorState edge=g.edge(src,dst).setDistance(loop?0:Integer.toUnsignedLong(meters.getInt(e*4)));
    if(edge.getEdge()!=e*2+direction)throw new IllegalStateException("source edge ID drift");
    edge.set(canonical,edge.getEdge()).set(source,e*2+direction).set(access,Byte.toUnsignedInt(a.get(e*2+direction)),2).set(surface,kind).set(paved,pf*(kind==0?1:100)).set(dirt,df);
    ByteBuffer geom=geometries.get(Short.toUnsignedInt(regions.getShort(e*2)));int id=local.getInt(e*4),count=geom.getInt(8);boolean doubles=(geom.getShort(6)&1)!=0;
    int start=geom.getInt(16+id*4),end=geom.getInt(20+id*4),coords=16+(count+1)*4;coords=(coords+(doubles?7:3))&~(doubles?7:3);
    PointList line=new PointList(Math.max(0,(end-start)/2-2),false);
    for(int i=start+2;i<end-2;i+=2)line.add(doubles?geom.getDouble(coords+(i+1)*8):geom.getFloat(coords+(i+1)*4),doubles?geom.getDouble(coords+i*8):geom.getFloat(coords+i*4));
    if(direction==1)line.reverse();
    if(loop)tails.add(new Tail(e*2+direction,dst,src,Integer.toUnsignedLong(meters.getInt(e*4)),line));else edge.setWayGeometry(line);
   }
   for(Tail tail:tails){var head=g.getEdgeIteratorStateForKey(tail.key*2);var edge=g.edge(tail.cloneNode,tail.original).setDistance(tail.meters).setWayGeometry(tail.geometry);edge.setFlags(head.getFlags());edge.set(canonical,edge.getEdge());loopTails.put(tail.key,edge.getEdge());}
   JSON.writeValue(loopFile.toFile(),loopTails);
   List<IntArrayList> keys=new ArrayList<>(),via=new ArrayList<>();List<com.carrotsearch.hppc.BitSet> bits=new ArrayList<>();
   for(JsonNode r:input.path("restrictions")){IntArrayList k=new IntArrayList(),n=new IntArrayList();var originals=r.path("keys");for(int i=0;i<originals.size();i++){int key=originals.get(i).asInt(),tail=loopTails.getOrDefault(key,key);if(i==0)k.add(tail*2);else if(i==originals.size()-1)k.add(key*2);else{k.add(key*2);if(tail!=key)k.add(tail*2);}}for(int i=0;i<k.size()-1;i++)n.add(g.getEdgeIteratorStateForKey(k.get(i)).getAdjNode());keys.add(k);via.add(n);com.carrotsearch.hppc.BitSet b=new com.carrotsearch.hppc.BitSet();b.set(0,NAMES.size());bits.add(b);}
   new RestrictionSetter(g,NAMES.stream().map(n->em.getTurnBooleanEncodedValue(TurnRestriction.key(n))).toList()).setDirectedRestrictions(keys,via,bits);
   System.out.println("VERIFIED_IMPORT "+nodes+" nodes "+edges+" source edges "+g.getEdges()+" expanded edges "+keys.size()+" restrictions");
  } catch(Exception e){throw new RuntimeException(e);}
 }
 @Override protected WeightingFactory createWeightingFactory() {
  return (profile,hints,disableTurns)-> {
   var em=getEncodingManager();IntEncodedValue access=em.getIntEncodedValue("dirt_access"),source=em.getIntEncodedValue("source_edge"),surface=em.getIntEncodedValue("surface_kind"),paved=em.getIntEncodedValue("paved_factor"),dirt=em.getIntEncodedValue("dirt_factor");
   BooleanEncodedValue restriction=em.getTurnBooleanEncodedValue(TurnRestriction.key(profile.getName()));
   boolean unknown=hints.getBool("allow_unknown",false),preparing=disableTurns;
   double wander=hints.getDouble("wander",1);if(!Double.isFinite(wander)||wander<0||wander>1)throw new IllegalArgumentException("wander out of range");
   double penalty=30*Math.pow(1-wander,2);
   Set<Integer> endpoints=new HashSet<>();for(String e:hints.getString("endpoint_edges","").split(","))if(!e.isEmpty())endpoints.add(Integer.parseInt(e));
   return new Weighting() {
    public double calcMinWeightPerDistance(){return 0;}
    public double calcEdgeWeight(EdgeIteratorState e,boolean reverse){
     int a=reverse?e.getReverse(access):e.get(access);
     if(a==2 || (!preparing && ((a==1&&!unknown)||(a>=3&&!endpoints.contains(e.get(source)/2)))))return Double.POSITIVE_INFINITY;
     double factor=switch(profile.getName()){case "paved"->e.get(paved);case "dirt10"->e.get(dirt)*(e.get(surface)==1?1:10);case "dirt30"->e.get(dirt)*(e.get(surface)==1?1:30);default->1;};
     return e.getDistance()*(factor+penalty);
    }
    public long calcEdgeMillis(EdgeIteratorState e,boolean r){return Math.round(e.getDistance()*1000);}
    public double calcTurnWeight(int in,int node,int out){return !disableTurns&&in>=0&&out>=0&&getBaseGraph().getTurnCostStorage().get(restriction,in,node,out)?Double.POSITIVE_INFINITY:0;}
    public long calcTurnMillis(int i,int n,int o){return 0;}
    public boolean hasTurnCosts(){return !disableTurns;}
    public String getName(){return "dirt";}
   };
  };
 }
 void indexSourceCopies(){
  var g=getBaseGraph();var canonical=getEncodingManager().getIntEncodedValue("canonical_edge");
  for(int tail:loopTails.values()){var e=g.getEdgeIteratorStateForKey(tail*2);loopOrigins.put(e.getBaseNode(),e.getAdjNode());}
  for(int e=input.path("edgeCount").asInt()*2+loopTails.size();e<g.getEdges();e++)sourceCopies.computeIfAbsent(g.getEdgeIteratorStateForKey(e*2).get(canonical),k->new ArrayList<>()).add(e);
 }
 void appendCopies(Snap original,List<Snap> result) {
  if(original.getSnappedPosition()==Snap.Position.TOWER&&loopOrigins.containsKey(original.getClosestNode())){int node=loopOrigins.get(original.getClosestNode());original.setClosestNode(node);original.setWayIndex(original.getClosestEdge().getBaseNode()==node?0:original.getClosestEdge().fetchWayGeometry(FetchMode.ALL).size()-1);}
  result.add(original);int key=original.getClosestEdge().get(getEncodingManager().getIntEncodedValue("canonical_edge"));
  for(int edge:sourceCopies.getOrDefault(key,List.of())){
   if(edge==original.getClosestEdge().getEdge())continue;
   Snap copy=new Snap(original.getQueryPoint().lat,original.getQueryPoint().lon);copy.setClosestNode(original.getClosestNode());copy.setQueryDistance(original.getQueryDistance());copy.setWayIndex(original.getWayIndex());copy.setSnappedPosition(original.getSnappedPosition());copy.setSnappedPoint(original.getSnappedPoint());
   copy.setClosestEdge(getBaseGraph().getEdgeIteratorStateForKey(edge*2+(original.getClosestEdge().get(EdgeIteratorState.REVERSE_STATE)?1:0)));result.add(copy);
  }
  // The index can choose an artificial copy; always include its original too.
  if(original.getClosestEdge().getEdge()!=key){
   Snap copy=new Snap(original.getQueryPoint().lat,original.getQueryPoint().lon);copy.setClosestNode(original.getClosestNode());copy.setQueryDistance(original.getQueryDistance());copy.setWayIndex(original.getWayIndex());copy.setSnappedPosition(original.getSnappedPosition());copy.setSnappedPoint(original.getSnappedPoint());copy.setClosestEdge(getBaseGraph().getEdgeIteratorStateForKey(key*2+(original.getClosestEdge().get(EdgeIteratorState.REVERSE_STATE)?1:0)));result.add(copy);
  }
 }
 List<Snap> snaps(JsonNode point,Weighting w) {
  double lat=point.get(1).asDouble(),lon=point.get(0).asDouble();var source=getEncodingManager().getIntEncodedValue("source_edge");
  Snap first=getLocationIndex().findClosest(lat,lon,e->Double.isFinite(w.calcEdgeWeight(e,false))||Double.isFinite(w.calcEdgeWeight(e,true)));
  if(!first.isValid()||first.getQueryDistance()>2000)throw new IllegalArgumentException("No legal endpoint within 2000m");
  int other=first.getClosestEdge().get(source)^1;
  Snap second=getLocationIndex().findClosest(lat,lon,e->e.get(source)==other&&(Double.isFinite(w.calcEdgeWeight(e,false))||Double.isFinite(w.calcEdgeWeight(e,true))));
  List<Snap> result=new ArrayList<>();appendCopies(first,result);if(second.isValid())appendCopies(second,result);return result;
 }
 QueryGraph project(List<Snap> snaps){
  QueryGraph graph=new ExactQueryGraph(getBaseGraph(),snaps);
  Map<Integer,Double> totals=new HashMap<>();Map<Integer,VirtualEdgeIteratorState> pieces=new HashMap<>();
  for(int id=getBaseGraph().getEdges();id<graph.getEdges();id++){
   var e=(VirtualEdgeIteratorState)graph.getEdgeIteratorStateForKey(id*2);if(pieces.putIfAbsent(e.getEdge(),e)!=null)continue;
   totals.merge(e.getOriginalEdgeKey()/2,e.getDistance(),Double::sum);
  }
  for(var e:pieces.values()){
   int original=e.getOriginalEdgeKey()/2;double total=totals.get(original),authoritative=getBaseGraph().getEdgeIteratorStateForKey(original*2).getDistance();
   double value=total>0?e.getDistance()/total*authoritative:0;
   e.setDistance(value);graph.getEdgeIteratorStateForKey(e.getReverseEdgeKey()).setDistance(value);
  }
  return graph;
 }
 Map<String,Object> directedRoute(JsonNode q) {
  long started=System.nanoTime();String name=q.path("profile").asText("distance");
  Weighting w=createWeighting(getProfile(name),new PMap().putObject("allow_unknown",q.path("allowUnknown").asBoolean(false)).putObject("wander",q.path("wander").asDouble(1)));
  List<Snap> from=snaps(q.path("start"),w),to=snaps(q.path("end"),w),all=new ArrayList<>(from);all.addAll(to);
  QueryGraph graph=project(all);long prepared=System.nanoTime();
  boolean flexible=q.path("flexible").asBoolean(false);
  RoutingAlgorithmFactory factory=flexible?new RoutingAlgorithmFactorySimple():new LMRoutingAlgorithmFactory(getLandmarks().get(name));
  AlgorithmOptions options=new AlgorithmOptions().setAlgorithm(flexible?"dijkstrabi":"astarbi").setTraversalMode(TraversalMode.EDGE_BASED).setMaxVisitedNodes(12000000).setTimeoutMillis(90000);
  com.graphhopper.routing.Path best=null;int visited=0;List<String> failures=new ArrayList<>();
  for(Snap a:from)for(Snap b:to){long remaining=90000-(System.nanoTime()-started)/1000000;if(remaining<=0){failures.add("request_time_budget");continue;}options.setTimeoutMillis(remaining);var algorithm=factory.createAlgo(graph,w,options);try{var p=algorithm.calcPath(a.getClosestNode(),b.getClosestNode());visited+=algorithm.getVisitedNodes();if(algorithm.getVisitedNodes()>=options.getMaxVisitedNodes()||(!p.isFound()&&(System.nanoTime()-started)/1000000>=90000))failures.add("incomplete_alternative_search");if(p.isFound()&&(best==null||p.getWeight()<best.getWeight()))best=p;}catch(Exception ex){failures.add(ex.toString());}}
  Map<String,Object> out=new LinkedHashMap<>();out.put("snapSeconds",(prepared-started)/1e9);out.put("seconds",(System.nanoTime()-started)/1e9);out.put("visited",visited);out.put("failures",failures);
  if(best==null){out.put("errors",List.of("No complete path"));return out;}
  // Every directional alternative must finish before claiming the minimum.
  out.put("errors",failures);out.put("distance",best.getDistance());out.put("weight",best.getWeight());out.put("points",best.calcPoints().toLineString(false).toString());
  var source=getEncodingManager().getIntEncodedValue("source_edge");var surface=getEncodingManager().getIntEncodedValue("surface_kind");
  out.put("edges",best.calcEdges().stream().map(e->Map.of("sourceKey",e.get(source),"engineEdge",e.getEdge(),"meters",e.getDistance(),"surfaceKind",e.get(surface),"from",e.getBaseNode(),"to",e.getAdjNode())).toList());return out;
 }
 List<Snap> preparedStationSnaps(JsonNode station,Weighting w){
  int source=station.path("edgeIndex").asInt(-1);if(source<0||source>=input.path("edgeCount").asInt())throw new IllegalArgumentException("Invalid prepared station source");
  double fraction=station.path("fraction").asDouble(Double.NaN);if(!Double.isFinite(fraction)||fraction<0||fraction>1)throw new IllegalArgumentException("Invalid station fraction");
  double lat=station.path("position").get(1).asDouble(),lon=station.path("position").get(0).asDouble();List<Snap> snaps=new ArrayList<>();
  for(int direction=0;direction<2;direction++){
   int sourceKey=source*2+direction;var e=getBaseGraph().getEdgeIteratorStateForKey(loopTails.getOrDefault(sourceKey,sourceKey)*2);if(!Double.isFinite(w.calcEdgeWeight(e,false)))continue;
   int points=e.fetchWayGeometry(FetchMode.ALL).size(),index=station.path("match").path("segmentIndex").asInt();if(direction==1)index=points-2-index;
   Snap snap=new Snap(lat,lon);snap.setClosestEdge(e);snap.setQueryDistance(station.path("match").path("distanceM").asDouble());snap.setSnappedPoint(new com.graphhopper.util.shapes.GHPoint3D(lat,lon,Double.NaN));
   double f=direction==0?fraction:1-fraction;if(f==0&&loopTails.containsKey(sourceKey))f=1;
   snap.setClosestNode(f==1?e.getAdjNode():e.getBaseNode());snap.setWayIndex(f==0?0:f==1?points-1:index);snap.setSnappedPosition(f==0||f==1?Snap.Position.TOWER:Snap.Position.EDGE);appendCopies(snap,snaps);
  }return snaps;
 }
 Map<String,Object> fuelRoute(JsonNode q) {
  if(q.has("arrivalHistory"))throw new IllegalArgumentException("Continuation import not yet implemented; refusing to discard history");
  long begin=System.nanoTime();String name=q.path("profile").asText("distance");
  Weighting w=createWeighting(getProfile(name),new PMap().putObject("allow_unknown",q.path("allowUnknown").asBoolean(false)).putObject("wander",q.path("wander").asDouble(1)));
  List<Snap> from=snaps(q.path("start"),w),to=snaps(q.path("end"),w),all=new ArrayList<>(from);all.addAll(to);
  List<Map.Entry<String,List<Snap>>> bindings=new ArrayList<>();Set<String> excluded=new HashSet<>();q.path("excludedStationIds").forEach(x->excluded.add(x.asText()));
  JsonNode stationInput=q.has("stations")?q.path("stations"):stationDataset==null?JSON.createArrayNode():stationDataset.path("policies").path(String.valueOf(q.path("allowUnknown").asBoolean(false)));
  for(JsonNode station:stationInput){
   if(station.has("rejected"))continue;
   String id=station.path("id").asText();if(id.isEmpty())throw new IllegalArgumentException("Station ID required");if(excluded.contains(id))continue;
   List<Snap> matches=(station.has("edgeIndex")?preparedStationSnaps(station,w):snaps(station.path("position"),w)).stream().filter(x->x.getQueryDistance()<=150).toList();
   if(!matches.isEmpty()){bindings.add(Map.entry(id,matches));all.addAll(matches);}
  }
  QueryGraph graph=project(all);Map<Integer,String> stations=new HashMap<>();for(var binding:bindings)for(Snap point:binding.getValue())stations.putIfAbsent(point.getClosestNode(),binding.getKey());
  JsonNode f=q.path("fuel");double full=f.path("usableRangeMeters").asDouble(Double.NaN),initial=f.path("initialUsableMeters").asDouble(Double.NaN);
  if(!Double.isFinite(full)||full<=0||!Double.isFinite(initial)||initial<0||initial>full)throw new IllegalArgumentException("Invalid usable fuel range");
  long deadline=begin+90000000000L;int maxLabels=Math.min(500000,q.path("maxLabels").asInt(100000));
  FuelSearch.Result result=null;com.graphhopper.routing.Path best=null;boolean roadComplete=true;int roadVisited=0;List<String> roadFailures=new ArrayList<>();
  if(!q.path("forceResourceSearch").asBoolean(false)){
   boolean flexible=q.path("flexible").asBoolean(false);RoutingAlgorithmFactory factory=flexible?new RoutingAlgorithmFactorySimple():new LMRoutingAlgorithmFactory(getLandmarks().get(name));
   for(int a:from.stream().map(Snap::getClosestNode).distinct().toList())for(int b:to.stream().map(Snap::getClosestNode).distinct().toList()){
    long millis=(deadline-System.nanoTime())/1000000;if(millis<=0){roadComplete=false;continue;}
    var options=new AlgorithmOptions().setAlgorithm(flexible?"dijkstrabi":"astar").setTraversalMode(TraversalMode.EDGE_BASED).setMaxVisitedNodes(12000000).setTimeoutMillis(millis);
    var algo=factory.createAlgo(graph,w,options);try{var candidate=algo.calcPath(a,b);roadVisited+=algo.getVisitedNodes();if(algo.getVisitedNodes()>=12000000||System.nanoTime()>=deadline)roadComplete=false;if(candidate.isFound()&&(best==null||candidate.getWeight()<best.getWeight()))best=candidate;}catch(Exception ex){roadComplete=false;roadFailures.add(ex.toString());}
   }
   if(roadComplete&&best!=null)result=FuelSearch.certify(graph,w,best,stations,full,initial,deadline,maxLabels);
  }
  if(result==null){
   var landmarks=getLandmarks().get(name);List<com.graphhopper.routing.lm.LMApproximator> bounds=new ArrayList<>();
   if(!q.path("disableFuelGuidance").asBoolean(false))for(int target:to.stream().map(Snap::getClosestNode).distinct().toList()){
    var bound=com.graphhopper.routing.lm.LMApproximator.forLandmarks(graph,graph.wrapWeighting(w),landmarks,Math.max(1,Math.min(12,landmarks.getLandmarkCount()/2)));bound.setTo(target);bounds.add(bound);
   }
   // Minimum across destination states remains a lower bound; fuel constraints only add cost.
   java.util.function.IntToDoubleFunction lowerBound=node->{double value=Double.POSITIVE_INFINITY;for(var bound:bounds)value=Math.min(value,bound.approximate(node));return Double.isFinite(value)?value:0;};
   result=FuelSearch.search(graph,w,from.stream().map(Snap::getClosestNode).distinct().toList(),new HashSet<>(to.stream().map(Snap::getClosestNode).toList()),stations,full,initial,deadline,maxLabels,lowerBound);
  }
  Map<String,Object> out=new LinkedHashMap<>();out.put("state",result.state());out.put("reason",result.reason());out.put("seconds",(System.nanoTime()-begin)/1e9);out.put("labels",result.labels());out.put("expanded",result.expanded());out.put("distance",result.meters());out.put("weight",result.cost());out.put("remainingUsableMeters",result.remaining());out.put("escapeStation",result.escapeStation());out.put("steps",fuelSteps(graph,result.steps()));out.put("escape",fuelSteps(graph,result.escape()));out.put("matchedStations",bindings.size());out.put("roadVisited",roadVisited);out.put("roadFailures",roadFailures);out.put("roadBestDistance",best==null?null:best.getDistance());out.put("roadSourceKeys",best==null?List.of():best.calcEdges().stream().map(e->List.of(e.getEdge(),e.get(getEncodingManager().getIntEncodedValue("source_edge")))).toList());out.put("stationAccessEvidence","legal_road_projection");return out;
 }
 List<Map<String,Object>> fuelSteps(QueryGraph graph,List<FuelSearch.Step> steps){
  List<Map<String,Object>> out=new ArrayList<>();var source=getEncodingManager().getIntEncodedValue("source_edge");
  for(var step:steps){Map<String,Object> row=new LinkedHashMap<>();row.put("meters",step.meters());row.put("from",step.from());row.put("to",step.to());row.put("engineEdge",step.edge());
   if(step.refill()!=null)row.put("refill",step.refill());else{var e=graph.getEdgeIteratorState(step.edge(),step.to());row.put("sourceKey",e.get(source));row.put("geometry",e.fetchWayGeometry(FetchMode.ALL).toLineString(false).toString());}out.add(row);
  }return out;
 }
 boolean accepts(JsonNode sequence) {
  if(sequence.isEmpty())return true;
  Set<Integer> states=new HashSet<>();var g=getBaseGraph();var source=getEncodingManager().getIntEncodedValue("source_edge");Weighting w=createWeighting(getProfile("distance"),new PMap().putObject("allow_unknown",true));
  record Hop(int node,int incoming,int depth){}
  for(int pos=0;pos<sequence.size();pos++){
   int key=sequence.get(pos).asInt(),start=g.getEdgeIteratorStateForKey(key*2).getBaseNode(),end=g.getEdgeIteratorStateForKey(loopTails.getOrDefault(key,key)*2).getAdjNode();Set<Integer> next=new HashSet<>();ArrayDeque<Hop> todo=new ArrayDeque<>();
   if(pos==0)todo.add(new Hop(start,-1,0));else for(int previous:states)if(g.getEdgeIteratorStateForKey(previous).getAdjNode()==start)todo.add(new Hop(start,previous/2,0));
   while(!todo.isEmpty()){
    Hop h=todo.removeFirst();var it=g.createEdgeExplorer().setBaseNode(h.node);
    while(it.next())if(it.get(source)==key&&Double.isFinite(w.calcEdgeWeight(it,false))&&Double.isFinite(w.calcTurnWeight(h.incoming,h.node,it.getEdge()))){
     if(it.getAdjNode()==end)next.add(it.getEdgeKey());else if(h.depth<2)todo.add(new Hop(it.getAdjNode(),it.getEdge(),h.depth+1));
    }
   }
   states=next;
  }
  return !states.isEmpty();
 }
 public static void main(String[] args) throws Exception {
  try(VerifiedHopper h=new VerifiedHopper(Path.of(args[0]),Path.of(args[1]))) {
   long start=System.nanoTime();h.importOrLoad();h.indexSourceCopies();Files.writeString(h.artifactIdentity,h.identity);System.out.println("READY "+(System.nanoTime()-start)/1e9);System.out.flush();
   BufferedReader in=new BufferedReader(new InputStreamReader(System.in));String line;
   while((line=in.readLine())!=null){long t=System.nanoTime();try {
    JsonNode q=JSON.readTree(line);if(q.has("walk")){System.out.println("RESULT "+JSON.writeValueAsString(Map.of("accepted",h.accepts(q.path("walk")))));continue;}if(q.has("fuel")){System.out.println("RESULT "+JSON.writeValueAsString(h.fuelRoute(q)));continue;}if(!q.path("standardApi").asBoolean(false)){System.out.println("RESULT "+JSON.writeValueAsString(h.directedRoute(q)));continue;}GHRequest req=new GHRequest(q.path("start").get(1).asDouble(),q.path("start").get(0).asDouble(),q.path("end").get(1).asDouble(),q.path("end").get(0).asDouble()).setProfile(q.path("profile").asText("distance"));
    req.putHint("ch.disable",true);req.putHint("lm.disable",q.path("flexible").asBoolean(false));req.putHint("allow_unknown",q.path("allowUnknown").asBoolean(false));req.putHint("wander",q.path("wander").asDouble(1));req.putHint("instructions",false);req.putHint("calc_points",true);req.putHint("way_point_max_distance",0);req.setPathDetails(List.of("source_edge","surface_kind","edge_id"));
    GHResponse response=h.route(req);Map<String,Object> out=new LinkedHashMap<>();out.put("seconds",(System.nanoTime()-t)/1e9);out.put("errors",response.getErrors().stream().map(Throwable::toString).toList());out.put("debug",response.getDebugInfo());
    if(!response.hasErrors()){var p=response.getBest();out.put("distance",p.getDistance());out.put("weight",p.getRouteWeight());out.put("details",p.getPathDetails());out.put("points",p.getPoints().toLineString(false).toString());}
    System.out.println("RESULT "+JSON.writeValueAsString(out));
   }catch(Exception e){System.out.println("RESULT "+JSON.writeValueAsString(Map.of("error",e.toString())));}System.out.flush();}
  }
 }
}
