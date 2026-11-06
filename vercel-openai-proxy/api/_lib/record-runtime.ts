import {Pool,PoolClient} from 'pg';
import {database} from './ledger';
/** A self-scheduling heartbeat must stop when its deployment is superseded.
 * Queues pin messages to their producer deployment; the shared DB owns activation. */
export async function isRecordDeploymentActive(client?:Pool|PoolClient):Promise<boolean>{
 const deployment=process.env.VERCEL_DEPLOYMENT_ID;
 if(!deployment)return true; // Local synthetic tests have no deployed consumer.
 const rows=(await (client??database()).query("SELECT deployment_id FROM ai_record_runtime WHERE id='record-updates'")).rows;
 return rows.length===1 && rows[0].deployment_id===deployment;
}
