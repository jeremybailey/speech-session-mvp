import unittest
from prepare import validate_expectation_coverage

class KeyCoverageTests(unittest.TestCase):
 def test_records_tab_presence_does_not_substitute_for_expectations(self):
  key={'sheets':{'Expected items':{'values':[[],['I1','a','Must appear'],['I2','b','Ambiguous']]}}}
  with self.assertRaisesRegex(AssertionError,'no positive'):
   validate_expectation_coverage(key,['a','b'])
  key['sheets']['Expected items']['values'].append(['I3','b','Must appear'])
  validate_expectation_coverage(key,['a','b'])
  with self.assertRaises(AssertionError):validate_expectation_coverage(key,['a','b','c'])

if __name__=='__main__':unittest.main()
