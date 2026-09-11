"""Bounded objective-specific landmark experiment at a paused native stage boundary."""
import json, os, pathlib, signal, subprocess, time
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
here=pathlib.Path(__file__).resolve().parent
python=str(root/'tools/venv/bin/python')
def run(name,command,seconds=600):
 return subprocess.run([python,str(here/'guarded-run.py'),'--out',str(root/'results'/f'{name}.json'),
  '--seconds',str(seconds),'--rss-mib','2048','--',*command],stdin=subprocess.DEVNULL).returncode==0
try:
 while not (root/'results/eastern-road/osrm-salvage-partition.guard.json').exists():time.sleep(2)
 command=['/opt/homebrew/opt/openjdk/bin/java','-Ddirt.objectiveLandmarks=true','-Xmx1g','-cp',
  str(root/'tools/gh-adapter')+':'+str(root/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',
  str(root/'data/verified-nsnb/verified-input.json'),str(root/'data/gh-verified-nsnb-directed-v2-objective')]
 if run('gh-nsnb-objective-import',command):
  run('gh-nsnb-objective-fuel-guard',[python,str(here/'verified-bench.py'),'--objective-landmarks',
   '--case','nsnb-balanced-road','--repeat','1','--usable-range-meters','180000',
   '--initial-usable-meters','90000','--out',str(root/'results/verified-nsnb-objective-fuel.json')])
finally:
 os.kill(10036,signal.SIGCONT)
 status=root/'results/PAUSED-COMPARISON.json'
 report=json.loads(status.read_text());report.update(mustResume=False,resumed=True);status.write_text(json.dumps(report,indent=2))
 print('Objective stage finished; comparison driver resumed.',flush=True)
