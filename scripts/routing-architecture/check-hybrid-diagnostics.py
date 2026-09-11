"""Validate the explicitly used diagnostics-schema keywords against real evidence.
This small check is not a general JSON Schema implementation.
"""
import json,pathlib,math
repo=pathlib.Path(__file__).resolve().parents[2]
schema=json.loads((repo/'docs/experiments/engine-architecture-2026-09-11/hybrid-diagnostics.schema.json').read_text())
def validate(value,s,path='$'):
 if 'const' in s:assert value==s['const'],path
 if 'type' in s:
  types=s['type'] if isinstance(s['type'],list) else [s['type']]
  tests={'integer':isinstance(value,int) and not isinstance(value,bool),'number':isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value),'object':isinstance(value,dict),'string':isinstance(value,str),'null':value is None}
  assert any(tests.get(t,False) for t in types),(path,types,value)
 if isinstance(value,(float,int)) and not isinstance(value,bool) and 'minimum' in s:assert value>=s['minimum'],path
 if isinstance(value,dict):
  assert all(k in value for k in s.get('required',[])),path
  if s.get('additionalProperties') is False:assert set(value)<=set(s.get('properties',{})),path
  for k,v in value.items():
   if k in s.get('properties',{}):validate(v,s['properties'][k],path+'.'+k)
r=pathlib.Path('/Users/richardsmith/.codex/experiments/routing-architecture-20260911/results')
count=0
for name in ['hybrid-refined-nsnb.json','hybrid-refined-wv.json','hybrid-strong-lm-wv.json','hybrid-qc-matrix.json']:
 for x in json.loads((r/name).read_text())['runs']:
  result=x['result'];validate({k:result[k] for k in ['resources','phases']},schema);count+=1
print(f'{count} measured diagnostics records pass the documented schema fields, units and nullability checks.')
