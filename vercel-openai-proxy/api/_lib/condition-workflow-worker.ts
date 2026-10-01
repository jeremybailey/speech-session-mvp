import { jobQueue, queueJobID } from './queue';
import { database } from './ledger';
import { prepareConditionStep, finishConditionStep, cleanupConditionWorkflows } from './condition-workflow-store';
import { runJob } from './worker';

export const conditionWorkflowTopic='condition-workflows';
export function conditionWorkflowsEnabled() {
  return process.env.AI_CONDITION_WORKFLOWS_ENABLED==='true' && process.env.AI_DURABLE_ENABLED==='true' && process.env.AI_QUEUE_ENABLED==='true';
}
export async function enqueueConditionWorkflow(id:string,revision:number) {
  if(!conditionWorkflowsEnabled()) throw new Error('pilot_disabled');
  queueJobID({id});
  await jobQueue.send(conditionWorkflowTopic,{id},{idempotencyKey:`${id}:${revision}`,retentionSeconds:604800});
}
// One budgeted step per delivery. Parent checkpoint and child ID survive process
// death. Duplicate deliveries reuse the child claim; uncertain calls never repeat.
export async function runConditionWorkflow(id:string,
  execute:(id:string)=>Promise<number>=runJob,
  enqueue:(id:string,revision:number)=>Promise<void>=enqueueConditionWorkflow) {
  if(!conditionWorkflowsEnabled()) throw new Error('pilot_disabled');
  await cleanupConditionWorkflows();
  let child:string|null;
  try {child=await prepareConditionStep(id);}
  catch(error) {
    const code=(error as Error).message;
    if(['budget_exhausted','invalid_condition_workflow'].includes(code)) {
      await database().query("UPDATE ai_condition_workflows SET state=$2,finished_at=now() WHERE id=$1 AND state IN ('queued','running') AND current_step IS NULL",
        [id,code==='budget_exhausted'?code:'invalid']);
      return;
    }
    throw error;
  }
  if(!child) return;
  await execute(child);
  const next=await finishConditionStep(id,child);
  // A send failure must fail this delivery. Redelivery resumes from the saved
  // revision; it cannot re-dispatch the step just completed.
  if(next && ['queued','running'].includes(next.state)) await enqueue(id,next.revision);
}
