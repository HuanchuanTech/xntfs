#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="${1:?Usage: bash tests/run_bridge_regressions.sh clean-NTFS-image [arch]}"
target_arch="${2:-$(uname -m)}"
library_dir="${NFSK_LIBNTFS_DIR:-$root/build/libntfs-universal}"
bridge_source="${NFSK_BRIDGE_SOURCE:-$root/ntfs3g/bridge}"
# Select before creating artifacts or compiling. Preserve the full default and
# canonical order; repeated group names must not repeat builds or test images.
requested="${NFSK_BRIDGE_SUITES-all}"
[[ "$requested" != *$'\n'* ]] || { printf 'Expected a single list of bridge suites\n' >&2; exit 2; }
read -r -a requested_suites <<< "$requested"
[[ ${#requested_suites[@]} -gt 0 ]] || { printf 'No bridge suites selected\n' >&2; exit 2; }
selected=" "
for suite in "${requested_suites[@]}"; do
    case "$suite" in
        all) selected+="core basic directory xattr symlink " ;;
        core|basic|directory|xattr|symlink) selected+="$suite " ;;
        *) printf 'Unknown bridge suite: %s\n' "$suite" >&2; exit 2 ;;
    esac
done
has_suite() { [[ "$selected" == *" $1 "* ]]; }
[[ -f "$fixture" ]] || { printf 'Expected a regular image file\n' >&2; exit 1; }
[[ -f "$library_dir/libntfs-3g.a" && -f "$library_dir/config.h" ]] || exit 1
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/bridge-regressions.XXXXXX")"
trap 'rm -f -- "$work/test.img"' EXIT
for suite in core basic directory xattr symlink; do
    if has_suite "$suite"; then printf '%s\n' "$suite" >> "$work/selected-suites.txt"; fi
done
step() {
    local phase="$1" label="$2"
    shift 2
    python3 "$root/tests/validation_timing.py" --output "$work/timings.jsonl" \
        --phase "$phase" --label "$label" -- "$@"
}
test_sdk="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
flags=(-arch "$target_arch" -g -mmacosx-version-min=15.4 -isysroot "$test_sdk" -DHAVE_CONFIG_H=1
       -I"$library_dir" -I"$root/ntfs-3g/include"
       -I"$bridge_source")
link_flags=(-framework CoreFoundation)
case "${NFSK_BRIDGE_PROFILE:-default}" in
    default) ;;
    o2) flags+=(-O2) ;;
    o3) flags+=(-O3) ;;
    o2-thinlto|o3-thinlto)
        flags+=("-O${NFSK_BRIDGE_PROFILE:1:1}" -flto=thin)
        link_flags+=(-Wl,-mllvm,-threads=2) ;;
    *) printf 'Unsupported bridge profile\n' >&2; exit 2 ;;
esac
case "${NFSK_SANITIZE:-}" in
    address|undefined) flags+=(-fsanitize="$NFSK_SANITIZE" -fno-omit-frame-pointer -fno-sanitize-recover=undefined) ;;
    "") ;;
    *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
if has_suite core; then
    step build core-bridge xcrun clang "${flags[@]}" -Dntfs_inode_close=nfsk_test_inode_close \
        -Dntfs_inode_real_close=nfsk_test_inode_real_close \
        -Dntfs_inode_sync=nfsk_test_inode_sync \
        -Dntfs_interix_types=nfsk_test_interix_types -Dntfs_attr_open=nfsk_test_attr_open \
        -Dntfs_attr_pread=nfsk_test_attr_pread -Dntfs_attr_pwrite=nfsk_test_attr_pwrite \
        -Dntfs_ucstombs=nfsk_test_ucstombs -Dmalloc=nfsk_test_malloc -Dfree=nfsk_test_free \
        -c "$bridge_source/ntfs_fskit.c" -o "$work/bridge.o"
    step build core-reparse xcrun clang "${flags[@]}" -I"$root/ntfs-3g/include/ntfs-3g" \
        -Dntfs_attr_readall=nfsk_test_reparse_readall -Dfree=nfsk_test_reparse_free \
        -c "$root/ntfs-3g/libntfs-3g/reparse.c" -o "$work/reparse.o"
    step build core-link xcrun clang "${flags[@]}" "${link_flags[@]}" "$root/tests/test_bridge_regressions.c" "$work/bridge.o" "$work/reparse.o" \
        "$library_dir/libntfs-3g.a" -o "$work/regressions"
    cp "$fixture" "$work/test.img"
    step test core "$work/regressions" "$work/test.img" 2>&1 | tee "$work/results.log"
