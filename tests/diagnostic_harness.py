"""Build frozen diagnostic recorder copies; all hooks stay outside product source."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inject(source):
    edits = [
        ('        pending += 1\n', '        pending += 1\n        DiagnosticProbe.pending(pending)\n'),
        ('        await withCheckedContinuation { continuation in\n',
         '        await withCheckedContinuation { continuation in\n            defer { DiagnosticProbe.snapshotEnqueued() }\n'),
        ('    private func withStore(_ body: (URL) throws -> Void) throws {\n',
         '    private func withStore(_ body: (URL) throws -> Void) throws {\n        DiagnosticProbe.store()\n'),
        ('try data.write(to: url, options: .atomic)',
         'try DiagnosticProbe.write(data.count)\n                    try data.write(to: url, options: .atomic)'),
        ('                        try JSONEncoder().encode(persisted).write(to: url, options: .atomic)',
         '                        let savedData = try JSONEncoder().encode(persisted)\n'
         '                        try DiagnosticProbe.write(savedData.count)\n'
         '                        try savedData.write(to: url, options: .atomic)'),
    ]
    for before, after in edits:
        if source.count(before) != 1:
            raise ValueError('Recorder changed; review diagnostic injection: ' + before.strip())
        source = source.replace(before, after)
    # These guards were added after the batching baseline. Keep frozen older
    # baselines buildable; final memory tests require the resulting counters.
    for before, after in [
        ('            pendingSnapshots += 1\n', '            pendingSnapshots += 1\n            DiagnosticProbe.snapshotPending(pendingSnapshots)\n'),
        ('                pendingSnapshots -= 1\n', '                pendingSnapshots -= 1\n                DiagnosticProbe.snapshotPending(pendingSnapshots)\n'),
        ('        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)\n',
         '        DiagnosticProbe.readReady()\n        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)\n'),
        ('            data.append(chunk)\n', '            data.append(chunk)\n            DiagnosticProbe.readBytes(data.count)\n'),
    ]:
        if source.count(before) > 1: raise ValueError('Ambiguous memory probe: ' + before.strip())
        source = source.replace(before, after)
    return source


def build(folder, recorder, harness, trace=False, sanitize=None):
    folder = Path(folder).resolve()
    folder.mkdir(parents=True, exist_ok=False)
    frozen = folder / 'source'
    frozen.mkdir()
    paths = [Path(recorder), ROOT / 'tests/diagnostic_probe.swift', ROOT / 'tests' / harness,
             ROOT / 'tests/diagnostic_harness.py']
    for path in paths:
        shutil.copyfile(path, frozen / path.name)
    source = frozen / 'DiagnosticRecorder.swift'
    original_hash = digest(source)
    if trace:
        instrumented = frozen / 'DiagnosticRecorder.instrumented.swift'
        instrumented.write_text(inject(source.read_text()))
        source = instrumented
    flags = ['-O', '-g', '-whole-module-optimization', '-parse-as-library', '-swift-version', '5',
             '-default-isolation', 'MainActor', '-target', platform.machine() + '-apple-macos15.4']
    if sanitize: flags += ['-sanitize=' + sanitize]
    env = dict(os.environ)
    env.pop('SDKROOT', None)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    env['SDKROOT'] = sdk
    command = ['xcrun', 'swiftc', *flags, str(source), str(frozen / 'diagnostic_probe.swift'),
               str(frozen / harness), '-o', str(folder / 'runner')]
    with (folder / 'build.log').open('w') as log:
        # Swift may emit module sidecars even for an executable. Keep each build
        # in its own folder so concurrent sanitizer builds cannot share them.
        subprocess.run(command, cwd=folder, env=env, check=True, timeout=180, stdout=log, stderr=log)
    manifest = {'recorder_sha256': original_hash, 'trace': trace, 'sanitize': sanitize,
                'sdk': sdk, 'platform': platform.platform(), 'command': command, 'cwd': str(folder),
                'sources': {path.name: digest(path) for path in frozen.iterdir()},
                'binary_sha256': digest(folder / 'runner')}
    (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return folder / 'runner'
