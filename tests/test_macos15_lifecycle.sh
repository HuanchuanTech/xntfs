#!/bin/bash
# No sudo, real disks, or writes to /Library. Exercises the shipped cleanup code.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
source "$root/xntfs/Resources/macos15-mount.sh"
work=$(mktemp -d "$root/_tmp/compat-lifecycle.XXXXXX")
destination="$work/session.fs"
controller=''
trap 'if [ -n "$controller" ]; then kill "$controller" 2>/dev/null || true; wait "$controller" 2>/dev/null || true; fi; rm -rf "$work"' EXIT

make_stage() {
    stage=$(mktemp -d "$work/session.XXXXXX")
    token=$(uuidgen)
    mkdir -p "$stage/route.fs/Contents"
    /usr/bin/osascript -l JavaScript - "$stage/route.fs/Contents/Info.plist" "$token" <<'JXA'
ObjC.import('Foundation');
function run(a) {
    var info = { CFBundleIdentifier: 'com.huanchuan.xntfs.macos15-session',
        XNTFSSession: { Schema: 1, Token: a[1], Boot: a[1], PID: 1, Expires: 1 } };
    var data = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError($(info), $.NSPropertyListXMLFormat_v1_0, 0, null);
    if (!data.writeToFileAtomically(a[0], true)) throw new Error('Cannot create fixture.');
}
JXA
    ln -s "$stage/route.fs" "$destination"
}

make_stage
remove_own_entry
[ ! -L "$destination" ]
remove_stage
[ ! -d "$stage" ]
printf 'PASS: normal cleanup removes only the owned link and known files.\n'

make_stage
saved_token="$token"
token=$(uuidgen)
if remove_own_entry; then printf 'FAIL: wrong token accepted.\n'; exit 1; fi
[ -L "$destination" ]
token="$saved_token"
remove_own_entry
remove_stage
printf 'PASS: receipt mismatch is not deleted.\n'

make_stage
rm "$destination"
ln -s "$work/unrelated.fs" "$destination"
remove_own_entry
[ "$(readlink "$destination")" = "$work/unrelated.fs" ]
remove_stage
rm "$destination"
printf 'PASS: unrelated routing link is preserved.\n'

start_controller() {
    /bin/bash -c '
        source "$1"
        destination="$2" stage="$3" token="$4" expires="$5"
        root_temp=$(dirname "$stage")
        acquire_operation_lock
        start_watchdog
        printf "%s\n" "$watchdog" > "$6"
        exec /bin/sleep 30
    ' controller "$script" "$destination" "$stage" "$token" "$1" "$work/ready" &
    controller=$!
    for i in {1..30}; do [ -f "$work/ready" ] && return; sleep 0.1; done
    printf 'FAIL: controller did not start.\n'; exit 1
}
await_cleanup() {
    for i in {1..50}; do [ ! -L "$destination" ] && [ ! -d "$stage" ] && return; sleep 0.1; done
    printf 'FAIL: watchdog did not clean up.\n'; exit 1
}
make_stage
start_controller "$(( $(date +%s) + 20 ))"
if /bin/bash -c 'source "$1"; root_temp="$2"; acquire_operation_lock' other "$script" "$work"; then
    printf 'FAIL: concurrent operation acquired the lock.\n'; exit 1
fi
printf 'PASS: concurrent mount/cleanup is refused while the controller is active.\n'
kill -KILL "$controller"
wait "$controller" 2>/dev/null || true
controller=''
await_cleanup
rm "$work/ready"
/bin/bash -c 'source "$1"; root_temp="$2"; acquire_operation_lock' other "$script" "$work"
printf 'PASS: actual controller SIGKILL triggers watchdog cleanup.\n'

make_stage
start_controller "$(( $(date +%s) + 2 ))"
await_cleanup
kill -0 "$controller"
kill -TERM "$controller"
wait "$controller" 2>/dev/null || true
controller=''
printf 'PASS: deadline cleanup runs while the controller is still alive.\n'
