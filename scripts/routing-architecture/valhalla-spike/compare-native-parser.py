"""Tiny native old/new parser comparison. Run under256MiB guard, no regional import."""
import pathlib,json,hashlib,subprocess,xml.etree.ElementTree as X
root=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911');out=root/'valhalla-spike';r=X.parse(out/'fixture.osm').getroot()
for k in range(12):X.SubElement(r,'node',id=str(1000+k),lat=str(45.06+.002*(k//3)),lon=str(-63+.002*(k%3)),version='1')
for i,ns in enumerate([[1000,1001,1002,1000],[1000,1003],[1004,1005,1006,1004],[1004,1007],[1005,1008],[1009,1010,1011,1009]]):
 w=X.SubElement(r,'way',id=str(2000+i),version='1')
 for n in ns:X.SubElement(w,'nd',ref=str(n))
 for k,v in {'highway':'residential','surface':'asphalt','motorcycle':'yes'}.items():X.SubElement(w,'tag',k=k,v=v)
# OSM parsers expect entity type/id ordering.
r[:]=sorted(r,key=lambda e:({'node':0,'way':1,'relation':2}[e.tag],int(e.attrib['id'])))
X.ElementTree(r).write(out/'fixture-culdesac.osm',encoding='utf-8',xml_declaration=True)
subprocess.run(['osmium','cat',str(out/'fixture-culdesac.osm'),'-o',str(out/'fixture-culdesac.osm.pbf'),'--overwrite'],check=True)
files={};commands=[]
for name,binary in [('original',root/'sources/valhalla/build/valhalla_build_tiles'),('streaming',out/'valhalla_build_tiles_streaming')]:
 config=json.loads((out/'config.json').read_text());config['mjolnir']['tile_dir']=str(out/('tiny-parseways-'+name));cp=out/('tiny-parseways-'+name+'.json');cp.write_text(json.dumps(config,indent=2));cmd=[str(binary),'-c',str(cp),'--end','parseways',str(out/'fixture-culdesac.osm.pbf')];commands.append(cmd)
 with (out/('tiny-parseways-'+name+'.log')).open('w') as f:subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,check=True)
 files[name]={str(p.relative_to(config['mjolnir']['tile_dir'])):hashlib.sha256(p.read_bytes()).hexdigest() for p in pathlib.Path(config['mjolnir']['tile_dir']).rglob('*') if p.is_file()}
# Timing stats are expected to differ, while all parser outputs must agree.
differences=[f for f in set(files['original'])|set(files['streaming']) if files['original'].get(f)!=files['streaming'].get(f)]
report={'commands':commands,'sha256':files,'differences':differences,'inputSha256':hashlib.sha256((out/'fixture-culdesac.osm.pbf').read_bytes()).hexdigest()};(out/'native-parser-comparison.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
assert not differences,differences
