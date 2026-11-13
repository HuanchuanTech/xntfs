#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
app="${1:?Usage: bash tests/run_macos27_images.sh signed-app signing-identity [fixture] [image|device|device-ro]}"
app="$(cd -- "$app" && pwd)"
export XNTFS_TEST_EXTENSION="$app/Contents/Extensions/ntfs3g.appex"
signing_identity="${2:?Provide a local code-signing identity}"
fixture="${3:-$root/ntfs-clean.img}"
mode="${4:-image}"
case "$mode" in image|device|device-ro) ;; *) printf 'Mode must be image, device, or device-ro\n' >&2; exit 1 ;; esac
if [[ "${XNTFS_TEST_STABILITY:-0}" == 1 && "$mode" != device ]]; then
  printf 'Stability validation requires the disposable device mode\n' >&2
  exit 1
fi
unset XNTFS_TEST_STABILITY_SCRIPT XNTFS_TEST_STABILITY_OUTPUT
unset XNTFS_TEST_DEVICE XNTFS_TEST_IMAGE XNTFS_TEST_READ_ONLY_MEDIA
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/macos27-image-tests.XXXXXX")"
if [[ "${XNTFS_TEST_STABILITY:-0}" == 1 ]]; then
  export XNTFS_TEST_STABILITY_SCRIPT="$root/tests/mounted_stability.py"
  export XNTFS_TEST_STABILITY_OUTPUT="$work"
fi
probe="$work/Test.app"
whole=""
partition=""
verify_attachment() {
  python3 - "$work/attached.img" "$whole" "$partition" "$work/attachment-identity.json" <<'PY'
import json, os, pathlib, plistlib, subprocess, sys

image, whole, partition, output = sys.argv[1:]
result = subprocess.run(["/usr/bin/hdiutil", "info", "-plist"],
                        capture_output=True, check=True, timeout=20)
images = plistlib.loads(result.stdout).get("images", [])
matches = [entry for entry in images
           if os.path.realpath(entry.get("image-path", "")) == os.path.realpath(image)]
if len(matches) != 1:
    raise SystemExit("Cannot uniquely identify this run's attached image; preserving it")
devices = [entry.get("dev-entry") for entry in matches[0].get("system-entities", [])]
if whole not in devices or partition not in devices or partition != whole + "s1":
    raise SystemExit("Attached image device identity changed; refusing device action")
identity = {"image": os.path.realpath(image), "whole": whole, "partition": partition}
pathlib.Path(output).write_text(json.dumps(identity, indent=2) + "\n")
print("ATTACHMENT " + json.dumps(identity))
PY
}
unregister_probe() {
  python3 - "$probe" "$work/unregister.log" <<'PY'
import pathlib, subprocess, sys

probe, log = sys.argv[1:]
tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
result = subprocess.run([tool, "-u", probe], stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True, timeout=20)
pathlib.Path(log).write_text(result.stdout)
if result.returncode == 0:
    print("CLEANUP test bundle unregistered")
    raise SystemExit(0)
if ": -10814" not in result.stdout:
    raise SystemExit("Test bundle unregister failed; see " + log)
# LaunchServices can report application-not-found for a host run directly.
# Accept that result only after independently checking the registration table.
with subprocess.Popen([tool, "-dump"], stdout=subprocess.PIPE,
                      stderr=subprocess.STDOUT, text=True) as query:
    present = False
    for line in query.stdout:
        if probe in line:
            present = True
    status = query.wait()
if status != 0 or present:
    raise SystemExit("Could not confirm the test bundle registration is absent")
print("CLEANUP test bundle was not registered; absence confirmed")
PY
}
cleanup() {
  local result=$?
  trap - EXIT
  printf 'CLEANUP original_exit=%s\n' "$result"
  if [[ -n "$whole" ]]; then
    if verify_attachment && /usr/bin/hdiutil detach "$whole"; then
      if [[ "$result" == 0 ]]; then
        /bin/rm -- "$work/attached.img" || result=1
      else
        printf 'Test failed; retained detached image: %s/attached.img\n' "$work" >&2
      fi
    else
      printf 'Detach failed; retained test image: %s/attached.img\n' "$work" >&2
      result=1
    fi
  fi
  if ! unregister_probe; then
    printf 'Test bundle unregister failed: %s\n' "$probe" >&2
    result=1
  fi
  if [[ -d "$probe" ]]; then /bin/rm -r -- "$probe" || result=1; fi
  exit "$result"
}
trap cleanup EXIT

