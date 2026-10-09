#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Usage: bash tests/run_volume_regressions.sh clean-NTFS-image [arch]}"
target_arch="${2:-$(uname -m)}"
[[ -f "$fixture" ]] || exit 1
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/volume-regressions.XXXXXX")"
trap 'rm -f -- "$work/test.img"' EXIT
xcrun clang -g -arch "$target_arch" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 -I"$root/build/libntfs-universal" \
    -I"$root/ntfs-3g/include" -I"$root/ntfs3g/bridge" \
    -c "$root/ntfs3g/bridge/ntfs_fskit.c" -o "$work/bridge.o"
xcrun clang -g -arch "$target_arch" -mmacosx-version-min=15.4 -fobjc-arc -fmodules -I"$root/ntfs3g/bridge" \
    -c "$root/ntfs3g/bridge/ntfs_device_fskit.m" -o "$work/backend.o"
xcrun swiftc -parse-as-library -target "$target_arch-apple-macos15.4" \
    -import-objc-header "$root/ntfs3g/ntfs3g-Bridging-Header.h" -I"$root/ntfs3g/bridge" \
    "$root/tests/test_volume_regressions.swift" "$root/ntfs3g/ntfs3gVolume.swift" \
    "$root/ntfs3g/ntfs3gFileSystem.swift" \
    "$root/ntfs3g/ntfs3gItem.swift" "$work/bridge.o" "$work/backend.o" \
    "$root/build/libntfs-universal/libntfs-3g.a" -framework FSKit -framework Foundation -framework DiskArbitration \
    -o "$work/test-volume"
cp "$fixture" "$work/test.img"
"$work/test-volume" "$work/test.img" 2>&1 | tee "$work/results.log"
printf 'Test artifacts: %s\n' "$work"
