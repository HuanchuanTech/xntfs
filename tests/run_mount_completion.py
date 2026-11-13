#!/usr/bin/env python3
"""Check actual MountService completion using finite synthetic DA/IOKit/FSClient inputs.

No native mounts, registrations or installed-app queries. Copied-source probes are
optional; framework internals and the startup query guard are not instrumented.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--source', type=Path, default=ROOT / 'xntfs/Services/MountService.swift')
parser.add_argument('--sanitize', choices=['address', 'thread'])
parser.add_argument('--probe', action='store_true')
parser.add_argument('--baseline-probe', action='store_true')
parser.add_argument('--denial-case', choices=['registry', 'discovery', 'missing', 'description', 'mounted', 'readonly', 'all'])
parser.add_argument('--compile-only', action='store_true')
parser.add_argument('--clean-timing', action='store_true', help='Disable observation counters; use --compile-only and runner --benchmark')
parser.add_argument('--arch', choices=['arm64', 'x86_64'], default=platform.machine())
args = parser.parse_args()
if args.clean_timing and not args.compile_only:
    parser.error('--clean-timing requires --compile-only; run the resulting runner with --benchmark')
if not args.compile_only and int(platform.mac_ver()[0].split('.')[0]) < 27:
    parser.error('runtime mount completion checks require macOS 27 or later')
out = args.output.resolve()
if not out.is_relative_to(ROOT / '_tmp'):
    parser.error('--output must be a new directory under project _tmp')
out.mkdir(parents=True, exist_ok=False)
frozen = out / 'source'
paths = ['Shared/DiagnosticRecorder.swift', 'xntfs/Model/NTFSDevice.swift',
         *[str(p.relative_to(ROOT)) for p in sorted((ROOT / 'xntfs/Services').glob('*.swift'))],
         *['tests/' + name for name in
         ['test_mount_completion.swift', 'mount_completion_shim.c', 'mount_completion_shim.h',
          'host_observation_shim.c', 'host_observation_shim.h', 'host_query_guard.c',
          'host_query_guard.h', 'run_mount_completion.py']]]
hashes = {}
for path in paths:
    src = args.source if path.endswith('/MountService.swift') else ROOT / path
    target = frozen / path
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, target)
    hashes[path] = hashlib.sha256(target.read_bytes()).hexdigest()
mount = frozen / 'xntfs/Services/MountService.swift'
text = mount.read_text()
needle = 'FSClient.shared.installedExtensions'
assert text.count(needle) == 1
text = text.replace(needle, 'MountModuleFixture.installedExtensions')
if args.probe:
    needle = '    init(_ handler: @escaping (DADissenter?) -> Void) { self.handler = handler }'
    assert text.count(needle) == 1
    text = text.replace(needle, '''    init(_ handler: @escaping (DADissenter?) -> Void) {
        self.handler = handler
        MountCallbackProbe.shared.acquire()
    }
    deinit { MountCallbackProbe.shared.release() }''')
mount.write_text(text)
env = os.environ.copy()
env.pop('SDKROOT', None)
commands = []
def build(label, command):
    command = list(map(str, command)); commands.append(command)
    with (out / (label + '.log')).open('w') as log:
        subprocess.run(command, cwd=out, env=env, stdout=log, stderr=log, check=True, timeout=180)

cflags = ['-arch', args.arch, '-g', '-fblocks', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=15.4']
sanitizer = ['-fsanitize=' + args.sanitize] if args.sanitize else []
for name in ['host_observation_shim', 'mount_completion_shim']:
    timing = ['-DOBSERVATION_CLEAN_TIMING'] if args.clean_timing and name == 'host_observation_shim' else []
    build(name, ['xcrun', 'clang', *cflags, *sanitizer, *timing, '-c', frozen / ('tests/' + name + '.c'), '-o', out / (name + '.o')])
# stat interposition may execute during sanitizer startup: leave only this guard unsanitized.
build('guard', ['xcrun', 'clang', *cflags, '-c', frozen / 'tests/host_query_guard.c', '-o', out / 'guard.o'])
shim = out / 'fixture.dylib'
build('fixture-link', ['xcrun', 'clang', *cflags, *sanitizer, '-dynamiclib',
    out / 'host_observation_shim.o', out / 'mount_completion_shim.o', out / 'guard.o',
    '-framework', 'DiskArbitration', '-framework', 'IOKit', '-framework', 'CoreFoundation',
    '-install_name', shim, '-o', shim])
flags = ['-O', '-g', '-parse-as-library', '-swift-version', '5', '-default-isolation', 'MainActor',
         '-target', args.arch + '-apple-macos15.4', '-module-name', 'MountCompletionTests']
if args.sanitize:
    flags += ['-sanitize=' + args.sanitize]
if args.probe:
    flags += ['-D', 'MOUNT_COMPLETION_PROBE']
build('swift', ['xcrun', 'swiftc', *flags, '-import-objc-header', frozen / 'tests/mount_completion_shim.h',
    shim, *[frozen / p for p in paths if p.endswith('.swift')], '-o', out / 'runner'])
manifest = {'sources': hashes, 'commands': commands, 'cwd': str(out), 'sanitize': args.sanitize,
            'probe': args.probe, 'denial_case': args.denial_case, 'clean_timing': args.clean_timing, 'real_mounts': False, 'compiled_sources': {
                str(p.relative_to(frozen)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in frozen.rglob('*') if p.is_file()},
            'binary_sha256': hashlib.sha256((out / 'runner').read_bytes()).hexdigest()}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
if not args.compile_only:
    command = [str(out / 'runner')] + (['--baseline-probe'] if args.baseline_probe else [])
    if args.denial_case:
        command += ['--denial-case', args.denial_case]
    with (out / 'results.log').open('w') as log:
        result = subprocess.run(command, cwd=out, env=env, stdout=log, stderr=log, timeout=90)
    (out / 'exit.json').write_text(json.dumps({'command': command, 'returncode': result.returncode}) + '\n')
    print((out / 'results.log').read_text())
    raise SystemExit(result.returncode)
