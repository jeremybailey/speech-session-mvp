import copy
import unittest
import contracts_v2 as contract
import test_contracts as fixtures


class RequiredCoverage(unittest.TestCase):
    def setUp(self):
        fixture = fixtures.EvidenceContract(); fixture.setUp()
        self.records = fixture.records
        self.good = copy.deepcopy(fixture.good)
        self.good.pop('recordReview')
        self.good['passageReview'] = {'r1.p1': 'used', 'r2.p1': 'used'}
        self.good['carePlans'] = [dict(id='p1', title='Call clinic', owner='patient', action='Call the clinic', followUp='tomorrow', considerations='', occurrences=['d2'], conditions=[], cite=['r2.p1'])]

    def test_schema_requires_every_passage_with_shared_disposition_type(self):
        p, _ = contract.payload(self.records)
        schema = p['response_format']['json_schema']['schema']
        coverage = schema['properties']['passageReview']
        self.assertEqual(coverage['required'], ['r1.p1', 'r2.p1'])
        self.assertFalse(coverage['additionalProperties'])
        self.assertEqual(coverage['properties']['r1.p1'], {'$ref': '#/$defs/disposition'})
        self.assertEqual(schema['properties']['details']['items']['properties']['cite']['maxItems'], 3)

    def test_good_and_absent_or_conflicting_disposition(self):
        _, audit = contract.resolve(self.good, self.records)
        self.assertFalse(audit['clinicallyVerified'])
        for action in ('delete', 'conflict'):
            r = copy.deepcopy(self.good)
            if action == 'delete':
                r['passageReview'].pop('r1.p1')
            else:
                r['passageReview']['r1.p1'] = 'nonclinical'
            with self.assertRaisesRegex(ValueError, 'disposition|conflicting_passage'):
                contract.resolve(r, self.records)

    def test_plan_without_card_or_nonatomic_blob_rejected(self):
        r = copy.deepcopy(self.good); r['carePlans'] = []
        with self.assertRaisesRegex(ValueError, 'missing_card'):
            contract.resolve(r, self.records)
        r = copy.deepcopy(self.good); r['details'][0]['text'] = 'x' * 361
        with self.assertRaisesRegex(ValueError, 'length_limit'):
            contract.resolve(r, self.records)


if __name__ == '__main__':
    unittest.main()
