import {acknowledgeResult,receiptDigest} from '../../_lib/result-receipts';
import { readFastDetailsCapacity } from '../../_lib/fast-details-experiment';
import { reservation } from '../../_lib/pricing';
import { summaryModelPolicy } from '../../_lib/model-policy';
import { outputTokenLimit } from '../../_lib/output-policy';
import { processingOwner, isFastRequest } from '../../_lib/fast-details-experiment';
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { verifyKindeBearer } from "../../_lib/verifyKinde";
import { cancel, cancelPayload, database, submit, retryExpiredResult, transaction, validatePayload } from "../../_lib/ledger";
import { enqueueJob } from "../../_lib/queue";
import { durableEnabledForOwner } from '../../_lib/pilot';
import { processingFailure, processingFailureReason, type ProcessingPhase } from '../../_lib/processing-errors';

export default async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader("Cache-Control", "no-store");
  let phase: ProcessingPhase = 'authentication';
  try {
    const owner = processingOwner(await verifyKindeBearer(req.headers.authorization), isFastRequest(req.headers));
    // Receipt cleanup stays available even if paid inference is disabled.
    if(req.method==='PATCH') {
      phase = 'receipt';
      const id=req.query.id;
      if(typeof id!=='string'||!/^[0-9a-f-]{36}$/i.test(id)) return res.status(400).json({error:{code:'invalid_id'}});
      return res.status(200).json(await acknowledgeResult(owner,id,receiptDigest(req.body),false));
    }
    if (!durableEnabledForOwner(owner)) return res.status(503).json({error:{code:"pilot_disabled"}});
    if (req.method === 'GET' && ['fast-details','checked-details'].includes(String(req.query.capacity))) {
      phase = 'capacity';
      if (!process.env.AI_BUDGET_ID) return res.status(503).json({error:{code:'fast_experiment_disabled'}});
      const reserves = ['extraction','checking'].map(stage => {
        const {model} = summaryModelPolicy(stage); return reservation(model, outputTokenLimit(model, stage));
      });
      const result = await transaction(db => readFastDetailsCapacity(db, process.env.AI_BUDGET_ID!, Math.max(...reserves), isFastRequest(req.headers) || req.query.capacity === 'fast-details'));
      return res.status(200).json(result);
    }
    if (req.method === "POST") {
      phase = 'validation';
      const payload=validatePayload(req.body, isFastRequest(req.headers));
      phase = 'submission';
      const job = req.body?.retry_expired_job_id === undefined ? await submit(owner,payload)
        : await retryExpiredResult(owner,payload,req.body.retry_expired_job_id);
      // A failed publish leaves a durable queued row. Resubmitting reuses that
      // row and retries publishing, never reserves or dispatches inference twice.
      if (job.state === "queued") {
        phase = 'publication';
        await enqueueJob(job.id);
      }
      return res.status(202).json(job);
    }
    if(req.method === 'DELETE' && req.query.id === undefined) {
      phase = 'cancellation';
      return res.status(200).json(await cancelPayload(owner,validatePayload(req.body, isFastRequest(req.headers))));
    }
    const id = req.query.id;
    if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) return res.status(400).json({error:{code:"invalid_id"}});
    if (req.method === "DELETE") { phase = 'cancellation'; await cancel(owner,id); }
    else if (req.method !== "GET") return res.status(405).end();
    phase = 'status';
    const job = (await database().query(`SELECT j.id,j.state,j.stage,j.model,j.cost_nusd,
      CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END AS result
      FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.owner=$1 AND j.id=$2`,[owner,id])).rows[0];
    return res.status(job ? 200 : 404).json(job ?? {error:{code:"not_found"}});
  } catch (cause) {
    const failure = processingFailure(cause, phase);
    console.error(JSON.stringify({event: 'ai_processing_failed', ...failure, reason: processingFailureReason(cause)}));
    return res.status(failure.status).json({error:{code: failure.code}});
  }
}
