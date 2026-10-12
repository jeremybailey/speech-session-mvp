import json,tempfile,unittest,subprocess,sys
from pathlib import Path
from report import summary
class ReportingTests(unittest.TestCase):
 def test_original_transcript_change_is_detected(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);run=root/'baseline-1';(run/'store').mkdir(parents=True);(run/'trace').mkdir()
   (run/'run.json').write_text(json.dumps({'run':'baseline-1','completed':True,'cold':True,'elapsedSeconds':60}))
   (root/'seed.json').write_text(json.dumps({'sessions':[{'id':'one','transcript':'Original synthetic text'}]}))
   (run/'store/sessions.json').write_text(json.dumps({'sessions':[{'id':'one','transcript':'Changed synthetic text'}]}))
   self.assertFalse(summary(root)['runs'][0]['sourceTranscriptsPreserved'])
   (run/'store/sessions.json').write_bytes((root/'seed.json').read_bytes())
   self.assertTrue(summary(root)['runs'][0]['sourceTranscriptsPreserved'])
 def test_invalid_workflow_without_result_is_reported(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);trace=root/'trace';trace.mkdir()
   (trace/'workflow.receipt.json').write_text(json.dumps({'state':'invalid','result':None}))
   result=json.loads(subprocess.check_output([sys.executable,str(Path(__file__).with_name('progress.py')),str(root)]))
   self.assertEqual(result['failures'][0]['state'],'invalid')
   self.assertIsNone(result['failures'][0]['diagnostics'])
 def test_incomplete_and_unreviewed_runs_cannot_qualify(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp)
   for arm,time,complete in [('baseline',100,True),('parallel',40,False),('hybrid',40,True)]:
    for n in range(1,4):
     p=root/f'{arm}-{n}';p.mkdir();(p/'trace').mkdir()
     (p/'run.json').write_text(json.dumps({'run':p.name,'completed':complete,'elapsedSeconds':time,'cold':True}))
   result=summary(root)
   self.assertNotIn('parallel',result['completedMediansSeconds']);self.assertEqual(result['releaseEligibleArms'],[])
   self.assertEqual(result['timeRatioToBaseline']['hybrid'],.4)
 def test_cached_retries_do_not_enter_cold_medians(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);run=root/'baseline-1';run.mkdir();(run/'trace').mkdir()
   (run/'run.json').write_text(json.dumps({'run':'baseline-1','completed':True,'elapsedSeconds':1,'cold':False}))
   self.assertEqual(summary(root)['completedMediansSeconds'],{})
 def test_versioned_run_cost_is_separate_but_cap_remains_cumulative(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);run=root/'baseline-1';run.mkdir();(run/'trace').mkdir()
   (root/'manifest.json').write_text(json.dumps({'prefix':'test:','ownerPrefix':'test:repair:'}))
   (run/'run.json').write_text(json.dumps({'run':'baseline-1','completed':True,'cold':True,'elapsedSeconds':60}))
   jobs=[{'id':owner,'owner':owner,'state':'completed','stage':'checking','cost_nusd':'1000000','reserve_nusd':'10000000','provider_seconds':3} for owner in ['test:baseline-1','test:repair:baseline-1']]
   (root/'status-cleanup.json').write_text(json.dumps({'jobs':jobs}))
   result=summary(root)
   self.assertEqual(result['experimentAccounting']['settledUSD'],.002)
   self.assertEqual(result['runs'][0]['ledgerCostUSD'],.001)
   self.assertEqual(result['runs'][0]['providerSecondsRecorded'],3)
   self.assertEqual(result['runs'][0]['providerTimedRequests'],1)
 def test_accounting_includes_uncertain_and_child_jobs_without_claiming_occurrence_audit(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);run=root/'baseline-1';run.mkdir();(run/'trace').mkdir()
   (root/'manifest.json').write_text(json.dumps({'prefix':'test:'}))
   (run/'run.json').write_text(json.dumps({'run':'baseline-1','completed':False,'elapsedSeconds':30,'originalOccurrenceCount':0,'sourceOccurrencesPreserved':True}))
   jobs=[{'id':'one','owner':'test:baseline-1','state':'incomplete','stage':'extraction','cost_nusd':'3000000','reserve_nusd':'10000000'}, {'id':'two','owner':'test:baseline-1','state':'uncertain','stage':'conditions','cost_nusd':None,'reserve_nusd':'20000000'}]
   (root/'status-cleanup.json').write_text(json.dumps({'jobs':jobs}))
   result=summary(root);self.assertEqual(result['experimentAccounting']['settledUSD'],.003)
   self.assertEqual(result['experimentAccounting']['unresolvedReservationUSD'],.02)
   row=result['runs'][0];self.assertEqual(row['ledgerRequestCount'],2)
   self.assertIsNone(row['sourceOccurrencesPreserved']);self.assertEqual(len(row['completionFailures']),2)
if __name__=='__main__':unittest.main()
