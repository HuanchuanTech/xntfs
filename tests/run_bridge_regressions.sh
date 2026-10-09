#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Usage: bash tests/run_bridge_regressions.sh clean-NTFS-image [arch]}"
target_arch="${2:-$(uname -m)}"
[[ -f "$fixture" ]] || { printf 'Expected a regular image file\n' >&2; exit 1; }
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/bridge-regressions.XXXXXX")"
trap 'rm -f -- "$work/test.img"' EXIT
flags=(-arch "$target_arch" -g -DHAVE_CONFIG_H=1
       -I"$root/build/libntfs-universal" -I"$root/ntfs-3g/include"
       -I"$root/ntfs3g/bridge")
if [[ "${NFSK_SANITIZE:-}" == address ]]; then flags+=(-fsanitize=address -fno-omit-frame-pointer); fi
xcrun clang "${flags[@]}" -Dntfs_inode_close=nfsk_test_inode_close \
    -Dntfs_inode_real_close=nfsk_test_inode_real_close \
    -Dntfs_inode_sync=nfsk_test_inode_sync \
    -c "$root/ntfs3g/bridge/ntfs_fskit.c" -o "$work/bridge.o"
xcrun clang "${flags[@]}" "$root/tests/test_bridge_regressions.c" "$work/bridge.o" \
    "$root/build/libntfs-universal/libntfs-3g.a" -framework CoreFoundation -o "$work/regressions"
cp "$fixture" "$work/test.img"
"$work/regressions" "$work/test.img" 2>&1 | tee "$work/results.log"
xcrun clang "${flags[@]}" "$root/tests/test_bridge.c" "$root/ntfs3g/bridge/ntfs_fskit.c" \
    "$root/build/libntfs-universal/libntfs-3g.a" -framework CoreFoundation -o "$work/existing-tests"
cp "$fixture" "$work/test.img"
"$work/existing-tests" "$work/test.img" 2>&1 | tee "$work/existing-results.log"
xcrun clang "${flags[@]}" -Dntfs_index_lookup=nfsk_test_index_lookup \
    -Dntfs_index_next=nfsk_test_index_next \
    -c "$root/ntfs3g/bridge/ntfs_fskit.c" -o "$work/enumeration-bridge.o"
xcrun clang "${flags[@]}" "$root/tests/test_directory_enumeration.c" "$work/enumeration-bridge.o" \
    "$root/build/libntfs-universal/libntfs-3g.a" -framework CoreFoundation -o "$work/enumeration-tests"
cp "$fixture" "$work/test.img"
"$work/enumeration-tests" "$work/test.img" 2>&1 | tee "$work/enumeration-results.log"
xcrun clang "${flags[@]}" -Dntfs_attr_pwrite=nfsk_test_attr_pwrite \
    -Dntfs_attr_pread=nfsk_test_attr_pread \
    -c "$root/ntfs3g/bridge/ntfs_fskit.c" -o "$work/xattr-bridge.o"
xcrun clang "${flags[@]}" "$root/tests/test_xattrs.c" "$work/xattr-bridge.o" \
    "$root/build/libntfs-universal/libntfs-3g.a" -framework CoreFoundation -o "$work/xattr-tests"
cp "$fixture" "$work/test.img"
"$work/xattr-tests" "$work/test.img" 2>&1 | tee "$work/xattr-results.log"
