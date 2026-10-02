import type { VercelRequest,VercelResponse } from '@vercel/node';
import { verifyKindeBearer } from '../../_lib/verifyKinde';
import { submitConditionWorkflow,conditionWorkflowStatus,cancelConditionWorkflow,cancelConditionPlan,cleanupConditionWorkflows } from '../../_lib/condition-workflow-store';
import { conditionWorkflowsEnabled,enqueueConditionWorkflow } from '../../_lib/condition-workflow-worker';
import { durableEnabledForOwner } from '../../_lib/pilot';
import {conditionUpload,cleanupConditionUploads} from '../../_lib/condition-upload';

export default async function handler(req:VercelRequest,res:VercelResponse) {
  res.setHeader('Cache-Control','no-store');
  try {
    const owner=await verifyKindeBearer(req.headers.authorization);
    if(!conditionWorkflowsEnabled() || !durableEnabledForOwner(owner)) return res.status(503).json({error:{code:'pilot_disabled'}});
    await cleanupConditionWorkflows();
    await cleanupConditionUploads();
    if(req.method==='PUT') {
      const job=await conditionUpload(owner,req.body);
      if(job.id && ['queued','running'].includes(job.state)) await enqueueConditionWorkflow(job.id,job.revision);
      return res.status(200).json(job);
    }
    if(req.method==='POST') {
      if(Buffer.byteLength(JSON.stringify(req.body))>400_000) return res.status(413).json({error:{code:'use_chunked_upload'}});
      const job=await submitConditionWorkflow(owner,req.body);
      if(['queued','running'].includes(job.state)) await enqueueConditionWorkflow(job.id,job.revision);
      return res.status(202).json(job);
    }
    if(req.method==='DELETE' && req.query.id===undefined) {
      return res.status(200).json(await cancelConditionPlan(owner,req.body));
    }
    const id=req.query.id;
    if(typeof id!=='string'||!/^[0-9a-f-]{36}$/i.test(id)) return res.status(400).end();
    if(req.method==='DELETE') await cancelConditionWorkflow(owner,id);
    else if(req.method!=='GET') return res.status(405).end();
    const part=req.query.part;
    if(part!==undefined && (typeof part!=='string'||!/^\d+$/.test(part))) return res.status(400).end();
    const job=await conditionWorkflowStatus(owner,id,part===undefined?undefined:Number(part));
    return res.status(job?200:404).json(job??{error:{code:'not_found'}});
  } catch(error) {
    const e=error as {message?:string;status?:number};
    const invalid=['invalid_condition_workflow','invalid_request','invalid_schema'].includes(e.message??'');
    return res.status(e.status??(invalid?400:503)).json({error:{code:invalid?'invalid_request':'processing_unavailable'}});
  }
}
