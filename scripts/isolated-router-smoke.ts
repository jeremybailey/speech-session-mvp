import {Readable} from 'node:stream';
import assert from 'node:assert/strict';
import handler from '../api/index';
import direct from '../server/v1/health-processing/record-updates';
function request(path:string,body:string,headers:Record<string,string>={}){return Object.assign(Readable.from([body]),{method:'POST',url:'/api/'+path,query:{__cc_route:path},headers});}
function response(){return {code:200,payload:null as unknown,status(n:number){this.code=n;return this},json(v:unknown){this.payload=v;return this},end(){return this},setHeader(){return this}};}
async function main(){
 const a=response(),b=response();
 await handler(request('v1/health-processing/record-updates','{}') as any,a as any);
 await direct(Object.assign(request('v1/health-processing/record-updates','{}'),{body:{}}) as any,b as any);
 assert.equal(a.code,401);assert.equal(a.code,b.code);assert.deepEqual(a.payload,b.payload);
 const malformed=response();await handler(request('v1/health-processing/record-updates','{') as any,malformed as any);assert.equal(malformed.code,400);
 for(const route of ['v1/health-processing/queue','v1/health-processing/record-update-queue','v1/health-processing/record-recovery-queue','v1/health-processing/condition-workflow-queue','../../server/_lib/ledger']){
  const res=response();await handler(request(route,'{}') as any,res as any);assert.equal(res.code,404);
 }
 const raw=request('v1/audio/transcriptions','not JSON',{'content-type':'multipart/form-data; boundary=test'}),rawResult=response();
 await handler(raw as any,rawResult as any);assert.equal(rawResult.code,401);assert.equal(raw.readableEnded,false);
 console.log('Router smoke passed: auth parity, malformed JSON rejection, raw-body preservation, and no public queue dispatch.');
}
main().catch(error=>{console.error(error);process.exitCode=1});
