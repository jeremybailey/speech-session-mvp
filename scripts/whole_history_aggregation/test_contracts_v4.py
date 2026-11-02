import copy
import unittest
import contracts_v4 as c


class LocalCardProjection(unittest.TestCase):
    def setUp(self):
        self.records = [{'id': 'one', 'text': 'Clinician: patient should call tomorrow.'},
                        {'id': 'two', 'text': 'Clinician: patient should call tomorrow.'}]
        self.good = {'passages': {}, 'conditions': [], 'relationships': [], 'overview': []}
        for pid in ('r1.p1', 'r2.p1'):
            self.good['passages'][pid] = {'disposition': 'used', 'facts': [dict(category='carePlan', text='Patient should call tomorrow.', by='clinician', status='recommended', event='', context=[], plan=dict(owner='patient', followUp='tomorrow', considerations=''))]}

    def test_same_action_preserves_both_occurrences_and_original_quotes(self):
        out, audit = c.resolve(self.good, self.records)
        self.assertEqual(len(out['carePlans']), 1)
        self.assertEqual(out['carePlans'][0]['occurrenceIDs'], ['r1.p1.1', 'r2.p1.1'])
        self.assertEqual({x['recordID'] for x in out['carePlans'][0]['sources']}, {'one', 'two'})
        self.assertEqual(out['carePlans'][0]['owner'], 'patient')
        self.assertFalse(audit['clinicallyVerified'])

    def test_distinct_owner_timing_or_status_cannot_merge(self):
        for change in ('owner', 'timing', 'status'):
            r = copy.deepcopy(self.good); f = r['passages']['r2.p1']['facts'][0]
            if change == 'owner': f['plan']['owner'] = 'clinic'
            elif change == 'timing': f['plan']['followUp'] = 'next week'
            else: f['status'] = 'conditional'
            self.assertEqual(len(c.resolve(r, self.records)[0]['carePlans']), 2)

    def test_unknown_owner_stays_empty_and_non_action_task_is_rejected(self):
        r = copy.deepcopy(self.good); r['passages']['r1.p1']['facts'][0]['plan']['owner'] = ''
        out, _ = c.resolve(r, self.records)
        self.assertEqual(out['carePlans'][0]['owner'], '')
        for category, status in [('symptoms', 'reported'), ('medications', 'reported'), ('carePlan', 'performed')]:
            r = copy.deepcopy(self.good); f = r['passages']['r1.p1']['facts'][0]; f.update(category=category, status=status)
            with self.assertRaisesRegex(ValueError, 'non_action|past_intervention'):
                c.resolve(r, self.records)

    def test_unsupported_condition_links_and_missing_action_metadata_fail(self):
        r = copy.deepcopy(self.good); r['conditions'] = [dict(id='c1', name='Invented', systems=[], sections=[], details=['invented'])]
        with self.assertRaisesRegex(ValueError, 'invalid_entity_link'): c.resolve(r, self.records)
        r = copy.deepcopy(self.good); r['passages']['r1.p1']['facts'][0]['plan'] = None
        with self.assertRaisesRegex(ValueError, 'ownership_metadata'): c.resolve(r, self.records)


if __name__ == '__main__':
    unittest.main()
