import test from 'node:test';
import assert from 'node:assert/strict';
import {summaryActivity} from '../api/_lib/summary-progress';
test('summary activity follows real running work, including checks and repairs',()=>{
 for(const [key,label] of [['draft:0','Reading records'],['check:0','Checking sources'],['merge:0:0','Combining notes'],['merge:0:0:check','Checking sources'],['audit:0','Reviewing coverage'],['final:0:0','Writing summary'],['final:publish:check','Final checks']])assert.equal(summaryActivity('running',[{key,state:'running'}]),label);
 assert.equal(summaryActivity('running',[{key:'final:publish:check',state:'running',repair:true}]),'Refining wording');
 assert.equal(summaryActivity('running',[{key:'check:0',state:'running'},{key:'draft:1',state:'running'}]),'Reading records');
 assert.equal(summaryActivity('running',[{key:'draft:0',state:'completed'},{key:'check:0',state:'queued'}]),'Preparing summary');
 assert.equal(summaryActivity('completed',[]),'Finishing up');
 assert.equal(summaryActivity('retry_scheduled',[]),'Waiting briefly');
});
