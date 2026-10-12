"""Compare explicit row judgments only when the key, source and denominator match.

This does not grade content or establish clinical accuracy. Use ignored benchmark
paths for reports containing patient data. Conditions/Relationships are not included.
"""
import argparse
import json
from pathlib import Path


def compare(baseline, candidate):
    for field in ('keySHA256', 'recordID', 'sourceSHA256', 'mode'):
        if not baseline.get(field) or baseline[field] != candidate.get(field):
            raise ValueError(f'Cannot compare different or missing {field}')
    old = {r['itemID']: r for r in baseline['rows']}
    new = {r['itemID']: r for r in candidate['rows']}
    if len(old) != len(baseline['rows']) or len(new) != len(candidate['rows']) or old.keys() != new.keys():
        raise ValueError('Row identities must be unique and identical')
    for item in old:
        if (old[item]['result'] == 'Excluded') != (new[item]['result'] == 'Excluded'):
            raise ValueError('Eligibility changed; do not report this as a pipeline gain')
    if baseline['score']['scored'] != candidate['score']['scored']:
        raise ValueError('Scoring denominators differ')
    changes = []
    for item, before in old.items():
        after = new[item]
        dimensions = {name: {'before': before['checks'].get(name), 'after': after['checks'].get(name)}
                      for name in sorted(before['checks'].keys() | after['checks'].keys())
                      if before['checks'].get(name) != after['checks'].get(name)}
        if dimensions or any(before.get(k) != after.get(k) for k in ('result', 'extractedCore', 'visibleCore')):
            changes.append({'itemID': item, 'before': before['result'], 'after': after['result'],
                            'coreBefore': {'extracted': before['extractedCore'], 'visible': before['visibleCore']},
                            'coreAfter': {'extracted': after['extractedCore'], 'visible': after['visibleCore']},
                            'dimensions': dimensions, 'beforeReason': before['reason'], 'afterReason': after['reason']})
    return {'scope': 'Expected items only; explicit provisional/reviewed judgments, not clinical accuracy',
            'keySHA256': baseline['keySHA256'], 'recordID': baseline['recordID'], 'mode': baseline['mode'],
            'baseline': baseline['score'], 'candidate': candidate['score'],
            'baselineCore': baseline['corePresence'], 'candidateCore': candidate['corePresence'],
            'newPasses': [i for i in old if old[i]['result'] == 'Fail' and new[i]['result'] == 'Pass'],
            'regressions': [i for i in old if old[i]['result'] == 'Pass' and new[i]['result'] == 'Fail'],
            'changes': changes}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = compare(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()))
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ('baseline', 'candidate', 'newPasses', 'regressions')}))
