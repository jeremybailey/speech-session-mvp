import copy
import unittest
import contracts_v8 as c


class FullAppCategories(unittest.TestCase):
    def setUp(self):
        self.records=[{'id':'one','text':'Patient reports an intolerance; lab result normal; clinic will call.'}]
        self.good=dict(passages={'r1.p1':[
            dict(k='allergies',s='reported',v=['Patient reports intolerance.','patient',''],c=[],p=None),
            dict(k='testsAndLabs',s='observed',v=['Lab result normal.','lab',''],c=[],p=None),
            dict(k='followUp',s='planned',v=['Clinic will call.','clinician',''],c=[],p=dict(owner='clinic',followUp='',considerations=''))]},conditions=[],relationships=[],overview=[])

    def test_allergy_lab_and_followup_categories_preserved(self):
        out,a=c.resolve(self.good,self.records)
        self.assertEqual([d['category'] for d in out['details']],['allergies','testsAndLabs','followUp'])
        self.assertEqual(out['carePlans'][0]['owner'],'clinic');self.assertEqual(len(a['appCategories']),12)
        self.assertFalse(a['clinicallyVerified'])

    def test_non_action_category_cannot_create_task(self):
        r=copy.deepcopy(self.good);r['passages']['r1.p1'][0]['p']=dict(owner='patient',followUp='',considerations='')
        with self.assertRaisesRegex(ValueError,'non_action'):c.resolve(r,self.records)

    def test_schema_covers_every_real_app_category(self):
        branches=c.schema_for(self.records)['$defs']['fact']['anyOf']
        self.assertEqual({k for b in branches for k in b['properties']['k']['enum']},set(c.CATEGORIES))
        self.assertNotIn('contacts',c.CATEGORIES);self.assertNotIn('other',c.CATEGORIES)


if __name__=='__main__':unittest.main()
