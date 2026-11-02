import copy
import unittest
import contracts_v6 as c


class TypedContextAndOwner(unittest.TestCase):
    def setUp(self):
        self.records = [{'id': 'one', 'text': 'Clinic will call with results.'}]
        self.good = dict(passages={'r1.p1': [dict(v=['contacts', 'Clinic will call with results.', 'clinician', 'planned', ''], c=[], p=dict(owner='clinic', followUp='when results available', considerations=''))]}, conditions=[], relationships=[], overview=[])

    def test_followup_action_keeps_raw_contact_category_and_explicit_owner(self):
        out, audit = c.resolve(self.good, self.records)
        self.assertEqual(out['details'][0]['category'], 'contacts')
        self.assertEqual(out['carePlans'][0]['owner'], 'clinic')
        self.assertEqual(audit['actionCategoryCompatibility'], {'r1.p1.1': 'contacts'})
        self.assertFalse(audit['clinicallyVerified'])

    def test_locator_cannot_become_owner_or_be_relocated(self):
        r = copy.deepcopy(self.good); r['passages']['r1.p1'][0]['p']['owner'] = 'r1.p1'
        with self.assertRaisesRegex(ValueError, 'not_plan_owner'): c.resolve(r, self.records)
        r = copy.deepcopy(self.good); r['passages']['r1.p1'][0]['c'] = ['invented']
        with self.assertRaisesRegex(ValueError, 'reference'): c.resolve(r, self.records)

    def test_past_contact_does_not_become_future_task(self):
        r = copy.deepcopy(self.good); r['passages']['r1.p1'][0]['v'][3] = 'historical'
        with self.assertRaisesRegex(ValueError, 'non_action'): c.resolve(r, self.records)

    def test_nonclinical_and_missing_source_are_explicit(self):
        r = copy.deepcopy(self.good); r['passages']['r1.p1'] = 'nonclinical'
        self.assertEqual(len(c.resolve(r, self.records)[0]['details']), 0)
        r['passages'] = {}
        with self.assertRaisesRegex(ValueError, 'passage'): c.resolve(r, self.records)


if __name__ == '__main__': unittest.main()
