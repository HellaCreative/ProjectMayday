"""Generate only isolated synthetic OSM and config; no published map edits."""
import json,pathlib,xml.etree.ElementTree as X
ROOT=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911')
out=ROOT/'valhalla-spike';out.mkdir(exist_ok=True)
r=X.Element('osm',version='0.6',generator='DIRT isolated compatibility fixture')
nodes={1:(45,-63.002),2:(45,-63),3:(45,-62.99),4:(45,-62.98),5:(45,-62.978),6:(45.006,-62.99),11:(45.03,-63.002),12:(45.03,-63),13:(45.03,-62.99),14:(45.03,-62.98),15:(45.03,-62.978),16:(45.037,-62.985)}
for n,(lat,lon) in nodes.items():X.SubElement(r,'node',id=str(n),lat=str(lat),lon=str(lon),version='1')
def way(i,ns,**tags):
 w=X.SubElement(r,'way',id=str(i),version='1')
 for n in ns:X.SubElement(w,'nd',ref=str(n))
 for k,v in dict(highway='unclassified',surface='asphalt',maxspeed='30',motorcycle='yes',name=str(i),**tags).items():X.SubElement(w,'tag',k=k,v=v)
way(101,[1,2]);way(102,[2,3,4]);way(103,[4,5])
# same road class/speed isolates surface preference. Gravel alternative is longer.
w=X.SubElement(r,'way',id='104',version='1')
for n in [2,6,4]:X.SubElement(w,'nd',ref=str(n))
for k,v in dict(highway='unclassified',surface='gravel',maxspeed='30',motorcycle='yes',name='104').items():X.SubElement(w,'tag',k=k,v=v)
way(201,[11,12,13]);way(202,[13,14]);way(203,[14,15]);way(204,[13,16,14])
rel=X.SubElement(r,'relation',id='301',version='1')
for role,ref in [('from',201),('via',202),('to',203)]:X.SubElement(rel,'member',type='way',ref=str(ref),role=role)
for k,v in {'type':'restriction','restriction':'no_straight_on'}.items():X.SubElement(rel,'tag',k=k,v=v)
X.ElementTree(r).write(out/'fixture.osm',encoding='utf-8',xml_declaration=True)
c=json.loads((ROOT/'tools/valhalla-atlantic.json').read_text());c['mjolnir'].update(tile_dir=str(out/'tiles'),concurrency=1,id_table_size=10000,admin='',timezone='',max_cache_size=16*1024*1024,hierarchy=False,shortcuts=False);c['logging']['type']=''
(out/'config.json').write_text(json.dumps(c,indent=2))
print(out)
