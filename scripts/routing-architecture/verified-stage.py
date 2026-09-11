"""Prioritize verified integration at native stage boundary, without overlapping measurements."""
import pathlib,subprocess,time,json
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');here=pathlib.Path(__file__).resolve().parent;py=str(r/'tools/venv/bin/python')
while not (r/'results/osrm-eastern-extract.json').exists():time.sleep(1)
def run(name,cmd,seconds=600):
 return subprocess.run([py,str(here/'guarded-run.py'),'--out',str(r/'results'/f'{name}.json'),'--seconds',str(seconds),'--',*cmd],stdin=subprocess.DEVNULL).returncode
cmd=['/opt/homebrew/opt/openjdk/bin/java','-Xmx1g','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',str(r/'data/verified-nsnb/verified-input.json'),str(r/'data/gh-verified-nsnb-directed-v2')]
if run('gh-verified-nsnb-import-v2',cmd,600)==0:
 run('gh-verified-nsnb-road-smoke-guard',[py,str(here/'verified-bench.py'),'--case','nsnb-balanced-road','--repeat','1','--out',str(r/'results/verified-nsnb-road-smoke.json')],600)
print('Verified stage finished; inspect results, then resume eastern driver PID75626 with SIGCONT.',flush=True)
