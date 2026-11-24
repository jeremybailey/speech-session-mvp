import copy
import unittest
import contracts_v10 as c
import test_contracts_v9 as fixtures


class SourceTimeStates(unittest.TestCase):
    def setUp(self):
        f=fixtures.ConcernFirst();f.setUp();self.records=f.records;self.good=copy.deepcopy(f.good);self.pid=f.pids[-1]

    def test_advice_cannot_be_marked_resolved_or_lose_plan_metadata(self):
        for status in ('resolved','observed'):
            r=copy.deepcopy(self.good);r['passages'][self.pid][0]['s']=status
            with self.assertRaisesRegex(ValueError,'care_state'):c.resolve(r,self.records)
        r=copy.deepcopy(self.good);r['passages'][self.pid][0]['p']=None
        with self.assertRaisesRegex(ValueError,'metadata'):c.resolve(r,self.records)

    def test_past_care_retains_actor_and_status_without_becoming_a_future_instruction(self):
        r=copy.deepcopy(self.good);r['passages'][self.pid][0]['s']='performed'
        out,a=c.resolve(r,self.records)
        self.assertEqual(out['carePlans'][0]['sourceStatus'],'performed')
        self.assertEqual(out['carePlans'][0]['owner'],'clinic')
        self.assertEqual(a['pastCareCards'],1);self.assertFalse(a['clinicallyVerified'])

    def test_schema_requires_metadata_for_all_care_states(self):
        branch=c.schema_for(self.records)['$defs']['fact']['anyOf'][0]
        self.assertNotIn('resolved',branch['properties']['s']['enum'])
        self.assertEqual(branch['properties']['p']['type'],'object')

    def test_future_lab_order_routes_as_action_without_rewriting_claim(self):
        r=copy.deepcopy(self.good);fact=r['passages'][self.pid][0];fact['k']='testsAndLabs'
        out,a=c.resolve(r,self.records)
        self.assertEqual(out['details'][0]['category'],'carePlan')
        self.assertEqual(out['details'][0]['title'],fact['v'][0])
        self.assertEqual(out['carePlans'][0]['owner'],'clinic')
        self.assertTrue(a['categoryAdjustments'])


if __name__=='__main__':unittest.main()
