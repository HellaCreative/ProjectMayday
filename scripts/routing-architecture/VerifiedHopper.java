// Private architecture experiment. Imports verified immutable DIRT topology into GH.
// Not a product engine or a published pack builder.
import com.graphhopper.*;
import com.graphhopper.config.*;
import com.graphhopper.routing.*;
import java.nio.file.Path;
import com.graphhopper.routing.querygraph.QueryGraph;
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
 VerifiedHopper(Path descriptor,Path target) throws Exception {
  this.descriptor=descriptor;input=JSON.readTree(descriptor.toFile());
  for(String n:List.of("edgeSurfaceLeaf","edgeRoadClassLeaf","edgeAccess"))if(!input.path("sections").path(n).path("type").asText().equals("Uint8Array"))throw new IOException("Unexpected section type "+n);
  if(!input.path("sections").path("edgeMeters").path("type").asText().equals("Uint32Array"))throw new IOException("Unexpected meters type");
  DefaultImportRegistry defaults=new DefaultImportRegistry();
  setImportRegistry(name -> switch(name) {
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
  c.putObject("graph.encoded_values","source_edge,dirt_access,surface_kind,paved_factor,dirt_factor");
  c.putObject("prepare.ch.threads",1);c.putObject("prepare.lm.threads",1);c.putObject("prepare.lm.landmarks",16);
  c.putObject("routing.max_visited_nodes",12000000);
  c.setProfiles(NAMES.stream().map(n->new Profile(n).setWeighting("custom").setTurnCostsConfig(new TurnCostsConfig(List.of("motorcycle"),0))).toList());
  // LM is prepared on the distance lower bound, with all endpoint/unknown access.
  c.setLMProfiles(NAMES.stream().map(n->n.equals("distance")?new LMProfile(n):new LMProfile(n).setPreparationProfile("distance")).toList());
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
   IntEncodedValue source=em.getIntEncodedValue("source_edge"),access=em.getIntEncodedValue("dirt_access"),surface=em.getIntEncodedValue("surface_kind"),paved=em.getIntEncodedValue("paved_factor"),dirt=em.getIntEncodedValue("dirt_factor");
   ByteBuffer xy=section("nodeCoords"),from=section("edgeFrom"),to=section("edgeTo"),meters=section("edgeMeters"),a=section("edgeAccess"),s=section("edgeSurfaceLeaf"),roads=section("edgeRoadClassLeaf"),regions=section("sourceRegions"),local=section("sourceEdges");
   List<ByteBuffer> geometries=new ArrayList<>();for(JsonNode p:input.path("geometryPaths"))geometries.add(map(Path.of(p.asText())));
   int nodes=input.path("nodeCount").asInt(),edges=input.path("edgeCount").asInt();
   for(int n=0;n<nodes;n++)g.getNodeAccess().setNode(n,xy.getFloat(n*8+4),xy.getFloat(n*8));
   for(int e=0;e<edges;e++) for(int direction=0;direction<2;direction++) {
    int kind=input.path("surfaceKinds").get(Byte.toUnsignedInt(s.get(e))).asInt();
    String road=input.path("roadClasses").get(Byte.toUnsignedInt(roads.get(e))).asText();
    int pf=switch(road){case "primary","primary_link"->4;case "trunk","trunk_link"->8;case "motorway","motorway_link","freeway"->32;case "service"->6;default->1;};
    int df=Set.of("motorway","motorway_link","freeway").contains(road)?8:1;
    EdgeIteratorState edge=g.edge(direction==0?from.getInt(e*4):to.getInt(e*4),direction==0?to.getInt(e*4):from.getInt(e*4)).setDistance(Integer.toUnsignedLong(meters.getInt(e*4)));
    if(edge.getEdge()!=e*2+direction)throw new IllegalStateException("source edge ID drift");
    edge.set(source,e*2+direction).set(access,Byte.toUnsignedInt(a.get(e*2+direction)),2).set(surface,kind).set(paved,pf*(kind==0?1:100)).set(dirt,df);
    ByteBuffer geom=geometries.get(Short.toUnsignedInt(regions.getShort(e*2)));int id=local.getInt(e*4),count=geom.getInt(8);boolean doubles=(geom.getShort(6)&1)!=0;
    int start=geom.getInt(16+id*4),end=geom.getInt(20+id*4),coords=16+(count+1)*4;coords=(coords+(doubles?7:3))&~(doubles?7:3);
    PointList line=new PointList(Math.max(0,(end-start)/2-2),false);
    for(int i=start+2;i<end-2;i+=2)line.add(doubles?geom.getDouble(coords+(i+1)*8):geom.getFloat(coords+(i+1)*4),doubles?geom.getDouble(coords+i*8):geom.getFloat(coords+i*4));
    if(direction==1)line.reverse();edge.setWayGeometry(line);
   }
   List<IntArrayList> keys=new ArrayList<>(),via=new ArrayList<>();List<com.carrotsearch.hppc.BitSet> bits=new ArrayList<>();
   for(JsonNode r:input.path("restrictions")){IntArrayList k=new IntArrayList(),n=new IntArrayList();r.path("keys").forEach(x->k.add(x.asInt()*2));r.path("viaNodes").forEach(x->n.add(x.asInt()));keys.add(k);via.add(n);com.carrotsearch.hppc.BitSet b=new com.carrotsearch.hppc.BitSet();b.set(0,NAMES.size());bits.add(b);}
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
 List<Snap> snaps(JsonNode point,Weighting w) {
  double lat=point.get(1).asDouble(),lon=point.get(0).asDouble();var source=getEncodingManager().getIntEncodedValue("source_edge");
  Snap first=getLocationIndex().findClosest(lat,lon,e->Double.isFinite(w.calcEdgeWeight(e,false))||Double.isFinite(w.calcEdgeWeight(e,true)));
  if(!first.isValid()||first.getQueryDistance()>2000)throw new IllegalArgumentException("No legal endpoint within 2000m");
  int other=first.getClosestEdge().get(source)^1;
  Snap second=getLocationIndex().findClosest(lat,lon,e->e.get(source)==other&&(Double.isFinite(w.calcEdgeWeight(e,false))||Double.isFinite(w.calcEdgeWeight(e,true))));
  return second.isValid()?List.of(first,second):List.of(first);
 }
 Map<String,Object> directedRoute(JsonNode q) {
  long started=System.nanoTime();String name=q.path("profile").asText("distance");
  Weighting w=createWeighting(getProfile(name),new PMap().putObject("allow_unknown",q.path("allowUnknown").asBoolean(false)).putObject("wander",q.path("wander").asDouble(1)));
  List<Snap> from=snaps(q.path("start"),w),to=snaps(q.path("end"),w),all=new ArrayList<>(from);all.addAll(to);
  QueryGraph graph=QueryGraph.create(getBaseGraph(),all);long prepared=System.nanoTime();
  boolean flexible=q.path("flexible").asBoolean(false);
  RoutingAlgorithmFactory factory=flexible?new RoutingAlgorithmFactorySimple():new LMRoutingAlgorithmFactory(getLandmarks().get(name));
  AlgorithmOptions options=new AlgorithmOptions().setAlgorithm(flexible?"dijkstrabi":"astarbi").setTraversalMode(TraversalMode.EDGE_BASED).setMaxVisitedNodes(12000000).setTimeoutMillis(90000);
  com.graphhopper.routing.Path best=null;int visited=0;List<String> failures=new ArrayList<>();
  for(Snap a:from)for(Snap b:to){var algorithm=factory.createAlgo(graph,w,options);try{var p=algorithm.calcPath(a.getClosestNode(),b.getClosestNode());visited+=algorithm.getVisitedNodes();if(p.isFound()&&(best==null||p.getWeight()<best.getWeight()))best=p;}catch(Exception ex){failures.add(ex.toString());}}
  Map<String,Object> out=new LinkedHashMap<>();out.put("snapSeconds",(prepared-started)/1e9);out.put("seconds",(System.nanoTime()-started)/1e9);out.put("visited",visited);out.put("failures",failures);
  if(best==null){out.put("errors",List.of("No complete path"));return out;}
  // Every directional alternative must finish before claiming the minimum.
  out.put("errors",failures);out.put("distance",best.getDistance());out.put("weight",best.getWeight());out.put("points",best.calcPoints().toLineString(false).toString());
  var source=getEncodingManager().getIntEncodedValue("source_edge");var surface=getEncodingManager().getIntEncodedValue("surface_kind");
  out.put("edges",best.calcEdges().stream().map(e->Map.of("sourceKey",e.get(source),"engineEdge",e.getEdge(),"meters",e.getDistance(),"surfaceKind",e.get(surface),"from",e.getBaseNode(),"to",e.getAdjNode())).toList());return out;
 }
 boolean accepts(JsonNode sequence) {
  if(sequence.isEmpty())return true;
  Set<Integer> states=new HashSet<>();var g=getBaseGraph();var source=getEncodingManager().getIntEncodedValue("source_edge");
  Weighting w=createWeighting(getProfile("distance"),new PMap().putObject("allow_unknown",true));
  for(int pos=0;pos<sequence.size();pos++){
   int key=sequence.get(pos).asInt(),id=key;var original=g.getEdgeIteratorStateForKey(key*2);Set<Integer> next=new HashSet<>();
   var it=g.createEdgeExplorer().setBaseNode(original.getBaseNode());
   while(it.next())if(it.get(source)==id&&it.getAdjNode()==original.getAdjNode()&&Double.isFinite(w.calcEdgeWeight(it,false))){
    if(pos==0)next.add(it.getEdgeKey());
    else for(int previous:states)if(g.getEdgeIteratorStateForKey(previous).getAdjNode()==it.getBaseNode()&&Double.isFinite(w.calcTurnWeight(previous/2,it.getBaseNode(),it.getEdge())))next.add(it.getEdgeKey());
   }
   states=next;
  }
  return !states.isEmpty();
 }
 public static void main(String[] args) throws Exception {
  try(VerifiedHopper h=new VerifiedHopper(Path.of(args[0]),Path.of(args[1]))) {
   long start=System.nanoTime();h.importOrLoad();System.out.println("READY "+(System.nanoTime()-start)/1e9);System.out.flush();
   BufferedReader in=new BufferedReader(new InputStreamReader(System.in));String line;
   while((line=in.readLine())!=null){long t=System.nanoTime();try {
    JsonNode q=JSON.readTree(line);if(q.has("walk")){System.out.println("RESULT "+JSON.writeValueAsString(Map.of("accepted",h.accepts(q.path("walk")))));continue;}if(!q.path("standardApi").asBoolean(false)){System.out.println("RESULT "+JSON.writeValueAsString(h.directedRoute(q)));continue;}GHRequest req=new GHRequest(q.path("start").get(1).asDouble(),q.path("start").get(0).asDouble(),q.path("end").get(1).asDouble(),q.path("end").get(0).asDouble()).setProfile(q.path("profile").asText("distance"));
    req.putHint("ch.disable",true);req.putHint("lm.disable",q.path("flexible").asBoolean(false));req.putHint("allow_unknown",q.path("allowUnknown").asBoolean(false));req.putHint("wander",q.path("wander").asDouble(1));req.putHint("instructions",false);req.putHint("calc_points",true);req.putHint("way_point_max_distance",0);req.setPathDetails(List.of("source_edge","surface_kind","edge_id"));
    GHResponse response=h.route(req);Map<String,Object> out=new LinkedHashMap<>();out.put("seconds",(System.nanoTime()-t)/1e9);out.put("errors",response.getErrors().stream().map(Throwable::toString).toList());out.put("debug",response.getDebugInfo());
    if(!response.hasErrors()){var p=response.getBest();out.put("distance",p.getDistance());out.put("weight",p.getRouteWeight());out.put("details",p.getPathDetails());out.put("points",p.getPoints().toLineString(false).toString());}
    System.out.println("RESULT "+JSON.writeValueAsString(out));
   }catch(Exception e){System.out.println("RESULT "+JSON.writeValueAsString(Map.of("error",e.toString())));}System.out.flush();}
  }
 }
}
