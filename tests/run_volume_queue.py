#!/usr/bin/env python3
"""Audit actual volume queue/caller ownership on bounded ordinary-file copies."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

from run_crash_consistency import ROOT, clone, demand, digest
from validation_timing import run_timed


def instrument(text):
    # Only the copied source gains names and witnesses. No new product hooks,
    # scheduling policy, queue, gate or borrowed-buffer copy is introduced.
    needle = 'private func withIO<T>('
    demand(text.count(needle) == 2, 'expected two withIO overloads')
    text = text.replace(needle, needle + 'function: String = #function, ')
    needle = 'private func replyWithItem('
    demand(text.count(needle) == 1, 'expected item reply helper')
    text = text.replace(needle, needle + 'function: String = #function, ')
    for start, end, indent, count in [
        ('    private func withIO<T>', '    private func refreshStatistics()', '            ', 2),
        ('    private func replyWithItem(', '    private func item(', '        ', 1),
    ]:
        a, b = text.index(start), text.index(end)
        section = text[a:b]
        needle = indent + 'ioQueue.async(execute: DispatchWorkItem { [self] in\n'
        demand(section.count(needle) == count, 'queue entry shape changed')
        section = section.replace(needle,
            indent + 'let lease = VolumeQueueLease(owner: ObjectIdentifier(self), function: function)\n'
            + indent + 'ioQueue.async(execute: DispatchWorkItem { [self, lease] in\n'
            + indent + '    lease.started()\n' + indent + '    defer { lease.finished() }\n')
        needle = indent + '})\n'
        demand(section.count(needle) == count, 'queue completion shape changed')
        section = section.replace(needle, needle + indent + 'lease.submitted()\n')
        text = text[:a] + section + text[b:]
    needle = '                nfsk_write(h, it.ino, Int64(offset), raw.baseAddress, Int64(raw.count), &err)'
    demand(text.count(needle) == 1, 'borrowed write call changed')
    text = text.replace(needle,
        '                VolumeQueueProbe.writePointer(raw.baseAddress, bytes: raw.count)\n'
        + needle.replace('nfsk_write(', 'return nfsk_write('))
    needle = '                return value.withUnsafeBytes { nfsk_setxattr(h, it.ino, key, $0.baseAddress, $0.count, bridgePolicy) }'
    demand(text.count(needle) == 1, 'borrowed xattr call changed')
    return text.replace(needle,
        '                return value.withUnsafeBytes { raw in\n'
        '                    VolumeQueueProbe.writePointer(raw.baseAddress, bytes: raw.count)\n'
        '                    return nfsk_setxattr(h, it.ino, key, raw.baseAddress, raw.count, bridgePolicy)\n'
        '                }')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, default=ROOT / 'tests/work.ntfs')
    parser.add_argument('--volume-source', type=Path, default=ROOT / 'ntfs3g/ntfs3gVolume.swift')
    parser.add_argument('--sanitize', choices=['address', 'thread'])
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default=platform.machine())
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--negative-control', choices=['dropped-write', 'retained-payload'])
    parser.add_argument('--scenario', choices=['all', 'xattr-retirement'], default='all')
    args = parser.parse_args()
    work = args.output.absolute()
    demand(work.parent.resolve().is_relative_to((ROOT / '_tmp').resolve()) and not work.exists(),
           'new output directory under project _tmp required')
    demand(args.compile_only or args.arch == platform.machine(), 'foreign architecture requires --compile-only')
    # Validate even a compile-only fixture before collecting a fingerprint; never
    # hash or open a raw device, symlink or unbounded caller-supplied input.
    demand(args.fixture.is_file() and not args.fixture.is_symlink()
           and args.fixture.stat().st_size <= 128 << 20, 'bounded ordinary-file fixture required')
    work.mkdir(parents=True)
    source = work / 'source'; source.mkdir()
    originals = {}
    names = [*['ntfs3g/' + n for n in ['ntfs3gVolume.swift', 'ntfs3gItem.swift', 'ntfs3gFileSystem.swift']],
             *['ntfs3g/bridge/' + n for n in ['ntfs_fskit.c', 'ntfs_fskit.h', 'ntfs_device_fskit.m']],
             'Shared/DiagnosticRecorder.swift',
             *['tests/' + n for n in ['test_volume_queue.swift', 'run_volume_queue.py',
                                     'validation_timing.py',
                                     'volume_write_gate.c', 'volume_write_gate.h', 'directory_packer.m', 'directory_packer.h']]]
    for relative in names:
        original = args.volume_source if relative == 'ntfs3g/ntfs3gVolume.swift' else ROOT / relative
        shutil.copy2(original, source / Path(relative).name)
        originals[relative] = digest(original)
    volume = source / 'ntfs3gVolume.swift'
    volume.write_text(instrument(volume.read_text()))
    if args.negative_control == 'dropped-write':
        text = volume.read_text()
        needle = 'return nfsk_write(h, it.ino, Int64(offset), raw.baseAddress, Int64(raw.count), &err)'
        demand(text.count(needle) == 1, 'negative write site changed')
        # One genuinely active pwrite still exercises the paused backend. Later
        # requests falsely report success without data, which reopen must detect.
        volume.write_text(text.replace(needle, 'if offset != 0 { return Int64(raw.count) }\n                ' + needle))
    elif args.negative_control == 'retained-payload':
        test = source / 'test_volume_queue.swift'; text = test.read_text()
        needle = '    static let state = Locked(State())\n'
        demand(text.count(needle) == 1, 'payload ledger shape changed')
        text = text.replace(needle, needle + '    static let retainedControl = Locked<[Data]>([])\n')
        needle = '        let data = Payload.make(bytes: bytes, value: value)\n'
        demand(text.count(needle) == 1, 'payload submit shape changed')
        test.write_text(text.replace(needle, needle + '        Payload.retainedControl.access { $0.append(data) }\n'))

    env = {k: v for k, v in os.environ.items() if k != 'SDKROOT'}
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    library = ROOT / 'build/libntfs-universal'
    flags = ['-O2', '-g', '-Werror', '-arch', args.arch, '-mmacosx-version-min=15.4', '-isysroot', sdk,
             '-DHAVE_CONFIG_H=1', '-I' + str(source), '-I' + str(library), '-I' + str(ROOT / 'ntfs-3g/include')]
    swift = ['-O', '-g', '-warnings-as-errors', '-swift-version', '5', '-whole-module-optimization',
             '-parse-as-library', '-target', args.arch + '-apple-macos15.4', '-sdk', sdk]
    if args.sanitize:
        flags += ['-fsanitize=' + args.sanitize, '-fno-omit-frame-pointer']
        swift += ['-sanitize=' + args.sanitize]
    commands = []
    for filename, obj, extra in [
        ('ntfs_fskit.c', 'bridge.o', ['-Dntfs_inode_open=nfsk_test_inode_open',
            '-Dntfs_inode_close=nfsk_test_inode_close', '-Dntfs_inode_real_close=nfsk_test_inode_real_close']),
        ('ntfs_device_fskit.m', 'backend.o', ['-fobjc-arc', '-Dpwrite=nfsk_test_pwrite',
            '-Dpread=nfsk_test_pread', '-Dfsync=nfsk_test_fsync']),
        ('volume_write_gate.c', 'gate.o', []), ('directory_packer.m', 'packer.o', ['-fobjc-arc']),
    ]:
        commands.append(['xcrun', 'clang', *flags, *extra, '-c', source / filename, '-o', work / obj])
    commands.append(['xcrun', 'swiftc', *swift, '-import-objc-header', source / 'volume_write_gate.h',
                     '-I' + str(source), *[source / n for n in ['test_volume_queue.swift', 'ntfs3gVolume.swift',
                         'ntfs3gItem.swift', 'ntfs3gFileSystem.swift', 'DiagnosticRecorder.swift']],
                     *[work / n for n in ['bridge.o', 'backend.o', 'gate.o', 'packer.o']],
                     library / 'libntfs-3g.a', '-framework', 'Foundation', '-framework', 'FSKit',
                     '-framework', 'DiskArbitration', '-o', work / 'runner'])
    manifest = {'original_sources': originals, 'compiled_sources': {p.name: digest(p) for p in source.iterdir()},
                'fixture': digest(args.fixture), 'library': digest(library / 'libntfs-3g.a'),
                'config': digest(library / 'config.h'), 'sdk': sdk,
                'commands': [[str(a) for a in c] for c in commands], 'sanitizer': args.sanitize,
                'upstream_instrumented': False, 'negative_control': args.negative_control,
                'scenario': args.scenario,
                'volume_source': str(args.volume_source.resolve()),
                'scope': 'regular file copies; actual volume/bridge; test-only queue/payload ledgers; no FSKit mount'}
    images = []
    try:
        for i, command in enumerate(commands):
            with (work / f'build-{i}.log').open('w') as log:
                run_timed(command, timing_path=work / 'timings.jsonl', phase='build', label=f'build-{i}',
                          env=env, cwd=work, check=True, timeout=180, stdout=log, stderr=subprocess.STDOUT)
        manifest['binary'] = digest(work / 'runner')
        if args.compile_only:
            manifest['runtime'] = 'NOT RUN'; print('PASS: compile/link only'); return
        for i in range(6 if args.scenario == 'all' else 1):
            image = work / f'case-{i}.ntfs'; clone(args.fixture, image); images.append(image)
        command = [str(work / 'runner'), args.scenario, *map(str, images)]
        manifest['run_command'] = command
        with (work / 'results.log').open('w') as log:
            result = run_timed(command, timing_path=work / 'timings.jsonl', phase='test', label='queue',
                               env=env, cwd=work, timeout=120, stdout=log, stderr=subprocess.STDOUT)
        manifest['exit_code'] = result.returncode
        lines = (work / 'results.log').read_text().splitlines()
        print('\n'.join(line for line in lines if line.startswith(('QUEUE_OWNERSHIP', 'PASS:'))))
        demand(result.returncode == 0, 'queue contract checks failed; inspect results.log')
    finally:
        for image in images: image.unlink(missing_ok=True)
        manifest['fixture_unchanged'] = digest(args.fixture) == manifest['fixture']
        (work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    demand(manifest['fixture_unchanged'], 'original fixture changed')


if __name__ == '__main__':
    main()
