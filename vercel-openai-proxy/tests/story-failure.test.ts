import test from 'node:test';
import assert from 'node:assert/strict';
import {storyOperationFailure} from '../api/_lib/story-failure';
test('chat distinguishes capacity, authentication and invalid requests without leaking exceptions',()=>{
 assert.deepEqual(storyOperationFailure(Error('budget_exhausted')),{status:429,code:'budget_exhausted'});
 assert.deepEqual(storyOperationFailure({status:401}),{status:401,code:'authentication_required'});
 assert.deepEqual(storyOperationFailure(Error('revision_conflict')),{status:409,code:'revision_conflict'});
 assert.deepEqual(storyOperationFailure(Error('invalid_reference')),{status:422,code:'invalid_request'});
 assert.deepEqual(storyOperationFailure(Error('private payload')),{status:503,code:'operation_unavailable'});
});
