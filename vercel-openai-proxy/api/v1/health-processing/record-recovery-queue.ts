import type {VercelRequest,VercelResponse} from '@vercel/node';
import {jobQueue,queueJobID} from '../../_lib/queue';
import {seedRecordRecovery,recoverRecordUpdates} from '../../_lib/incremental-workflow';
const consume=jobQueue.handleNodeCallback(async(message:unknown)=>{
 queueJobID(message);
 if(process.env.AI_INCREMENTAL_RECORDS_ENABLED!=='true'||process.env.AI_QUEUE_ENABLED!=='true'||process.env.AI_DURABLE_ENABLED!=='true')return;
 // Schedule the next durable tick before scanning; queue retries cover a failed send.
 await seedRecordRecovery();await recoverRecordUpdates();
},{visibilityTimeoutSeconds:60,retry:()=>({afterSeconds:30})});
export default async function handler(req:VercelRequest,res:VercelResponse){return consume(req,res);}
