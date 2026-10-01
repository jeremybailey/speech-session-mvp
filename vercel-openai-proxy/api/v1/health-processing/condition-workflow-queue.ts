import { jobQueue,queueJobID } from '../../_lib/queue';
import { conditionWorkflowsEnabled,runConditionWorkflow } from '../../_lib/condition-workflow-worker';
import type { VercelRequest,VercelResponse } from '@vercel/node';
const consume=jobQueue.handleNodeCallback(async(message:unknown)=>{
  try {await runConditionWorkflow(queueJobID(message));}
  catch {throw new Error('condition_workflow_delivery_deferred');}
},{visibilityTimeoutSeconds:300,retry:()=>({afterSeconds:60})});
// Must remain private under the queue/v2beta trigger.
export default function handler(req:VercelRequest,res:VercelResponse) {
  res.setHeader('Cache-Control','no-store');
  if(!conditionWorkflowsEnabled()) return res.status(503).end();
  return consume(req,res);
}
