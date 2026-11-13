#!/usr/bin/env python3
"""Test actual diagnostic observation/capture with synthetic DA and copied FSClient stub."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--monitor-source', type=Path, default=ROOT / 'xntfs/Services/DiskArbitrationMonitor.swift')
parser.add_argument('--report-source', type=Path, default=ROOT / 'xntfs/Services/ProblemReport.swift')
parser.add_argument('--image-source', type=Path, default=ROOT / 'xntfs/Services/ImageMountService.swift')
parser.add_argument('--model-source', type=Path, default=ROOT / 'xntfs/Services/AppModel.swift')
parser.add_argument('--sanitize', choices=['address', 'thread'])
parser.add_argument('--probe', action='store_true')
parser.add_argument('--debug', action='store_true')
parser.add_argument('--capture-only', action='store_true')
parser.add_argument('--passive-case', choices=['monitor', 'model', 'history'])
args = parser.parse_args()
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
frozen = out / 'source'
paths = [ROOT / 'Shared/DiagnosticRecorder.swift', *sorted((ROOT / 'xntfs/Services').glob('*.swift')),
         ROOT / 'xntfs/Model/NTFSDevice.swift', *[ROOT / 'tests' / name for name in
         ['test_host_diagnostics.swift', 'host_observation_shim.c', 'host_observation_shim.h',
          'host_query_guard.c', 'host_query_guard.h', 'run_host_diagnostics.py']]]
hashes = {}
for source in paths:
    relative = source.relative_to(ROOT)
    if source.name == 'DiskArbitrationMonitor.swift': source = args.monitor_source
    if source.name == 'ProblemReport.swift': source = args.report_source
    if source.name == 'ImageMountService.swift': source = args.image_source
    if source.name == 'AppModel.swift': source = args.model_source
    target = frozen / relative
    target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
    hashes[str(relative)] = hashlib.sha256(target.read_bytes()).hexdigest()

# Never call FSClient or inspect the installed app. Keep the rest of the real
# service and real report capture code, replacing only this copied method body.
extension = frozen / 'xntfs/Services/ExtensionStatus.swift'
text = extension.read_text()
start = text.index('    func refresh(appURL:')
end = text.index('    static func embeddedExtension(', start)
text = text[:start] + '''    func refresh(appURL: URL = Bundle.main.bundleURL) async {
        await CaptureFixture.refresh()
        queryError = CaptureFixture.queryError
        state = queryError == nil ? .enabled : .unknown
        installedCount = queryError == nil ? 1 : 0
        moduleURLs = queryError == nil ? [URL(fileURLWithPath: "/Applications/xntfs.app", isDirectory: true)] : []
    }

''' + text[end:]
extension.write_text(text)
# Gate the actual recorder queue only in the frozen test copy. The shared test
# recorder uses process memory, never the installed app's App Group directory.
recorder = frozen / 'Shared/DiagnosticRecorder.swift'
text = recorder.read_text()
needle = '            pendingSnapshots += 1\n'
assert text.count(needle) == 1
text = text.replace(needle, needle + '            CaptureHistoryGate.snapshotStarted()\n')
text += '''
extension DiagnosticRecorder {
    func holdCaptureHistoryForTest() {
        queue.async { CaptureHistoryGate.wait() }
    }
}
'''
recorder.write_text(text)
monitor = frozen / 'xntfs/Services/DiskArbitrationMonitor.swift'
if args.probe:
    text = monitor.read_text()
    start = text.index('    func devicesForDiagnostics()')
    end = text.index('    var currentDevices:', start)
    section = text[start:end]
    needle = '            queue.async { [self] in\n'
    assert section.count(needle) == 1
    section = section.replace(needle, '            let queryLease = DiagnosticOwnershipProbe(owner: ObjectIdentifier(self))\n'
                              '            queue.async { [self, queryLease] in\n'
                              '                defer { withExtendedLifetime(queryLease) {} }\n')
    text = text[:start] + section + text[end:]
    start = text.index('    private func publish() {')
    end = text.index('    // MARK: description parsing', start)
    section = text[start:end]
    # Both the frozen baseline and candidate keep their actual publication logic.
    # These witnesses count closure ownership and snapshot materializations only.
    section = section.replace('DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?(list) }',
                              'DispatchQueue.main.async { [weak self] in\n'
                              '            self?.onDevicesChanged?(list)\n        }')
    needle = '        DispatchQueue.main.async { [weak self] in\n'
    assert section.count(needle) == 1
    section = section.replace(needle,
        '        let publicationLease = PublicationOwnershipProbe(owner: ObjectIdentifier(self))\n'
        '        DispatchQueue.main.async { [weak self, publicationLease] in\n'
        '            defer { withExtendedLifetime(publicationLease) {} }\n')
    if 'let list = currentDevices' in section:
        section = section.replace('        let list = currentDevices\n',
                                  '        let list = currentDevices\n'
                                  '        PublicationOwnershipProbe.copied(rows: list.count)\n')
    else:
        needle = '            let list = Array(self.devices.values)\n'
        assert section.count(needle) == 1
        section = section.replace(needle, needle + '            PublicationOwnershipProbe.copied(rows: list.count)\n')
    monitor.write_text(text[:start] + section + text[end:])

commands = []
def run_build(command, label):
    commands.append(command)
    with (out / (label + '.log')).open('w') as log:
        subprocess.run(command, cwd=out, stdout=log, stderr=log, check=True, timeout=180)

cflags = ['-g'] + (['-fsanitize=' + args.sanitize] if args.sanitize else [])
run_build(['xcrun', 'clang', '-fblocks', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=15.4',
           *cflags, '-c', str(frozen / 'tests/host_observation_shim.c'), '-o', str(out / 'observation.o')], 'fixture-build')
# stat can run during sanitizer startup; only this small atomic guard is unsanitized.
run_build(['xcrun', 'clang', '-g', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=15.4',
           '-c', str(frozen / 'tests/host_query_guard.c'), '-o', str(out / 'guard.o')], 'guard-build')
shim = out / 'shim.dylib'
run_build(['xcrun', 'clang', '-mmacosx-version-min=15.4', *cflags, '-dynamiclib',
           str(out / 'observation.o'), str(out / 'guard.o'), '-framework', 'DiskArbitration',
           '-framework', 'IOKit', '-framework', 'CoreFoundation', '-install_name', str(shim), '-o', str(shim)], 'shim-build')
flags = ['-Onone' if args.debug else '-O', '-g', '-parse-as-library', '-swift-version', '5',
         '-default-isolation', 'MainActor', '-module-name', 'HostDiagnosticAdmission',
         '-target', platform.machine() + '-apple-macos15.4']
if args.sanitize: flags += ['-sanitize=' + args.sanitize]
if args.probe: flags += ['-D', 'HOST_DIAGNOSTIC_PROBE']
swift = [frozen / p.relative_to(ROOT) for p in paths if p.suffix == '.swift']
run_build(['xcrun', 'swiftc', *flags, '-import-objc-header', str(frozen / 'tests/host_observation_shim.h'),
           str(shim), *map(str, swift), '-o', str(out / 'runner')], 'swift-build')
manifest = {'sources': hashes, 'commands': commands, 'cwd': str(out), 'probe': args.probe,
            'sanitize': args.sanitize, 'extension_refresh_stub': True,
            'compiled_sources': {str(p.relative_to(frozen)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in frozen.rglob('*') if p.is_file()},
            'binary_sha256': hashlib.sha256((out / 'runner').read_bytes()).hexdigest()}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
with (out / 'results.log').open('w') as log:
    result = subprocess.run([str(out / 'runner'), *(['--capture-only'] if args.capture_only else []),
                             *(['--passive-case', args.passive_case] if args.passive_case else [])],
                            cwd=out, stdout=log, stderr=log, timeout=90)
print((out / 'results.log').read_text())
raise SystemExit(result.returncode)
