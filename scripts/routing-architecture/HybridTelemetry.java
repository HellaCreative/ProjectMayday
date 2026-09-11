// Process-wide heap sampling and request-thread allocation accounting.
// Mapped capacity is virtual capacity, not resident pages or OS cache usage.
import java.lang.management.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
final class HybridTelemetry {
 static final MemoryMXBean MEMORY=ManagementFactory.getMemoryMXBean();
 static final AtomicLong PEAK=new AtomicLong();
 static final ScheduledExecutorService SAMPLER=Executors.newSingleThreadScheduledExecutor(r->{var t=new Thread(r,"hybrid-memory-sampler");t.setDaemon(true);return t;});
 static {sample();SAMPLER.scheduleAtFixedRate(HybridTelemetry::sample,50,50,TimeUnit.MILLISECONDS);}
 static void sample(){PEAK.accumulateAndGet(MEMORY.getHeapMemoryUsage().getUsed(),Math::max);}
 record Reading(long heapUsed,long heapCommitted,long nonHeapUsed,long mappedCapacity,long directCapacity,long gcCount,long gcMillis,long allocated){}
 static Reading read(){
  sample();var heap=MEMORY.getHeapMemoryUsage();long mapped=0,direct=0,gc=0,millis=0,allocated=-1;
  for(var b:ManagementFactory.getPlatformMXBeans(BufferPoolMXBean.class)){
   if(b.getName().startsWith("mapped"))mapped+=b.getTotalCapacity();else if(b.getName().equals("direct"))direct+=b.getTotalCapacity();
  }
  for(var c:ManagementFactory.getGarbageCollectorMXBeans()){if(c.getCollectionCount()>=0)gc+=c.getCollectionCount();if(c.getCollectionTime()>=0)millis+=c.getCollectionTime();}
  var bean=ManagementFactory.getThreadMXBean();
  if(bean instanceof com.sun.management.ThreadMXBean t&&t.isThreadAllocatedMemorySupported()&&t.isThreadAllocatedMemoryEnabled())allocated=t.getThreadAllocatedBytes(Thread.currentThread().threadId());
  return new Reading(heap.getUsed(),heap.getCommitted(),MEMORY.getNonHeapMemoryUsage().getUsed(),mapped,direct,gc,millis,allocated);
 }
 static Map<String,Object> finish(Reading before){
  var after=read();Map<String,Object> out=new LinkedHashMap<>();
  out.put("schemaVersion",1);out.put("heapUsedBeforeBytes",before.heapUsed());out.put("heapUsedAfterBytes",after.heapUsed());out.put("heapCommittedBytes",after.heapCommitted());out.put("servingLifetimeSampledPeakHeapBytes",PEAK.get());out.put("heapSampleIntervalMillis",50);
  out.put("nonHeapUsedBytes",after.nonHeapUsed());out.put("mappedBufferCapacityBytes",after.mappedCapacity());out.put("directBufferCapacityBytes",after.directCapacity());
  out.put("processGcCollectionsDuringRequest",after.gcCount()-before.gcCount());out.put("processGcMillisDuringRequest",after.gcMillis()-before.gcMillis());
  out.put("requestThreadAllocatedBytes",before.allocated()<0||after.allocated()<0?null:after.allocated()-before.allocated());
  out.put("scope","Heap peak is shared serving lifetime, excludes earlier import. GC deltas include concurrent requests. Mapped capacity is not residency. Allocation is this request thread only, excludes transport serialization.");return out;
 }
}
