#!/usr/bin/env python3
"""Clean paired recorder timings followed by separate store-count diagnostics."""
import argparse
import json
import os
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import sys
import time
sys.dont_write_bytecode = True
from diagnostic_harness import ROOT, build, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-source', type=Path, required=True)
    parser.add_argument('--candidate-source', type=Path, default=ROOT / 'Shared/DiagnosticRecorder.swift')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=7)
    parser.add_argument('--groups', type=int, default=32)
    args = parser.parse_args()
    if args.rounds < 1 or args.groups < 1: parser.error('positive rounds and groups required')
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    binaries = {}
    for label, source in [('baseline', args.baseline_source), ('candidate', args.candidate_source)]:
        for mode in ['clean', 'trace']:
            binaries[label, mode] = build(output / label / mode, source, 'benchmark_diagnostics.swift', trace=mode == 'trace')
    manifest = {'created': time.time(), 'rounds': args.rounds, 'groups': args.groups,
                'scope': 'Isolated ordinary-file diagnostic stores seeded with 400 events; no App Group, mounts or network',
                'timing': 'Clean -O binaries; trace copies supply counters only',
                'recorder_hashes': {label: json.loads((binary.parent / 'manifest.json').read_text())['recorder_sha256']
                                    for (label, mode), binary in binaries.items() if mode == 'clean'},
                'runner_sha256': digest(Path(__file__)), 'manifests': {label + '-' + mode: str((binary.parent / 'manifest.json').relative_to(output))
                                                                   for (label, mode), binary in binaries.items()}}
    shutil.copyfile(Path(__file__), output / Path(__file__).name)
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    rows, diagnostics = [], []
    runs = [(str(i + 1), label, 'clean') for i in range(args.rounds)
            for label in (['baseline', 'candidate'] if i % 2 == 0 else ['candidate', 'baseline'])]
    runs += [('diagnostic', label, 'trace') for label in ['baseline', 'candidate']]
    env = dict(os.environ); env.pop('SDKROOT', None)
    for repetition, label, mode in runs:
        binary = binaries[label, mode]; prefix = output / (repetition + '-' + label)
        with prefix.with_suffix('.jsonl').open('w') as result, prefix.with_suffix('.log').open('w') as log:
            subprocess.run([str(binary), str(binary.parent / 'store'), str(args.groups)],
                           check=True, timeout=90, env=env, stdout=result, stderr=log)
        records = [dict(round=repetition, variant=label, **json.loads(line)) for line in prefix.with_suffix('.jsonl').read_text().splitlines()]
        (rows if mode == 'clean' else diagnostics).extend(records)
        print('PASS', repetition, label, flush=True)
    summary = {}
    for workload in sorted({row['workload'] for row in rows}):
        matching = [row for row in rows if row['workload'] == workload]
        result = {}
        for metric in ['wall_ns', 'cpu_ns', 'p95_group_ns', 'p95_caller_ns', 'rss_bytes']:
            a, b = [[row[metric] for row in matching if row['variant'] == label] for label in ['baseline', 'candidate']]
            changes = [100 * (old - new) / old for old, new in zip(a, b)]
            value = {'baseline_median': statistics.median(a), 'candidate_median': statistics.median(b),
                     'paired_improvement_pct': changes, 'median_improvement_pct': statistics.median(changes)}
            if metric in ['wall_ns', 'cpu_ns']:
                rng = random.Random(20261107)
                estimates = sorted(statistics.median(rng.choices(changes, k=len(changes))) for _ in range(10000))
                value['paired_median_bootstrap_95_pct'] = [estimates[249], estimates[9749]]
            result[metric] = value
        result['diagnostics'] = {row['variant']: {key: row[key] for key in ['operations', 'stores', 'writes', 'bytes', 'maximum_pending']}
                                 for row in diagnostics if row['workload'] == workload}
        summary[workload] = result
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    for workload, result in summary.items():
        print(workload, 'wall change %.1f%%, CPU %.1f%%' % (result['wall_ns']['median_improvement_pct'], result['cpu_ns']['median_improvement_pct']))


if __name__ == '__main__': main()
