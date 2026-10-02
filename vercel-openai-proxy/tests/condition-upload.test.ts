import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {assembleUpload,validateUpload} from '../api/_lib/condition-upload';
test('large Unicode manifests survive bounded upload and reject missing/reordered data',()=>{
  const data=Buffer.from(JSON.stringify({source:'Synthetic 🧪 '.repeat(80000)}));
  const digest=createHash('sha256').update(data).digest('hex');
  const parts=[];for(let i=0;i<data.length;i+=240000) parts.push(data.subarray(i,i+240000).toString('base64'));
  parts.forEach((content,index)=>validateUpload({operation:'part',digest,count:parts.length,index,content}));
  assert.deepEqual(assembleUpload(parts,digest),JSON.parse(data.toString()));
  assert.throws(()=>assembleUpload(parts.slice(1),digest));
  assert.throws(()=>assembleUpload([...parts].reverse(),digest));
  assert.throws(()=>validateUpload({operation:'part',digest,count:1,index:1,content:parts[0]}));
  assert.throws(()=>validateUpload({operation:'part',digest,count:1,index:0,content:'not base64'}));
});