mkdir -p "$probe/Contents/MacOS" "$probe/Contents/Resources"
cp "$app/Contents/Info.plist" "$probe/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Probe' "$probe/Contents/Info.plist"
cp "$app/Contents/embedded.provisionprofile" "$probe/Contents/embedded.provisionprofile"
if [[ "$mode" == image ]]; then
  raw_directory="$work/xntfs-native-tests-$(/usr/bin/uuidgen)"
  mkdir "$raw_directory"
  export XNTFS_TEST_IMAGE="$raw_directory/quoted ' NTFS 镜像.img"
  cp "$fixture" "$XNTFS_TEST_IMAGE"
  printf 'Raw test directory (select this folder when prompted): %s\n' "$raw_directory"
else
  cp "$fixture" "$probe/Contents/Resources/input.img"
fi
/usr/bin/codesign -d --entitlements :- "$app" > "$work/entitlements.plist"
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.fskit.mount' "$work/entitlements.plist"
test_source="$root/tests/test_macos27_images.swift"
if [[ "$mode" != image ]]; then test_source="$root/tests/test_macos27_devices.swift"; fi

/usr/bin/xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos27.0" \
  "$test_source" \
  "$root/Shared/DiagnosticRecorder.swift" \
  "$root/xntfs/Services/ProblemReport.swift" \
  "$root/xntfs/Services/ImageMountService.swift" \
  "$root/xntfs/Services/ExtensionStatus.swift" \
  "$root/xntfs/Services/AppModel.swift" \
  "$root/xntfs/Services/AppSettings.swift" \
  "$root/xntfs/Services/MountService.swift" \
  "$root/xntfs/Services/DiskArbitrationMonitor.swift" \
  "$root/xntfs/Model/NTFSDevice.swift" \
  -o "$probe/Contents/MacOS/Probe"
/usr/bin/codesign --sign "$signing_identity" --entitlements "$work/entitlements.plist" "$probe"
/usr/bin/xcrun swiftc "$root/tests/verify_macos27_images.swift" -o "$work/verify-host"
if [[ "$mode" == image ]]; then
  "$probe/Contents/MacOS/Probe" --event-loop-smoke | /usr/bin/tee "$work/event-loop-smoke.log"
  /usr/bin/grep -Fx 'PASS native event loop: async continuation after modal close' "$work/event-loop-smoke.log"
fi
if [[ "$mode" != image ]]; then
  "$probe/Contents/MacOS/Probe" --status-only
  /usr/bin/xcrun swift "$root/tests/prepare_macos27_device.swift" "$fixture" "$work/attached.img"
  access=-readwrite
  if [[ "$mode" == device-ro ]]; then access=-readonly; export XNTFS_TEST_READ_ONLY_MEDIA=1; fi
  /usr/bin/hdiutil attach -nomount "$access" -plist "$work/attached.img" > "$work/attached.plist"
  devices="$(/usr/bin/xcrun swift "$root/tests/prepare_macos27_device.swift" --devices "$work/attached.plist")"
  whole="${devices%%$'\n'*}"
  partition="${devices##*$'\n'}"
  verify_attachment
  export XNTFS_TEST_DEVICE="${partition#/dev/}"
  export XNTFS_TEST_IMAGE="$work/attached.img"
fi
"$work/verify-host" "$probe/Contents/MacOS/Probe" 2>&1 | /usr/bin/tee "$work/results.log"
printf 'Results: %s/results.log\n' "$work"
