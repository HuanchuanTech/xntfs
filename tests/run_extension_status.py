#!/usr/bin/env python3
"""Exercise the real refresh method with a finite synthetic FSClient query source.

Only copies under a fresh _tmp output directory are changed. No app bundle is
built, registered, installed or queried. The production recorder uses process
memory in this standalone executable. Framework internals are not instrumented.
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
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--source', type=Path, default=ROOT / 'xntfs/Services/ExtensionStatus.swift')
parser.add_argument('--sanitize', choices=['address', 'thread'])
parser.add_argument('--legacy', action='store_true')
parser.add_argument('--probe', action='store_true', help='Hold copied pending-task promotion to test the handoff gap')
parser.add_argument('--baseline-probe', action='store_true')
parser.add_argument('--compile-only', action='store_true')
parser.add_argument('--arch', choices=['arm64', 'x86_64'], default=platform.machine())
args = parser.parse_args()
out = args.output.resolve()
if not out.is_relative_to(ROOT / '_tmp'):
    parser.error('--output must be a new directory under the project _tmp')
out.mkdir(parents=True, exist_ok=False)
frozen = out / 'source'
frozen.mkdir()
paths = [(args.source, 'ExtensionStatus.swift'),
         (ROOT / 'Shared/DiagnosticRecorder.swift', 'DiagnosticRecorder.swift'),
         (ROOT / 'tests/test_extension_status.swift', 'test_extension_status.swift'),
         (Path(__file__).resolve(), 'run_extension_status.py')]
hashes = {}
for path, name in paths:
    target = frozen / name
    shutil.copy2(path, target)
    hashes[name] = hashlib.sha256(target.read_bytes()).hexdigest()
source = frozen / 'ExtensionStatus.swift'
text = source.read_text()
needle = 'FSClient.shared.installedExtensions'
assert text.count(needle) == 1
text = text.replace(needle, 'ExtensionQueryFixture.installedExtensions')
needle = 'ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15'
assert text.count(needle) == 1
text = text.replace(needle, 'true' if args.legacy else 'false')
if args.probe:
    needle = '                await current.value\n'
    assert text.count(needle) == 1
    text = text.replace(needle, needle + '                await ExtensionQueryFixture.pausePromotion()\n')
source.write_text(text)
flags = ['-O', '-g', '-parse-as-library', '-swift-version', '5',
         '-default-isolation', 'MainActor', '-module-name', 'ExtensionRefreshTests',
         '-target', args.arch + '-apple-macos15.4']
if args.sanitize:
    flags += ['-sanitize=' + args.sanitize]
if args.probe:
    flags += ['-D', 'EXTENSION_REFRESH_PROBE']
command = ['xcrun', 'swiftc', *flags, str(source), str(frozen / 'DiagnosticRecorder.swift'),
           str(frozen / 'test_extension_status.swift'), '-o', str(out / 'runner')]
env = os.environ.copy()
env.pop('SDKROOT', None)
with (out / 'build.log').open('w') as log:
    subprocess.run(command, cwd=out, env=env, stdout=log, stderr=log, check=True, timeout=180)
manifest = {'sources': hashes, 'command': command, 'cwd': str(out), 'sanitize': args.sanitize,
            'legacy': args.legacy, 'promotion_probe': args.probe,
            'compiled_sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in frozen.glob('*.swift')},
            'binary_sha256': hashlib.sha256((out / 'runner').read_bytes()).hexdigest()}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
if not args.compile_only:
    command = [str(out / 'runner')]
    if args.baseline_probe:
        command += ['--baseline-probe']
    with (out / 'results.log').open('w') as log:
        result = subprocess.run(command, cwd=out, env=env, stdout=log, stderr=log, timeout=90)
    print((out / 'results.log').read_text())
    raise SystemExit(result.returncode)
