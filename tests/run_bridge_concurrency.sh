#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Usage: bash tests/run_bridge_concurrency.sh clean-NTFS-image [arch]}"
target_arch="${2:-$(uname -m)}"
libntfs="${NFSK_LIBNTFS_DIR:-$root/build/libntfs-universal}"
[[ -f "$fixture" ]] || { printf 'Expected a regular image file\n' >&2; exit 1; }
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/bridge-concurrency.XXXXXX")"
trap 'rm -f -- "$work/first.img" "$work/second.img"' EXIT
flags=(-g -arch "$target_arch" -mmacosx-version-min=15.4 -DHAVE_CONFIG_H=1
    -I"$libntfs" -I"$root/ntfs-3g/include" -I"$root/ntfs3g/bridge")
case "${NFSK_SANITIZE:-}" in
    thread|address) flags+=(-fsanitize="$NFSK_SANITIZE" -fno-omit-frame-pointer) ;;
    "") ;;
    *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
xcrun clang "${flags[@]}" "$root/tests/test_bridge_concurrency.c" "$root/ntfs3g/bridge/ntfs_fskit.c" \
    "$libntfs/libntfs-3g.a" -framework CoreFoundation -o "$work/test-concurrency"
cp "$fixture" "$work/first.img"
cp "$fixture" "$work/second.img"
"$work/test-concurrency" "$work/first.img" "$work/second.img" 2>&1 | tee "$work/results.log"
printf 'Test artifacts: %s\n' "$work"
