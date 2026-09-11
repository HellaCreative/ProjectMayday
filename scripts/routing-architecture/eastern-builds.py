"""Sequential resource-bounded imports; continue independent engines after a failure."""
import pathlib,subprocess,json,time
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');here=pathlib.Path(__file__).resolve().parent;py=str(r/'tools/venv/bin/python')
while not (r/'results/gh-eastern-import-v2.json').exists():time.sleep(1)
jobs=[('gh-verified-nsnb-import',['/opt/homebrew/opt/openjdk/bin/java','-Xmx1g','-cp',str(r/'tools/gh-adapter')+':'+str(r/'tools/graphhopper-web-11.0.jar'),'VerifiedHopper',str(r/'data/verified-nsnb/verified-input.json'),str(r/'data/gh-verified-nsnb-directed-v1')]),('osrm-eastern-extract',[py,'-m','osrm','extract','-t','2','-p',str(r/'sources/osrm/profiles/car.lua'),str(r/'data/eastern-260907.osm.pbf')]),('osrm-eastern-partition',[py,'-m','osrm','partition','-t','2',str(r/'data/eastern-260907.osrm')]),('osrm-eastern-customize',[py,'-m','osrm','customize','-t','2',str(r/'data/eastern-260907.osrm')]),('valhalla-eastern-admins',[str(r/'sources/valhalla/build/valhalla_build_admins'),'-c',str(r/'tools/valhalla-eastern.json'),str(r/'data/eastern-260907.osm.pbf')]),('valhalla-eastern-tiles',[str(r/'sources/valhalla/build/valhalla_build_tiles'),'-c',str(r/'tools/valhalla-eastern.json'),str(r/'data/eastern-260907.osm.pbf')])]
fail=set()
for name,cmd in jobs:
 if name=='osrm-eastern-partition' and 'osrm-eastern-extract' in fail:continue
 if name=='osrm-eastern-customize' and ('osrm-eastern-extract' in fail or 'osrm-eastern-partition' in fail):continue
 p=subprocess.run([py,str(here/'guarded-run.py'),'--out',str(r/'results'/f'{name}.json'),'--seconds','1800','--',*cmd],stdin=subprocess.DEVNULL)
 if p.returncode:fail.add(name)
print(json.dumps({'failed':sorted(fail)}),flush=True)
