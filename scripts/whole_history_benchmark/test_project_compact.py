import copy, hashlib, unittest
from project_compact import project
import json

class CompactProjection(unittest.TestCase):
 def fixture(self):
  record={'id':'record-a','text':'Synthetic headache.','sourceSHA256':hashlib.sha256(b'Synthetic headache.').hexdigest()}
  fact={'k':'symptoms','s':'reported','v':['Headache','Patient',''],'c':[],'g':['c1'],'p':None,'m':None,'f':[]}
  wire={'concerns':[{'id':'c1','name':'Headache','systems':['neurological'],'evidence':['r1.p1']}],'passages':{'r1.p1':[fact]}}
  envelope={'result':{'output':json.dumps(wire)},'locators':{'r1.p1':{'recordID':'record-a','sourceSHA256':record['sourceSHA256'],'quote':record['text']}}}
  return [record],envelope,wire
 def test_preserves_source_identity_and_explicit_graph_without_promoting_trust(self):
  records,envelope,_=self.fixture();entries,graph=project(records,envelope)
  self.assertEqual(entries['record-a'][0]['statement'],'Headache')
  self.assertFalse(entries['record-a'][0]['accepted'])
  self.assertFalse(graph['clinicallyVerified'])
  self.assertEqual(graph['entities'][-1]['from'],'r1.p1.f1')
  self.assertEqual(graph['entities'][-1]['to'],'c1')
 def test_bucket_adapter_keeps_identity_and_rejects_missing_source(self):
  records,envelope,wire=self.fixture()
  categories=['chiefComplaint','symptoms','findings','medications','carePlan','practitionerContact','vaccinations','allergies','testsAndLabs','followUp','biopsychosocialContext','otherNotes']
  fact=wire['passages']['r1.p1'][0];fact.pop('k');fact['r']='r1.p1'
  wire={'concerns':wire['concerns'],'overview':[],'facts':{k:[] for k in categories},'ignored':[]};wire['facts']['symptoms']=[fact]
  envelope['result']['output']=json.dumps(wire)
  entries,graph=project(records,envelope);self.assertEqual(entries['record-a'][0]['id'],'r1.p1.f1')
  wire['ignored']=[{'r':'r1.p1','reason':'nonclinical'}];envelope['result']['output']=json.dumps(wire)
  with self.assertRaisesRegex(AssertionError,'Contradictory ignore marker'):project(records,envelope)
 def test_ignored_passage_stays_available_for_omission_review(self):
  records,envelope,wire=self.fixture();wire['passages']['r1.p1']='nonclinical';envelope['result']['output']=json.dumps(wire)
  entries,graph=project(records,envelope);self.assertEqual(entries['record-a'],[])
  self.assertEqual(graph['entities'][0]['kind'],'ignoredPassage')
 def test_rejects_changed_source_and_cross_record_reference(self):
  records,envelope,wire=self.fixture();bad=copy.deepcopy(records);bad[0]['text']='Changed'
  with self.assertRaisesRegex(AssertionError,'Source hash mismatch'):project(bad,envelope)
  envelope['locators']['r2.p1']={'recordID':'record-b','quote':'Other'}
  wire['passages']['r2.p1']='nonclinical';wire['passages']['r1.p1'][0]['c']=['r2.p1'];envelope['result']['output']=json.dumps(wire)
  with self.assertRaisesRegex(AssertionError,'Cross-record reference'):project(records,envelope)
 def test_rejects_unknown_concern_and_ungrounded_locator(self):
  records,envelope,wire=self.fixture();wire['passages']['r1.p1'][0]['g']=['invented'];envelope['result']['output']=json.dumps(wire)
  with self.assertRaisesRegex(AssertionError,'Unknown concern'):project(records,envelope)
  records,envelope,_=self.fixture();envelope['locators']['r1.p1']['quote']='Invented quotation'
  with self.assertRaisesRegex(AssertionError,'Ungrounded locator'):project(records,envelope)

if __name__=='__main__':unittest.main()
