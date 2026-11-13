#!/usr/bin/env python3
"""Measure legacy open-record growth using bounded ordinary-file images only.

Clean timings and copied-source visit/I/O diagnostics are separate processes.
Use the same source for both variants for an A/A noise control. No OS mount,
device access, installed extension, upstream rebuild or growing cache is used.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess

from run_crash_consistency import ROOT, clone, demand, digest


def instrument(source):
    needle = ('    for (nfsk_open_ref *entry = volume_context(vol)->open_items; entry; entry = entry->next)\n'
              '        if (MREF(entry->ref) == MREF(ref)) return entry;')
    demand(source.count(needle) == 1, 'open lookup loop shape changed')
    source = source.replace(needle, needle.split('\n')[0] + ' {\n'
                            '        nfsk_ref_visit(0);\n' + needle.split('\n')[1] + '\n    }')
    needle = '    for (nfsk_open_ref *entry = volume_context(vol)->open_items; entry; entry = entry->next) {'
    # The preceding replacement added the same loop. Limit the second probe to
    # the retention function, and fail closed if its implementation changes.
    start = source.index('static bool nfsk_is_retention_name(')
    end = source.index('\n}', start) + 2
    section = source[start:end]
    demand(section.count(needle) == 1, 'retention loop shape changed')
    source = source[:start] + section.replace(needle, needle + '\n        nfsk_ref_visit(1);') + source[end:]
    return ('extern void nfsk_ref_visit(int);\n' + source
            + '\nsize_t nfsk_ref_devctx_size(void) { return sizeof(nfsk_devctx); }\n'
            + 'size_t nfsk_ref_entry_size(void) { return sizeof(nfsk_open_ref); }\n')


def build(work, bridge, diagnostic, env, sdk, arch):
    work.mkdir(); source = work / 'source'; source.mkdir()
    originals = {}
    for name in ['ntfs_fskit.c', 'ntfs_fskit.h', 'ntfs_device_fskit.m']:
        originals[name] = digest(bridge / name)
        shutil.copy2(bridge / name, source / name)
    test = ROOT / 'tests/benchmark_open_refs.c'
    shutil.copy2(test, source / test.name); originals[test.name] = digest(test)
    if diagnostic:
        file = source / 'ntfs_fskit.c'; file.write_text(instrument(file.read_text()))
    library = ROOT / 'build/libntfs-universal'
    flags = ['-O2', '-g', '-Werror', '-Wall', '-Wextra', '-arch', arch, '-mmacosx-version-min=15.4', '-isysroot', sdk,
             '-DHAVE_CONFIG_H=1', '-I' + str(library), '-I' + str(ROOT / 'ntfs-3g/include'), '-I' + str(source)]
    extra = ['-Dpwrite=nfsk_ref_pwrite', '-Dpread=nfsk_ref_pread', '-Dfsync=nfsk_ref_fsync'] if diagnostic else []
    commands = [
        ['xcrun', 'clang', *flags, '-c', source / 'ntfs_fskit.c', '-o', work / 'bridge.o'],
        ['xcrun', 'clang', *flags, '-fobjc-arc', *extra, '-c', source / 'ntfs_device_fskit.m', '-o', work / 'backend.o'],
        ['xcrun', 'clang', *flags, *(['-DNFSK_REF_DIAGNOSTIC=1'] if diagnostic else []),
         source / test.name, work / 'bridge.o', work / 'backend.o', library / 'libntfs-3g.a',
         '-framework', 'Foundation', '-framework', 'FSKit', '-o', work / 'runner']]
    record = {'original_sources': originals, 'compiled_sources': {p.name: digest(p) for p in source.iterdir()},
              'diagnostic': diagnostic, 'commands': [list(map(str, c)) for c in commands]}
    (work / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
    for i, command in enumerate(commands):
        with (work / f'build-{i}.log').open('w') as log:
            subprocess.run(list(map(str, command)), env=env, cwd=work, check=True, timeout=180,
                           stdout=log, stderr=subprocess.STDOUT)
    record['binary'] = digest(work / 'runner')
    (work / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
    return work / 'runner'


def run(binary, mode, image, prefix, env):
    with prefix.with_suffix('.csv').open('x') as output, prefix.with_suffix('.log').open('x') as log:
        subprocess.run([str(binary), mode, str(image), str(prefix.with_suffix('.raw.csv'))],
                       env=env, cwd=binary.parent, check=True, timeout=300, stdout=output, stderr=log)
    if mode == 'prepare':
        return []
    with prefix.with_suffix('.csv').open() as src:
        rows = [{k: v if k == 'workload' else int(v) for k, v in row.items()} for row in csv.DictReader(src)]
    demand(len(rows) == 33 and len({(r['opened'], r['workload']) for r in rows}) == 33, 'complete workload matrix')
    for row in rows:
        demand(row['operations'] in [512, 8192] and row['writes'] == row['flushes'] == 0, 'read-only measured workload')
    return rows


def interval(values):
    rng = random.Random(15)
    samples = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(10000))
    return {'median_percent': statistics.median(values), 'bootstrap95_percent': [samples[249], samples[9749]],
            'pairs_percent': values}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-dir', type=Path, required=True)
    parser.add_argument('--candidate-dir', type=Path, default=ROOT / 'ntfs3g/bridge')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, default=ROOT / 'tests/work.ntfs')
    parser.add_argument('--rounds', type=int, default=7)
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default=platform.machine())
    parser.add_argument('--compile-only', action='store_true')
    args = parser.parse_args()
    demand(1 <= args.rounds <= 7, 'rounds must be 1..7')
    demand(args.compile_only or args.arch == platform.machine(), 'foreign architecture requires --compile-only')
    demand(args.fixture.is_file() and not args.fixture.is_symlink() and args.fixture.stat().st_size <= 128 << 20,
           'bounded ordinary-file fixture required')
    work = args.output.absolute()
    demand(work.parent.resolve().is_relative_to((ROOT / '_tmp').resolve()) and not work.exists(),
           'new output directory under project _tmp required')
    work.mkdir(parents=True)
    env = {k: v for k, v in os.environ.items() if k != 'SDKROOT'}
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    library = ROOT / 'build/libntfs-universal'
    manifest = {'fixture': digest(args.fixture), 'library': digest(library / 'libntfs-3g.a'),
                'config': digest(library / 'config.h'), 'sdk': sdk, 'arch': args.arch, 'rounds': args.rounds,
                'compiler': subprocess.check_output(['xcrun', 'clang', '--version'], env=env, text=True),
                'scope': 'legacy macOS 15 open-reference registration; regular-file backend; no OS mount',
                'upstream_instrumented': False, 'samples': 'raw CSV; only summary rows retained across rounds'}
    images = []; runs = []; probes = {}
    try:
        binaries = {(variant, diagnostic): build(work / (variant + ('-trace' if diagnostic else '-clean')),
                                                source.resolve(), diagnostic, env, sdk, args.arch)
                    for variant, source in [('a', args.baseline_dir), ('b', args.candidate_dir)]
                    for diagnostic in [False, True]}
        if args.compile_only:
            manifest['runtime'] = 'NOT RUN'; print('PASS: compile/link only'); return
        prepared = work / 'prepared.ntfs'; images.append(prepared); clone(args.fixture, prepared)
        run(binaries['a', False], 'prepare', prepared, work / 'prepare', env)
        manifest['prepared'] = digest(prepared)
        for round_no in range(args.rounds):
            pair = {}
            for variant in (['a', 'b'] if round_no % 2 == 0 else ['b', 'a']):
                prefix = work / f'round-{round_no}-{variant}'
                image = prefix.with_suffix('.ntfs'); images.append(image); clone(prepared, image)
                pair[variant] = run(binaries[variant, False], 'measure', image, prefix, env)
                demand(digest(image) == manifest['prepared'], 'read-only image changed')
                image.unlink()
            demand([(r['opened'], r['workload'], r['checksum']) for r in pair['a']] ==
                   [(r['opened'], r['workload'], r['checksum']) for r in pair['b']], 'variant outcomes differ')
            runs.append(pair); print(f'PASS: clean pair {round_no + 1}/{args.rounds}', flush=True)
        for variant in ['a', 'b']:
            prefix = work / ('diagnostic-' + variant)
            image = prefix.with_suffix('.ntfs'); images.append(image); clone(prepared, image)
            probes[variant] = run(binaries[variant, True], 'measure', image, prefix, env)
            demand(digest(image) == manifest['prepared'], 'diagnostic image changed'); image.unlink()
            for clean, probe in zip(runs[0][variant], probes[variant]):
                demand((clean['opened'], clean['workload'], clean['checksum']) ==
                       (probe['opened'], probe['workload'], probe['checksum']), 'probe outcomes differ')
        demand([r['reads'] for r in probes['a']] == [r['reads'] for r in probes['b']], 'variant read calls differ')
        summary = []
        for i, row in enumerate(runs[0]['a']):
            result = {k: row[k] for k in ['opened', 'workload', 'operations']}
            for metric in ['wall_ns', 'cpu_ns', 'p50_ns', 'p95_ns', 'p99_ns', 'rss_bytes']:
                # A clock tick can exceed an idempotent reopen. Keep its raw zero
                # samples and absolute values, but do not invent a percent ratio.
                result[metric] = (interval([(pair['b'][i][metric] / pair['a'][i][metric] - 1) * 100 for pair in runs])
                                  if all(pair['a'][i][metric] for pair in runs) else
                                  {'median_percent': None, 'bootstrap95_percent': None,
                                   'reason': 'zero baseline samples below clock resolution'})
                result[metric]['a_median'] = statistics.median(pair['a'][i][metric] for pair in runs)
                result[metric]['b_median'] = statistics.median(pair['b'][i][metric] for pair in runs)
            summary.append(result)
        (work / 'summary.json').write_text(json.dumps({'workloads': summary, 'diagnostics': probes}, indent=2) + '\n')
        print('PASS: names/identity/attributes/cookies/checksums, diagnostic I/O equality, unchanged images')
    finally:
        for image in images: image.unlink(missing_ok=True)
        manifest['fixture_unchanged'] = digest(args.fixture) == manifest['fixture']
        (work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    demand(manifest['fixture_unchanged'], 'original fixture changed')


if __name__ == '__main__':
    main()
