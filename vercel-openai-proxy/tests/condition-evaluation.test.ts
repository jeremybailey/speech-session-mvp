import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {evaluationPlan,assessConditionCase} from '../scripts/condition-evaluation';
test('evaluation covers production request building and rejects empty results',async()=>{
  const cases=[];
  for(const file of ['evaluation.json','context-evaluation.json']) cases.push(...JSON.parse(await readFile(`../Tests/Fixtures/ConditionSynthesis/${file}`,'utf8')));
  const contract={instructions:'Offline contract fixture',response_format:{type:'json_schema',json_schema:{name:'fixture',strict:true,schema:{type:'object',properties:{},additionalProperties:false}}}};
  for(const fixture of cases) {
    assert.ok(evaluationPlan(fixture,{mapping:contract,verification:contract}).batches.length);
    assert.ok(assessConditionCase(fixture,{groups:[],unassigned:[]}).includes('invalid_coverage'));
  }
});
