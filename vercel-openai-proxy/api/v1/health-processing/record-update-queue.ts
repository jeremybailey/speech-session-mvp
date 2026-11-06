import type {VercelRequest,VercelResponse} from '@vercel/node';
import {jobQueue,queueJobID} from '../../_lib/queue';
import {runRecordUnit} from '../../_lib/incremental-workflow';
const consume=jobQueue.handleNodeCallback(async(message:unknown)=>{await runRecordUnit(queueJobID(message));},
 {visibilityTimeoutSeconds:60,retry:()=>({afterSeconds:30})});
export default async function handler(req:VercelRequest,res:VercelResponse){
 if(process.env.AI_INCREMENTAL_RECORDS_ENABLED!=='true'||process.env.AI_DURABLE_ENABLED!=='true')return res.status(503).end();
 return consume(req,res);
}
