#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Usage: bash tests/run_volume_concurrency.sh clean-NTFS-image [arch]}"
target_arch="${2:-$(uname -m)}"
libntfs="${NFSK_LIBNTFS_DIR:-$root/build/libntfs-universal}"
source_dir="${NFSK_VOLUME_SOURCE:-$root/ntfs3g}"
[[ -f "$fixture" ]] || { printf 'Expected a regular image file\n' >&2; exit 1; }
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/volume-concurrency.XXXXXX")"
trap 'rm -f -- "$work/test.img"' EXIT
c_sanitize=(-g)
swift_sanitize=(-g)
case "${NFSK_SANITIZE:-}" in
    thread|address) c_sanitize+=(-fsanitize="$NFSK_SANITIZE" -fno-omit-frame-pointer); swift_sanitize+=(-sanitize="$NFSK_SANITIZE") ;;
    "") ;;
    *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
xcrun clang "${c_sanitize[@]}" -g -arch "$target_arch" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 \
    -I"$libntfs" -I"$root/ntfs-3g/include" -I"$source_dir/bridge" \
    -Dntfs_inode_open=nfsk_test_inode_open -Dntfs_inode_close=nfsk_test_inode_close -Dntfs_inode_real_close=nfsk_test_inode_real_close \
    -c "$source_dir/bridge/ntfs_fskit.c" -o "$work/bridge.o"
xcrun clang "${c_sanitize[@]}" -g -arch "$target_arch" -mmacosx-version-min=15.4 -fobjc-arc -fmodules \
    -Dpwrite=nfsk_test_pwrite -Dpread=nfsk_test_pread -Dfsync=nfsk_test_fsync -I"$source_dir/bridge" \
    -c "$source_dir/bridge/ntfs_device_fskit.m" -o "$work/backend.o"
xcrun clang "${c_sanitize[@]}" -g -arch "$target_arch" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 \
    -I"$libntfs" -I"$root/ntfs-3g/include" -I"$source_dir/bridge" \
    -c "$root/tests/volume_write_gate.c" -o "$work/gate.o"
xcrun clang "${c_sanitize[@]}" -arch "$target_arch" -mmacosx-version-min=15.4 -fobjc-arc -fmodules -I"$source_dir/bridge" \
    -c "$root/tests/directory_packer.m" -o "$work/packer.o"
xcrun swiftc "${swift_sanitize[@]}" -g -parse-as-library -target "$target_arch-apple-macos15.4" \
    -import-objc-header "$root/tests/volume_write_gate.h" -I"$source_dir/bridge" \
    "$root/tests/test_volume_concurrency.swift" "$source_dir/ntfs3gVolume.swift" \
    "$root/Shared/DiagnosticRecorder.swift" "$source_dir/ntfs3gFileSystem.swift" \
    "$source_dir/ntfs3gItem.swift" "$work/bridge.o" "$work/backend.o" "$work/gate.o" "$work/packer.o" \
    "$libntfs/libntfs-3g.a" -framework FSKit -framework Foundation -framework DiskArbitration \
    -o "$work/test-volume-concurrency"
cp "$fixture" "$work/test.img"
"$work/test-volume-concurrency" "$work/test.img" 2>&1 | tee "$work/results.log"
printf 'Test artifacts: %s\n' "$work"