fi
if has_suite basic; then
    step build basic-link xcrun clang "${flags[@]}" "${link_flags[@]}" "$root/tests/test_bridge.c" "$bridge_source/ntfs_fskit.c" \
        "$library_dir/libntfs-3g.a" -o "$work/existing-tests"
    cp "$fixture" "$work/test.img"
    step test basic "$work/existing-tests" "$work/test.img" 2>&1 | tee "$work/existing-results.log"
fi
if has_suite directory; then
    step build directory-bridge xcrun clang "${flags[@]}" -Dntfs_index_lookup=nfsk_test_index_lookup \
        -Dntfs_index_next=nfsk_test_index_next \
        -Dntfs_ucstombs=nfsk_test_ucstombs -Dfree=nfsk_test_free \
        -Dntfs_attr_lookup=nfsk_test_attr_lookup \
        -Dntfs_attr_get_search_ctx=nfsk_test_attr_get_search_ctx \
        -Dntfs_attr_put_search_ctx=nfsk_test_attr_put_search_ctx \
        -Dntfs_inode_open=nfsk_test_inode_open -Dntfs_attr_open=nfsk_test_attr_open \
        -Dntfs_inode_close=nfsk_test_inode_close -Dntfs_inode_real_close=nfsk_test_inode_real_close \
        -c "$bridge_source/ntfs_fskit.c" -o "$work/enumeration-bridge.o"
    step build directory-link xcrun clang "${flags[@]}" "${link_flags[@]}" "$root/tests/test_directory_enumeration.c" "$work/enumeration-bridge.o" \
        "$library_dir/libntfs-3g.a" -o "$work/enumeration-tests"
    cp "$fixture" "$work/test.img"
    step test directory "$work/enumeration-tests" "$work/test.img" 2>&1 | tee "$work/enumeration-results.log"
fi
if has_suite xattr; then
    step build xattr-bridge xcrun clang "${flags[@]}" -Dntfs_attr_pwrite=nfsk_test_attr_pwrite \
        -Dntfs_attr_pread=nfsk_test_attr_pread \
        -Dmalloc=nfsk_test_malloc -Drealloc=nfsk_test_realloc -Dfree=nfsk_test_free \
        -Dntfs_inode_close=nfsk_test_inode_close -Dntfs_inode_real_close=nfsk_test_inode_real_close \
        -c "$bridge_source/ntfs_fskit.c" -o "$work/xattr-bridge.o"
    step build xattr-link xcrun clang "${flags[@]}" "${link_flags[@]}" "$root/tests/test_xattrs.c" "$work/xattr-bridge.o" \
        "$library_dir/libntfs-3g.a" -o "$work/xattr-tests"
    cp "$fixture" "$work/test.img"
    step test xattr "$work/xattr-tests" "$work/test.img" 2>&1 | tee "$work/xattr-results.log"
fi
if has_suite symlink; then
    step build symlink-bridge xcrun clang "${flags[@]}" \
        -Dmalloc=nfsk_test_malloc -Dfree=nfsk_test_free -Dntfs_ucstombs=nfsk_test_ucstombs \
        -Dntfs_attr_open=nfsk_test_attr_open -Dntfs_attr_close=nfsk_test_attr_close \
        -Dntfs_attr_pwrite=nfsk_test_attr_pwrite \
        -Dntfs_inode_close=nfsk_test_inode_close -Dntfs_inode_real_close=nfsk_test_inode_real_close \
        -Dntfs_delete=nfsk_test_delete \
        -c "$bridge_source/ntfs_fskit.c" -o "$work/symlink-bridge.o"
    step build symlink-link xcrun clang "${flags[@]}" "${link_flags[@]}" \
        "$root/tests/test_symlink_targets.c" "$work/symlink-bridge.o" \
        "$library_dir/libntfs-3g.a" -o "$work/symlink-tests"
    for mode in normal faults backend-error backend-zero backend-resident short-write cleanup windows; do
        cp "$fixture" "$work/test.img"
        step test "symlink-$mode" env NFSK_SYMLINK_TEST_MODE="$mode" \
            "$work/symlink-tests" "$work/test.img" 2>&1 | tee "$work/symlink-$mode.log"
    done
fi
printf 'Test artifacts: %s\n' "$work"
