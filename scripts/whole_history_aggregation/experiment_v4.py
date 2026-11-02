"""Compact passage B; local cards and citations, private 270s provider deadline."""
import argparse
import json
from pathlib import Path
import sys
import contracts_v4 as contract
import experiment as base

base.VERSION = contract.VERSION
base.bundle = contract.bundle
base.payload = contract.payload
base.resolve = contract.resolve
sys.modules['contracts'] = contract

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['prepare', 'freeze', 'run', 'verify'])
    p.add_argument('output', type=Path)
    p.add_argument('--prior', type=Path, default=base.ROOT / 'build/benchmarks/2026-11-01-whole-history-B-passages-v1')
    p.add_argument('--repetition', type=int, choices=[1, 2, 3], default=1)
    a = p.parse_args(); out = a.output.resolve()
    if not out.is_relative_to(base.ROOT / 'build/benchmarks'):
        p.error('Private ignored benchmark storage required')
    records = json.loads(((a.prior if a.action == 'prepare' else out) / 'records.json').read_text())['records']
    contract.configure(records)
    if a.action == 'prepare':
        base.prepare(out, a.prior.resolve())
        worker = out / 'deployment/vercel-openai-proxy/api/_lib/worker.ts'
        text = worker.read_text()
        assert "? 240_000 : 100_000" in text
        worker.write_text(text.replace('? 240_000 : 100_000', '? 270_000 : 100_000'))
        manifest = json.loads((out / 'manifest.json').read_text())
        manifest.update(baselineReference=str(base.ROOT / 'build/benchmarks/2026-11-01-whole-history-fixed/baseline-1'),
                        providerDeadlinesSeconds={'baseline': 100, 'candidate': 270}, localCardsAndCitations=True,
                        deadlineRationale='Verified Hobby plan allows 300s diagnostic function; 270s leaves settlement margin. Prior unknown reservation retained.')
        base.write(out / 'manifest.json', manifest)
    elif a.action == 'run':
        base.run(out, a.repetition)
    else:
        getattr(base, a.action)(out)
