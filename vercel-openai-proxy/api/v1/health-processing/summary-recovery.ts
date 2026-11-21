import type {VercelRequest,VercelResponse} from '@vercel/node';
import {database} from '../../_lib/ledger';
import {cleanupSummaries,dispatchSummaries} from '../../_lib/summary-workflow-store';
export default async function handler(req:VercelRequest,res:VercelResponse){
 if(!process.env.CRON_SECRET||req.headers.authorization!==`Bearer ${process.env.CRON_SECRET}`)return res.status(401).end();
 if(req.method!=='GET'&&req.method!=='POST')return res.status(405).end();
 try{await cleanupSummaries();await database().query('DELETE FROM ai_summary_uploads WHERE expires_at<=now()');return res.json({dispatched:await dispatchSummaries()});}
 catch{return res.status(503).json({error:{code:'summary_recovery_unavailable'}});}
}
