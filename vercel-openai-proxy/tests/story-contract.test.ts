import test from 'node:test';import assert from 'node:assert/strict';import {storyRequest,storyResult,storyPayload,storyCandidate} from '../api/_lib/story-contract';
const input=storyRequest({id:'00000000-0000-4000-8000-000000000001',version:'story-v1',kind:'edit',baseRevision:1,before:'Pain daily',after:'Pain stopped last week',targetIDs:['a'],evidence:[{id:'a',text:'Pain daily',title:'Note'}]});
test('reject invented targets, evidence and rewritten patient corrections',()=>{for(const change of [{targetIDs:['b']},{citationIDs:['b']},{text:'No further treatment needed'}])assert.throws(()=>storyResult(JSON.stringify({kind:'correction',text:input.after,targetIDs:['a'],citationIDs:[],question:'',...change}),input));});
test('presentation and questions cannot silently mutate facts',()=>{assert.throws(()=>storyResult(JSON.stringify({kind:'presentation',text:'',targetIDs:['a'],citationIDs:[],question:''}),input));assert.throws(()=>storyResult(JSON.stringify({kind:'correction',text:input.after,targetIDs:[],citationIDs:[],question:''}),{...input,kind:'chat'}));});
test('clear patient update accepted with exact words and temporal targets left empty',()=>{assert.equal(storyResult(JSON.stringify({kind:'correction',text:input.after,targetIDs:[],citationIDs:[],question:''}),input).text,input.after);});

test('care status changes require an explicit correction without retiring the recommendation',()=>{
 const result={kind:'correction',text:input.after,targetIDs:[],citationIDs:[],question:'',actionUpdates:[{factID:'a',status:'current'}]};
 assert.equal(storyResult(JSON.stringify(result),input).actionUpdates.length,1);
 for(const value of [{...result,kind:'presentation'},{...result,targetIDs:['a']},{...result,actionUpdates:[{factID:'other',status:'current'}]}])assert.throws(()=>storyResult(JSON.stringify(value),input));
 assert.throws(()=>storyResult(JSON.stringify(result),{...input,kind:'chat'}));
});

import {storyDraftText} from '../api/_lib/story-stream';
test('malformed candidate citations can reach repair but cannot publish',()=>{
 const bad=JSON.stringify({kind:'answer',text:'Synthetic answer',targetIDs:[],citationIDs:['invented'],question:'',actionUpdates:[]});
 const request={...input,kind:'chat' as const,conversation:[{role:'user' as const,text:'What happened before?'}]};
 assert.doesNotThrow(()=>storyPayload(request,storyCandidate(bad)));
 assert.throws(()=>storyResult(bad,request));
 const payload=storyPayload(request);const schema=(payload.response_format.json_schema as any);
 assert.equal(schema.name,'story_chat_stream_v1');assert.deepEqual(schema.schema.properties.citationIDs.items.enum,['a']);
 assert.equal(JSON.parse(payload.input).request.conversation.length,1);
});
test('stream preview exposes only text and handles split escapes',()=>{
 assert.equal(storyDraftText('{"kind":"answer","text":"Hello'), 'Hello');
 assert.equal(storyDraftText('{"text":"Hello world","citationIDs":["a"]}'),'Hello world');
 assert.equal(storyDraftText('{"kind":"answer"'),undefined);
 assert.equal(storyDraftText(JSON.stringify({text:'A "quote" and a newline\nnext'})),'A "quote" and a newline\nnext');
});
