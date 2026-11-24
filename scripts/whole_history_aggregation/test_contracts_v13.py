import copy,unittest
import contracts_v13 as c
import test_contracts_v9 as fixtures
class ShortOverview(unittest.TestCase):
    def setUp(self):
        f=fixtures.ConcernFirst();f.setUp();self.records=f.records;self.good=copy.deepcopy(f.good)
        for rows in self.good['passages'].values():
            if isinstance(rows,list):
                for row in rows:
                    if row['p'] is not None:row['p']={dict(owner='a',followUp='t',considerations='q')[k]:v for k,v in row['p'].items()}
    def test_rejects_multiple_or_multiline_paragraphs(self):
        r=copy.deepcopy(self.good);r['overview']*=2
        with self.assertRaisesRegex(ValueError,'one_paragraph'):c.resolve(r,self.records)
        for text in ['First.\nSecond.','X'*1001]:
            r=copy.deepcopy(self.good);r['overview'][0]['text']=text
            with self.assertRaisesRegex(ValueError,'not_condensed'):c.resolve(r,self.records)
    def test_details_and_ownership_unchanged_by_short_overview(self):
        a,_=c.previous.resolve(self.good,self.records);b,_=c.resolve(self.good,self.records)
        self.assertEqual(a,b)
    def test_schema_constrains_summary_without_changing_fact_contract(self):
        before=c.previous.schema_for(self.records);after=c.schema_for(self.records)
        self.assertEqual(before['properties']['passages'],after['properties']['passages'])
        self.assertEqual(before['$defs'],after['$defs'])
        self.assertEqual(after['properties']['overview']['maxItems'],1)
        self.assertEqual(after['properties']['overview']['items']['properties']['text']['maxLength'],1000)
