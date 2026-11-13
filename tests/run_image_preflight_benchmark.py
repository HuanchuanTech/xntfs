#!/usr/bin/env python3
"""Measure MainActor responsiveness with controlled ordinary-file read delays.

Baseline is the old synchronous production validator; candidate is the new
orchestration with stub FSKit/bookmark capabilities. Total wall/CPU costs cover
different scope, so only heartbeat stalls and read/close counts are comparable.
No device, actual FSKit mount, app bundle or registration is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--control', action='store_true')
    parser.add_argument('--rounds', type=int, default=7)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.baseline_source = args.baseline_source.resolve()
    if args.rounds < 1:
        parser.error('rounds must be positive')
    args.output.mkdir(parents=True, exist_ok=False)
    frozen = args.output / 'source'
    paths = list((ROOT / 'xntfs/Services').glob('*.swift'))
    paths += [ROOT / path for path in ['Shared/DiagnosticRecorder.swift', 'xntfs/Model/NTFSDevice.swift',
        'tests/image_preflight_gate.c', 'tests/image_preflight_gate.h', 'tests/benchmark_image_preflight.swift',
        'tests/run_image_preflight.sh', 'tests/run_image_preflight_benchmark.py']]
    for path in paths:
        target = frozen / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    baseline = args.output / 'baseline-ImageMountService.swift'
    shutil.copyfile(args.baseline_source, baseline)
    env = dict(os.environ, NFSK_HOST_SOURCE_ROOT=str(frozen))
    env.pop('SDKROOT', None)
    env.pop('NFSK_SANITIZE', None)
    manifest = {'created': time.time(), 'platform': platform.platform(), 'rounds': args.rounds,
        'scope': __doc__, 'control': args.control,
        'baseline_source_sha256': digest(baseline),
        'sources': {str(path.relative_to(frozen)): digest(path) for path in frozen.rglob('*') if path.is_file()},
        'sdk': subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip(),
        'swiftc': subprocess.check_output(['xcrun', 'swiftc', '--version'], env=env, text=True).strip(),
        'clang': subprocess.check_output(['xcrun', 'clang', '--version'], env=env, text=True).strip(),
        'binaries': {}}
    for label in ['baseline', 'candidate']:
        folder = args.output / label
        folder.mkdir()
        is_baseline = label == 'baseline' or args.control
        source = baseline if is_baseline else frozen / 'xntfs/Services/ImageMountService.swift'
        build_env = dict(env, NFSK_IMAGE_SERVICE_SOURCE=str(source))
        with (folder / 'build.log').open('w') as log:
            subprocess.run(['bash', str(frozen / 'tests/run_image_preflight.sh'),
                            'baseline-benchmark' if is_baseline else 'benchmark', str(folder)],
                           env=build_env, check=True, timeout=180, stdout=log, stderr=log)
        manifest['binaries'][label] = {name: digest(folder / name) for name in ['runner', 'image-gate.dylib']}
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    rows = []
    for i in range(args.rounds):
        for label in (['baseline', 'candidate'] if i % 2 == 0 else ['candidate', 'baseline']):
            prefix = args.output / (str(i + 1) + '-' + label)
            with prefix.with_suffix('.jsonl').open('w') as result, prefix.with_suffix('.log').open('w') as log:
                subprocess.run([str(args.output / label / 'runner'), str(args.output / label)],
                               env=env, check=True, timeout=30, stdout=result, stderr=log)
            records = [dict(round=i + 1, variant=label, **json.loads(line))
                       for line in prefix.with_suffix('.jsonl').read_text().splitlines()]
            rows.extend(records)
            print('PASS', i + 1, label, flush=True)
    summary = {}
    for workload in ['fast', 'delayed']:
        matching = [row for row in rows if row['workload'] == workload]
        metrics = {}
        for metric in ['heartbeat_max_ns', 'wall_ns', 'cpu_ns', 'rss_bytes',
                       'read_calls', 'read_bytes', 'close_calls', 'main_thread_reads']:
            a, b = [[row[metric] for row in matching if row['variant'] == label] for label in ['baseline', 'candidate']]
            result = {'baseline_median': statistics.median(a), 'candidate_median': statistics.median(b)}
            if metric == 'heartbeat_max_ns':
                changes = [100 * (x - y) / x for x, y in zip(a, b)]
                result.update(paired_improvement_pct=changes, median_improvement_pct=statistics.median(changes))
            metrics[metric] = result
        summary[workload] = metrics
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Delayed heartbeat: %.2f ms -> %.2f ms' % tuple(summary['delayed']['heartbeat_max_ns'][key] / 1e6 for key in ['baseline_median', 'candidate_median']))


if __name__ == '__main__':
    main()
