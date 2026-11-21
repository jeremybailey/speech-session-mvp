import test from 'node:test';
import assert from 'node:assert/strict';
import {validateSummaryTemporal,supportedSummaryTemporal} from '../api/_lib/summary-temporal';
const evidence=[{id:'e1',text:'Breastfeeding documented Sep 6, 2024. Weakness about 10 years before Sep 2024. Fractures 5–6 years before Sep 2024.'}];
const timing={role:'ongoing',start:'2024-09-06',end:null,approximate:false,sourceQuote:'Breastfeeding documented Sep 6, 2024.',citationIDs:['e1']};
test('point timing requires original evidence, precision and grounded arithmetic',()=>{
 validateSummaryTemporal(timing,['e1'],evidence);
 validateSummaryTemporal({...timing,role:'event',start:'2014',approximate:true,sourceQuote:'Weakness about 10 years before Sep 2024.'},['e1'],evidence);
 validateSummaryTemporal({...timing,role:'event',start:'2018',end:'2019',sourceQuote:'Fractures 5–6 years before Sep 2024.'},['e1'],evidence);
 for(const change of [{start:'2025'},{start:'2024-02-30'},{sourceQuote:'Invented source date 2024'},{citationIDs:['e2']},{role:'unknown'}])assert.throws(()=>validateSummaryTemporal({...timing,...change},['e1'],evidence));
 assert.throws(()=>validateSummaryTemporal({...timing,role:'event',start:'2014',sourceQuote:'Weakness about 10 years before Sep 2024.'},['e1'],evidence));
 assert.throws(()=>validateSummaryTemporal({...timing,role:'event',start:'2024',approximate:true,sourceQuote:'Weakness about 10 years before Sep 2024.'},['e1'],evidence));
 validateSummaryTemporal({role:'unknown',start:null,end:null,approximate:false,sourceQuote:null,citationIDs:[]},['e1'],evidence);
});

test('date quotes match decoded clinical evidence without bridging unrelated fields',()=>{
 const source='Breastfeeding documented\nSep 6, 2024.';
 const encoded=[{id:'e1',text:'Clinical evidence: '+JSON.stringify({source})}];
 validateSummaryTemporal(timing,['e1'],encoded);
 const quoted={...timing,sourceQuote:'"Breastfeeding" documented Sep 6, 2024.'};
 validateSummaryTemporal(quoted,['e1'],[{id:'e1',text:JSON.stringify({source:quoted.sourceQuote})}]);
 assert.throws(()=>validateSummaryTemporal(timing,['e1'],[{id:'e1',text:JSON.stringify({topic:'Breastfeeding documented',date:'Sep 6, 2024.'})}]));
 assert.throws(()=>validateSummaryTemporal({...timing,sourceQuote:'Breastfeeding documented Sep 6, 2025.'},['e1'],encoded));
});

test('unsupported optional timing becomes unknown while supported timing survives',()=>{
 assert.deepEqual(supportedSummaryTemporal(timing,['e1'],evidence),timing);
 for(const bad of [{...timing,sourceQuote:'Invented evidence in 2024'},{...timing,start:'2025'},null]){
  assert.deepEqual(supportedSummaryTemporal(bad,['e1'],evidence),{role:'unknown',start:null,end:null,approximate:false,sourceQuote:null,citationIDs:[]});
 }
});

test('date precision cannot invent a month or day from a supported year',()=>{
 for(const start of ['2024-08-06','2024-09-07'])assert.throws(()=>validateSummaryTemporal({...timing,start},['e1'],evidence));
 for(const quote of ['September 2024','Maybe 6, 2024','Marching 6, 2024']){
  assert.throws(()=>validateSummaryTemporal({...timing,start:'2024-09-06',sourceQuote:quote},['e1'],[{id:'e1',text:quote}]));
 }
 for(const quote of ['September 6, 2024','6 September 2024','2024-09-06']){
  validateSummaryTemporal({...timing,sourceQuote:quote},['e1'],[{id:'e1',text:quote}]);
  validateSummaryTemporal({...timing,start:'2024-09',sourceQuote:quote},['e1'],[{id:'e1',text:quote}]);
 }
 assert.equal(supportedSummaryTemporal({...timing,start:'2024-09-07'},['e1'],evidence).role,'unknown');
});
