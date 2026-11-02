import copy
import unittest
import contracts_v7 as c


class ActionSchema(unittest.TestCase):
    def setUp(self):
        self.records = [{'id': 'one', 'text': 'Clinic will call tomorrow.'}]
        self.good = dict(passages={'r1.p1': [dict(k='carePlan', s='planned', v=['Clinic will call tomorrow.', 'clinician', ''], c=[], p=dict(owner='clinic', followUp='tomorrow', considerations=''))]}, conditions=[dict(id='c1', name='Pregnancy follow-up', systems=['reproductive'], details=['r1.p1.1'])], relationships=[], overview=[])

    def test_action_owner_and_app_navigation(self):
        out, audit = c.resolve(self.good, self.records)
        self.assertEqual(out['carePlans'][0]['owner'], 'clinic')
        self.assertEqual(out['conditions'][0]['appSections'], ['Pregnancy & related care'])
        self.assertFalse(audit['clinicallyVerified'])

    def test_future_metadata_and_unknown_system_fail(self):
        r = copy.deepcopy(self.good); r['passages']['r1.p1'][0]['p'] = None
        with self.assertRaisesRegex(ValueError, 'metadata_contract'): c.resolve(r, self.records)
        r = copy.deepcopy(self.good); r['conditions'][0]['systems'] = ['invented']
        with self.assertRaisesRegex(ValueError, 'body_system'): c.resolve(r, self.records)

    def test_schema_has_required_plan_for_future_actions(self):
        schema = c.schema_for(self.records); future = schema['$defs']['fact']['anyOf'][0]
        self.assertEqual(future['properties']['k']['enum'], ['carePlan'])
        self.assertEqual(future['properties']['p']['type'], 'object')
        self.assertIn('p', future['required'])


if __name__ == '__main__': unittest.main()
