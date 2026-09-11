// Private shared-graph service: bounded queue, request deadlines and cancellation.
import java.nio.file.Path;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

public final class ConcurrentVerifiedHopper {
 static void emit(String kind,Object value){try{synchronized(System.out){System.out.println(kind+" "+VerifiedHopper.JSON.writeValueAsString(value));}}catch(IOException e){throw new UncheckedIOException(e);}}
 static final class Service implements AutoCloseable {
  final VerifiedHopper hopper;final ThreadPoolExecutor pool;
  final ConcurrentHashMap<String,Job> jobs=new ConcurrentHashMap<>();
  final AtomicInteger active=new AtomicInteger(),peak=new AtomicInteger();
  Service(VerifiedHopper hopper,int workers){this.hopper=hopper;pool=new ThreadPoolExecutor(workers,workers,0,TimeUnit.SECONDS,new ArrayBlockingQueue<>(8));}
  final class Job implements Runnable {
   final String id;final ObjectNode query;final long submitted=System.nanoTime(),budgetMillis;
   final AtomicBoolean terminal=new AtomicBoolean();volatile boolean cancelled;volatile Thread runner;
   Job(String id,ObjectNode query){this.id=id;this.query=query;budgetMillis=VerifiedHopper.requestBudgetMillis(query);}
   synchronized void finish(Map<String,Object> response){if(terminal.compareAndSet(false,true)){if(cancelled){response.remove("result");response.put("error","cancelled");}jobs.remove(id,this);response.put("requestId",id);emit("RESULT",response);}}
   synchronized boolean cancel(){if(terminal.get())return false;cancelled=true;Thread t=runner;if(t!=null)t.interrupt();else if(pool.remove(this))finish(new LinkedHashMap<>(Map.of("error","cancelled","queueSeconds",(System.nanoTime()-submitted)/1e9)));return true;}
   public void run(){
    runner=Thread.currentThread();long started=System.nanoTime();
    Map<String,Object> response=new LinkedHashMap<>();response.put("queueSeconds",(started-submitted)/1e9);
    long remaining=budgetMillis-(started-submitted)/1000000;
    if(cancelled||remaining<=0){response.put("error",cancelled?"cancelled":"queue_deadline");runner=null;Thread.interrupted();finish(response);return;}
    query.put("timeoutMillis",remaining);int count=active.incrementAndGet();peak.accumulateAndGet(count,Math::max);response.put("routingCallsAtStart",count);
    try{response.put("result",query.path("hybrid").asBoolean(false)?HybridHopper.route(hopper,query):query.has("fuel")?hopper.fuelRoute(query):hopper.directedRoute(query));}
    catch(Exception ex){response.put("error",ex.toString());}
    finally{active.decrementAndGet();runner=null;response.put("peakConcurrentRoutingCalls",peak.get());response.put("executionSeconds",(System.nanoTime()-started)/1e9);
     if(cancelled||Thread.currentThread().isInterrupted()){response.remove("result");response.put("error","cancelled");}
     Thread.interrupted();finish(response);
    }
   }
  }
  void accept(JsonNode input){
   if(input.has("memorySnapshotId")){
    String id=input.path("memorySnapshotId").asText();
    if(!jobs.isEmpty()){emit("CONTROL",Map.of("memorySnapshotId",id,"error","service_not_idle"));return;}
    var before=HybridTelemetry.read();boolean gc=input.path("requestGc").asBoolean(false);if(gc)System.gc();
    emit("CONTROL",Map.of("memorySnapshotId",id,"explicitGcRequested",gc,"resources",HybridTelemetry.finish(before)));return;
   }
   if(input.has("cancelRequestId")){String id=input.path("cancelRequestId").asText();Job job=jobs.get(id);boolean accepted=job!=null&&job.cancel();emit("CONTROL",Map.of("cancelRequestId",id,"accepted",accepted));return;}
   String id=input.path("requestId").asText();if(id.isEmpty()||!input.isObject())throw new IllegalArgumentException("requestId and object required");
   var job=new Job(id,input.deepCopy());if(jobs.putIfAbsent(id,job)!=null){emit("CONTROL",Map.of("requestId",id,"error","duplicate_request_id"));return;}
   try{pool.execute(job);}catch(RejectedExecutionException ex){job.finish(new LinkedHashMap<>(Map.of("error","bounded_queue_full")));}
  }
  public void close()throws InterruptedException{
   pool.shutdown();if(!pool.awaitTermination(180,TimeUnit.SECONDS)){
    for(var job:jobs.values())job.cancel();pool.shutdownNow();if(!pool.awaitTermination(100,TimeUnit.SECONDS))throw new IllegalStateException("Workers did not stop");
   }
  }
 }
 public static void main(String[] args)throws Exception{
  int workers=Integer.parseInt(args[2]);if(workers<1||workers>4)throw new IllegalArgumentException("workers1..4");
  try(var hopper=new VerifiedHopper(Path.of(args[0]),Path.of(args[1]))){
   long started=System.nanoTime();hopper.importOrLoad();hopper.indexSourceCopies();
   try(var service=new Service(hopper,workers);var input=new BufferedReader(new InputStreamReader(System.in))){
    System.out.println("READY "+(System.nanoTime()-started)/1e9);String line;
    while((line=input.readLine())!=null)try{service.accept(VerifiedHopper.JSON.readTree(line));}catch(Exception e){emit("CONTROL",Map.of("error","invalid_request","detail",e.toString()));}
   }
  }
 }
}
