import copy
import unittest
from compare_scorecards import compare


class ComparisonTests(unittest.TestCase):
    def fixture(self):
        return {'keySHA256': 'synthetic-key', 'recordID': 'synthetic-record', 'sourceSHA256': 'synthetic-source',
                'mode': 'provisional-draft', 'score': {'passed': 0, 'scored': 1, 'percent': 0},
                'corePresence': {'expectedPositiveRows': 1, 'extracted': 1, 'visible': 0},
                'rows': [{'itemID': 'I001', 'result': 'Fail', 'extractedCore': True, 'visibleCore': False,
                          'checks': {'visibility': 'Fail'}, 'reason': 'Synthetic hidden fact'}]}

    def test_changed_key_or_denominator_cannot_masquerade_as_improvement(self):
        old = self.fixture()
        for field in ['keySHA256', 'sourceSHA256', 'recordID', 'mode']:
            new = copy.deepcopy(old); new[field] = 'different'
            with self.assertRaises(ValueError): compare(old, new)
        new = copy.deepcopy(old); new['rows'][0]['result'] = 'Excluded'
        with self.assertRaises(ValueError): compare(old, new)

    def test_visibility_gain_is_not_a_full_pass_until_other_checks_pass(self):
        old = self.fixture(); new = copy.deepcopy(old)
        new['rows'][0]['visibleCore'] = True
        new['rows'][0]['checks'] = {'visibility': 'Pass', 'qualifiers': 'Fail'}
        result = compare(old, new)
        self.assertEqual(result['newPasses'], [])
        self.assertEqual(len(result['changes']), 1)
        new['rows'][0]['result'] = 'Pass'; new['rows'][0]['checks']['qualifiers'] = 'Pass'
        new['score']['passed'] = 1
        self.assertEqual(compare(old, new)['newPasses'], ['I001'])
        self.assertEqual(compare(new, old)['regressions'], ['I001'])


if __name__ == '__main__': unittest.main()
