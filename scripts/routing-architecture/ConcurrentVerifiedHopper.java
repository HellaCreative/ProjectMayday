// Private shared-graph worker experiment. Additive/fuel prototype, not product API.
import java.nio.file.Path;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;

public final class ConcurrentVerifiedHopper {
 public static void main(String[] args) throws Exception {
  int workers=Integer.parseInt(args[2]);if(workers<1||workers>4)throw new IllegalArgumentException("workers1..4");
  try(VerifiedHopper h=new VerifiedHopper(Path.of(args[0]),Path.of(args[1]))){
   long init=System.nanoTime();h.importOrLoad();h.indexSourceCopies();
   var pool=new ThreadPoolExecutor(workers,workers,0,TimeUnit.SECONDS,new ArrayBlockingQueue<Runnable>(8));
   var active=new java.util.concurrent.atomic.AtomicInteger();var peak=new java.util.concurrent.atomic.AtomicInteger();
   System.out.println("READY "+(System.nanoTime()-init)/1e9);
   try(BufferedReader input=new BufferedReader(new InputStreamReader(System.in))){
    String line;
    while((line=input.readLine())!=null){
     var q=VerifiedHopper.JSON.readTree(line);String id=q.path("requestId").asText();
     if(id.isEmpty())throw new IllegalArgumentException("requestId required");
     long submitted=System.nanoTime();
     try{pool.execute(()->{
      long started=System.nanoTime();Map<String,Object> response=new LinkedHashMap<>();response.put("requestId",id);response.put("queueSeconds",(started-submitted)/1e9);
      int count=active.incrementAndGet();peak.accumulateAndGet(count,Math::max);response.put("routingCallsAtStart",count);
      try{response.put("result",q.path("hybrid").asBoolean(false)?HybridHopper.route(h,q):q.has("fuel")?h.fuelRoute(q):h.directedRoute(q));}
      catch(Exception ex){response.put("error",ex.toString());}
      finally{active.decrementAndGet();response.put("peakConcurrentRoutingCalls",peak.get());}
      response.put("executionSeconds",(System.nanoTime()-started)/1e9);
      try{synchronized(System.out){System.out.println("RESULT "+VerifiedHopper.JSON.writeValueAsString(response));}}
      catch(Exception ex){throw new RuntimeException(ex);}
     });}catch(RejectedExecutionException ex){System.out.println("RESULT "+VerifiedHopper.JSON.writeValueAsString(Map.of("requestId",id,"error","bounded_queue_full")));}
    }
   }finally{
    pool.shutdown();if(!pool.awaitTermination(180,TimeUnit.SECONDS)){pool.shutdownNow();if(!pool.awaitTermination(100,TimeUnit.SECONDS))throw new IllegalStateException("Workers did not stop");}
   }
  }
 }
}
