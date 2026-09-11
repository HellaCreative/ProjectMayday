"""Bounded local engine build/run, process-group RSS and disk reserve recorded."""
import argparse,json,os,pathlib,resource,signal,subprocess,time,shutil
p=argparse.ArgumentParser();p.add_argument('--out',required=True);p.add_argument('--seconds',type=int,default=1200);p.add_argument('--rss-mib',type=int,default=4096);p.add_argument('command',nargs=argparse.REMAINDER);a=p.parse_args()
cmd=a.command[1:] if a.command[0]=='--' else a.command
out=pathlib.Path(a.out);out.parent.mkdir(parents=True,exist_ok=True)
started=time.time();samples=[];failure=None
with out.with_suffix('.log').open('w') as log:
 child=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 while child.poll() is None:
  raw=subprocess.run(['ps','-axo','pgid=,rss='],capture_output=True,text=True).stdout
  rss=sum(int(row.split()[1])*1024 for row in raw.splitlines() if len(row.split())==2 and row.split()[0]==str(child.pid))
  free=shutil.disk_usage(out.parent).free;samples.append({'elapsedSeconds':time.time()-started,'rssBytes':rss,'diskFreeBytes':free})
  if rss>a.rss_mib*1048576:failure='process_group_rss_budget'
  elif free<4*1024**3:failure='four_gib_disk_reserve'
  elif time.time()-started>a.seconds:failure='wall_time_budget'
  if failure:
   os.killpg(child.pid,signal.SIGTERM)
   try:child.wait(10)
   except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
   break
  time.sleep(1)
 usage=resource.getrusage(resource.RUSAGE_CHILDREN)
result={'command':cmd,'cwd':os.getcwd(),'seconds':time.time()-started,'returncode':child.returncode,'guardFailure':failure,'sampledGroupPeakMiB':max((s['rssBytes'] for s in samples),default=0)/1048576,'samples':samples,'childUsage':dict(zip(['userSeconds','systemSeconds','maxRss','integralShared','integralData','integralStack','minorFaults','majorFaults','swaps','inputBlocks','outputBlocks','messagesSent','messagesReceived','signals','voluntarySwitches','involuntarySwitches'],usage)),'limits':{'rssMiB':a.rss_mib,'seconds':a.seconds,'diskReserveGiB':4},'scope':'RSS includes this process group only, sampled each second. getrusage children also includes sampler processes; block counters are not exact mmap bytes.'}
out.write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k not in ['samples','childUsage','command']}),flush=True)
raise SystemExit(child.returncode or bool(failure))
