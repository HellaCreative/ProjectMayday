const test=require('node:test'),assert=require('node:assert/strict');
const {regionalHopOwner}=require('./regional-hop-owner');const {allows}=require('./v4-access-policy');
test('middle hop follows both seam memberships, not polygon side',()=>{
 for(const [a,b,c] of [['ns','nb','me'],['ns','nb','qc'],['ca','or','wa'],['bc','wa','or']])
  assert.equal(regionalHopOwner({between:[a,b]},{between:[b,c]},a),b);
 assert.equal(regionalHopOwner({resolvedRegionId:'ns'},{between:['nb','ns']},'ns'),'ns');
 assert.equal(regionalHopOwner({between:['nb','me']},{resolvedRegionId:'me'},'nb'),'me');
 assert.throws(()=>regionalHopOwner({between:['ns','nb']},{between:['ca','or']},'ns'));
});
test('V4 directional permission overrides contradictory aggregate classification',()=>{
 const p={edgeFrom:[0],edgeTo:[1],edgeAccess:[0,1],edgeAttrs:[65535]};
 assert.equal(allows(p,0,0,1,false),true);assert.equal(allows(p,0,1,0,false),false);assert.equal(allows(p,0,1,0,true),true);
 for(const code of [2,5]){p.edgeAccess=[code,code];assert.equal(allows(p,0,0,1,true),false);}
 p.edgeAccess=[4,4];assert.equal(allows(p,0,0,1,true),false);assert.equal(allows(p,0,0,1,true,0),true);
});
