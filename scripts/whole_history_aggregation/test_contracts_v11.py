import copy
import unittest
import contracts_v11 as c
import test_contracts_v9 as fixtures

class CompactSources(unittest.TestCase):
    def setUp(self):
        self.old=c.source.bundle;c.install()
    def tearDown(self):c.source.bundle=self.old
    def test_schema_builds_with_compact_plan(self):
        schema=c.schema_for([{'id':'one','text':'Some advice.'}])
        self.assertEqual(schema['$defs']['fact']['anyOf'][0]['properties']['p']['required'],['a','t','q'])
    def test_originals_and_offsets_are_lossless(self):
        text=('Original clinical sentence. '*80)+'Final qualifier.'
        records=[{'id':'one','text':text},{'id':'two','text':'Other record.'}]
        data,table=c.bundle(records)
        for r,original in zip(data['originalRecords'],records):
            self.assertEqual(''.join(p['text'] for p in r['passages']),original['text'])
            for p in r['passages']:
                loc=table[p['id']];self.assertEqual(original['text'][loc['start']:loc['end']],loc['quote'])
                self.assertEqual(loc['recordID'],original['id'])
    def test_compact_action_preserves_status_and_owner(self):
        f=fixtures.ConcernFirst();f.setUp();r=copy.deepcopy(f.good)
        for rows in r['passages'].values():
            if isinstance(rows,list):
                for row in rows:
                    if row['p'] is not None:row['p']={dict(owner='a',followUp='t',considerations='q')[k]:v for k,v in row['p'].items()}
        out,a=c.resolve(r,f.records)
        self.assertEqual(out['carePlans'][0]['owner'],'clinic')
        self.assertFalse(a['clinicallyVerified'])
