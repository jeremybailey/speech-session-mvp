import type { VercelRequest, VercelResponse } from "@vercel/node";
import { verifyKindeBearer } from "../../_lib/verifyKinde";
import { cancel, cancelPayload, database, submit, validatePayload } from "../../_lib/ledger";
import { enqueueJob } from "../../_lib/queue";
import { durableEnabledForOwner } from '../../_lib/pilot';

export default async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader("Cache-Control", "no-store");
  try {
    const owner = await verifyKindeBearer(req.headers.authorization);
    if (!durableEnabledForOwner(owner)) return res.status(503).json({error:{code:"pilot_disabled"}});
    if (req.method === "POST") {
      const job = await submit(owner, validatePayload(req.body));
      // A failed publish leaves a durable queued row. Resubmitting reuses that
      // row and retries publishing, never reserves or dispatches inference twice.
      if (job.state === "queued") await enqueueJob(job.id);
      return res.status(202).json(job);
    }
    if(req.method === 'DELETE' && req.query.id === undefined) {
      return res.status(200).json(await cancelPayload(owner,validatePayload(req.body)));
    }
    const id = req.query.id;
    if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) return res.status(400).json({error:{code:"invalid_id"}});
    if (req.method === "DELETE") await cancel(owner,id);
    else if (req.method !== "GET") return res.status(405).end();
    const job = (await database().query(`SELECT j.id,j.state,j.stage,j.model,j.cost_nusd,
      CASE WHEN p.expires_at>now() THEN p.result ELSE NULL END AS result
      FROM ai_jobs j LEFT JOIN ai_payloads p ON p.job_id=j.id WHERE j.owner=$1 AND j.id=$2`,[owner,id])).rows[0];
    return res.status(job ? 200 : 404).json(job ?? {error:{code:"not_found"}});
  } catch (cause) {
    const e = cause as {status?:number;message?:string};
    const code = ["budget_exhausted","invalid_request","invalid_schema"].includes(e.message ?? "") ? e.message : "processing_unavailable";
    return res.status(e.status ?? (code === "budget_exhausted" ? 402 : code?.startsWith("invalid") ? 400 : 503)).json({error:{code}});
  }
}
