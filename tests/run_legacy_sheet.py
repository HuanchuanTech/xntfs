#!/usr/bin/env python3
"""Exercise actual mount sheets in an offscreen SwiftUI host, without devices."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--modern', action='store_true', help='Test MountSheet actions instead of the legacy panel')
parser.add_argument('--sheet-source', type=Path)
parser.add_argument('--case', choices=['stale', 'parent', 'inflight', 'command', 'all'], default='all')
parser.add_argument('--sanitize', choices=['address', 'thread'])
args = parser.parse_args()
sheet_name = 'MountSheet.swift' if args.modern else 'LegacyMountSheet.swift'
test_name = 'test_mount_sheet.swift' if args.modern else 'test_legacy_sheet.swift'
sheet_source = args.sheet_source or ROOT / 'xntfs' / sheet_name
if not args.modern and args.case in ['inflight', 'command']:
    parser.error('--case inflight/command requires --modern')
if args.modern and args.case == 'stale':
    parser.error('--case stale is legacy-only; use parent, inflight or command')
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
frozen = out / 'source'
paths = [ROOT / 'Shared/DiagnosticRecorder.swift', ROOT / 'xntfs/Model/NTFSDevice.swift',
         *sorted((ROOT / 'xntfs/Services').glob('*.swift')),
         *[ROOT / 'xntfs' / name for name in
           [sheet_name, 'ExtensionEnablementInstructions.swift', 'CopyableCommand.swift',
            *(['DiskUtility.swift'] if args.modern else [])]],
         *[ROOT / 'tests' / name for name in [test_name, 'run_legacy_sheet.py',
           'host_observation_shim.c', 'host_observation_shim.h', 'host_query_guard.c', 'host_query_guard.h']]]
hashes = {}
for original in paths:
    relative = original.relative_to(ROOT)
    source = sheet_source if original.name == sheet_name else original
    target = frozen / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    hashes[str(relative)] = hashlib.sha256(target.read_bytes()).hexdigest()

# Observe actual State/Environment-derived values at body evaluation. The probe
# keeps one value snapshot and never changes selection, commands or view identity.
sheet = frozen / 'xntfs' / sheet_name
text = sheet.read_text()
needle = '    var body: some View {\n'
assert text.count(needle) == 1
if args.modern:
    text = text.replace(needle, needle + '''        let _ = MountSheetProbe.observe(selected: device, readOnly: readOnly, busy: busy,
            mount: { await doMount() }, toggle: { readOnly = $0 })
''')
    for before, after in [
        ('CopyableCommand(command: systemCommand)', 'CopyableCommand(command: MountSheetProbe.display(systemCommand))'),
        ('Text(errorText)', 'Text(MountSheetProbe.displayError(errorText))'),
        ('case .mounted: dismiss()', 'case .mounted: MountSheetProbe.didDismiss()')
    ]:
        assert text.count(before) == 1
        text = text.replace(before, after)
    for button, probe in [('Close', 'closeDisabled'), ('Mount', 'mountDisabled')]:
        pattern = r'(Button\("' + button + r'"\)[\s\S]*?\.disabled\()([^)]*)(\))'
        text, count = re.subn(pattern, lambda m: m[1] + 'MountSheetProbe.' + probe + '(' + m[2] + ')' + m[3], text)
        assert count == 1
else:
    text = text.replace(needle, needle + '        let _ = LegacySheetProbe.observe(selected: device, current: currentDevice, command: command)\n')
sheet.write_text(text)

# Supply resource/boot inputs only; retain the real command validation/quoting.
command = frozen / 'xntfs/Services/LegacyMountCommand.swift'
text = command.read_text()
needle = 'Bundle.main.url(forResource: "macos15-mount", withExtension: "sh")'
assert text.count(needle) == 1
text = text.replace(needle, 'URL(fileURLWithPath: "/fixture/A \' script.sh", isDirectory: false)')
start = text.index('    static func bootSessionUUID()')
end = text.index('    static func mount(', start)
text = text[:start] + '''    static func bootSessionUUID() -> String? {
        "11111111-2222-3333-4444-555555555555"
    }

''' + text[end:]
command.write_text(text)

# No external provider call may escape an unexpected view lifecycle callback.
extension = frozen / 'xntfs/Services/ExtensionStatus.swift'
text = extension.read_text()
start = text.index('    func refresh(appURL:')
end = text.index('    static func embeddedExtension(', start)
extension.write_text(text[:start] + '''    func refresh(appURL: URL = Bundle.main.bundleURL) async {
        preconditionFailure("Hosted sheet must not query FSClient")
    }

''' + text[end:])

commands = []
def build(label, command):
    commands.append(command)
    with (out / (label + '.log')).open('w') as log:
        subprocess.run(command, cwd=out, stdout=log, stderr=log, check=True, timeout=180)

cflags = ['-g'] + (['-fsanitize=' + args.sanitize] if args.sanitize else [])
build('fixture', ['xcrun', 'clang', '-fblocks', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=15.4',
    *cflags, '-c', str(frozen / 'tests/host_observation_shim.c'), '-o', str(out / 'fixture.o')])
# Keep the startup stat interposer unsanitized, as in the existing host runners.
build('guard', ['xcrun', 'clang', '-g', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=15.4',
    '-c', str(frozen / 'tests/host_query_guard.c'), '-o', str(out / 'guard.o')])
shim = out / 'shim.dylib'
build('shim', ['xcrun', 'clang', '-mmacosx-version-min=15.4', *cflags, '-dynamiclib',
    str(out / 'fixture.o'), str(out / 'guard.o'), '-framework', 'DiskArbitration', '-framework', 'IOKit',
    '-framework', 'CoreFoundation', '-install_name', str(shim), '-o', str(shim)])
flags = ['-O', '-g', '-parse-as-library', '-swift-version', '5', '-default-isolation', 'MainActor',
         '-target', platform.machine() + '-apple-macos15.4']
if args.sanitize:
    flags += ['-sanitize=' + args.sanitize]
plugin = ('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins#'
          '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-plugin-server')
build('swift', ['xcrun', 'swiftc', *flags, '-external-plugin-path', plugin,
    '-import-objc-header', str(frozen / 'tests/host_observation_shim.h'), str(shim),
    *[str(frozen / p.relative_to(ROOT)) for p in paths if p.suffix == '.swift'], '-o', str(out / 'runner')])
manifest = {'sources': hashes, 'commands': commands, 'modern': args.modern, 'case': args.case, 'sanitize': args.sanitize,
            'compiled_sources': {str(p.relative_to(frozen)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in frozen.rglob('*') if p.is_file()}}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
with (out / 'results.log').open('w') as log:
    result = subprocess.run([str(out / 'runner'), args.case], cwd=out, stdout=log, stderr=log, timeout=90)
(out / 'exit.json').write_text(json.dumps({'returncode': result.returncode}) + '\n')
print((out / 'results.log').read_text())
raise SystemExit(result.returncode)
