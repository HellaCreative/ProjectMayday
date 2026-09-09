"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {loadRegionRows}=require('./live-canary');
test('start both regional loads before either resolves and retain requested order',async()=>{
 const pending=new Map(),started=[];
 const result=loadRegionRows(['ns','nb'],id=>{started.push(id);return new Promise(resolve=>pending.set(id,resolve));});
 assert.deepEqual(started,['ns','nb']);
 pending.get('nb')({region:'nb',release:'02'});
 pending.get('ns')({region:'ns',release:'02'});
 assert.deepEqual(await result,[{region:'ns',release:'02'},{region:'nb',release:'02'}]);
});
test('a failed regional load never returns a partial pack list',async()=>{
 await assert.rejects(loadRegionRows(['ns','nb'],async id=>{if(id==='nb')throw Error('pack unavailable');return {region:id};}),/pack unavailable/);
});
