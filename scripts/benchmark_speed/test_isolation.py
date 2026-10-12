"""Static invariants complement runtime adapter tests; no inference or account access."""
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class IsolationTests(unittest.TestCase):
 def test_diagnostics_stay_isolated_and_budget_import_has_one_adapter(self):
  for p in (ROOT/'vercel-openai-proxy/api').rglob('*.ts'):
   self.assertNotIn('decisions-benchmark',p.read_text(),str(p))
   if p != ROOT/'vercel-openai-proxy/api/_lib/fast-details-experiment.ts':
    self.assertNotIn('benchmark-budget',p.read_text(),str(p))
  self.assertNotIn('BenchmarkHybrid',(ROOT/'SpeechSessionApp/HealthSummaryModel.swift').read_text())
if __name__=='__main__':unittest.main()
