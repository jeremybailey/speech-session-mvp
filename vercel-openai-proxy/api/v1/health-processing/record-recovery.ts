import type {VercelRequest,VercelResponse} from '@vercel/node';
import {seedRecordRecovery,recoverRecordUpdates} from '../../_lib/incremental-workflow';
export default async function handler(req:VercelRequest,res:VercelResponse){
 res.setHeader('Cache-Control','no-store');
 if(!process.env.CRON_SECRET||req.headers.authorization!==`Bearer ${process.env.CRON_SECRET}`)return res.status(401).end();
 if(req.method!=='GET'&&req.method!=='POST')return res.status(405).end();
 if(process.env.AI_INCREMENTAL_RECORDS_ENABLED!=='true'||process.env.AI_QUEUE_ENABLED!=='true'||process.env.AI_DURABLE_ENABLED!=='true')return res.status(200).json({enabled:false});
 try {await seedRecordRecovery();return res.json({recovered:await recoverRecordUpdates()});}
 catch {return res.status(503).json({error:'recovery_unavailable'});}
}
