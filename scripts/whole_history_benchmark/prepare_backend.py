"""Create an expiring private deployment; changes apply only to this copy."""
import hashlib,json,secrets,shutil,time,uuid
from contracts import SCHEMA, INSTRUCTIONS, CHECK_INSTRUCTIONS
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def prepare(out):
    continuation=json.loads((out/'continuation.json').read_text()) if (out/'continuation.json').exists() else None
    combined=out/'combined'; deploy=out/'deployment'; backend=deploy/'vercel-openai-proxy'
    backend.mkdir(parents=True)
    project=ROOT/'.vercel'
    if not project.exists() and continuation: project=Path(continuation['priorExperiment'])/'deployment/.vercel'
    shutil.copytree(project,deploy/'.vercel',ignore=shutil.ignore_patterns('*.env*'))
    for name in ('package.json','package-lock.json','tsconfig.json'):shutil.copy2(combined/'vercel-openai-proxy'/name,backend/name)
    pkg=json.loads((backend/'package.json').read_text());pkg['scripts']['vercel-build']='npm run typecheck';(backend/'package.json').write_text(json.dumps(pkg,indent=2))
    for name in ('api/_lib','scripts'):shutil.copytree(combined/'vercel-openai-proxy'/name,backend/name)
    shutil.copy2(ROOT/'scripts/whole_history_benchmark/allowance.ts',backend/'scripts/whole-history-allowance.ts')
    ledger=backend/'api/_lib/ledger.ts'; s=ledger.read_text();s="import { enforceWholeHistoryAllowance } from '../../scripts/whole-history-allowance';\n"+s
    s=s.replace('await enforceFastDetailsBudget(db, owner, reserve);','await enforceWholeHistoryAllowance(db, owner, reserve);')
    s=s.replace('"condition-verification"]','"condition-verification", "whole-history-generation", "whole-history-check"]')
    s=s.replace('> 200_000',"> (String(p.stage).startsWith('whole-history-') ? 2_000_000 : 200_000)")
    ledger.write_text(s)
    policy=backend/'api/_lib/output-policy.ts';s=policy.read_text().replace("  return model ===", "  if (model === 'gpt-6-luna' && ['whole-history-generation','whole-history-check'].includes(stage)) return 64_000;\n  return model ===");policy.write_text(s)
    worker=backend/'api/_lib/worker.ts';s=worker.read_text().replace('  await cleanup();','  // Experiment scope: do not run shared maintenance.');s=s.replace('timeout: 100_000', "timeout: job.payload.stage.startsWith('whole-history-') ? 240_000 : 100_000");worker.write_text(s)
    endpoint=(ROOT/'scripts/benchmark_speed/endpoint.ts').read_text()
    endpoint=endpoint.replace("import { database,transaction,submitWithinTransaction,validatePayload }", "import { database,transaction,submitWithinTransaction,validatePayload,cancel }")
    endpoint=endpoint.replace('(baseline|parallel|hybrid|combined|shadow|controls)','(baseline|single|check)')
    endpoint=endpoint.replace("policy=summaryModelPolicy(payload.stage)","policy=payload.stage.startsWith('whole-history-') ? {model:'gpt-6-luna' as const,effort:'medium'} : summaryModelPolicy(payload.stage)")
    endpoint="import { isDeepStrictEqual } from 'node:util';\nimport { readFastDetailsCapacity } from './_lib/fast-details-experiment';\n"+endpoint
    endpoint=endpoint.replace("  if(b.action==='status')", "  if(b.action==='capacity')return res.json(await readFastDetailsCapacity(database() as any,process.env.AI_BUDGET_ID!,214500000,false));\n  if(b.action==='status')")
    endpoint=endpoint.replace("   const payload=validatePayload", "   const candidate=String(b.payload?.stage).startsWith('whole-history-');\n   if(candidate){ const p=b.payload; const expected=p.stage==='whole-history-generation'?config.generationInstructions:config.checkInstructions; if(p.instructions!==expected||!isDeepStrictEqual(p.response_format?.json_schema?.schema,config.candidateSchema)||Buffer.byteLength(JSON.stringify(p))+4096+64000>1050000)throw Error('invalid_request'); }\n   if((b.run.startsWith('baseline-')&&candidate)||(!b.run.startsWith('baseline-')&&!candidate))throw Error('invalid_request');\n   const payload=validatePayload")
    endpoint=endpoint.replace("  if(b.action==='job'||b.action==='run'){","  if(b.action==='cancel'){if(!uuid(b.id)||!await job(b.id))return res.status(404).json({error:'not_found'});await cancel(owner,b.id);return res.json(await job(b.id));}\n  if(b.action==='job'||b.action==='run'){")
    endpoint=endpoint.replace('j.output_tokens,j.reasoning_effort','j.output_tokens,j.cached_tokens,j.model,j.reasoning_effort')
    endpoint=endpoint.replace('CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END result','CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END result')
    endpoint=endpoint.replace("(p.result->>'providerSeconds')::double precision AS provider_seconds", "p.result->'diagnostics' AS diagnostics, (p.result->'diagnostics'->>'providerSeconds')::double precision AS provider_seconds")
    endpoint=endpoint.replace("[config.prefix])).rows,\n   budget:","[config.prefix+(config.runVersion??'')])).rows,\n   experimentAccounting:(await database().query('SELECT COALESCE(sum(cost_nusd),0)::text settled_nusd,COALESCE(sum(CASE WHEN cost_nusd IS NULL THEN reserve_nusd ELSE 0 END),0)::text unresolved_nusd,COALESCE(sum(COALESCE(cost_nusd,reserve_nusd)),0)::text committed_nusd FROM ai_jobs WHERE left(owner,length($1))=$1',[config.prefix])).rows[0],\n   budget:")
    # Scope cancellation/purge/reads remain guarded by authenticated prefix.
    (backend/'api/benchmark.ts').write_text(endpoint)
    (backend/'vercel.json').write_text(json.dumps({'functions':{'api/benchmark.ts':{'maxDuration':300}}}))
    token=secrets.token_urlsafe(32);prefix=continuation['prefix'] if continuation else 'benchmark-whole-history-'+str(uuid.uuid4())+':'
    run_version='trial-'+uuid.uuid4().hex+':'
    config={'prefix':prefix,'runVersion':run_version,'tokenHash':hashlib.sha256(token.encode()).hexdigest(),'expiresAt':int((time.time()+24*3600)*1000),'candidateSchema':SCHEMA,'generationInstructions':INSTRUCTIONS,'checkInstructions':CHECK_INSTRUCTIONS}
    (backend/'api/config.json').write_text(json.dumps(config));(backend/'api/config.json').chmod(0o600)
    (out/'auth.json').write_text(json.dumps({'token':token,'cli':['npx','--yes','vercel@65.9.0'],'maxTimeSeconds':310}));(out/'auth.json').chmod(0o600)
    (out/'manifest.json').write_text(json.dumps({'prefix':prefix,'ownerPrefix':prefix+run_version,'runVersion':run_version,'experimentLimitUSD':5,'allowanceScope':'All historical and current jobs under the immutable experiment prefix','providerDeadlinesSeconds':{'baseline':100,'candidate':240},'functionMaxDurationSeconds':300,'priorExperiment':continuation,'expiresAt':config['expiresAt'],
      'baseline':'combined current care-plan and recovery source','plannedOrder':[['A1','B1','C1'],['B2','C2','A2'],['A3','B3','C3']],
      'baselineModelPolicy':'Unchanged current server policy','candidateModel':'gpt-6-luna','candidateReasoning':'medium','candidateOutputTokens':64000,
      'clinicalGrading':'Draft-only, provisional; unchanged answer key excluded from all processing requests',
      'productionChanges':False,'attribution':'B generation full cost/time attributed to B and C; actual spend counted once'},indent=2))
    print('Private diagnostic copy prepared; no inference/deployment.')
if __name__=='__main__':import sys;prepare(Path(sys.argv[1]).resolve())
