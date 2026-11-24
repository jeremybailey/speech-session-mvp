import copy,json,unittest
from contracts import payload,validate,SCHEMA
class Contracts(unittest.TestCase):
 def setUp(self):
  self.records=[{'id':'r1','text':'Synthetic patient reports cough.'}]
  self.good={k:[] for k in SCHEMA['properties']}
  self.good['details']=[{'id':'d1','recordID':'r1','category':'symptoms','title':'Cough','description':'Patient reports cough','date':'','attribution':'patient','clinicalStatus':'reported','statementType':'report','qualifiers':[],'conditionIDs':[],'sources':[{'recordID':'r1','quote':'patient reports cough'}]}]
 def test_good(self):self.assertFalse(validate(self.good,self.records)['clinicallyVerified'])
 def test_malformed(self):
  for value in [None,{},[],{'details':[]}]:
   with self.assertRaises((AssertionError,TypeError)):validate(value,self.records)
 def test_missing_reference(self):
  for refs in [[],[{'recordID':'unknown','quote':'cough'}],[{'recordID':'r1','quote':'invented'}]]:
   bad=copy.deepcopy(self.good);bad['details'][0]['sources']=refs
   with self.assertRaises(AssertionError):validate(bad,self.records)
 def test_unknown_link(self):
  bad=copy.deepcopy(self.good);bad['details'][0]['conditionIDs']=['invented']
  with self.assertRaises(AssertionError):validate(bad,self.records)
 def test_preflight(self):
  _,gate=payload(self.records);self.assertEqual(gate['outputAllowance'],64000)
  with self.assertRaises(ValueError):payload([{'id':'r','text':'x'*1_050_000}])
 def test_check_includes_same_proposal(self):
  p,_=payload(self.records,self.good);self.assertEqual(json.loads(p['input'])['unverifiedProposal'],self.good)
if __name__=='__main__':unittest.main()
