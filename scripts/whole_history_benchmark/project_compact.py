"""Project compact B wire output for explicit local semantic review; never import it.

Raw statements, categories and links are preserved without semantic matching or
scoring. Expectations must be reviewed independently with score_scorecard.py.
"""
import argparse, hashlib, json
from pathlib import Path


def project(records, envelope):
    originals = {r['id'].lower(): r for r in records}
    assert len(originals) == len(records), 'Duplicate originals'
    for r in records:
        assert hashlib.sha256(r['text'].encode()).hexdigest() == r['sourceSHA256'], 'Source hash mismatch'
    wire = json.loads(envelope['result']['output'])
    locators = envelope['locators']
    if 'facts' in wire:
        categories = ['chiefComplaint','symptoms','findings','medications','carePlan','practitionerContact','vaccinations','allergies','testsAndLabs','followUp','biopsychosocialContext','otherNotes']
        assert set(wire) == {'concerns','overview','facts','ignored'}, 'Invalid bucket envelope'
        assert set(wire['facts']) == set(categories), 'Invalid category buckets'
        passages = {key: [] for key in locators}
        for category in categories:
            for row in wire['facts'][category]:
                assert set(row) == {'r','s','v','c','p','g','m','f'}, 'Invalid bucket row'
                assert row['r'] in passages, 'Unknown primary source'
                passages[row['r']].append(dict(k=category, **{k:v for k,v in row.items() if k != 'r'}))
        ignored = set()
        for row in wire['ignored']:
            assert set(row) == {'r','reason'} and row['r'] in passages, 'Invalid ignore source'
            assert row['r'] not in ignored and not passages[row['r']], 'Contradictory ignore marker'
            ignored.add(row['r']); passages[row['r']] = row['reason']
        assert all(passages.values()), 'Missing primary source coverage'
        wire = dict(concerns=wire['concerns'],overview=wire['overview'],passages=passages)
    assert set(wire['passages']) == set(locators), 'Missing passage accounting'
    groups = {g['id']: g for g in wire['concerns']}
    assert len(groups) == len(wire['concerns']), 'Duplicate concerns'
    entities = []
    entries = {r['id'].lower(): [] for r in records}
    for passage, facts in wire['passages'].items():
        assert passage in locators, 'Unknown passage'
        locator = locators[passage]
        rid = locator['recordID'].lower()
        assert rid in originals, 'Unknown original'
        assert locator['sourceSHA256'] == originals[rid]['sourceSHA256'], 'Locator source mismatch'
        assert locator['quote'] and locator['quote'] in originals[rid]['text'], 'Ungrounded locator'
        if isinstance(facts, str):
            assert facts in {'nonclinical', 'other_person', 'unintelligible'}, 'Unknown ignore marker'
            entities.append({'id': passage + '.ignored', 'kind': 'ignoredPassage', 'sourceSessionID': originals[rid]['id'], 'sourceReference': passage, 'reason': facts})
            continue
        assert isinstance(facts, list), 'Invalid passage shape'
        for index, fact in enumerate(facts):
            refs = [passage] + fact['c']
            assert all(ref in locators and locators[ref]['recordID'].lower() == rid for ref in refs), 'Cross-record reference'
            assert set(fact['g']) <= groups.keys(), 'Unknown concern'
            row = {'id': f'{passage}.f{index + 1}', 'kind': 'details',
                   'sourceSessionID': originals[rid]['id'], 'visible': True,
                   'accepted': False, 'experimentalUnverifiedProposal': True,
                   'category': fact['k'], 'clinicalStatus': fact['s'],
                   'statement': fact['v'][0], 'attribution': fact['v'][1],
                   'date': fact['v'][2], 'sourceReferences': refs,
                   'conditionIDs': fact['g'], 'plan': fact['p'],
                   'medication': fact['m'], 'fields': fact['f']}
            entries[rid].append(row); entities.append(row)
    for concern in wire['concerns']:
        assert all(ref in locators for ref in concern['evidence']), 'Unknown concern evidence'
        entities.append({'kind': 'conditions', **concern})
    for row in list(entities):
        if row['kind'] == 'details':
            for concern in row['conditionIDs']:
                entities.append({'id': row['id'] + '->' + concern, 'kind': 'relationships',
                                 'from': row['id'], 'to': concern, 'relationship': 'linkedToCondition'})
    return entries, {'entities': entities, 'clinicallyVerified': False}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--records', required=True); p.add_argument('--candidate', required=True)
    p.add_argument('--output-dir', required=True); args = p.parse_args()
    records = json.loads(Path(args.records).read_text())
    if isinstance(records, dict): records = records['records']
    envelope = json.loads(Path(args.candidate).read_text())
    entries, graph = project(records, envelope)
    output = Path(args.output_dir); output.mkdir(parents=True, exist_ok=True)
    for record in records:
        projection = {'recordID': record['id'], 'sourceSHA256': record['sourceSHA256'],
                      'entries': entries[record['id'].lower()], 'clinicallyVerified': False}
        (output / (record['id'] + '.output.json')).write_text(json.dumps(projection, indent=2))
    graph['candidateSHA256'] = hashlib.sha256(Path(args.candidate).read_bytes()).hexdigest()
    (output / 'graph-projection.json').write_text(json.dumps(graph, indent=2))
    print('Private review projections written. No semantic scores or app writes performed.')

if __name__ == '__main__': main()
