import copy
import unittest
import contracts_v5 as c


class FixedColumns(unittest.TestCase):
    def setUp(self):
        self.records = [{'id': 'one', 'text': 'Clinician: call tomorrow.'}, {'id': 'two', 'text': 'Another visit: call tomorrow.'}]
        self.good = dict(passages={pid: [['carePlan', 'Call tomorrow.', 'clinician', 'recommended', '', '', 'patient', 'tomorrow', '']] for pid in ('r1.p1', 'r2.p1')}, conditions=[], relationships=[], overview=[])

    def test_columns_preserve_claim_owner_and_unknown_date_occurrences(self):
        out, audit = c.resolve(self.good, self.records)
        self.assertEqual(len(out['details']), 2)
        self.assertEqual(len(out['carePlans']), 2)
        self.assertEqual(out['carePlans'][0]['owner'], 'patient')
        self.assertFalse(audit['clinicallyVerified'])
        self.assertEqual(out['details'][0]['sources'][0]['quote'], self.records[0]['text'])

    def test_exact_duplicate_source_retains_occurrences_in_one_card(self):
        records = [self.records[0], {**self.records[0], 'id': 'two'}]
        out, _ = c.resolve(self.good, records)
        self.assertEqual(len(out['carePlans']), 1)
        self.assertEqual(len(out['carePlans'][0]['occurrenceIDs']), 2)

    def test_column_count_wrong_type_bad_reference_and_sentinel_content_fail(self):
        for case in ('length', 'type', 'reference', 'sentinel'):
            r = copy.deepcopy(self.good); row = r['passages']['r1.p1'][0]
            if case == 'length': row.pop()
            elif case == 'type': row[0] = 12
            elif case == 'reference': row[5] = 'invented'
            else: row[0] = 'nonclinical'
            with self.assertRaises(ValueError): c.resolve(r, self.records)

    def test_patient_history_does_not_become_a_task(self):
        r = copy.deepcopy(self.good); row = r['passages']['r1.p1'][0]; row[0] = 'medications'; row[3] = 'reported'
        with self.assertRaisesRegex(ValueError, 'non_action'): c.resolve(r, self.records)
        row[6:] = ['', '', '']; out, _ = c.resolve(r, self.records)
        self.assertEqual(len(out['carePlans']), 1)

    def test_omitted_passage_and_csv_id_guessing_fail(self):
        r = copy.deepcopy(self.good); r['passages'].pop('r1.p1')
        with self.assertRaisesRegex(ValueError, 'passage'): c.resolve(r, self.records)
        r = copy.deepcopy(self.good); r['conditions'] = [['c1', 'Concern', '', '', 'r1.p1.99']]
        with self.assertRaisesRegex(ValueError, 'invalid_entity_link'): c.resolve(r, self.records)


if __name__ == '__main__':
    unittest.main()
