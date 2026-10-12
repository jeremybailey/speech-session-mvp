import unittest
from transport_errors import error_message
class TransportErrorsTests(unittest.TestCase):
 def test_protected_deployment_is_auth_failure(self):
  self.assertEqual(error_message({'error':{'code':'401','message':'Protected deployment'},'protection':{}}),'Benchmark deployment authentication rejected (HTTP 401); no automatic retry')
 def test_unknown_structured_error_does_not_expose_body(self):
  self.assertNotIn('private content',error_message({'error':{'message':'private content'}}))
 def test_endpoint_errors_and_success_remain_distinct(self):
  self.assertEqual(error_message({'error':'experiment_budget_exhausted'}),'experiment_budget_exhausted')
  self.assertIsNone(error_message({'id':'job-id','state':'completed','result':{'output':'clinical text'}}))
 def test_nonobject_response_is_transport_failure(self):
  self.assertIn('transport',error_message([]))
if __name__=='__main__':unittest.main()
