import test from 'node:test';import assert from 'node:assert/strict';import {splitHandoffItems} from '../api/_lib/summary-punctuation';
test('split top-level qualifiers without dropping or inventing text',()=>{
 assert.deepEqual(splitHandoffItems('Care — declined; possible review'),['Care — declined','Care — possible review']);
 for(const text of ['Care — “declined; possible review”','Care — declined (today; optional later)','Care — declined;','No topic; unchanged'])assert.deepEqual(splitHandoffItems(text),[text]);
});
