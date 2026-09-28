#!/bin/bash
# Live test: a disposable, unique-serial MBR image; never a physical drive.
# Run via sudo from the desktop user. Does not install apps or change preferences.
set -euo pipefail
[ "$#" = 5 ] || { printf 'Usage: sudo bash %s FIXTURE APP VERIFIER OUTPUT X86_EXTENSION_UUID\n' "$0"; exit 2; }
[ "$EUID" = 0 ] && [ "${SUDO_UID:-0}" -gt 0 ]
[[ "$(/usr/bin/sw_vers -productVersion)" = 15.* ]]
[ "$(/usr/bin/uname -m)" = x86_64 ]
owner=$SUDO_UID
[ "$owner" = "$(/usr/bin/stat -f %u /dev/console)" ]
fixture=$1 app=$2 verifier=$3 output=$4 expected_uuid=$5
script="$app/Contents/Resources/macos15-mount.sh"
route=/Library/Filesystems/xntfs-macos15-session.fs
[ -f "$fixture" ] && [ -f "$script" ] && [ -x "$verifier" ]
[ ! -e "$output" ] && [ ! -L "$output" ]
[ ! -e "$route" ] && [ ! -L "$route" ]
/bin/mkdir -p "$output"
/usr/sbin/chown "$owner":staff "$output"
exec > >(/usr/bin/tee "$output/report.txt") 2>&1
as_user() { /usr/bin/sudo -H -u "#$owner" "$@"; }
copy="$output/test-copy.img"
whole='' device='' attached=0
hash() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
original_hash=$(hash "$fixture")
printf '%s\n' "$original_hash" > "$output/fixture-before.sha256"
/sbin/mount > "$output/mounts-before.txt"
/usr/bin/pgrep -x ntfs3g > "$output/old-pids.txt" || true
finish() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    /bin/bash "$script" --authorized "$owner" cleanup || status=1
    if [ -n "$whole" ]; then
        if as_user /usr/bin/hdiutil detach "$whole"; then whole=''; attached=0; else status=1; fi
    fi
    if [ "$attached" = 0 ]; then
        /bin/rm -f "$copy"
    else
        printf 'Copy still attached or its device was not identified; preserving %s\n' "$copy"
        status=1
    fi
    hash "$fixture" > "$output/fixture-after.sha256"
    /usr/bin/cmp "$output/fixture-before.sha256" "$output/fixture-after.sha256" || status=1
    /sbin/mount > "$output/mounts-after.txt"
    /usr/bin/cmp "$output/mounts-before.txt" "$output/mounts-after.txt" || status=1
    [ ! -e "$route" ] && [ ! -L "$route" ] || status=1
    printf 'TEST EXIT STATUS: %s\n' "$status"
    printf '%s\n' "$status" > "$output/exit.txt"
    /usr/sbin/chown -R "$owner":staff "$output"
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
/bin/cp -X "$fixture" "$copy"
/usr/sbin/chown "$owner":staff "$copy"

attach() {
    # Preserve the copy on parsing errors; a successful attach may already own it.
    attached=1
    as_user /usr/bin/hdiutil attach "$1" -plist "$copy" > "$output/attach.plist"
    read -r whole device <<< "$("$verifier" attach "$output/attach.plist")"
    [[ "$whole" =~ ^/dev/disk[0-9]+$ ]] && [ "$device" = "${whole#/dev/}s1" ]
    /usr/sbin/ioreg -a -r -c IOMedia -l > "$output/media.plist"
    read -r entry size <<< "$("$verifier" media "$output/media.plist" "$device")"
    boot=$(/usr/sbin/sysctl -n kern.bootsessionuuid)
}
line() { /sbin/mount | /usr/bin/grep -F "/dev/$device on "; }
no_route() { [ ! -e "$route" ] && [ ! -L "$route" ]; }
invoke() {
    /bin/bash "$script" --authorized "$owner" mount "$device" "$entry" "$size" "$boot" "$1" "$app"
    no_route
}
check() {
    /usr/sbin/diskutil info -plist "$device" > "$output/info-$1.plist"
    local point
    point=$("$verifier" point "$output/info-$1.plist")
    as_user "$verifier" check "$1" "$point" "$device"
    line
}
verify_new_binary() {
    local pid matched=0
    for pid in $(/usr/bin/pgrep -x ntfs3g); do
        /usr/bin/grep -qx "$pid" "$output/old-pids.txt" && continue
        if /usr/bin/sample "$pid" 1 1 -file "$output/extension-$pid.sample.txt"; then
            if /usr/bin/grep -iF "$expected_uuid" "$output/extension-$pid.sample.txt"; then matched=1; fi
        fi
    done
    [ "$matched" = 1 ] || { printf 'FAIL: no newly launched extension with the expected Mach-O UUID.\n'; return 1; }
    printf 'PASS: running extension matches the new x86_64 build UUID.\n'
}

printf 'OS: '; /usr/bin/sw_vers -productVersion
printf 'Architecture: '; /usr/bin/uname -m
printf 'Expected new extension UUID: %s\n' "$expected_uuid"
/usr/bin/codesign --verify --deep --strict "$app"
/bin/bash "$script" --self-test
attach -readwrite
line | /usr/bin/grep -F '(ntfs,'
if /bin/bash "$script" --authorized "$owner" mount "$device" "$((entry+1))" "$size" "$boot" auto "$app"; then
    printf 'FAIL: stale connection accepted.\n'; exit 1
fi
no_route
line | /usr/bin/grep -F '(ntfs,'
printf 'PASS: stale connection refused without replacing the existing mount.\n'

before_ro=$(hash "$copy")
invoke ro
check ro
verify_new_binary
as_user /usr/sbin/diskutil unmount "$device"
[ "$(hash "$copy")" = "$before_ro" ]
printf 'PASS: explicit read-only mount left the complete image unchanged.\n'

# The supplied fixture is an image. The installed app must have imageReadOnly=false
# for this case; do not silently rewrite the user's setting to make the test pass.
invoke auto
check rw
as_user /usr/sbin/diskutil unmount "$device"
before_remount=$(hash "$copy")
invoke ro
check remount-ro
as_user /usr/sbin/diskutil unmount "$device"
[ "$(hash "$copy")" = "$before_remount" ]
printf 'PASS: writes persist after unmount; read-only remount does not modify the image.\n'
as_user /usr/bin/hdiutil detach "$whole"; whole=''; attached=0

before_media=$(hash "$copy")
attach -readonly
line | /usr/bin/grep -F '(ntfs,'
printf 'PASS: subsequent attachment without the temporary route uses native NTFS.\n'
invoke auto
check media-ro
as_user /usr/bin/hdiutil detach "$whole"; whole=''; attached=0
[ "$(hash "$copy")" = "$before_media" ]
printf 'PASS: read-only media stays read-only despite the writable image default.\n'
printf 'ALL UNIFIED LOAD/ACTIVATE CHECKS PASSED.\n'
