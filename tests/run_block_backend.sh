#!/bin/bash
# Memory resource and a tiny ordinary file; never opens a device or mounts an image.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
mode="${1:-test}"
source_dir="${2:-$root/ntfs3g/bridge}"
target_arch="${3:-$(uname -m)}"
case "$mode" in test|benchmark|build) ;; *) printf 'Expected test, benchmark or build\n' >&2; exit 2 ;; esac
mkdir -p "$root/_tmp"
if [[ -n "${NFSK_BLOCK_OUTPUT:-}" ]]; then
    work="$NFSK_BLOCK_OUTPUT"
    mkdir "$work"
else
    work="$(mktemp -d "$root/_tmp/block-backend.XXXXXX")"
fi
sdk="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
flags=(-O2 -g -arch "$target_arch" -mmacosx-version-min=15.4 -isysroot "$sdk"
       -fobjc-arc -I"$source_dir")
case "${NFSK_SANITIZE:-}" in
    thread|address) flags+=(-fsanitize="$NFSK_SANITIZE" -fno-omit-frame-pointer) ;;
    "") ;;
    *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
backend_flags=("${flags[@]}")
case "${NFSK_BLOCK_ALLOCATION_HOOKS:-1}" in
    1) backend_flags+=(-Dmalloc=nfsk_test_malloc -Drealloc=nfsk_test_realloc -Dfree=nfsk_test_free) ;;
    0) ;; # Timing builds omit test allocator hooks.
    *) printf 'NFSK_BLOCK_ALLOCATION_HOOKS must be 0 or 1\n' >&2; exit 2 ;;
esac
env -u SDKROOT xcrun clang "${backend_flags[@]}" \
    -c "$source_dir/ntfs_device_fskit.m" -o "$work/backend.o"
env -u SDKROOT xcrun clang "${flags[@]}" "${NFSK_BLOCK_HARNESS:-$root/tests/test_block_backend.m}" \
    "$work/backend.o" -framework Foundation -framework FSKit -o "$work/test-backend"
if [[ "$mode" != build ]]; then
    "$work/test-backend" "$mode" 2>&1 | tee "$work/results.log"
fi
printf 'Test artifacts: %s\n' "$work"
