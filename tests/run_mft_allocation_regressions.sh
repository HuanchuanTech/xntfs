#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Usage: bash tests/run_mft_allocation_regressions.sh clean-NTFS-image [arch]}"
target_arch="${2:-$(uname -m)}"
[[ -f "$fixture" ]] || { printf 'Expected a regular image file\n' >&2; exit 1; }
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/mft-allocation.XXXXXX")"
trap 'rm -f -- "$work/test.img"' EXIT
flags=(-arch "$target_arch" -g -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1
       -I"$root/build/libntfs-universal" -I"$root/ntfs-3g/include"
       -I"$root/ntfs3g/bridge")
if [[ "${NFSK_SANITIZE:-}" == address ]]; then flags+=(-fsanitize=address -fno-omit-frame-pointer); fi
xcrun clang "${flags[@]}" -fobjc-arc -fmodules -c \
    "$root/ntfs3g/bridge/ntfs_device_fskit.m" -o "$work/backend.o"
xcrun clang "${flags[@]}" "$root/tests/test_mft_allocation.c" \
    "$root/ntfs3g/bridge/ntfs_fskit.c" "$work/backend.o" \
    "$root/build/libntfs-universal/libntfs-3g.a" \
    -framework FSKit -framework Foundation -o "$work/mft-allocation"
cp "$fixture" "$work/test.img"
printf 'Results: %s/results.log\n' "$work"
"$work/mft-allocation" "$work/test.img" 2>&1 | tee "$work/results.log"
