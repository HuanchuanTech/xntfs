#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Usage: bash tests/run_volume_regressions.sh clean-NTFS-image [arch]}"
target_arch="${2:-$(uname -m)}"
library_dir="${NFSK_LIBNTFS_DIR:-$root/build/libntfs-universal}"
[[ -f "$fixture" ]] || exit 1
[[ -f "$library_dir/libntfs-3g.a" && -f "$library_dir/config.h" ]] || exit 1
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/volume-regressions.XXXXXX")"
trap 'rm -f -- "$work/test.img"' EXIT
test_sdk="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
c_sanitize=(-g -isysroot "$test_sdk")
swift_sanitize=(-g -sdk "$test_sdk")
case "${NFSK_BRIDGE_PROFILE:-default}" in
    default) ;;
    o2) c_sanitize+=(-O2) ;;
    o3) c_sanitize+=(-O3) ;;
    o2-thinlto|o3-thinlto)
        c_sanitize+=("-O${NFSK_BRIDGE_PROFILE:1:1}" -flto=thin)
        swift_sanitize+=(-Xclang-linker -flto=thin -Xlinker -mllvm -Xlinker -threads=2
                         -Xlinker -object_path_lto -Xlinker "$work/lto-objects") ;;
    *) printf 'Unsupported bridge profile\n' >&2; exit 2 ;;
esac
case "${NFSK_SANITIZE:-}" in
    address) c_sanitize+=(-fsanitize=address -fno-omit-frame-pointer); swift_sanitize+=(-sanitize=address) ;;
    "") ;;
    *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
xcrun clang "${c_sanitize[@]}" -arch "$target_arch" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1 -I"$library_dir" \
    -I"$root/ntfs-3g/include" -I"$root/ntfs3g/bridge" \
    -c "$root/ntfs3g/bridge/ntfs_fskit.c" -o "$work/bridge.o"
xcrun clang "${c_sanitize[@]}" -arch "$target_arch" -mmacosx-version-min=15.4 -fobjc-arc -fmodules -I"$root/ntfs3g/bridge" \
    -c "$root/ntfs3g/bridge/ntfs_device_fskit.m" -o "$work/backend.o"
xcrun clang "${c_sanitize[@]}" -arch "$target_arch" -mmacosx-version-min=15.4 -fobjc-arc -fmodules -I"$root/ntfs3g/bridge" \
    -c "$root/tests/directory_packer.m" -o "$work/packer.o"
xcrun swiftc "${swift_sanitize[@]}" -parse-as-library -target "$target_arch-apple-macos15.4" \
    -import-objc-header "$root/tests/directory_packer.h" -I"$root/ntfs3g/bridge" \
    "$root/tests/test_volume_regressions.swift" "$root/ntfs3g/ntfs3gVolume.swift" \
    "$root/Shared/DiagnosticRecorder.swift" \
    "$root/ntfs3g/ntfs3gFileSystem.swift" \
    "$root/ntfs3g/ntfs3gItem.swift" "$work/bridge.o" "$work/backend.o" "$work/packer.o" \
    "$library_dir/libntfs-3g.a" -framework FSKit -framework Foundation -framework DiskArbitration \
    -o "$work/test-volume"
cp "$fixture" "$work/test.img"
"$work/test-volume" "$work/test.img" 2>&1 | tee "$work/results.log"
printf 'Test artifacts: %s\n' "$work"
