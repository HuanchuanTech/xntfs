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
unset XNTFS_TEST_DEVICE XNTFS_TEST_IMAGE XNTFS_TEST_READ_ONLY_MEDIA
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/macos27-image-tests.XXXXXX")"
probe="$work/Test.app"
whole=""
cleanup() {
  if [[ -n "$whole" ]]; then
    if /usr/bin/hdiutil detach "$whole"; then
      /bin/rm -- "$work/attached.img"
    else
      printf 'Detach failed; retained test image: %s/attached.img\n' "$work" >&2
    fi
  fi
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$probe" || true
  if [[ -d "$probe" ]]; then /bin/rm -r -- "$probe"; fi
}
trap cleanup EXIT

mkdir -p "$probe/Contents/MacOS" "$probe/Contents/Resources"
cp "$app/Contents/Info.plist" "$probe/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Probe' "$probe/Contents/Info.plist"
cp "$app/Contents/embedded.provisionprofile" "$probe/Contents/embedded.provisionprofile"
cp "$fixture" "$probe/Contents/Resources/input.img"
/usr/bin/codesign -d --entitlements :- "$app" > "$work/entitlements.plist"
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.fskit.mount' "$work/entitlements.plist"
test_source="$root/tests/test_macos27_images.swift"
if [[ "$mode" != image ]]; then test_source="$root/tests/test_macos27_devices.swift"; fi

/usr/bin/xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos27.0" \
  "$test_source" \
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
if [[ "$mode" != image ]]; then
  /usr/bin/xcrun swift "$root/tests/prepare_macos27_device.swift" "$fixture" "$work/attached.img"
  access=-readwrite
  if [[ "$mode" == device-ro ]]; then access=-readonly; export XNTFS_TEST_READ_ONLY_MEDIA=1; fi
  /usr/bin/hdiutil attach -nomount "$access" -plist "$work/attached.img" > "$work/attached.plist"
  devices="$(/usr/bin/xcrun swift "$root/tests/prepare_macos27_device.swift" --devices "$work/attached.plist")"
  whole="${devices%%$'\n'*}"
  partition="${devices##*$'\n'}"
  export XNTFS_TEST_DEVICE="${partition#/dev/}"
  export XNTFS_TEST_IMAGE="$work/attached.img"
fi
"$work/verify-host" "$probe/Contents/MacOS/Probe" 2>&1 | /usr/bin/tee "$work/results.log"
printf 'Results: %s/results.log\n' "$work"
