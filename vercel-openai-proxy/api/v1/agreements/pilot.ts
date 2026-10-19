import type { VercelRequest, VercelResponse } from '@vercel/node';
import { randomUUID } from 'node:crypto';
import { verifyKindeBearer } from '../../_lib/verifyKinde';
import { transaction } from '../../_lib/ledger';
import { pilotAgreement, agreementHash, agreementText, validateAcceptance } from '../../_lib/pilot-agreement';

export function makePilotAgreementHandler(verify: typeof verifyKindeBearer = verifyKindeBearer) {
return async function handler(req: VercelRequest, res: VercelResponse) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET' && req.method !== 'POST') { res.setHeader('Allow', 'GET, POST'); return res.status(405).end(); }
  try {
    const owner = await verify(req.headers.authorization);
    if (process.env.PILOT_AGREEMENT_VERSION !== pilotAgreement.version) return res.status(503).json({ error: 'agreement_unavailable' });
    const acceptance = req.method === 'POST' ? validateAcceptance(req.body) : null;
    const receipt = await transaction(async db => {
      if (acceptance) await db.query(`INSERT INTO pilot_agreement_acceptances
        (id,owner,version,sha256,agreement_text,action,app_version,app_build)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(owner,version,sha256) DO NOTHING`,
        [randomUUID(),owner,pilotAgreement.version,agreementHash,agreementText,pilotAgreement.action,acceptance.appVersion,acceptance.appBuild]);
      return (await db.query(`SELECT id,owner,version,sha256,accepted_at FROM pilot_agreement_acceptances
        WHERE owner=$1 AND version=$2 AND sha256=$3`, [owner,pilotAgreement.version,agreementHash])).rows[0] ?? null;
    });
    return res.status(200).json({ agreement: { ...pilotAgreement, sha256: agreementHash }, receipt });
  } catch (error) {
    const status = (error as { status?: number }).status ?? 503;
    return res.status(status).json({ error: status === 409 ? 'agreement_changed' : 'agreement_unavailable' });
  }
}

}
export default makePilotAgreementHandler();
