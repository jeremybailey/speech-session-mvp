// Offline validation only. Private plans and model output stay under build/.
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {resolve,join} from 'node:path';

async function main() {
 const [root,planPath,responsePath,batchText]=process.argv.slice(2);
 const lib=resolve(root,'deployment/vercel-openai-proxy/api/_lib');
 const old=await import(pathToFileURL(join(lib,'condition-workflow.baseline.ts')).href);
 const fixed=await import(pathToFileURL(join(lib,'condition-workflow.ts')).href);
 const plan=old.validateConditionPlan(JSON.parse(await readFile(planPath,'utf8')));
 const raw=JSON.parse(await readFile(responsePath,'utf8')).result.output;
 const state=old.initialConditionState(plan);state.batch=Number(batchText);
 assert.throws(()=>old.acceptConditionResponse(plan,state,raw));
 const accepted=fixed.acceptConditionResponse(plan,state,raw);
 assert.equal(accepted.phase,'verification');
 assert.deepEqual(accepted.result.groups,state.result.groups,'Mapper output must not become accepted clinical links');
 const input=JSON.parse(fixed.nextConditionRequest(plan,accepted).payload.input);
 assert.equal(input.groups.flatMap((g:any)=>g.entries).length+accepted.proposal.unassigned.length,plan.batches[state.batch].length);
 assert(input.groups.every((g:any)=>g.reason===undefined),'Verifier must not inherit mapper rationale');
 const response=JSON.parse(raw);
 const pair=response.groups.findIndex((g:any,i:number)=>response.groups.some((h:any,j:number)=>j<i&&h.name===g.name&&h.bodySystem===g.bodySystem));
 const empty=response.groups.findIndex((g:any)=>g.entryIDs.length===0);
 assert(pair>=0 || empty>=0);
 const earlier=pair>=0 ? response.groups.findIndex((g:any)=>g.name===response.groups[pair].name&&g.bodySystem===response.groups[pair].bodySystem) : response.groups.findIndex((g:any)=>g.entryIDs.length>1);
 assert(earlier>=0);
 const mutations=pair>=0 ? [
  (x:any)=>{x.groups[pair].entryIDs=x.groups[earlier].entryIDs;},
  (x:any)=>{x.groups[pair].isPrimary=!x.groups[earlier].isPrimary;},
  (x:any)=>{x.groups[pair].entryIDs=['r999999'];},
  (x:any)=>{x.groups.splice(pair,1);}
 ] : [
  (x:any)=>{x.groups.push(structuredClone(x.groups[earlier]));},
  (x:any)=>{const g=x.groups[earlier],other={...g,entryIDs:g.entryIDs.slice(1),isPrimary:!g.isPrimary};g.entryIDs=g.entryIDs.slice(0,1);x.groups.push(other);},
  (x:any)=>{x.groups[earlier].entryIDs=['r999999'];},
  (x:any)=>{x.groups.splice(earlier,1);},
  (x:any)=>{x.groups[empty].bodySystem='invalid-system';}
 ];
 for(const mutate of mutations) {const bad=structuredClone(response);mutate(bad);assert.throws(()=>fixed.acceptConditionResponse(plan,state,JSON.stringify(bad)));}
 const before=state.result.groups.flatMap((g:any)=>g.entryIDs).length;
 const rejected=fixed.acceptConditionResponse(plan,accepted,JSON.stringify({decisions:input.groups.map((g:any)=>({name:g.name,bodySystem:g.bodySystem,nameSupported:false,supportedEntryIDs:[],reason:'Synthetic unsupported judgment'}))}));
 assert.equal(rejected.result.groups.flatMap((g:any)=>g.entryIDs).length,before);
 assert(plan.batches[state.batch].every((e:any)=>rejected.result.unassigned.includes(e.id)));
 const result={originalRejected:true,repairedRequiresVerification:true,sourceEntriesPreserved:plan.batches[state.batch].length,emptyHeadingsOmitted:empty>=0,overlapConflictUnknownAndMissingRejected:true,unsupportedLinksRemainUnassigned:true};
 await writeFile(resolve(root,'condition-completion-validation.json'),JSON.stringify(result,null,2));
 console.log(JSON.stringify(result));
}
main().catch(e=>{console.error(e);process.exitCode=1;});
