import copy
import unittest
import contracts_v3 as c


class PassageAlignedContract(unittest.TestCase):
    def setUp(self):
        self.records = [{'id': 'one', 'text': 'Patient denies cough.'}, {'id': 'two', 'text': 'Label: take one tablet daily.'}]
        self.good = {k: [] for k in ('conditions', 'relationships', 'carePlans', 'overview')}
        self.good['passages'] = {
            'r1.p1': {'disposition': 'used', 'facts': [dict(category='symptoms', text='Patient denies cough.', by='patient', status='negative', event='', context=[])]},
            'r2.p1': {'disposition': 'used', 'facts': [dict(category='medications', text='Label directs one tablet daily; actual use unknown.', by='label', status='prescribed', event='', context=[])]}}
        self.good['carePlans'] = [dict(id='p1', title='Label directions', owner='patient', action='One tablet daily', followUp='', considerations='Actual use unknown', occurrences=['r2.p1.1'], conditions=[], cite=['r2.p1'])]

    def test_local_fact_identity_and_prescribed_medication_card(self):
        out, audit = c.resolve(self.good, self.records)
        self.assertEqual([d['id'] for d in out['details']], ['r1.p1.1', 'r2.p1.1'])
        self.assertEqual(out['details'][1]['category'], 'medications')
        self.assertEqual(out['details'][0]['sources'], [{'recordID': 'one', 'quote': self.records[0]['text']}])
        self.assertFalse(audit['clinicallyVerified'])

    def test_missing_passage_empty_used_and_hidden_facts_fail(self):
        for mode in ['missing', 'empty', 'hidden']:
            r = copy.deepcopy(self.good)
            if mode == 'missing':
                r['passages'].pop('r1.p1')
            elif mode == 'empty':
                r['passages']['r1.p1']['facts'] = []
            else:
                r['passages']['r1.p1']['disposition'] = 'nonclinical'
            with self.assertRaisesRegex(ValueError, 'passage'):
                c.resolve(r, self.records)

    def test_unknown_and_cross_record_context_fail(self):
        for ref in ['invented', 'r2.p1', 'r1.p1']:
            r = copy.deepcopy(self.good); r['passages']['r1.p1']['facts'][0]['context'] = [ref]
            with self.assertRaisesRegex(ValueError, 'reference|wrong_record'):
                c.resolve(r, self.records)

    def test_medication_history_cannot_become_card_or_missing_link_invented(self):
        r = copy.deepcopy(self.good); r['passages']['r2.p1']['facts'][0]['status'] = 'reported'
        with self.assertRaisesRegex(ValueError, 'occurrence_category'):
            c.resolve(r, self.records)
        r = copy.deepcopy(self.good); r['carePlans'][0]['occurrences'] = ['r2.p1.99']
        with self.assertRaisesRegex(ValueError, 'invalid_entity_link'):
            c.resolve(r, self.records)

    def test_schema_and_input_require_all_originals_without_expectations(self):
        p, gate = c.payload([{**r, 'expectations': 'DO NOT SEND'} for r in self.records])
        self.assertNotIn('DO NOT SEND', p['input'])
        schema = p['response_format']['json_schema']['schema']
        self.assertEqual(schema['properties']['passages']['required'], ['r1.p1', 'r2.p1'])
        self.assertEqual(gate['outputAllowance'], 64000)


if __name__ == '__main__':
    unittest.main()
