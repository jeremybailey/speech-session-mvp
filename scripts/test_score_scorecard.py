"""Synthetic checks for score arithmetic, exclusions and identity isolation."""
import hashlib
import unittest
import sys
sys.dont_write_bytecode = True
from score_scorecard import score


class ScorecardTests(unittest.TestCase):
    def setUp(self):
        self.key = {'sheets': {
            'Records': {'values': [['R1', 'Synthetic', 'Example source.']]},
            'Expected items': {'values': [['I001', 'R1', 'Must appear', 'Example meaning', '', '', '', '', '', '', '', '', '', '', 'Not scored', '', '', '', 'Draft']]}}}
        self.output = {'recordID': 'R1', 'sourceSHA256': hashlib.sha256(b'Example source.').hexdigest(),
                       'entries': [{'id': 'E1', 'sourceSessionID': 'R1', 'visible': True}]}
        self.judgments = {'items': {'I001': {'entryIDs': ['E1'], 'reason': 'Synthetic reviewed match.',
            'extractedCore': True, 'visibleCore': True,
            'checks': {**dict.fromkeys(['meaning', 'qualifiers', 'category', 'statementType', 'clinicalStatus', 'attribution', 'date'], 'Pass'),
                       **dict.fromkeys(['conditionLinks', 'bodySystem', 'appSection'], 'Not scored')}}}}

    def test_draft_excluded_by_default(self):
        self.assertEqual(score(self.key, self.output, self.judgments)['score']['scored'], 0)

    def test_opt_in_draft_has_separate_reviewed_denominator(self):
        result = score(self.key, self.output, self.judgments, True)
        self.assertEqual(result['score']['percent'], 100)
        self.assertEqual(result['reviewedScore']['scored'], 0)

    def test_one_required_failure_fails_row(self):
        self.judgments['items']['I001']['checks']['qualifiers'] = 'Fail'
        self.assertEqual(score(self.key, self.output, self.judgments, True)['score']['passed'], 0)

    def test_hidden_correct_draft_does_not_pass(self):
        self.output['entries'][0]['visible'] = False
        self.judgments['items']['I001']['visibleCore'] = False
        self.assertEqual(score(self.key, self.output, self.judgments, True)['score']['passed'], 0)

    def test_unresolved_stays_excluded_in_provisional_mode(self):
        self.key['sheets']['Expected items']['values'][0][18] = 'Unresolved'
        self.assertEqual(score(self.key, self.output, self.judgments, True)['score']['scored'], 0)

    def test_cross_record_match_rejected(self):
        self.output['entries'][0]['sourceSessionID'] = 'R2'
        with self.assertRaises(AssertionError): score(self.key, self.output, self.judgments, True)

    def test_changed_source_rejected(self):
        self.output['sourceSHA256'] = 'changed'
        with self.assertRaises(AssertionError): score(self.key, self.output, self.judgments, True)

    def test_missing_required_dimension_rejected(self):
        del self.judgments['items']['I001']['checks']['date']
        with self.assertRaises(AssertionError): score(self.key, self.output, self.judgments, True)

    def test_prohibited_visible_claim_cannot_pass(self):
        self.key['sheets']['Expected items']['values'][0][2] = 'Must not appear'
        self.judgments['items']['I001']['checks'] = {'absence': 'Pass'}
        self.assertEqual(score(self.key, self.output, self.judgments, True)['score']['passed'], 0)


if __name__ == '__main__': unittest.main()
