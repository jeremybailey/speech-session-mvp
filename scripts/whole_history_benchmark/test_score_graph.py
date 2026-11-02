import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from score_scorecard import score_graph
class GraphScoring(unittest.TestCase):
 def test_explicit_review_and_draft_separation(self):
  key={'sheets':{'Conditions':{'values':[['C1','Concern','','Must appear','','','','','Draft']]},'Relationships':{'values':[['R1','I1','belongs to','C1','','Draft']]}}}
  checks={'presence':'Pass','meaning':'Pass','bodySystem':'Pass','appSection':'Pass','sourceSupport':'Pass','direction':'Pass','ownership':'Pass'}
  j={s:{i:{'entityIDs':['e1'],'checks':checks,'reason':'Synthetic source-backed semantic review'}} for s,i in [('Conditions','C1'),('Relationships','R1')]}
  output={'entities':[{'id':'e1'}]}
  self.assertEqual(score_graph(key,output,j)['Conditions']['score']['scored'],0)
  self.assertEqual(score_graph(key,output,j,True)['Conditions']['score']['passed'],1)
  j['Relationships']['R1']['entityIDs']=['invented']
  with self.assertRaises(AssertionError):score_graph(key,output,j,True)
if __name__=='__main__':unittest.main()
