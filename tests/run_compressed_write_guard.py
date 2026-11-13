#!/usr/bin/env python3
"""Verify compressed DATA admission without mutating original images or mounting.

This is a safety restriction check, not compressed write/recovery acceptance.
"""
import argparse
import copy
import errno
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

from ntfs_compressed_check import CompressedImage
from ntfs_image_check import DATA, Invalid, need
from run_compressed_regressions import ROOT, noise, sha
from run_compressed_xattr_matrix import KEY, fingerprint
from validation_timing import run_timed

NAMES = ('Empty', 'Small', 'High', 'Mixed', 'Random', 'Zero', 'Plain')


def snapshot(path):
    parsed = CompressedImage(path)
    try:
        parsed.scan()
        need(not parsed.errors, 'independent_structure:' + str(parsed.errors[:3]))
        streams, compression = {}, {}
        for name in NAMES:
            record = parsed.records[parsed.paths['/' + name]]
            for key in ('', KEY):
                attr = parsed.attr(record, DATA, key, optional=bool(key))
                label = name + ':' + key
                streams[label] = None if attr is None else fingerprint(parsed.stream(attr))
                compression[label] = None if attr is None else attr.get('compression', 0)
        return {'streams': streams, 'compression': compression, 'namespace': sorted(parsed.paths)}
    finally:
        parsed.close()


