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
 byte[] stressMask;
 final double costScale;
 final boolean additiveLandmarkGuidance;
 final boolean multiEndpointSearch;
 VerifiedHopper(Path descriptor,Path target) throws Exception {
  this.descriptor=descriptor;input=JSON.readTree(descriptor.toFile());
  loopFile=target.resolve("dirt-loop-tails.json");
  if(Files.exists(loopFile)){JsonNode loops=JSON.readTree(loopFile.toFile());loops.fields().forEachRemaining(e->loopTails.put(Integer.parseInt(e.getKey()),e.getValue().asInt()));}
  artifactIdentity=target.resolve("dirt-input.identity");
  String maskPath=System.getProperty("dirt.stressMask");
  if(maskPath!=null){
   Path mp=Path.of(maskPath);var receipt=JSON.readTree(mp.resolveSibling("mask-receipt.json").toFile());stressMask=Files.readAllBytes(mp);
   if(stressMask.length!=input.path("edgeCount").asInt()||!receipt.path("sourceManifestSha256").equals(input.path("sourceManifestSha256"))||!receipt.path("maskSha256").asText().equals(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(stressMask))))throw new IOException("Stress mask identity mismatch");
   if(!Files.exists(target.resolve("properties")))throw new IOException("Stress mask requires an existing prepared graph");
  }
  boolean objectiveLandmarks=Boolean.getBoolean("dirt.objectiveLandmarks");
  boolean stressLandmarks=Boolean.getBoolean("dirt.stressLandmarks");
  boolean objectiveKilometers=Boolean.getBoolean("dirt.objectiveLandmarkKilometers");
  additiveLandmarkGuidance=Boolean.getBoolean("dirt.additiveLandmarkGuidance");
  multiEndpointSearch=Boolean.getBoolean("dirt.multiEndpointSearch");
  if(additiveLandmarkGuidance&&!objectiveLandmarks)throw new IOException("Additive guidance requires separate objective and distance landmark indexes");
  if(objectiveKilometers&&!objectiveLandmarks)throw new IOException("Kilometer objective landmarks require objective-specific preparation");
  costScale=stressLandmarks||objectiveKilometers?1000:1;
  if(stressLandmarks&&(stressMask==null||objectiveLandmarks))throw new IOException("Stress landmarks require the pinned mask and distance-profile preparation configuration");
  if(stressMask!=null&&objectiveLandmarks)throw new IOException("Stress weights cannot use unrelated objective landmark preparation");
  identity=(stressLandmarks?"directed-v2-loop-stress-lm-km:"+HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(stressMask))+":":objectiveKilometers?"directed-v2-loop-objective-lm-km:":objectiveLandmarks?"directed-v2-loop-objective-lm:":"directed-v2-loop-distance-lm:")+HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(descriptor)));
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
  // Preparation permits all endpoint/unknown access, so each objective remains
  // a lower bound when request access, wander or distance penalties are added.
  // Preparing one objective per process bounds preparation residency. Serving
  // omits this property and loads the complete four-objective index.
  String prepareProfile=System.getProperty("dirt.prepareProfile");
  if(prepareProfile!=null&&(!objectiveKilometers||!NAMES.contains(prepareProfile)))throw new IOException("Single-profile preparation requires kilometer objective landmarks and a known profile");
  c.setLMProfiles(NAMES.stream().filter(n->prepareProfile==null||n.equals(prepareProfile)).map(n->objectiveLandmarks||n.equals("distance")?new LMProfile(n):new LMProfile(n).setPreparationProfile("distance")).toList());
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
   boolean cancellable=hints.getBool("cancellable",false);
   boolean unknown=hints.getBool("allow_unknown",false),preparing=disableTurns;
   double wander=hints.getDouble("wander",1);if(!Double.isFinite(wander)||wander<0||wander>1)throw new IllegalArgumentException("wander out of range");
   double extra=hints.getDouble("distance_penalty",0);if(!Double.isFinite(extra)||extra<0)throw new IllegalArgumentException("Invalid distance penalty");
   double penalty=30*Math.pow(1-wander,2)+extra;
   Set<Integer> endpoints=new HashSet<>();for(String e:hints.getString("endpoint_edges","").split(","))if(!e.isEmpty())endpoints.add(Integer.parseInt(e));
   return new Weighting() {
    public double calcMinWeightPerDistance(){return 0;}
    public double calcEdgeWeight(EdgeIteratorState e,boolean reverse){
     if(cancellable&&Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException("request_cancelled");
     if(stressMask!=null&&stressMask[e.get(source)/2]!=0)return Double.POSITIVE_INFINITY;
     int a=reverse?e.getReverse(access):e.get(access);
     if(a==2 || (!preparing && ((a==1&&!unknown)||(a>=3&&!endpoints.contains(e.get(source)/2)))))return Double.POSITIVE_INFINITY;
     double factor=switch(profile.getName()){case "paved"->e.get(paved);case "dirt10"->e.get(dirt)*(e.get(surface)==1?1:10);case "dirt30"->e.get(dirt)*(e.get(surface)==1?1:30);default->1;};
     if(stressMask!=null)factor=e.get(surface)==1?1:500;
     return e.getDistance()*(factor+penalty)/costScale;
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
  long started=System.nanoTime(),budgetMillis=requestBudgetMillis(q);String name=q.path("profile").asText("distance");
  Weighting w=createWeighting(getProfile(name),new PMap().putObject("cancellable",true).putObject("allow_unknown",q.path("allowUnknown").asBoolean(false)).putObject("wander",q.path("wander").asDouble(1)));
  List<Snap> from=snaps(q.path("start"),w),to=snaps(q.path("end"),w),all=new ArrayList<>(from);all.addAll(to);
  QueryGraph graph=project(all);long prepared=System.nanoTime();
  boolean flexible=q.path("flexible").asBoolean(false);
  RoutingAlgorithmFactory factory=flexible?new RoutingAlgorithmFactorySimple():new LMRoutingAlgorithmFactory(getLandmarks().get(name));
  AlgorithmOptions options=new AlgorithmOptions().setAlgorithm(flexible?"dijkstrabi":"astarbi").setTraversalMode(TraversalMode.EDGE_BASED).setMaxVisitedNodes(12000000).setTimeoutMillis(budgetMillis);
  com.graphhopper.routing.Path best=null;int visited=0;List<String> failures=new ArrayList<>();
  for(Snap a:from)for(Snap b:to){long remaining=budgetMillis-(System.nanoTime()-started)/1000000;if(remaining<=0){failures.add("request_time_budget");continue;}options.setTimeoutMillis(remaining);var algorithm=factory.createAlgo(graph,w,options);try{var p=algorithm.calcPath(a.getClosestNode(),b.getClosestNode());visited+=algorithm.getVisitedNodes();if(algorithm.getVisitedNodes()>=options.getMaxVisitedNodes()||(!p.isFound()&&(System.nanoTime()-started)/1000000>=budgetMillis))failures.add("incomplete_alternative_search");if(p.isFound()&&(best==null||p.getWeight()<best.getWeight()))best=p;}catch(Exception ex){failures.add(ex.toString());}}
  Map<String,Object> out=new LinkedHashMap<>();out.put("snapSeconds",(prepared-started)/1e9);out.put("seconds",(System.nanoTime()-started)/1e9);out.put("visited",visited);out.put("failures",failures);
  if(best==null){out.put("errors",List.of("No complete path"));return out;}
  // Every directional alternative must finish before claiming the minimum.
  out.put("errors",failures);out.put("distance",best.getDistance());out.put("weight",best.getWeight()*costScale);out.put("points",best.calcPoints().toLineString(false).toString());
  var source=getEncodingManager().getIntEncodedValue("source_edge");var surface=getEncodingManager().getIntEncodedValue("surface_kind");
  out.put("edges",best.calcEdges().stream().map(e->Map.of("sourceKey",e.get(source),"engineEdge",e.getEdge(),"meters",e.getDistance(),"surfaceKind",e.get(surface),"pavedBackroadCost",e.getDistance()*e.get(getEncodingManager().getIntEncodedValue("paved_factor")),"from",e.getBaseNode(),"to",e.getAdjNode())).toList());return out;
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
 static record MaxGuidance(WeightApproximator original,WeightApproximator distance,double factor) implements WeightApproximator {
  public double approximate(int node){return Math.max(original.approximate(node),factor*distance.approximate(node));}
  public void setTo(int node){original.setTo(node);distance.setTo(node);}
  public WeightApproximator reverse(){return new MaxGuidance(original.reverse(),distance.reverse(),factor);}
  public double getSlack(){return Math.max(original.getSlack(),factor*distance.getSlack());}
 }
 static record SumGuidance(WeightApproximator objective,WeightApproximator distance,double factor) implements WeightApproximator {
  public double approximate(int node){return objective.approximate(node)+factor*distance.approximate(node);}
  public void setTo(int node){objective.setTo(node);distance.setTo(node);}
  public WeightApproximator reverse(){return new SumGuidance(objective.reverse(),distance.reverse(),factor);}
  public double getSlack(){return objective.getSlack()+factor*distance.getSlack();}
 }
 WeightApproximator additiveBound(QueryGraph graph,String name,double lambda){
  if(!additiveLandmarkGuidance||!Double.isFinite(lambda)||lambda<0)throw new IllegalArgumentException("Invalid additive guidance configuration");
  var objective=getLandmarks().get(name);var distance=getLandmarks().get("distance");
  int count=Math.max(1,Math.min(12,objective.getLandmarkCount()/2));
  // Each term uses its own preparation weighting, including the virtual-target
  // adjustment. Using the scalar weighting here would count lambda twice.
  var a=com.graphhopper.routing.lm.DirtLandmarkAccess.distanceBound(graph,graph.wrapWeighting(objective.getWeighting()),objective,count);
  var b=com.graphhopper.routing.lm.DirtLandmarkAccess.distanceBound(graph,graph.wrapWeighting(distance.getWeighting()),distance,count);
  // For every eligible path P, cost(P)=base(P)+lambda*distance(P).
  // Independent lower bounds can be added; both use the same internal units.
  return new SumGuidance(a,b,lambda);
 }
 void strengthenAdditiveGuidance(RoutingAlgorithm algorithm,QueryGraph graph,String name,double lambda){
  ((AStar)algorithm).setApproximation(additiveBound(graph,name,lambda));
 }
 record EndpointSearch(com.graphhopper.routing.Path path,int visited,boolean complete){}
 EndpointSearch searchEndpoints(QueryGraph graph,Weighting w,String name,double lambda,List<Integer> from,List<Integer> to,long millis){
  if(from.isEmpty()||to.isEmpty())return new EndpointSearch(new com.graphhopper.routing.Path(graph),0,true);
  if(millis<=0)return new EndpointSearch(new com.graphhopper.routing.Path(graph),0,false);
  long until=System.nanoTime()+millis*1000000L;
  var lm=getLandmarks().get(name);int count=Math.max(1,Math.min(12,lm.getLandmarkCount()/2));
  Map<Integer,WeightApproximator> bounds=new LinkedHashMap<>();
  for(int target:to)bounds.put(target,additiveLandmarkGuidance&&lambda>0?additiveBound(graph,name,lambda):com.graphhopper.routing.lm.LMApproximator.forLandmarks(graph,graph.wrapWeighting(w),lm,count));
  var algorithm=new com.graphhopper.routing.DirtMultiEndpointAStar(graph,graph.wrapWeighting(w),TraversalMode.EDGE_BASED);
  algorithm.setMaxVisitedNodes(12000000);algorithm.setTimeoutMillis(millis);
  var result=algorithm.calcPaths(from,bounds);
  return new EndpointSearch(result,algorithm.getVisitedNodes(),algorithm.getVisitedNodes()<12000000&&System.nanoTime()<until);
 }
 void strengthenDistanceGuidance(RoutingAlgorithm algorithm,QueryGraph graph,Weighting scalar,String name,double lambda){
  if(costScale!=1)throw new IllegalArgumentException("Scaled distance guidance requires the original metre-based distance landmark artifact");
  var access=getEncodingManager().getIntEncodedValue("dirt_access");
  Weighting distance=new Weighting(){
   public double calcMinWeightPerDistance(){return 0;}
   public double calcEdgeWeight(EdgeIteratorState e,boolean reverse){return (reverse?e.getReverse(access):e.get(access))==2?Double.POSITIVE_INFINITY:e.getDistance();}
   public long calcEdgeMillis(EdgeIteratorState e,boolean reverse){return 0;}
   public double calcTurnWeight(int in,int node,int out){return 0;}
   public long calcTurnMillis(int in,int node,int out){return 0;}
   public boolean hasTurnCosts(){return false;}
   public String getName(){return "distance_lower_bound";}
  };
  var lm=getLandmarks().get("distance");int count=Math.max(1,Math.min(12,lm.getLandmarkCount()/2));
  var dist=com.graphhopper.routing.lm.DirtLandmarkAccess.distanceBound(graph,graph.wrapWeighting(distance),lm,count);
  var original=com.graphhopper.routing.lm.LMApproximator.forLandmarks(graph,graph.wrapWeighting(scalar),getLandmarks().get(name),count);
  // Every imported objective costs at least one per metre; lambda adds to every
  // edge. Thus (1+lambda)*distanceLowerBound remains admissible. No road costs,
  // fuel arithmetic, eligibility or preferences are changed by this heuristic.
  ((AStar)algorithm).setApproximation(new MaxGuidance(original,dist,1+lambda));
 }
 Map<String,Object> fuelRoute(JsonNode q) {
  if(q.has("arrivalHistory"))throw new IllegalArgumentException("Continuation import not yet implemented; refusing to discard history");
  long begin=System.nanoTime(),deadline=begin+requestBudgetMillis(q)*1000000L;String name=q.path("profile").asText("distance");
  Weighting w=createWeighting(getProfile(name),new PMap().putObject("cancellable",true).putObject("allow_unknown",q.path("allowUnknown").asBoolean(false)).putObject("wander",q.path("wander").asDouble(1)));
  List<Snap> from=snaps(q.path("start"),w),to=snaps(q.path("end"),w),all=new ArrayList<>(from);all.addAll(to);
  List<Map.Entry<String,List<Snap>>> bindings=new ArrayList<>();Set<String> excluded=new HashSet<>();q.path("excludedStationIds").forEach(x->excluded.add(x.asText()));
  JsonNode stationInput=q.has("stations")?q.path("stations"):stationDataset==null?JSON.createArrayNode():stationDataset.path("policies").path(String.valueOf(q.path("allowUnknown").asBoolean(false)));
  for(JsonNode station:stationInput){
   if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException("request_cancelled");
   if(System.nanoTime()>=deadline)throw new IllegalStateException("request_time_budget_during_matching");
   if(station.has("rejected"))continue;
   String id=station.path("id").asText();if(id.isEmpty())throw new IllegalArgumentException("Station ID required");if(excluded.contains(id))continue;
   List<Snap> matches=(station.has("edgeIndex")?preparedStationSnaps(station,w):snaps(station.path("position"),w)).stream().filter(x->x.getQueryDistance()<=150).toList();
   if(!matches.isEmpty()){bindings.add(Map.entry(id,matches));all.addAll(matches);}
  }
  long matchedAt=System.nanoTime();
  QueryGraph graph=project(all);long projectedAt=System.nanoTime();Map<Integer,String> stations=new HashMap<>();for(var binding:bindings)for(Snap point:binding.getValue())stations.putIfAbsent(point.getClosestNode(),binding.getKey());
  JsonNode f=q.path("fuel");double full=f.path("usableRangeMeters").asDouble(Double.NaN),initial=f.path("initialUsableMeters").asDouble(Double.NaN);
  if(!Double.isFinite(full)||full<=0||!Double.isFinite(initial)||initial<0||initial>full)throw new IllegalArgumentException("Invalid usable fuel range");
  int maxLabels=Math.min(500000,q.path("maxLabels").asInt(100000));
  Map<String,Object> phases=new LinkedHashMap<>();phases.put("matchingSeconds",(matchedAt-begin)/1e9);phases.put("queryGraphSeconds",(projectedAt-matchedAt)/1e9);
  double certificateSeconds=0,alternativeSeconds=0,repairSeconds=0;
  long roadAt=System.nanoTime();
  FuelSearch.Result result=null;com.graphhopper.routing.Path best=null;boolean roadComplete=true;int roadVisited=0;List<String> roadFailures=new ArrayList<>();
  if(!q.path("forceResourceSearch").asBoolean(false)){
   boolean flexible=q.path("flexible").asBoolean(false);RoutingAlgorithmFactory factory=flexible?new RoutingAlgorithmFactorySimple():new LMRoutingAlgorithmFactory(getLandmarks().get(name));
   if(multiEndpointSearch&&!flexible){
    try{var trial=searchEndpoints(graph,w,name,0,from.stream().map(Snap::getClosestNode).distinct().toList(),to.stream().map(Snap::getClosestNode).distinct().toList(),(deadline-System.nanoTime())/1000000);roadVisited=trial.visited();roadComplete=trial.complete();if(trial.path().isFound())best=trial.path();}
    catch(Exception ex){roadComplete=false;roadFailures.add(ex.toString());}
   }else for(int a:from.stream().map(Snap::getClosestNode).distinct().toList())for(int b:to.stream().map(Snap::getClosestNode).distinct().toList()){
    long millis=(deadline-System.nanoTime())/1000000;if(millis<=0){roadComplete=false;continue;}
    var options=new AlgorithmOptions().setAlgorithm(flexible?"dijkstrabi":"astar").setTraversalMode(TraversalMode.EDGE_BASED).setMaxVisitedNodes(12000000).setTimeoutMillis(millis);
    var algo=factory.createAlgo(graph,w,options);try{var candidate=algo.calcPath(a,b);roadVisited+=algo.getVisitedNodes();if(algo.getVisitedNodes()>=12000000||System.nanoTime()>=deadline)roadComplete=false;if(candidate.isFound()&&(best==null||candidate.getWeight()<best.getWeight()))best=candidate;}catch(Exception ex){roadComplete=false;roadFailures.add(ex.toString());}
   }
   if(roadComplete&&best!=null){long t=System.nanoTime();result=FuelSearch.certify(graph,w,best,stations,full,initial,deadline,maxLabels);certificateSeconds+=(System.nanoTime()-t)/1e9;}
  }
  phases.put("roadAndCertificateSeconds",(System.nanoTime()-roadAt)/1e9);phases.put("roadSearchSeconds",(System.nanoTime()-roadAt)/1e9-certificateSeconds);
  Map<String,Object> repairDiagnostics=new LinkedHashMap<>();
  if(result==null&&best!=null&&q.path("fuelRepair").asBoolean(false)){
   long t=System.nanoTime();
   var repairPortfolio=q.path("refineFuelRepair").asBoolean(false)?FuelRepair.refine(graph,w,best,stations,full,initial,deadline,maxLabels,30000,!name.equals("distance")):null;
   var repaired=repairPortfolio==null?FuelRepair.repair(graph,w,best,stations,full,initial,deadline,maxLabels,30000,q.path("earlyFuelRepair").asBoolean(false),q.path("objectiveFuelRepair").asBoolean(false),q.path("downstreamFuelRepair").asBoolean(false)):repairPortfolio.selected();
   if(repairPortfolio!=null)repairDiagnostics.put("trials",repairPortfolio.trials());
   repairSeconds+=(System.nanoTime()-t)/1e9;result=repaired.result();repairDiagnostics.put("reachedMeters",repaired.reachedMeters());repairDiagnostics.put("remainingMeters",repaired.remainingMeters());repairDiagnostics.put("position",List.of(graph.getNodeAccess().getLon(repaired.node()),graph.getNodeAccess().getLat(repaired.node())));repairDiagnostics.put("seconds",(System.nanoTime()-t)/1e9);repairDiagnostics.put("attempts",repaired.attempts());repairDiagnostics.put("labels",repaired.labels());repairDiagnostics.put("reason",repaired.reason());repairDiagnostics.put("maxExcursionMeters",30000);
  }
  List<Map<String,Object>> portfolio=new ArrayList<>();
  if(result==null&&!name.equals("distance")&&q.path("fuelPortfolio").asBoolean(false)){
   // Candidate generation only: scalarization does not prove constrained optimality.
   // Every accepted path is certified on the same exact turn-state query graph.
   for(double lambda:q.path("hybrid").asBoolean(false)?new double[]{30,300}:new double[]{0.25,1,3,10,30,100,300}){
    if(System.nanoTime()>=deadline)break;
    long alternativeAt=System.nanoTime();
    Weighting scalar=createWeighting(getProfile(name),new PMap().putObject("cancellable",true).putObject("allow_unknown",q.path("allowUnknown").asBoolean(false)).putObject("wander",q.path("wander").asDouble(1)).putObject("distance_penalty",lambda));
    var factory=new LMRoutingAlgorithmFactory(getLandmarks().get(name));
    com.graphhopper.routing.Path selected=null;boolean complete=true;int visited=0;
    if(multiEndpointSearch){
     try{var trial=searchEndpoints(graph,scalar,name,lambda,from.stream().map(Snap::getClosestNode).distinct().toList(),to.stream().map(Snap::getClosestNode).distinct().toList(),(deadline-System.nanoTime())/1000000);visited=trial.visited();complete=trial.complete();if(trial.path().isFound())selected=trial.path();}
     catch(Exception ex){complete=false;roadFailures.add(ex.toString());}
    }else for(int a:from.stream().map(Snap::getClosestNode).distinct().toList())for(int b:to.stream().map(Snap::getClosestNode).distinct().toList()){
     long millis=(deadline-System.nanoTime())/1000000;if(millis<=0){complete=false;continue;}
     var options=new AlgorithmOptions().setAlgorithm("astar").setTraversalMode(TraversalMode.EDGE_BASED).setMaxVisitedNodes(12000000).setTimeoutMillis(millis);
     var algo=factory.createAlgo(graph,scalar,options);
     if(additiveLandmarkGuidance)strengthenAdditiveGuidance(algo,graph,name,lambda);
     else if(q.path("scaledDistanceGuidance").asBoolean(false))strengthenDistanceGuidance(algo,graph,scalar,name,lambda);
     try{var path=algo.calcPath(a,b);visited+=algo.getVisitedNodes();if(algo.getVisitedNodes()>=12000000||System.nanoTime()>=deadline)complete=false;if(path.isFound()&&(selected==null||path.getWeight()<selected.getWeight()))selected=path;}catch(Exception ex){complete=false;roadFailures.add(ex.toString());}
    }
    alternativeSeconds+=(System.nanoTime()-alternativeAt)/1e9;long certificateAt=System.nanoTime();
    FuelSearch.Result certified=complete&&selected!=null?FuelSearch.certify(graph,w,selected,stations,full,initial,deadline,maxLabels):null;
    certificateSeconds+=(System.nanoTime()-certificateAt)/1e9;
    FuelRepair.Attempt candidateRepair=null;
    if(certified==null&&selected!=null&&q.path("fuelRepair").asBoolean(false)){
     long repairAt=System.nanoTime();
     var alternatives=q.path("refineFuelRepair").asBoolean(false)?FuelRepair.refine(graph,w,selected,stations,full,initial,deadline,maxLabels,30000,!name.equals("distance")):null;
     candidateRepair=alternatives==null?FuelRepair.repair(graph,w,selected,stations,full,initial,deadline,maxLabels,30000,q.path("earlyFuelRepair").asBoolean(false),q.path("objectiveFuelRepair").asBoolean(false),q.path("downstreamFuelRepair").asBoolean(false)):alternatives.selected();
     if(alternatives!=null)repairDiagnostics.put("lambda"+lambda,alternatives.trials());
     certified=candidateRepair.result();repairSeconds+=(System.nanoTime()-repairAt)/1e9;
    }
    double originalCost=0;
    if(certified!=null){var original=graph.wrapWeighting(w);int incoming=-1;for(var edge:selected.calcEdges()){originalCost+=original.calcEdgeWeight(edge,false)+original.calcTurnWeight(incoming,edge.getBaseNode(),edge.getEdge());incoming=edge.getEdge();}}
    if(candidateRepair!=null&&certified!=null)originalCost=certified.cost();
    Map<String,Object> row=new LinkedHashMap<>();if(candidateRepair!=null)row.put("repair",Map.of("attempts",candidateRepair.attempts(),"labels",candidateRepair.labels(),"reason",String.valueOf(candidateRepair.reason())));row.put("lambda",lambda);row.put("complete",complete);row.put("visited",visited);row.put("distance",selected==null?null:selected.getDistance());row.put("fuelCertified",certified!=null);row.put("originalCost",certified==null?null:originalCost*costScale);portfolio.add(row);
    if(certified!=null&&(result==null||originalCost<result.cost()))result=new FuelSearch.Result("found","scalar_portfolio_fixed_path_certificate",certified.steps(),certified.meters(),originalCost,certified.remaining(),certified.escape(),certified.escapeStation(),0,0);
    if(result!=null&&q.path("hybrid").asBoolean(false))break;
   }
  }
  if(result==null&&q.path("portfolioOnly").asBoolean(false))result=FuelSearch.failed(q.path("hybrid").asBoolean(false)?(System.nanoTime()>=deadline?"time_budget":"bounded_hybrid_candidates_exhausted"):"portfolio_no_certificate",0,0);
  if(result==null){
   var landmarks=getLandmarks().get(name);List<com.graphhopper.routing.lm.LMApproximator> bounds=new ArrayList<>();
   if(!q.path("disableFuelGuidance").asBoolean(false))for(int target:to.stream().map(Snap::getClosestNode).distinct().toList()){
    var bound=com.graphhopper.routing.lm.LMApproximator.forLandmarks(graph,graph.wrapWeighting(w),landmarks,Math.max(1,Math.min(12,landmarks.getLandmarkCount()/2)));bound.setTo(target);bounds.add(bound);
   }
   // Minimum across destination states remains a lower bound; fuel constraints only add cost.
   java.util.function.IntToDoubleFunction lowerBound=node->{double value=Double.POSITIVE_INFINITY;for(var bound:bounds)value=Math.min(value,bound.approximate(node));return Double.isFinite(value)?value:0;};
   result=FuelSearch.search(graph,w,from.stream().map(Snap::getClosestNode).distinct().toList(),new HashSet<>(to.stream().map(Snap::getClosestNode).toList()),stations,full,initial,deadline,maxLabels,lowerBound);
  }
  phases.put("alternativeSearchSeconds",alternativeSeconds);phases.put("fuelCertificateSeconds",certificateSeconds);phases.put("fuelRepairSeconds",repairSeconds);long assemblyAt=System.nanoTime();
  Map<String,Object> out=new LinkedHashMap<>();out.put("phases",phases);out.put("repair",repairDiagnostics);out.put("portfolio",portfolio);out.put("portfolioSearchComplete",portfolio.isEmpty()?null:portfolio.size()==(q.path("hybrid").asBoolean(false)?2:7)&&portfolio.stream().allMatch(x->Boolean.TRUE.equals(x.get("complete"))));out.put("state",result.state());out.put("reason",result.reason());out.put("seconds",(System.nanoTime()-begin)/1e9);out.put("labels",result.labels());out.put("expanded",result.expanded());out.put("distance",result.meters());out.put("weight",result.cost()*costScale);out.put("remainingUsableMeters",result.remaining());out.put("escapeStation",result.escapeStation());out.put("steps",fuelSteps(graph,result.steps()));out.put("escape",fuelSteps(graph,result.escape()));out.put("matchedStations",bindings.size());out.put("roadVisited",roadVisited);out.put("roadFailures",roadFailures);out.put("roadBestDistance",best==null?null:best.getDistance());out.put("roadSourceKeys",best==null?List.of():best.calcEdges().stream().map(e->List.of(e.getEdge(),e.get(getEncodingManager().getIntEncodedValue("source_edge")))).toList());out.put("stationAccessEvidence","legal_road_projection");out.put("internalCostScale",costScale);
  if(q.path("hybrid").asBoolean(false)&&best!=null){
   List<FuelSearch.Step> roadSteps=best.calcEdges().stream().map(e->new FuelSearch.Step(e.getEdge(),e.getBaseNode(),e.getAdjNode(),e.getDistance(),null)).toList();
   out.put("roadCandidate",Map.of("state","found","alternativesComplete",roadComplete,"distance",best.getDistance(),"weight",best.getWeight()*costScale,"steps",fuelSteps(graph,roadSteps),"fuelStatus","unverified"));
  }
  phases.put("geometryAssemblySeconds",(System.nanoTime()-assemblyAt)/1e9);out.put("seconds",(System.nanoTime()-begin)/1e9);
  return out;
 }
 List<Map<String,Object>> fuelSteps(QueryGraph graph,List<FuelSearch.Step> steps){
  List<Map<String,Object>> out=new ArrayList<>();var source=getEncodingManager().getIntEncodedValue("source_edge");
  for(var step:steps){if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException("request_cancelled");Map<String,Object> row=new LinkedHashMap<>();row.put("meters",step.meters());row.put("from",step.from());row.put("to",step.to());row.put("engineEdge",step.edge());
   if(step.refill()!=null)row.put("refill",step.refill());else{var e=graph.getEdgeIteratorState(step.edge(),step.to());row.put("sourceKey",e.get(source));row.put("surfaceKind",e.get(getEncodingManager().getIntEncodedValue("surface_kind")));row.put("pavedBackroadCost",step.meters()*e.get(getEncodingManager().getIntEncodedValue("paved_factor")));row.put("geometry",e.fetchWayGeometry(FetchMode.ALL).toLineString(false).toString());}out.add(row);
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
 static long requestBudgetMillis(JsonNode q){
  if(!q.has("timeoutMillis"))return 90000;
  if(!q.path("timeoutMillis").isIntegralNumber())throw new IllegalArgumentException("timeoutMillis must be an integer");
  long value=q.path("timeoutMillis").asLong();if(value<1||value>90000)throw new IllegalArgumentException("timeoutMillis must be1..90000");return value;
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
