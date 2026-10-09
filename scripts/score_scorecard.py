"""Score a frozen key against a saved projection and explicit semantic judgments.

No inference or spreadsheet writes. Semantic matches must be reviewed separately;
IDs and per-dimension judgments are bound to the exact key and output hashes.
Draft scoring is opt-in and is always reported separately from reviewed scoring.
Patient inputs/outputs belong in ignored build/benchmarks, never in fixtures.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tally(rows):
    scored = [r for r in rows if r['result'] in ('Pass', 'Fail')]
    passed = sum(r['result'] == 'Pass' for r in scored)
    return {'passed': passed, 'scored': len(scored),
            'percent': round(100 * passed / len(scored), 1) if scored else None}


def score(key, output, judgments, include_draft=False):
    entries = {e['id']: e for e in output['entries']}
    assert len(entries) == len(output['entries']), 'Duplicate output IDs'
    records = key['sheets']['Records']['values']
    record = next(r for r in records if r and r[0] == output['recordID'])
    assert hashlib.sha256(record[2].encode()).hexdigest() == output['sourceSHA256'], 'Source mismatch'
    rows = [r + [None] * (20 - len(r)) for r in key['sheets']['Expected items']['values']
            if len(r) > 1 and r[1] == output['recordID']]
    assert len({r[0] for r in rows}) == len(rows), 'Duplicate item IDs'
    assessments = judgments['items']
    assert set(assessments) == {r[0] for r in rows}, 'Judgments must cover exactly the selected record'
    results = []
    for row in rows:
        item_id, expectation, status = row[0], row[2], row[18]
        j = assessments[item_id]
        matched = j['entryIDs']
        assert set(matched) <= entries.keys(), f'{item_id}: invented output ID'
        assert all(entries[i].get('sourceSessionID') == output['recordID'] for i in matched), 'Cross-record match'
        assert isinstance(j.get('extractedCore'), bool) and isinstance(j.get('visibleCore'), bool), 'Explicit presence judgments required'
        assert not j['extractedCore'] or matched, 'Present extraction needs a matched entry'
        assert not j['visibleCore'] or (j['extractedCore'] and any(entries[i]['visible'] for i in matched)), 'Visible presence needs a visible matched entry'
        checks = j['checks']
        assert all(v in ('Pass', 'Fail', 'Not scored') for v in checks.values()), 'Invalid dimension result'
        assert j['reason'].strip(), 'A qualitative explanation is required'
        eligible = expectation in ('Must appear', 'Must not appear') and (
            status == 'Reviewed' or (include_draft and status == 'Draft'))
        if expectation == 'Must appear':
            required = {'meaning', 'qualifiers', 'category', 'statementType', 'clinicalStatus', 'attribution', 'date', 'conditionLinks', 'bodySystem', 'appSection'}
            assert required <= checks.keys(), f'{item_id}: missing dimension checks'
            assert all(checks[k] != 'Not scored' for k in required - {'conditionLinks', 'bodySystem', 'appSection'}), 'Required dimensions cannot be silently skipped'
            if row[14] in ('Ambiguous', 'Not scored'):
                assert all(checks[k] == 'Not scored' for k in ('conditionLinks', 'bodySystem', 'appSection'))
            visible = any(entries[i]['visible'] for i in matched)
            # Matched candidates alone do not establish equivalent meaning.
            checks = dict(checks, visibility='Pass' if visible else 'Fail')
            passed = visible and 'Fail' not in checks.values()
        elif expectation == 'Must not appear':
            assert 'absence' in checks and checks['absence'] != 'Not scored'
            passed = checks['absence'] == 'Pass' and not any(entries[i]['visible'] for i in matched)
        else:
            passed = False
        results.append({'itemID': item_id, 'expectation': expectation, 'reviewStatus': status,
                        'expectedMeaning': row[3], 'entryIDs': matched, 'checks': checks,
                        'extractedCore': j.get('extractedCore'), 'visibleCore': j.get('visibleCore'),
                        'result': ('Pass' if passed else 'Fail') if eligible else 'Excluded',
                        'reason': j['reason']})
    reviewed = [r for r in results if r['reviewStatus'] == 'Reviewed']
    dimensions = {}
    for dimension in sorted({d for r in results for d in r['checks']}):
        checks = [r['checks'][dimension] for r in results if r['result'] != 'Excluded'
                  and dimension in r['checks'] and r['checks'][dimension] != 'Not scored']
        dimensions[dimension] = tally([{'result': c} for c in checks])
    positives = [r for r in results if r['result'] != 'Excluded' and r['expectation'] == 'Must appear']
    return {'mode': 'provisional-draft' if include_draft else 'reviewed-only',
            'recordID': output['recordID'], 'sourceSHA256': output['sourceSHA256'],
            'reviewedScore': tally(reviewed), 'score': tally(results), 'dimensions': dimensions,
            'corePresence': {'expectedPositiveRows': len(positives),
                             'extracted': sum(r['extractedCore'] is True for r in positives),
                             'visible': sum(r['visibleCore'] is True for r in positives)},
            'rows': results}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--key', required=True); p.add_argument('--output', required=True)
    p.add_argument('--judgments', required=True); p.add_argument('--report', required=True)
    p.add_argument('--include-draft', action='store_true')
    args = p.parse_args()
    key, output, judgments = [json.loads(Path(x).read_text()) for x in (args.key, args.output, args.judgments)]
    assert judgments['keySHA256'] == digest(args.key), 'Key changed: review judgments again'
    assert judgments['outputSHA256'] == digest(args.output), 'Output changed: review judgments again'
    report = score(key, output, judgments, args.include_draft)
    report.update(keySHA256=digest(args.key), outputSHA256=digest(args.output), evaluator=judgments['evaluator'])
    path = Path(args.report); path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + '\n')
    with path.with_suffix('.csv').open('w') as f:
        writer = csv.writer(f)
        writer.writerow(['Item ID', 'Expected meaning', 'Result', 'Extracted core', 'Visible core', 'Failed dimensions', 'Reason', 'Matched entry IDs'])
        for row in report['rows']:
            writer.writerow([row['itemID'], row['expectedMeaning'], row['result'], row['extractedCore'], row['visibleCore'],
                             '; '.join(k for k,v in row['checks'].items() if v == 'Fail'), row['reason'], '; '.join(row['entryIDs'])])
    print(json.dumps({k: report[k] for k in ('mode', 'reviewedScore', 'score', 'corePresence')}))


if __name__ == '__main__':
    main()
