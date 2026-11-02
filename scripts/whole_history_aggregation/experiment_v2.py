"""Explicit v2 entry point; keeps every source bound by the v1 trial immutable."""
import argparse
import json
from pathlib import Path
import sys
import contracts_v2 as contract
import experiment as base

base.VERSION = contract.VERSION
base.bundle = contract.bundle
base.payload = contract.payload
base.resolve = contract.resolve
# The unchanged private deployment preparer imports these contract values.
sys.modules['contracts'] = contract

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['prepare', 'freeze', 'run', 'verify'])
    p.add_argument('output', type=Path)
    p.add_argument('--prior', type=Path, default=base.ROOT / 'build/benchmarks/2026-11-01-whole-history-B-evidence-v2')
    p.add_argument('--repetition', type=int, choices=[1, 2, 3], default=1)
    a = p.parse_args()
    out = a.output.resolve()
    if not out.is_relative_to(base.ROOT / 'build/benchmarks'):
        p.error('Private ignored benchmark storage required')
    records = json.loads(((a.prior if a.action == 'prepare' else out) / 'records.json').read_text())['records']
    contract.configure(records)
    if a.action == 'prepare':
        base.prepare(out, a.prior.resolve())
        manifest = json.loads((out / 'manifest.json').read_text())
        manifest['baselineReference'] = str(base.ROOT / 'build/benchmarks/2026-11-01-whole-history-fixed/baseline-1')
        base.write(out / 'manifest.json', manifest)
    elif a.action == 'run':
        base.run(out, a.repetition)
    else:
        getattr(base, a.action)(out)
