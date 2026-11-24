import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from score_scorecard import score_graph
class GraphEdges(unittest.TestCase):
 def test_negative_l_prefix_and_duplicate_conditions(self):
  key={'sheets':{'Conditions':{'values':[['C001','first','','Must appear','','','','','Draft'],['C001','second','','Must appear','','','','','Draft']]},'Relationships':{'values':[['L001','I1','Must not link to condition','C1','','Draft']]}}}
  j={'Conditions':{'C001':{'entityIDs':[],'checks':{},'reason':'Conflicting duplicate frozen rows'}},'Relationships':{'L001':{'entityIDs':[],'checks':{'absence':'Pass','meaning':'Pass','direction':'Pass','ownership':'Pass','sourceSupport':'Pass'},'reason':'Synthetic source gives no such relationship; output has none'}}}
  r=score_graph(key,{'entities':[]},j,True);self.assertEqual(r['Conditions']['ambiguousIDs'],['C001']);self.assertEqual(r['Conditions']['score']['scored'],0);self.assertEqual(r['Relationships']['score']['passed'],1)
  j['Relationships']['L001']['checks']['absence']='Fail';self.assertEqual(score_graph(key,{'entities':[]},j,True)['Relationships']['score']['passed'],0)
if __name__=='__main__':unittest.main()
