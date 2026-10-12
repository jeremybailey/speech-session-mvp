// Offline deterministic replay; all clinical evidence stays in the ignored run folder.
import {readFileSync,writeFileSync,readdirSync} from 'node:fs';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {compactConditionPlan,initialConditionState,nextConditionRequest,acceptConditionResponse} from '../../vercel-openai-proxy/api/_lib/condition-workflow';
const [rootText,run]=process.argv.slice(2),root=resolve(rootText);
const read=(path:string)=>JSON.parse(readFileSync(resolve(root,path),'utf8'));
const hash=(path:string)=>createHash('sha256').update(readFileSync(path)).digest('hex');
assert.equal(hash(resolve('api/_lib/condition-workflow.ts')),hash(resolve(root,'deployment/vercel-openai-proxy/api/_lib/condition-workflow.ts')),'Frozen coordinator must match replay');
const manifest=read('manifest.json'),plan=compactConditionPlan(read('frozen-plan.json'));
if(manifest.linkRecoveryRuns?.includes(run)||run==='controls-3')plan.repairRejectedLinks=true;
if(manifest.packedRecoveryRuns?.includes(run))plan.packRecovery=true;
let state=initialConditionState(plan);
const owner=read('manifest.json').ownerPrefix+run;
const jobs=read(run+'/ledger.json').jobs.filter((j:any)=>j.owner===owner).sort((a:any,b:any)=>a.created_at.localeCompare(b.created_at));
const stages:any[]=[];
for(const row of jobs){
 const job=read(run+'/jobs/'+row.id+'.json');assert.equal(job.state,'completed');
 const request=nextConditionRequest(plan,state)!;assert.equal(request.payload.stage,job.stage);
 const before=structuredClone(state),raw=job.result.output;
 state=acceptConditionResponse(plan,state,raw);
 stages.push({jobID:job.id,stage:job.stage,recovery:!!before.recoveringHeading,
  sourceIDs:Object.values(request.map),rejectedHeadings:before.headingRecovery?.rejectedNames,
  acceptedIDsAdded:state.result.groups.flatMap(g=>g.entryIDs).filter(id=>!before.result.groups.some(g=>g.entryIDs.includes(id))),
  unassignedIDsAdded:state.result.unassigned.filter(id=>!before.result.unassigned.includes(id)),
  reasoningTokens:job.result.diagnostics?.reasoningTokens??0,outputTokens:Number(job.output_tokens),
  reasoningEffort:job.reasoning_effort,providerSeconds:job.result.diagnostics?.providerSeconds??0});
 // Recovery can append independently checked links; it must never remove accepted ones.
 for(const g of before.result.groups)assert(state.result.groups.some(h=>h.name===g.name&&h.bodySystem===g.bodySystem&&g.entryIDs.every(id=>h.entryIDs.includes(id))));
}
assert.equal(state.phase,'completed');
const completed=readdirSync(resolve(root,run,'trace')).filter(f=>f.endsWith('.receipt.json'))
 .map(f=>read(run+'/trace/'+f)).filter(v=>v.state==='completed'&&v.result?.output)
 .map(v=>JSON.parse(v.result.output)).filter(v=>Array.isArray(v.groups));
assert.equal(completed.length,1);
const canonical=(v:any)=>({groups:v.groups.map((g:any)=>[g.name,g.bodySystem,[...g.entryIDs].sort()]).sort((a:any,b:any)=>JSON.stringify(a).localeCompare(JSON.stringify(b))),unassigned:[...v.unassigned].sort()});
assert.deepEqual(canonical(state.result),canonical(completed[0]),'Replay must match the saved final memberships');
writeFileSync(resolve(root,run,'offline-audit.json'),JSON.stringify({completed:true,acceptedLinksPreserved:true,stages,result:state.result},null,2));
console.log(JSON.stringify({completed:true,calls:stages.length,recoveryCalls:stages.filter(x=>x.recovery).length,recoveredEntries:stages.filter(x=>x.recovery).flatMap(x=>x.acceptedIDsAdded).length,reasoningTokens:stages.reduce((a,x)=>a+x.reasoningTokens,0)}));
