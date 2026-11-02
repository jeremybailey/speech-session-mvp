import copy
import hashlib
import unittest
from contracts import bundle, payload, resolve, SCHEMA


class EvidenceContract(unittest.TestCase):
    def setUp(self):
        self.records = [{'id': 'original-one', 'text': 'Patient denies cough. Do not take medicine unless the clinician advises it.'},
                        {'id': 'original-two', 'text': 'Call the clinic tomorrow.'}]
        self.good = {k: [] for k in SCHEMA['properties']}
        self.good['details'] = [dict(id='d1', r='r1', category='symptoms', text='Patient denies cough.', by='patient', status='negative', event='', cite=['r1.p1']),
                                dict(id='d2', r='r2', category='carePlan', text='Call the clinic tomorrow.', by='patient', status='recommended', event='', cite=['r2.p1'])]
        self.good['recordReview'] = [dict(r='r1', excluded=[]), dict(r='r2', excluded=[])]

    def bad(self, result, pattern):
        with self.assertRaisesRegex(ValueError, pattern):
            resolve(result, self.records)

    def test_lossless_unicode_boundaries_and_hash(self):
        text = '🙂 café\r\nDr. Q said “no”. ' * 130
        records = [{'id': 'x', 'text': text, 'sourceSHA256': hashlib.sha256(text.encode()).hexdigest()}]
        source, table = bundle(records)
        self.assertEqual(''.join(x['text'] for x in source['originalRecords'][0]['passages']), text)
        self.assertTrue(all(text[v['start']:v['end']] == v['quote'] for v in table.values()))
        with self.assertRaisesRegex(ValueError, 'hash_mismatch'):
            bundle([{**records[0], 'text': text + 'x'}])

    def test_resolves_original_identity_without_fabricated_quotation(self):
        output, audit = resolve(self.good, self.records)
        self.assertEqual(output['details'][0]['sources'][0], {'recordID': 'original-one', 'quote': self.records[0]['text']})
        self.assertFalse(audit['clinicallyVerified'])
        self.assertEqual(audit['recordCount'], 2)

    def test_missing_invented_duplicate_and_wrong_record_evidence_fail(self):
        for refs in [[], ['r1.p999'], ['r1.p1', 'r1.p1'], ['r2.p1']]:
            r = copy.deepcopy(self.good); r['details'][0]['cite'] = refs
            self.bad(r, 'passage_reference|wrong_record')

    def test_omitted_record_and_passage_disposition_fail(self):
        r = copy.deepcopy(self.good); r['recordReview'].pop(); self.bad(r, 'record_review')
        r = copy.deepcopy(self.good); r['details'].pop(); self.bad(r, 'unaccounted_passages')
        r = copy.deepcopy(self.good); r['recordReview'][0]['excluded'] = [{'reason': 'nonclinical', 'passages': ['r1.p1']}]
        self.bad(r, 'conflicting_passage')

    def test_complete_exclusion_is_bookkeeping_not_clinical_acceptance(self):
        r = copy.deepcopy(self.good); r['details'].pop()
        r['recordReview'][1]['excluded'] = [{'reason': 'nonclinical', 'passages': ['r2.p1']}]
        _, audit = resolve(r, self.records)
        self.assertFalse(audit['clinicallyVerified'])
        self.assertEqual(audit['excluded'], 1)

    def test_unknown_links_and_non_plan_occurrences_fail(self):
        r = copy.deepcopy(self.good); r['conditions'] = [dict(id='c1', name='Cough', systems=[], sections=[], details=['invented'], cite=['r1.p1'])]
        self.bad(r, 'invalid_entity_link')
        r = copy.deepcopy(self.good); r['carePlans'] = [dict(id='p1', title='Wrong plan', owner='', action='Wait', followUp='', considerations='', occurrences=['d1'], conditions=[], cite=['r1.p1'])]
        self.bad(r, 'care_plan_occurrence_category')

    def test_malformed_payload_and_duplicate_identity_fail(self):
        for bad in [None, {}, [], {**self.good, 'extra': []}]:
            self.bad(bad, 'malformed_object')
        r = copy.deepcopy(self.good); r['details'][1]['id'] = 'd1'; self.bad(r, 'duplicate_or_missing_entity')
        with self.assertRaisesRegex(ValueError, 'duplicate_or_missing_original'):
            bundle([self.records[0], self.records[0]])

    def test_key_and_generated_state_cannot_enter_provider_bundle(self):
        r = [{**self.records[0], 'expectations': 'SECRET ANSWER KEY', 'summary': 'GENERATED SUMMARY'}]
        p, gate = payload(r)
        self.assertNotIn('SECRET ANSWER KEY', p['input']); self.assertNotIn('GENERATED SUMMARY', p['input'])
        self.assertEqual(gate['outputAllowance'], 64000)
        with self.assertRaisesRegex(ValueError, 'single_request_only'):
            payload(r, {})
        with self.assertRaisesRegex(ValueError, 'context_limit_exceeded'):
            payload([{'id': 'too-large', 'text': 'x' * 1_050_000}])

    def test_ambiguity_negation_and_ownership_fixture_retains_source_and_claim(self):
        r = copy.deepcopy(self.good)
        r['details'][0]['text'] = self.records[0]['text']; r['details'][0]['by'] = 'unclear'
        r['carePlans'] = [dict(id='p1', title='Call clinic', owner='patient', action='Call the clinic', followUp='tomorrow', considerations='', occurrences=['d2'], conditions=[], cite=['r2.p1'])]
        out, _ = resolve(r, self.records)
        self.assertIn('Do not', out['details'][0]['title'])
        self.assertEqual(out['details'][0]['attribution'], 'unclear')
        self.assertEqual(out['carePlans'][0]['owner'], 'patient')


if __name__ == '__main__':
    unittest.main()
