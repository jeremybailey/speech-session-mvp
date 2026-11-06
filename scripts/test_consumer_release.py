import unittest
from check_consumer_release import failures
class ReleaseGateTests(unittest.TestCase):
    def test_missing_or_provisional_evidence_fails(self):
        self.assertIn('answer key is not adjudicated',failures({}))
        self.assertIn('supportedPrecision',failures({'supportedPrecision':True}))
    def test_hiding_an_expected_fact_cannot_be_counted_as_recall(self):
        self.assertIn('materialRecall',failures({'materialRecall':.94}))
    def test_speed_without_quality_is_not_a_release(self):
        self.assertIn('criticalErrors',failures({'criticalErrors':1,'newRecordP95Seconds':1}))
if __name__=='__main__':unittest.main()
