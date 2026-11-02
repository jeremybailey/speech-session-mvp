import json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from run import candidate
from report import summarize
class RunnerOutcomes(unittest.TestCase):
 def test_null_uncertain_result_is_not_retried_or_counted_complete(self):
  records=[{'id':'r1','text':'Synthetic patient reports cough.'}]
  with tempfile.TemporaryDirectory() as folder:
   root=Path(folder)
   with patch('run.request',side_effect=[{'id':'synthetic-job','state':'uncertain'},{'id':'synthetic-job','state':'uncertain','result':None},{'jobs':[]}]) as send:
    result=candidate(root,'single-1',records)
   self.assertFalse(result['completed']);self.assertEqual(result['providerState'],'uncertain');self.assertEqual(result['failure'],'provider_uncertain')
   self.assertEqual([call.args[2]['action'] for call in send.call_args_list],['submit','job','status'])
   self.assertFalse((root/'single-1/output.json').exists())
 def test_unresolved_usage_is_unknown_and_reservation_is_retained(self):
  job={'id':'synthetic-job','state':'uncertain','cost_nusd':None,'reserve_nusd':'258000000','started_at':'2026-11-01T00:00:01Z','created_at':'2026-11-01T00:00:00Z'}
  report=summarize([job]);self.assertEqual(report['unresolvedReservationUSD'],.258);self.assertEqual(report['tokenUsageUnavailableJobs'],['synthetic-job']);self.assertEqual(report['reasoningUsageUnavailableJobs'],['synthetic-job'])
if __name__=='__main__':unittest.main()
