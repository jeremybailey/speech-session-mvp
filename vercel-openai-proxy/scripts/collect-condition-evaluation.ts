// Read-only receipt collection. Never POSTs or invokes inference.
import {execFileSync} from 'node:child_process';
import {writeFile} from 'node:fs/promises';
async function main() {
  const [deployment,linkedDirectory,outputPath]=process.argv.slice(2);
  if(!deployment?.startsWith('https://speech-session-')||!linkedDirectory||!outputPath) throw new Error('Expected deployment URL, linked directory, and receipt path');
  const raw=execFileSync('npx',['--yes','vercel@62.0.0','curl','/api/condition-evaluation','--deployment',deployment,'--','--silent','--show-error'],
    {cwd:linkedDirectory,encoding:'utf8',maxBuffer:4_000_000});
  const value=JSON.parse(raw);
  const receipt={generatedAt:new Date().toISOString(),deployment,contractDigest:value.contractDigest,model:value.model,reasoning:value.reasoning,
    cases:value.results.map((r:any)=>({id:r.id,fixture:r.case,state:r.state,errors:r.errors})),
    budget:{limit_nusd:value.budget.limit_nusd,used_nusd:value.budget.used_nusd,reserved_nusd:value.budget.reserved_nusd},
    usage:{tracking_start:value.usage.tracking_start,updated_at:value.usage.updated_at,
      lifetime_nusd:value.usage.lifetime_nusd,unresolved_charges:value.usage.unresolved_charges,
      entries:value.usage.entries.map((r:any)=>({id:r.id,stage:r.stage,model:r.model,workload_type:r.workload_type,state:r.state,cost_nusd:r.cost_nusd,retry_count:r.retry_count}))},
    notice:'Synthetic cases only. Estimated API cost; provider billing is authoritative. Shared budget includes previous iterations. No attributable historical baseline; no verified 10x claim.'};
  await writeFile(outputPath,JSON.stringify(receipt,null,2));
  console.log(JSON.stringify(receipt));
}
main().catch(()=>{console.error('Evaluation receipt unavailable; no model request was made.');process.exitCode=1;});
