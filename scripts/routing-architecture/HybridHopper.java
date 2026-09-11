// Local JSON-lines integration boundary. No live API or product profile aliases.
import java.nio.file.Path;
import java.io.*;
import java.util.*;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
public final class HybridHopper {
 static Map<String,Object> route(VerifiedHopper hopper,JsonNode input){
  if(input.has("arrivalHistory"))throw new IllegalArgumentException("Continuation import unsupported; history cannot be discarded");
  ObjectNode q=input.deepCopy();q.put("hybrid",true);
  Map<String,Object> envelope=new LinkedHashMap<>();envelope.put("engine","dirt-graphhopper-hybrid-v1");envelope.put("sourceIdentity",hopper.identity);
  envelope.put("navigationReady",false);envelope.put("candidatePolicy","preferred_road_then_bounded_first_feasible_fuel_repair");
  envelope.put("profile",q.path("profile").asText("distance"));envelope.put("productProfileParity",false);
  if(!q.has("fuel")){
   var road=hopper.directedRoute(q);envelope.put("road",road);envelope.put("fuel",Map.of("status","not_requested"));
   envelope.put("state",road.containsKey("distance")?"road_only":"incomplete");return envelope;
  }
  q.put("fuelRepair",true);q.put("fuelPortfolio",true);q.put("portfolioOnly",true);
  var fuel=hopper.fuelRoute(q);boolean verified="found".equals(fuel.get("state"));
  envelope.put("state",verified?"fuel_verified":"fuel_unresolved");
  envelope.put("road",fuel.remove("roadCandidate"));envelope.put("fuel",fuel);
  envelope.put("navigationReady",false);envelope.put("stationEvidence","legal_road_projection_only");
  return envelope;
 }
 public static void main(String[] args)throws Exception{
  try(var hopper=new VerifiedHopper(Path.of(args[0]),Path.of(args[1]))){
   hopper.importOrLoad();hopper.indexSourceCopies();System.out.println("READY hybrid-v1");System.out.flush();
   var reader=new BufferedReader(new InputStreamReader(System.in));String line;
   while((line=reader.readLine())!=null){try{System.out.println("RESULT "+VerifiedHopper.JSON.writeValueAsString(route(hopper,VerifiedHopper.JSON.readTree(line))));}
    catch(Exception e){System.out.println("RESULT "+VerifiedHopper.JSON.writeValueAsString(Map.of("state","error","error",e.toString())));}System.out.flush();}
  }
 }
}
