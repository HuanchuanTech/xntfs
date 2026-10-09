#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Usage: bash tests/run_feature_regressions.sh clean-NTFS-image [arch]}"
target_arch="${2:-$(uname -m)}"
[[ -f "$fixture" ]] || { printf 'Expected a regular image file\n' >&2; exit 1; }
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/feature-regressions.XXXXXX")"
trap 'rm -f -- "$work/test.img"' EXIT
flags=(-arch "$target_arch" -mmacosx-version-min=15.4 -g -Wall -Wextra -DHAVE_CONFIG_H=1
       -I"$root/build/libntfs-universal" -I"$root/ntfs-3g/include" -I"$root/ntfs3g/bridge")
if [[ "${NFSK_SANITIZE:-}" == address ]]; then flags+=(-fsanitize=address -fno-omit-frame-pointer); fi
xcrun clang "${flags[@]}" "$root/tests/test_feature_alignment.c" "$root/ntfs3g/bridge/ntfs_fskit.c" \
    "$root/build/libntfs-universal/libntfs-3g.a" -framework CoreFoundation -o "$work/feature-tests"
cp "$fixture" "$work/test.img"
"$work/feature-tests" "$work/test.img" 2>&1 | tee "$work/results.log"
for nonresident in 0 1; do
    for nth in {1..12}; do
        cp "$fixture" "$work/test.img"
        "$work/feature-tests" "$work/test.img" "$nth" "$nonresident" 2>&1 | tee -a "$work/faults.log"
    done
done
printf 'Test artifacts: %s\n' "$work"
