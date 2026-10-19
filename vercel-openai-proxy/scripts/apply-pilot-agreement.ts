import { readFile } from 'node:fs/promises';
import { Pool } from 'pg';
import { randomUUID } from 'node:crypto';
import { pilotAgreement, agreementHash, agreementText } from '../api/_lib/pilot-agreement';

async function main() {
  if (process.env.MIGRATE_PILOT_AGREEMENT !== '1') return;
  if (process.env.PILOT_AGREEMENT_VERSION !== '2026-10-19.1') throw new Error('agreement_version_not_enabled');
  if (!process.env.DATABASE_URL) throw new Error('database_unavailable');
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 1, connectionTimeoutMillis: 10000 });
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    await db.query("SELECT pg_advisory_xact_lock(hashtext('pilot-agreement-migration-009'))");
    await db.query(await readFile('migrations/009_pilot_agreements.sql', 'utf8'));
    await db.query('COMMIT');
    // Verify the production schema with a synthetic receipt, rolled back in full.
    await db.query('BEGIN');
    const id = randomUUID(); const owner = `synthetic-migration-check-${id}`;
    const insert = `INSERT INTO pilot_agreement_acceptances
      (id,owner,version,sha256,agreement_text,action,app_version,app_build)
      VALUES ($1,$2,$3,$4,$5,$6,'synthetic-check','0') ON CONFLICT(owner,version,sha256) DO NOTHING`;
    const values = [id,owner,pilotAgreement.version,agreementHash,agreementText,pilotAgreement.action];
    await db.query(insert,values);
    await db.query(insert,[randomUUID(),...values.slice(1)]);
    const rows = (await db.query('SELECT id,accepted_at FROM pilot_agreement_acceptances WHERE owner=$1',[owner])).rows;
    if (rows.length !== 1 || rows[0].id !== id || !rows[0].accepted_at) throw new Error('receipt_check_failed');
    await db.query('ROLLBACK');
    console.log('PASS pilot agreement audit migration 009 and synthetic receipt round trip; synthetic transaction rolled back; no clinical tables changed.');
  } catch (error) { await db.query('ROLLBACK'); throw error; }
  finally { db.release(); await pool.end(); }
}
main().catch(() => { console.error('Pilot agreement migration failed; deployment must stop.'); process.exitCode = 1; });
