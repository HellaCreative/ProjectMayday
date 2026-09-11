"""Local bounded worker batch; immutable data copied per worker, no new service."""
import json,os,pathlib,subprocess,time,statistics,random
root=pathlib.Path(os.environ.get('CAPACITY_OUTPUT_ROOT','/tmp/dirt-performance-capacity'));root.mkdir(exist_ok=True)
cases=['ns-short-balanced-road','ns-long-dirt-road','nsnb-balanced-road','qc-long-balanced-road','ns-short-cleanest-fuel','ns-short-partial-tank']
jobs=cases*8;random.Random(761).shuffle(jobs)
physical=int(subprocess.check_output(['sysctl','-n','hw.memsize'],text=True))
prior_peak=None
counts=[int(x) for x in os.environ.get('CAPACITY_WORKERS','1,2,4').split(',')]
if any(x not in [1,2,4] for x in counts):raise ValueError('Bounded worker counts are 1, 2 or 4')
for count in counts:
 if prior_peak and prior_peak*count>physical*.35:
  (root/('workers-'+str(count)+'-not-run.json')).write_text(json.dumps({'reason':'conservative35%physical-memory allowance for workers','predictedBytes':prior_peak*count,'physicalBytes':physical}));break
 assignments=[[] for _ in range(count)];weights=[0]*count
 for job in jobs:
  i=min(range(count),key=lambda i:weights[i]);assignments[i].append(job);weights[i]+=7 if job.startswith('qc-') else 1
 started=time.time()*1000;workers=[]
 for i,workload in enumerate(assignments):
  stem=root/('workers-'+str(count)+'-'+str(i));inp=pathlib.Path(str(stem)+'.workload.json');inp.write_text(json.dumps(workload));out=pathlib.Path(str(stem)+'.json');log=open(str(stem)+'.log','w')
  env=dict(os.environ,PERFORMANCE_WORKLOAD=str(inp));p=subprocess.Popen(['node','scripts/pack-fabric/bench/compare-routing-preparation.js',workload[0],'runtime-candidate',str(out),'1'],env=env,stdout=log,stderr=subprocess.STDOUT)
  workers.append((p,out,log))
 peak_sum=0
 while any(p.poll() is None for p,_,_ in workers):
  active=[str(p.pid) for p,_,_ in workers if p.poll() is None]
  if active:
   r=subprocess.run(['ps','-o','rss=','-p',','.join(active)],capture_output=True,text=True)
   peak_sum=max(peak_sum,sum(int(x) for x in r.stdout.split() if x.isdigit())*1024)
  time.sleep(.2)
 ended=time.time()*1000;runs=[];peaks=[]
 for p,out,log in workers:
  log.close()
  if p.returncode:raise RuntimeError('Worker failed; inspect '+str(out))
  d=json.load(out.open());runs+=d['runs'];peaks.append(max(r['peakRoutingMiB'] for r in d['runs'])*1048576)
 if len(runs)!=len(jobs) or not all(r['complete'] for r in runs):raise RuntimeError('Incomplete capacity batch')
 prior_peak=max(peaks)
 service=[r['ms'] for r in runs];latency=[r['runEndedAt']-started for r in runs]
 result={'workers':count,'requests':len(runs),'seconds':(ended-started)/1000,'requestsPerSecond':len(runs)*1000/(ended-started),'sampledAggregatePeakMiB':peak_sum/1048576,'sumWorkerHighWaterMiB':sum(peaks)/1048576,'serviceMedianMs':statistics.median(service),'batchCompletionP95Ms':sorted(latency)[int(.95*(len(latency)-1))],'queueMedianMs':statistics.median(r['runStartedAt']-started for r in runs),'physicalBytes':physical,'scope':'48 queued mixed local requests; naturally collected Node workers, no forced GC. Static balanced assignment; no shared-memory mapping. Observed batch percentile, not a sustainable production p95.'}
 (root/('workers-'+str(count)+'-summary.json')).write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
