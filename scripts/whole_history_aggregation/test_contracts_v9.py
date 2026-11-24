import copy
import unittest
import contracts_v9 as c


class ConcernFirst(unittest.TestCase):
    def setUp(self):
        self.records=[{'id':'one','text':'Header date. '+'x'*430+' Clinic will call tomorrow.'}]
        _,table=c.bundle(self.records);self.pids=list(table)
        self.good=dict(concerns=[dict(id='c1',name='Follow-up concern',systems=['unknown'],evidence=[self.pids[-1]])],overview=[dict(text='Follow-up is planned.',cite=[self.pids[-1]])],passages={p:'nonclinical' for p in self.pids})
        self.good['passages'][self.pids[-1]]=[dict(k='followUp',s='planned',v=['Clinic will call tomorrow.','clinician',''],c=[self.pids[0]],p=dict(owner='clinic',followUp='tomorrow',considerations=''),g=['c1'])]

    def test_context_only_header_is_valid_without_inventing_a_fact(self):
        out,a=c.resolve(self.good,self.records)
        self.assertEqual(a['contextOnlySources'],{self.pids[0]:'nonclinical'})
        self.assertEqual(len(out['details']),1);self.assertEqual(out['carePlans'][0]['owner'],'clinic')
        self.assertFalse(a['clinicallyVerified'])

    def test_unknown_group_source_or_wrong_record_remains_rejected(self):
        r=copy.deepcopy(self.good);r['passages'][self.pids[-1]][0]['g']=['c99']
        with self.assertRaisesRegex(ValueError,'concern_link'):c.resolve(r,self.records)
        r=copy.deepcopy(self.good);r['passages'][self.pids[-1]][0]['c']=['invented']
        with self.assertRaisesRegex(ValueError,'source_reference'):c.resolve(r,self.records)

    def test_missing_organization_and_metadata_cannot_pass(self):
        r=copy.deepcopy(self.good);r['concerns']=[]
        with self.assertRaisesRegex(ValueError,'organization'):c.resolve(r,self.records)
        r=copy.deepcopy(self.good);r['passages'][self.pids[-1]][0]['p']=None
        with self.assertRaisesRegex(ValueError,'metadata'):c.resolve(r,self.records)

    def test_schema_plans_first_and_limits_references_to_actual_originals(self):
        schema=c.schema_for(self.records)
        self.assertEqual(list(schema['properties']),['concerns','overview','passages'])
        self.assertEqual(schema['$defs']['sourceRef']['enum'],self.pids)
        self.assertEqual(schema['properties']['concerns']['minItems'],1)
        self.assertEqual(schema['properties']['overview']['minItems'],1)

    def test_redundant_context_is_a_reference_set_without_dropping_distinct_evidence(self):
        r=copy.deepcopy(self.good);r['passages'][self.pids[-1]][0]['c']=[self.pids[-1],self.pids[0]]
        out,a=c.resolve(r,self.records)
        self.assertEqual(len(out['details'][0]['sources']),2)
        self.assertTrue(a['deduplicatedReferenceLists'])


if __name__=='__main__':unittest.main()
