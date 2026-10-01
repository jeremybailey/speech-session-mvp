import { createHmac, randomUUID } from 'node:crypto';
import { database, transaction, submitWithinTransaction,workloadType } from './ledger';
import { conditionModel, conditionReasoning } from './model-policy';
import { ConditionState, validateConditionPlan, initialConditionState, nextConditionRequest, acceptConditionResponse } from './condition-workflow';

const active = (state:string) => ['queued','running'].includes(state);
function canonical(value:any):string {
  if(Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if(value && typeof value==='object') return `{${Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')}}`;
  return JSON.stringify(value);
}
export async function submitConditionWorkflow(owner:string,value:unknown,stopBeforeSubmission=false) {
  const plan=validateConditionPlan(value), secret=process.env.AI_DEDUPE_SECRET;
  if(!secret) throw new Error('dedupe_secret_unavailable');
  const {workload_type,...clinicalPlan}=plan;
  const hash=createHmac('sha256',secret).update(canonical([owner,'condition-workflow-v1',clinicalPlan])).digest('hex');
  return transaction(async db=>{
    const id=randomUUID(), checkpoint=initialConditionState(plan), state=stopBeforeSubmission?'cancelled':checkpoint.phase==='completed'?'completed':'queued';
    const created=await db.query(`INSERT INTO ai_condition_workflows(id,owner,request_hash,state,record_count,budget_id,finished_at,workload_type,model,reasoning_effort)
      VALUES($1,$2,$3,$4,$5,$6,CASE WHEN $4 IN ('completed','cancelled') THEN now() ELSE NULL END,$7,$8,$9)
      ON CONFLICT(owner,request_hash) DO NOTHING RETURNING id,state,revision`,[id,owner,hash,state,plan.batches.flat().length,process.env.AI_BUDGET_ID,workloadType(workload_type),conditionModel(),conditionReasoning()]);
    if(created.rows.length) {
      if(!stopBeforeSubmission) await db.query('INSERT INTO ai_condition_workflow_payloads(workflow_id,plan,checkpoint) VALUES($1,$2,$3)',[id,plan,checkpoint]);
      return created.rows[0];
    }
    return (await db.query('SELECT id,state,revision FROM ai_condition_workflows WHERE owner=$1 AND request_hash=$2',[owner,hash])).rows[0];
  });
}
// A cancellation arriving before POST leaves only a nonclinical identity tombstone.
// If POST wins the race, cancel the existing parent before acknowledging Stop.
export async function cancelConditionPlan(owner:string,value:unknown) {
  const job=await submitConditionWorkflow(owner,value,true);
  await cancelConditionWorkflow(owner,job.id);
  return conditionWorkflowStatus(owner,job.id);
}
export async function conditionWorkflowStatus(owner:string,id:string) {
  return (await database().query(`SELECT w.id,w.state,w.revision,w.record_count,
    CASE WHEN w.state='completed' AND p.expires_at>now() THEN jsonb_build_object('output',(p.checkpoint->'result')::text) ELSE NULL END result
    FROM ai_condition_workflows w LEFT JOIN ai_condition_workflow_payloads p ON p.workflow_id=w.id
    WHERE w.owner=$1 AND w.id=$2`,[owner,id])).rows[0];
}
// Atomic checkpoint + reservation means no orphan paid step on process death.
export async function prepareConditionStep(id:string):Promise<string|null> {
  return transaction(async db=>{
    const w=(await db.query('SELECT * FROM ai_condition_workflows WHERE id=$1 FOR UPDATE',[id])).rows[0];
    if(!w || !active(w.state)) return null;
    const p=(await db.query('SELECT * FROM ai_condition_workflow_payloads WHERE workflow_id=$1 AND expires_at>now()',[id])).rows[0];
    if(!p) { await db.query("UPDATE ai_condition_workflows SET state='expired',finished_at=now() WHERE id=$1",[id]);return null; }
    if(w.current_step) return w.current_step;
    const next=nextConditionRequest(p.plan,p.checkpoint);
    if(!next) {await db.query("UPDATE ai_condition_workflows SET state='completed',finished_at=now() WHERE id=$1",[id]);return null;}
    const child=await submitWithinTransaction(db,w.owner,{...next.payload,workload_type:w.workload_type},w.budget_id,w.model,w.reasoning_effort);
    await db.query('INSERT INTO ai_condition_workflow_steps(workflow_id,revision,job_id,incurs_cost) VALUES($1,$2,$3,$4)',[id,w.revision,child.id,!child.reused]);
    await db.query("UPDATE ai_condition_workflows SET state='running',current_step=$2 WHERE id=$1",[id,child.id]);
    return child.id;
  });
}
export async function finishConditionStep(id:string,childID:string):Promise<{state:string;revision:number}|null> {
  return transaction(async db=>{
    const w=(await db.query('SELECT * FROM ai_condition_workflows WHERE id=$1 FOR UPDATE',[id])).rows[0];
    if(!w || !active(w.state) || w.current_step!==childID) return w??null;
    const p=(await db.query('SELECT * FROM ai_condition_workflow_payloads WHERE workflow_id=$1 AND expires_at>now()',[id])).rows[0];
    const child=(await db.query(`SELECT j.state,CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END result
      FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.id=$1 AND j.owner=$2`,[childID,w.owner])).rows[0];
    if(child && active(child.state)) throw new Error('condition_step_pending');
    let state=!p?'expired':child?.state==='completed'?'running':child?.state??'incomplete';
    let checkpoint:ConditionState|undefined;
    if(state==='running') {
      try {
        if(typeof child.result?.output!=='string') throw new Error('missing_result');
        checkpoint=acceptConditionResponse(p.plan,p.checkpoint,child.result.output);
        if(checkpoint.phase==='completed') state='completed';
      } catch {state='invalid';}
    }
    if(checkpoint) await db.query('UPDATE ai_condition_workflow_payloads SET checkpoint=$2 WHERE workflow_id=$1',[id,checkpoint]);
    const revision=w.revision+1;
    await db.query(`UPDATE ai_condition_workflows SET state=$2,revision=$3,current_step=NULL,
      finished_at=CASE WHEN $2='running' THEN NULL ELSE now() END WHERE id=$1`,[id,state,revision]);
    return {state,revision};
  });
}
export async function cancelConditionWorkflow(owner:string,id:string) {
  await transaction(async db=>{
    const w=(await db.query('SELECT * FROM ai_condition_workflows WHERE owner=$1 AND id=$2 FOR UPDATE',[owner,id])).rows[0];
    if(!w || !active(w.state)) return;
    if(w.current_step) {
      const child=(await db.query('SELECT * FROM ai_jobs WHERE id=$1 FOR UPDATE',[w.current_step])).rows[0];
      const shared=(await db.query("SELECT 1 FROM ai_condition_workflows WHERE id<>$1 AND current_step=$2 AND state IN ('queued','running') LIMIT 1",[id,w.current_step])).rows.length>0;
      if(child?.state==='queued' && !shared) {
        await db.query("UPDATE ai_jobs SET state='cancelled',cost_nusd=0,finished_at=now() WHERE id=$1",[child.id]);
        await db.query('UPDATE ai_budgets SET reserved_nusd=reserved_nusd-$2 WHERE id=$1',[child.budget_id,child.reserve_nusd]);
        await db.query('DELETE FROM ai_payloads WHERE job_id=$1',[child.id]);
      }
    }
    await db.query("UPDATE ai_condition_workflows SET state='cancelled',finished_at=now() WHERE id=$1",[id]);
    await db.query('DELETE FROM ai_condition_workflow_payloads WHERE workflow_id=$1',[id]);
  });
}

export async function cleanupConditionWorkflows() {
  await transaction(async db=>{
    await db.query(`UPDATE ai_condition_workflows w SET state='expired',finished_at=now()
      FROM ai_condition_workflow_payloads p WHERE w.id=p.workflow_id AND p.expires_at<=now() AND w.state IN ('queued','running')`);
    await db.query('DELETE FROM ai_condition_workflow_payloads WHERE expires_at<=now()');
  });
}
