import {isRecordDeploymentActive} from '../../_lib/record-runtime';
import type {VercelRequest,VercelResponse} from '@vercel/node';
import {jobQueue,queueJobID} from '../../_lib/queue';
import {runSummary,dispatchSummaries,summariesEnabled} from '../../_lib/summary-workflow-store';
// Private queue trigger; messages contain only opaque workflow IDs.
const consume=jobQueue.handleNodeCallback(async message=>{if(!await isRecordDeploymentActive())return;await runSummary(queueJobID(message));await dispatchSummaries();},{visibilityTimeoutSeconds:360,retry:()=>({afterSeconds:30})});
export default async function handler(req:VercelRequest,res:VercelResponse){if(!summariesEnabled())return res.status(503).end();return consume(req,res);}
