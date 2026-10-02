import {createHash} from 'node:crypto';
import {database,transaction} from './ledger';
import {submitConditionWorkflow,cancelConditionWorkflow,conditionWorkflowStatus} from './condition-workflow-store';

export type Upload={operation:'part'|'finish'|'cancel'|'status';digest:string;count:number;index?:number;content?:string};
export function validateUpload(value:unknown):Upload {
  const p=value as Upload;
  if(!p || !['part','finish','cancel','status'].includes(p.operation) || !/^[a-f0-9]{64}$/.test(p.digest) ||
    !Number.isInteger(p.count)||p.count<1||p.count>256 || (p.operation==='part' &&
      (!Number.isInteger(p.index)||p.index!<0||p.index!>=p.count||typeof p.content!=='string'||
       Buffer.byteLength(p.content)>320_000 || p.content.length===0 ||
       Buffer.from(p.content,'base64').toString('base64')!==p.content))) throw new Error('invalid_request');
  return p;
}
export function assembleUpload(parts:string[],digest:string):unknown {
  const data=Buffer.concat(parts.map(p=>Buffer.from(p,'base64')));
  if(data.length>60_000_000||createHash('sha256').update(data).digest('hex')!==digest) throw new Error('invalid_request');
  return JSON.parse(data.toString('utf8'));
}
// Upload and re-upload are free. No model dispatch occurs until all parts validate.
// A stable digest makes interrupted upload resumable and cancellation race-safe.
export async function conditionUpload(owner:string,value:unknown) {
  const p=validateUpload(value);
  const row=await transaction(async db=>{
    await db.query(`INSERT INTO ai_condition_uploads(owner,digest,part_count,state) VALUES($1,$2,$3,$4)
      ON CONFLICT DO NOTHING`,[owner,p.digest,p.count,p.operation==='cancel'?'cancelled':'uploading']);
    const r=(await db.query('SELECT * FROM ai_condition_uploads WHERE owner=$1 AND digest=$2 FOR UPDATE',[owner,p.digest])).rows[0];
    if(r.part_count!==p.count) throw new Error('invalid_request');
    if(p.operation==='cancel') {
      await db.query("UPDATE ai_condition_uploads SET state='cancelled' WHERE owner=$1 AND digest=$2",[owner,p.digest]);
      await db.query('DELETE FROM ai_condition_upload_parts WHERE owner=$1 AND digest=$2',[owner,p.digest]);
      return {...r,state:'cancelled'};
    }
    if(new Date(r.expires_at).getTime()<=Date.now() && r.state==='uploading') {
      await db.query("UPDATE ai_condition_uploads SET state='expired' WHERE owner=$1 AND digest=$2",[owner,p.digest]);
      return {...r,state:'expired'};
    }
    if(r.state!=='uploading') return r;
    if(p.operation==='part') {
      const old=(await db.query('SELECT content FROM ai_condition_upload_parts WHERE owner=$1 AND digest=$2 AND part_index=$3',[owner,p.digest,p.index])).rows[0];
      if(old && old.content!==p.content) throw new Error('invalid_request');
      await db.query('INSERT INTO ai_condition_upload_parts(owner,digest,part_index,content) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING',[owner,p.digest,p.index,p.content]);
    }
    return r;
  });
  if(row.state==='cancelled') {
    if(row.workflow_id) await cancelConditionWorkflow(owner,row.workflow_id);
    return {state:'cancelled'};
  }
  if(row.workflow_id) return conditionWorkflowStatus(owner,row.workflow_id);
  if(row.state==='expired') return {state:'expired'};
  const parts=(await database().query('SELECT part_index,content FROM ai_condition_upload_parts WHERE owner=$1 AND digest=$2 ORDER BY part_index',[owner,p.digest])).rows;
  if(p.operation!=='finish') return {state:'uploading',received:parts.map(p=>p.part_index)};
  return transaction(async db=>{
    const r=(await db.query('SELECT * FROM ai_condition_uploads WHERE owner=$1 AND digest=$2 FOR UPDATE',[owner,p.digest])).rows[0];
    if(r.state==='cancelled'||r.state==='expired') return {state:r.state};
    if(r.workflow_id) return (await db.query('SELECT id,state,revision FROM ai_condition_workflows WHERE owner=$1 AND id=$2',[owner,r.workflow_id])).rows[0];
    const lockedParts=(await db.query('SELECT part_index,content FROM ai_condition_upload_parts WHERE owner=$1 AND digest=$2 ORDER BY part_index',[owner,p.digest])).rows;
    if(lockedParts.length!==p.count || lockedParts.some((r,i)=>r.part_index!==i)) throw new Error('invalid_request');
    const plan=assembleUpload(lockedParts.map(r=>r.content),p.digest);
    // Atomic finalization: no orphan parent can outlive a cancelled upload.
    const job=await submitConditionWorkflow(owner,plan,false,db);
    await db.query("UPDATE ai_condition_uploads SET workflow_id=$3,state='completed' WHERE owner=$1 AND digest=$2",[owner,p.digest,job.id]);
    await db.query('DELETE FROM ai_condition_upload_parts WHERE owner=$1 AND digest=$2',[owner,p.digest]);
    return job;
  });
}
export async function cleanupConditionUploads() {
  await transaction(async db=>{
    await db.query("UPDATE ai_condition_uploads SET state='expired' WHERE state='uploading' AND expires_at<=now()");
    await db.query('DELETE FROM ai_condition_upload_parts p USING ai_condition_uploads u WHERE p.owner=u.owner AND p.digest=u.digest AND u.expires_at<=now()');
  });
}
