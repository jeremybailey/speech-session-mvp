import test from 'node:test';
import assert from 'node:assert/strict';
import {qualifierRegressions} from '../scripts/summary-benchmark-qualifiers';
test('speed probes detect a preference strengthened into a commitment',()=>{
 assert.deepEqual(qualifierRegressions('Vitamin K — tentatively okay for newborn','Vitamin K — agreed for newborn'),['vitamin-k-preference']);
 assert.deepEqual(qualifierRegressions('Vitamin K — tentatively okay for newborn','Vitamin K — tentative newborn preference'),[]);
});
test('speed probes detect lost medication status and conditional procedures',()=>{
 const before='Budesonide — not started\nMontelukast — stopped\nMRI — deferred unless symptoms persist';
 assert.deepEqual(qualifierRegressions(before,'Budesonide — prescribed\nMontelukast — current\nMRI — booked'),['budesonide-unstarted','montelukast-stopped','mri-conditional']);
 assert.deepEqual(qualifierRegressions(before,before),[]);
});
test('speed probes keep qualifications attached to their own topic',()=>{
 assert.deepEqual(qualifierRegressions('Penicillin — anaphylaxis','Penicillin allergy\nAnother drug — anaphylaxis'),['penicillin-anaphylaxis']);
});