def validate_event(event, expected, no_mutation):
    need(event['result'] == expected, 'operation_result:' + str(event))
    need(all(event[k] == 0 for k in ('getattr', 'close', 'sync', 'second_sync', 'release', 'attrs_live')),
         'healthy_lifecycle:' + str(event))
    need(event['read'] == min(event['after_size'], 16), 'bridge_read_after_operation')
    if no_mutation:
        need(event['operation_writes'] == event['mutation_calls'] == event['pclose_calls'] == 0,
             'rejection_before_mutation:' + str(event))
        need(event['before_size'] == event['after_size'] and event['old_xattr'] == event['new_xattr'],
             'rejected_sizes_unchanged')
        need(event['faults_reached'] == 0, 'fault_is_prevented_not_recovered')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=Path)
    parser.add_argument('--source', type=Path, default=ROOT / 'ntfs3g/bridge')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sanitize', choices=('address', 'undefined'))
    parser.add_argument('--swift', action='store_true', help='also verify real Swift callback error propagation')
    args = parser.parse_args()
    if args.swift and args.sanitize == 'undefined':
        parser.error('Swift callback checks support AddressSanitizer or an uninstrumented build')
    work = args.output.resolve()
    need(work.is_relative_to(ROOT / '_tmp') and not work.exists(), 'new_project_output')
    work.mkdir(parents=True)
    shutil.copy2(__file__, work / Path(__file__).name)
    report = {'scope': 'Compressed DATA writes rejected before mutation; no installed FSKit/device acceptance',
              'cases': [], 'prepared': {}}
    env = dict(os.environ)
    env.pop('SDKROOT', None)

    def run(command, label):
        p = run_timed([str(x) for x in command], timing_path=work / 'timings.jsonl', phase='test', label=label,
                      env=env, cwd=ROOT, capture_output=True, text=True, timeout=90)
        (work / (label + '.log')).write_text(p.stdout + p.stderr)
        need(p.returncode == 0, 'command:' + label + ':' + p.stderr[-1000:])
        return p.stdout

    build = [sys.executable, '-B', ROOT / 'tests/run_compressed_regressions.py', args.fixture.resolve(),
             '--source', args.source.resolve(), '--output', work / 'build', '--fixtures-only']
    if args.sanitize:
        build += ['--sanitize', args.sanitize]
    run(build, 'build-fixtures')
    tool, seed = work / 'build/fixture-tool', work / 'build/seeded.img'
    seed_sha = sha(seed)
    payload = work / 'value.data'
    value = b'R' * 67237
    payload.write_bytes(value)
    empty = work / 'empty.data'
    empty.write_bytes(b'')
    counter = 0

    def case(prepared, name, mode, argument, expected, *, no_mutation=True, readonly=False, new_body=None, new_named=None):
        nonlocal counter
        counter += 1
        label = f'{counter:02d}-{name}-{mode}'
        image = work / 'case.img'
        need(not image.exists(), 'new_case_image')
        shutil.copyfile(prepared, image)
        before = snapshot(image)
        event = json.loads(run([tool, 'guard-ro' if readonly else 'guard', image, name, mode, argument], label))
        validate_event(event, expected, no_mutation)
        after = snapshot(image)
        desired = copy.deepcopy(before['streams'])
        if not no_mutation:
            if mode in ('write', 'append', 'truncate'):
                desired[name + ':'] = fingerprint(new_body)
            else:
                desired[name + ':' + KEY] = fingerprint(new_named)
        need(after['streams'] == desired, 'all_file_and_named_bytes:' + label)
        need(after['namespace'] == before['namespace'], 'namespace:' + label)
        if no_mutation:
            need(after == before, 'all_compression_states:' + label)
        readback = work / 'readback.data'
        for stream in ('', KEY):
            expected_bytes = desired[name + ':' + stream]
            if expected_bytes is None:
                continue
            command = [tool, 'read-stream' if stream else 'read', image, name]
            if stream:
                command.append(stream)
            run(command + [readback], label + '-native-' + ('named' if stream else 'main'))
            need(fingerprint(readback.read_bytes()) == expected_bytes, 'native_readback:' + label)
            readback.unlink()
        report['cases'].append({'case': label, 'expected': expected, 'event': event,
                                'unchanged': no_mutation, 'independent_and_native': 'PASS',
                                'fault_status': 'PREVENTED_BEFORE_IO' if 'fail' in mode else 'NOT_REQUESTED'})
        (work / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        image.unlink()

    initial = snapshot(seed)
    for name in NAMES[:-1]:
        need(initial['compression'][name + ':'] == 1, 'genuine_compressed:' + name)
        size = initial['streams'][name + ':']['size']
        for mode in ('open-write', 'write', 'append'):
            case(seed, name, mode, payload, -errno.ENOTSUP)
        for amount in sorted({0, size, size + 700}):
            case(seed, name, 'truncate', amount, -errno.ENOTSUP)
    case(seed, 'High', 'zero-write', payload, 0)
    case(seed, 'High', 'write', payload, -errno.EROFS, readonly=True)
    case(seed, 'High', 'open-write', payload, -errno.EROFS, readonly=True)
    case(seed, 'Plain', 'open-write', payload, 0)
    for mode in ('xattr-set', 'xattr-create'):
        case(seed, 'High', mode, payload, -errno.EPERM)
    for mode in ('xattr-replace', 'xattr-delete'):
        case(seed, 'High', mode, payload, -errno.ENOATTR)

    preparations = [
        ('resident', 'High', b'A' * 127, 'seed-stream', None),
        ('empty', 'High', b'', 'seed-stream', None),
        ('existing', 'High', b'A' * 66236, 'seed-stream', None),
        ('zero-r_zero', 'High', bytes(131072), 'seed-stream', None),
        ('near-full', 'High', b'A' * 66236, 'seed-stream', 'near-full'),
        ('fragmented', 'High', noise(66236), 'seed-stream', 'fragmented'),
        ('compressed-named-plain-file', 'Plain', b'A' * 66236, 'seed-stream-compressed', None),
        ('plain-named-compressed-file', 'High', b'A' * 127, 'seed-stream-plain', None),
    ]
    for profile, name, old, seed_command, layout in preparations:
        prepared = work / 'prepared.img'
        shutil.copyfile(seed, prepared)
        old_value = work / 'old.data'
        old_value.write_bytes(old)
        run([tool, seed_command, prepared, name, KEY, old_value, 1], profile + '-seed')
        if layout:
            run([tool, 'space', prepared, layout], profile + '-space')
        before = snapshot(prepared)
        compressed = profile != 'plain-named-compressed-file'
        need(before['compression'][name + ':' + KEY] == int(compressed), 'named_compression:' + profile)
        report['prepared'][profile] = {'sha256': sha(prepared), 'named': fingerprint(old), 'compressed': compressed}
        if compressed:
            new = noise(131072)[::-1] if profile == 'fragmented' else (
                b'R' * 65536 + bytes(65536) if profile == 'zero-r_zero' else value)
            payload.write_bytes(new)
            for mode in ('xattr-set', 'xattr-replace', 'xattr-delete'):
                case(prepared, name, mode, payload, -errno.EPERM)
            case(prepared, name, 'xattr-set', empty, -errno.EPERM)
            case(prepared, name, 'xattr-create', payload, -errno.EEXIST)
            if profile == 'zero-r_zero':
                for mode in ('xattr-read-fail-2', 'xattr-read-fail-3', 'xattr-write-fail-3'):
                    case(prepared, name, mode, payload, -errno.EPERM)
        else:
            payload.write_bytes(value)
            for mode in ('xattr-set', 'xattr-replace'):
                case(prepared, name, mode, payload, 0, no_mutation=False, new_named=value)
            case(prepared, name, 'xattr-delete', empty, 0, no_mutation=False, new_named=None)
        prepared.unlink()
    payload.write_bytes(value)
    plain = (work / 'build/Plain.data').read_bytes()
    case(seed, 'Plain', 'write', payload, len(value), no_mutation=False, new_body=value + plain[len(value):])
    case(seed, 'Plain', 'append', payload, len(value), no_mutation=False, new_body=plain + value)
    for amount in (0, 127, len(plain) + 700):
        case(seed, 'Plain', 'truncate', amount, 0, no_mutation=False,
             new_body=plain[:amount] + bytes(max(0, amount - len(plain))))
    for mode in ('xattr-set', 'xattr-create'):
        case(seed, 'Plain', mode, payload, 0, no_mutation=False, new_named=value)
    need(sha(seed) == seed_sha, 'seed_preserved')
    if args.swift:
        manifest = json.loads((work / 'build/manifest.json').read_text())
        commands = []
        # The Swift executable uses the production C/backend without fixture hooks.
        # Flags, source copies, SDK and sanitizer otherwise match this run.
        for command in manifest['commands'][:2]:
            command = [x for x in command if not x.startswith(('-Dntfs_', '-Dpread=', '-Dpwrite=', '-Dfsync='))]
            command[-1] = str(work / ('swift-' + Path(command[-1]).name))
            commands.append(command)
        frozen = work / 'swift-source'
        frozen.mkdir()
        paths = [ROOT / 'tests/test_compressed_write_guard.swift', ROOT / 'Shared/DiagnosticRecorder.swift']
        paths += [ROOT / 'ntfs3g' / name for name in ('ntfs3gVolume.swift', 'ntfs3gFileSystem.swift', 'ntfs3gItem.swift')]
        for path in paths:
            shutil.copy2(path, frozen / path.name)
        commands.append(['xcrun', 'swiftc', '-g', '-parse-as-library', '-sdk', manifest['sdk'],
                         '-target', platform.machine() + '-apple-macos15.4',
                         *(['-sanitize=address'] if args.sanitize == 'address' else []),
                         '-import-objc-header', str(work / 'build/source/ntfs_fskit.h'),
                         '-I' + str(work / 'build/source'),
                         *[str(frozen / p.name) for p in paths], str(work / 'swift-bridge.o'),
                         str(work / 'swift-backend.o'), str(ROOT / 'build/libntfs-universal/libntfs-3g.a'),
                         '-framework', 'FSKit', '-framework', 'Foundation', '-framework', 'DiskArbitration',
                         '-o', str(work / 'swift-guard')])
        (work / 'swift-manifest.json').write_text(json.dumps({'commands': commands,
            'sources': {str(p.relative_to(ROOT)): sha(p) for p in paths}}, indent=2) + '\n')
        for index, command in enumerate(commands):
            # Keep Swift compiler side products in the owned output directory.
            p = run_timed(command, timing_path=work / 'timings.jsonl', phase='build', label=f'swift-build-{index}',
                          env=env, cwd=work, capture_output=True, text=True, timeout=90)
            (work / f'swift-build-{index}.log').write_text(p.stdout + p.stderr)
            need(p.returncode == 0, 'swift_build:' + p.stderr[-2000:])
        report['swift'] = {}
        for mode in ('legacy', 'modern'):
            image = work / ('swift-' + mode + '.img')
            shutil.copyfile(seed, image)
            before = snapshot(image)
            output = run([work / 'swift-guard', image, mode], 'swift-' + mode)
            after = snapshot(image)
            expected = copy.deepcopy(before['streams'])
            expected['Plain:'] = fingerprint(b'R' * 700 + plain[700:])
            expected['Plain:' + KEY] = fingerprint(b'R' * 700)
            need(after['streams'] == expected and after['namespace'] == before['namespace'], 'swift_persisted:' + mode)
            report['swift'][mode] = {'result': 'PASS', 'output': output, 'independent_contents_and_structure': 'PASS'}
            image.unlink()
    report['result'] = 'PASS_LOCAL_COMPRESSED_WRITE_RESTRICTION'
    report['count'] = counter
    report['seed_sha256'] = seed_sha
    (work / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'result': report['result'], 'cases': counter, 'output': str(work)}, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Invalid, OSError, subprocess.SubprocessError) as e:
        print('CHECK FAILED:', e, file=sys.stderr)
        sys.exit(1)
