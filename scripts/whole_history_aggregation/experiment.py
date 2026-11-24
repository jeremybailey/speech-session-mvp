"""Isolated B development. Explicit runs only, no automatic paid repair/retry.

Reuses the prior diagnostic admission/transport/cleanup implementation without
changing its frozen sources, shared allowance, production routes, or app stores.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from contracts import VERSION, bundle, payload, resolve

ROOT = Path(__file__).resolve().parents[2]
LEGACY = Path('/Users/jeremybailey/.codex/worktrees/citation-recovery/SpeechSessionMVP/scripts/whole_history_benchmark')


def load(name):
    spec = importlib.util.spec_from_file_location('aggregation_legacy_' + name, LEGACY / (name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    path.chmod(0o600)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(out, prior):
    out.mkdir(mode=0o700, parents=False, exist_ok=False)
    previous = json.loads((prior / 'latest-accounting.json').read_text())
    for name in ('records.json', 'key.json', 'grading-rubric.json', 'dataset-audit.json', 'answer-key-audit.json'):
        shutil.copy2(prior / name, out / name)
    (out / 'combined').mkdir()
    shutil.copytree(prior / 'combined/vercel-openai-proxy', out / 'combined/vercel-openai-proxy', ignore=shutil.ignore_patterns('node_modules', '.vercel'))
    original_manifest = json.loads((prior / 'manifest.json').read_text())
    write(out / 'continuation.json', {'priorExperiment': str(prior), 'prefix': original_manifest['prefix'],
          'priorAccounting': previous['experimentAccounting'], 'lifetimeLimitUSD': 5,
          'newAttemptsExplicitlyRequested': True, 'purpose': 'Improve B completeness and evidence fidelity; no production change'})
    load('prepare_backend').prepare(out)
    manifest = json.loads((out / 'manifest.json').read_text())
    manifest.update(version=VERSION, plannedOrder=[['B1'], ['B2'], ['B3']],
        baselineReference=str(prior / 'baseline-1'), baselineRerun=False,
        candidateOnly=True, independentPaidChecker=False, automaticPaidRetry=False,
        evaluation='Frozen Draft key; semantic reviewer sees outputs only after prompt/schema frozen. Passage coverage is not accuracy.',
        productionChanges=False)
    write(out / 'manifest.json', manifest)
    records = json.loads((out / 'records.json').read_text())['records']
    source, table = bundle(records)
    write(out / 'source-bundle.json', source)
    write(out / 'source-locators.json', table)
    _, gate = payload(records)
    write(out / 'preflight.json', gate)
    print(f'Prepared {len(records)} originals and {len(table)} lossless passages; no model dispatch.')


def freeze(out):
    gate = json.loads((out / 'synthetic-gates.json').read_text())
    if not gate['passed']:
        raise ValueError('synthetic_gates_not_passed')
    transport = load('run')
    status = transport.request(out, 'single-1', {'action': 'status'}, out / 'preflight-trace')
    write(out / 'runtime-policy.json', status)
    previous = json.loads((out / 'continuation.json').read_text())['priorAccounting']
    if status['jobs'] or int(status['experimentAccounting']['committed_nusd']) < int(previous['committed_nusd']):
        raise ValueError('unexpected_scope_or_historical_accounting')
    if int(status['budget']['limit_nusd']) != 20_000_000_000:
        raise ValueError('shared_pilot_cap_changed')
    files = {}
    for base in [Path(__file__).parent, LEGACY, out / 'deployment/vercel-openai-proxy/api', out / 'deployment/vercel-openai-proxy/scripts']:
        for path in base.rglob('*'):
            if path.is_file() and path.suffix in ('.py', '.ts', '.swift', '.json') and 'node_modules' not in path.parts:
                name = str(path.relative_to(out)) if path.is_relative_to(out) else str(path)
                files[name] = sha(path)
    for name in ('records.json', 'key.json', 'grading-rubric.json', 'dataset-audit.json', 'answer-key-audit.json',
                 'manifest.json', 'continuation.json', 'source-bundle.json', 'source-locators.json', 'preflight.json',
                 'runtime-policy.json', 'synthetic-gates.json', 'deployment/vercel-openai-proxy/package-lock.json',
                 'deployment/vercel-openai-proxy/package.json', 'deployment/vercel-openai-proxy/vercel.json'):
        files[name] = sha(out / name)
    prior = Path(json.loads((out / 'continuation.json').read_text())['priorExperiment'])
    files[str(prior / 'freeze.json')] = sha(prior / 'freeze.json')
    write(out / 'freeze.json', {'files': files, 'version': VERSION, 'syntheticTestsPassed': True,
        'combinedBuildPassed': True, 'combinedTestsPassed': True,
        'baselineValidation': 'Unchanged prior fixed-build reference; A is not rerun and its failed time is not a successful baseline',
        'timingScope': 'harness, not phone', 'outputAllowance': 64000, 'contextLimit': 1050000})
    print('Frozen B prompt, schema, sources, key, transport and cumulative accounting before inference.')


def verify(out):
    for name, expected in json.loads((out / 'freeze.json').read_text())['files'].items():
        p = Path(name) if name.startswith('/') else out / name
        if sha(p) != expected:
            raise ValueError('frozen_source_changed:' + name)


def run(out, repetition):
    verify(out)
    transport = load('run')
    name = f'single-{repetition}'
    folder = out / name
    folder.mkdir(mode=0o700, exist_ok=False)
    records = json.loads((out / 'records.json').read_text())['records']
    p, gate = payload(records)
    write(folder / 'request.json', p)
    write(folder / 'preflight.json', gate)
    start = time.monotonic()
    summary = {'run': name, 'version': VERSION, 'completed': False, 'clinicallyVerified': False,
               'semanticAccuracyEstablished': False, 'automaticPaidRetry': False}
    try:
        job = transport.request(out, name, {'action': 'submit', 'payload': p}, folder / 'trace')
        summary['jobID'] = job['id']
        deadline = time.monotonic() + 420
        job = transport.request(out, name, {'action': 'job', 'id': job['id']}, folder / 'trace')
        while job['state'] in ('queued', 'running'):
            if time.monotonic() > deadline:
                raise ValueError('wait_limit_no_redispatch')
            action = 'run' if job['state'] == 'queued' else 'job'
            job = transport.request(out, name, {'action': action, 'id': job['id']}, folder / 'trace')
            write(folder / 'receipt.json', job)
        summary['providerState'] = job['state']
        raw = (job.get('result') or {}).get('output')
        if job['state'] != 'completed' or not raw:
            raise ValueError('provider_' + job['state'])
        (folder / 'raw-output.txt').write_text(raw)
        compact = json.loads(raw)
        write(folder / 'compact-output.json', compact)
        expanded, integrity = resolve(compact, records)
        write(folder / 'output.json', expanded)
        write(folder / 'integrity.json', integrity)
        for r in records:
            entries = [{**d, 'sourceSessionID': d['recordID'], 'visible': True, 'accepted': False,
                        'experimentalUnverifiedProposal': True} for d in expanded['details'] if d['recordID'] == r['id']]
            write(folder / (r['id'] + '.output.json'), {'recordID': r['id'], 'sourceSHA256': r['sourceSHA256'],
                  'entries': entries, 'clinicallyVerified': False,
                  'visibilityMeaning': 'Private review projection only; never patient-store visibility'})
        summary['completed'] = True
    except Exception as e:
        summary['failure'] = str(e)
    summary['elapsedSeconds'] = time.monotonic() - start
    write(folder / 'run.json', summary)
    status = transport.request(out, name, {'action': 'status'}, folder / 'trace')
    write(out / 'latest-accounting.json', status)
    write(folder / 'ledger.json', status)
    print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'freeze', 'run', 'verify'])
    parser.add_argument('output', type=Path)
    parser.add_argument('--prior', type=Path, default=ROOT / 'build/benchmarks/2026-11-01-whole-history-fixed')
    parser.add_argument('--repetition', type=int, choices=[1, 2, 3], default=1)
    args = parser.parse_args()
    out = args.output.resolve()
    if not out.is_relative_to(ROOT / 'build/benchmarks'):
        parser.error('Private ignored benchmark storage required')
    if args.action == 'prepare':
        prepare(out, args.prior.resolve())
    elif args.action == 'run':
        run(out, args.repetition)
    else:
        globals()[args.action](out)
