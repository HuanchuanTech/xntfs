#!/bin/bash
# User-run compatibility operation, never executed by the sandboxed app.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

destination='/Library/Filesystems/xntfs-macos15-session.fs'
stage=''
token=''
watchdog=''
command_pid=''
script=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Foundation parses plists; IOKit verifies that the kernel enforces the exact match.
jxa() {
    /usr/bin/osascript -l JavaScript - "$@" 9>&- <<'JXA'
ObjC.import('Foundation');
function require(value, message) { if (!value) throw new Error(message); }
function plist(path) {
    var data = $.NSData.dataWithContentsOfFile(path), error = Ref(), format = Ref();
    require(data && !data.isNil(), 'Cannot read ' + path);
    var result = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 0, format, error);
    require(result && !result.isNil(), 'Invalid plist: ' + path);
    return ObjC.deepUnwrap(result);
}
function integer(value) { return typeof value === 'number' && value > 0 && value <= 9007199254740991 && Math.floor(value) === value; }
function mountState(disk) {
    return disk.Mounted === true || (typeof disk.MountPoint === 'string' && disk.MountPoint.length > 0) ? 'mounted' : 'unmounted';
}
function rows(nodes, result) {
    nodes.forEach(function (node) {
        if (node.IOObjectClass === 'IOMedia') result.push(node);
        rows(node.IORegistryEntryChildren || [], result);
    });
}
function properties(device, id, size, disk, media) {
    require(/^disk[0-9]+(s[0-9]+)*$/.test(device), 'Invalid BSD device.');
    require(integer(id) && integer(size), 'Invalid device identity or size.');
    require(disk.DeviceIdentifier === device && disk.DeviceNode === '/dev/' + device, 'Disk identity changed.');
    require(media.IORegistryEntryID === id && media['BSD Name'] === device && media.Leaf === true,
        'Device disconnected or replaced. Copy a new command from the app.');
    require(media.Size === size && (disk.Size === size || disk.TotalSize === size), 'Device size changed.');
    require(typeof media.Whole === 'boolean' && disk.WholeDisk === media.Whole, 'Whole-disk identity mismatch.');
    require(typeof media.Writable === 'boolean' && disk.WritableMedia === media.Writable, 'Media access mismatch.');
    var point = disk.MountPoint || '';
    require(point !== '/' && point.indexOf('/System/') !== 0, 'Refusing a system volume.');
    return { IORegistryEntryID: id, 'BSD Name': device, Leaf: true,
        Whole: media.Whole, Writable: media.Writable, Size: size };
}
function kernelMatch(table, id) {
    ObjC.import('IOKit');
    var service = $.IOServiceGetMatchingService(0, $.IORegistryEntryIDMatching(id));
    require(service !== 0, 'Device disappeared.');
    function matches(value) {
        var result = Ref();
        require($.IOServiceMatchPropertyTable(service, $(value), result) === 0, 'Kernel match failed.');
        return Number(result[0]) !== 0;
    }
    try {
        require(matches(table), 'The exact media rule does not match.');
        var wrong = Object.assign({}, table, { IORegistryEntryID: id + 1 });
        require(!matches(wrong), 'The kernel did not enforce the connection identity.');
        wrong = Object.assign({}, table, { 'BSD Name': 'disk999999' });
        require(!matches(wrong), 'The kernel did not enforce the BSD name.');
    } finally { $.IOObjectRelease(service); }
}
function ntfs(device) {
    var file = $.NSFileHandle.fileHandleForReadingAtPath('/dev/r' + device);
    require(file && !file.isNil(), 'Cannot read the NTFS boot sector.');
    var header;
    try { header = file.readDataOfLength(512); } finally { file.closeFile; }
    require(Number(header.length) === 512, 'Incomplete boot sector.');
    var oem = $.NSString.alloc.initWithDataEncoding(header.subdataWithRange($.NSMakeRange(3, 8)), $.NSASCIIStringEncoding);
    require(oem && !oem.isNil() && ObjC.unwrap(oem) === 'NTFS    ', 'This device is not NTFS.');
    require(ObjC.unwrap(header.subdataWithRange($.NSMakeRange(510, 2)).base64EncodedStringWithOptions(0)) === 'Vao=',
        'Invalid NTFS boot signature.');
}
function receipt(info) {
    require(info.CFBundleIdentifier === 'com.huanchuan.xntfs.macos15-session', 'Not an xntfs compatibility entry.');
    var r = info.XNTFSSession;
    require(r && r.Schema === 1 && /^[0-9A-F-]{36}$/.test(r.Token) && /^[0-9A-F-]{36}$/.test(r.Boot),
        'Unrecognized cleanup receipt.');
    require(integer(r.PID) && integer(r.Expires), 'Invalid cleanup lifetime.');
    return r;
}
function mounted(text, device, point, access) {
    require(typeof point === 'string' && point.indexOf('/Volumes/') === 0 && !/[\r\n]/.test(point), 'No /Volumes mount point.');
    var prefix = '/dev/' + device + ' on ' + point + ' (';
    var lines = text.split('\n').filter(function (line) { return line.indexOf(prefix) === 0; });
    require(lines.length === 1 && /\)$/.test(lines[0]), 'No matching mount table entry.');
    var flags = lines[0].slice(prefix.length, -1).split(/,\s*/);
    require(flags[0] === 'xntfs', 'The volume did not mount with xntfs. Check extension enablement and registration.');
    require(access !== 'ro' || flags.indexOf('read-only') >= 0, 'Read-only requested but not observed.');
    return lines[0];
}
function run(args) {
    if (args[0] === 'receipt') {
        var r = receipt(plist(args[1]));
        return [r.Token, r.Boot, r.PID, r.Expires].join(' ');
    }
    if (args[0] === 'mounted') {
        var disk = plist(args[1]);
        require(disk.DeviceIdentifier === args[3], 'Mounted device changed.');
        return mounted(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(args[2], $.NSUTF8StringEncoding, null)),
            args[3], disk.MountPoint, args[4]);
    }
    if (args[0] === 'self-test') {
        var disk = { DeviceIdentifier: 'disk6s1', DeviceNode: '/dev/disk6s1', Size: 1024, WholeDisk: false, WritableMedia: true };
        var media = { IORegistryEntryID: 4294968000, 'BSD Name': 'disk6s1', Leaf: true, Whole: false, Writable: true, Size: 1024 };
        var tests = 0;
        properties('disk6s1', 4294968000, 1024, disk, media); tests++;
        require(mountState({ MountPoint: '/Volumes/Test' }) === 'mounted', 'MountPoint-only mount was missed.'); tests++;
        require(mountState({ MountPoint: '' }) === 'unmounted', 'Empty mount point was treated as mounted.'); tests++;
        require(mountState({ Mounted: true }) === 'mounted', 'Mounted flag was missed.'); tests++;
        properties('disk6s1', 4294968000, 1024, Object.assign({}, disk, { WritableMedia: false }), Object.assign({}, media, { Writable: false })); tests++;
        properties('disk6s1', 4294968000, 1024, Object.assign({}, disk, { WholeDisk: true }), Object.assign({}, media, { Whole: true })); tests++;
        function rejects(fn) { var rejected = false; try { fn(); } catch (_) { rejected = true; } require(rejected, 'Expected rejection.'); tests++; }
        ['disk6s1;id', '../disk6s1', 'rdisk6s1', '/dev/disk6s1'].forEach(function (name) {
            rejects(function () { properties(name, 4294968000, 1024, disk, media); });
        });
        [0, 4294968001, 9007199254740992].forEach(function (id) {
            rejects(function () { properties('disk6s1', id, 1024, disk, media); });
        });
        [{ Leaf: false }, { Size: 2048 }, { Writable: false }, { Whole: true }, { 'BSD Name': 'disk7s1' }].forEach(function (change) {
            rejects(function () { properties('disk6s1', 4294968000, 1024, disk, Object.assign({}, media, change)); });
        });
        rejects(function () { properties('disk6s1', 4294968000, 1024, Object.assign({}, disk, { MountPoint: '/' }), media); });
        var line = '/dev/disk6s1 on /Volumes/Test (xntfs, local, read-only, fskit)';
        mounted(line, 'disk6s1', '/Volumes/Test', 'ro'); tests++;
        rejects(function () { mounted(line.replace('xntfs', 'ntfs'), 'disk6s1', '/Volumes/Test', 'auto'); });
        rejects(function () { mounted(line.replace('read-only', 'noowners'), 'disk6s1', '/Volumes/Test', 'ro'); });
        rejects(function () { mounted(line, 'disk7s1', '/Volumes/Test', 'auto'); });
        rejects(function () { receipt({ CFBundleIdentifier: 'someone.else' }); });
        return 'PASS: ' + tests + ' compatibility safety checks.';
    }
    require(args[0] === 'validate' || args[0] === 'create', 'Unknown validator operation.');
    var device = args[1], id = Number(args[2]), size = Number(args[3]);
    var disk = plist(args[4]), all = [];
    rows(plist(args[5]), all);
    var matches = all.filter(function (row) { return row['BSD Name'] === device; });
    require(matches.length > 0 && matches.every(function (row) { return row.IORegistryEntryID === id; }), 'Ambiguous device identity.');
    var table = properties(device, id, size, disk, matches[0]);
    kernelMatch(table, id);
    ntfs(device);
    if (args[0] === 'validate') return mountState(disk);
    var extension = plist(args[6] + '/Contents/Extensions/ntfs3g.appex/Contents/Info.plist');
    var attrs = extension.EXAppExtensionAttributes || {};
    require(extension.CFBundleIdentifier === 'com.huanchuan.xntfs.ntfs3g' && attrs.FSShortName === 'xntfs' &&
        attrs.FSSupportsBlockResources === true && attrs.FSPersonalities && attrs.FSPersonalities.NTFS,
        'This app does not contain the expected xntfs block-device extension.');
    var result = {
        CFBundleIdentifier: 'com.huanchuan.xntfs.macos15-session', CFBundleName: 'xntfs_fskit',
        CFBundleInfoDictionaryVersion: '6.0', CFBundlePackageType: 'fs  ', CFBundleVersion: '1',
        FSIsFSModule: true, FSBundleID: 'com.huanchuan.xntfs.ntfs3g', FSImplementation: ['UserFS'],
        FSPersonalities: { NTFS: { FSName: 'NTFS (NTFS-3G)', FSSubType: 0, FSfileObjectsAreCaseSensitive: false } },
        FSMediaTypes: { SelectedVolume: { FSMediaProperties: table, FSProbeOrder: -10000, autodiskmount: false } },
        XNTFSSession: { Schema: 1, Token: args[7], Boot: args[8], PID: Number(args[9]), Expires: Number(args[10]) }
    };
    receipt(result);
    var error = Ref();
    var data = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError($(result), $.NSPropertyListXMLFormat_v1_0, 0, error);
    require(data && !data.isNil() && data.writeToFileAtomically(args[11], true), 'Cannot write temporary descriptor.');
}
JXA
}

bounded() {
    local limit="$1" status=0 i=0
    shift
    "$@" 9>&- & command_pid=$!
    while kill -0 "$command_pid" 2>/dev/null; do
        if [ "$i" -ge "$limit" ]; then
            kill -TERM "$command_pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$command_pid" 2>/dev/null || true
            wait "$command_pid" 2>/dev/null || true
            command_pid=''
            printf 'Timed out. A Disk Arbitration request may still finish; re-check the app before retrying.\n' >&2
            return 124
        fi
        sleep 1
        i=$((i + 1))
    done
    wait "$command_pid" || status=$?
    command_pid=''
    return "$status"
}

# Only a root-owned symlink into root's boot-cleaned temporary directory is ours.
read_entry() {
    [ -L "$destination" ] || { [ ! -e "$destination" ] && return 1; fail 'An unrelated object occupies the routing path; not removing it.'; }
    [ "$(/usr/bin/stat -f '%u' "$destination")" = 0 ] || fail 'Routing link is not owned by root.'
    local target
    target=$(/usr/bin/readlink "$destination")
    [[ "$target" =~ ^$root_temp/xntfs-macos15\.[A-Za-z0-9]+/route\.fs$ ]] || fail 'Unrecognized routing link target.'
    entry_stage=${target%/route.fs}
    [ ! -L "$entry_stage" ] && [ ! -L "$target" ] || fail 'Unexpected symlink in the temporary bundle.'
    if [ ! -e "$entry_stage" ]; then entry_receipt=''; return 0; fi
    [ "$(/usr/bin/stat -f '%u:%Lp' "$entry_stage")" = '0:700' ] || fail 'Temporary directory ownership or permissions changed.'
    [ ! -L "$target/Contents" ] && [ ! -L "$target/Contents/Info.plist" ] || fail 'Unexpected symlink in the temporary descriptor.'
    entry_receipt=$(jxa receipt "$target/Contents/Info.plist") || fail 'Cannot validate the existing entry; not deleting it.'
}

remove_own_entry() {
    if [ -L "$destination" ] && [ "$(/usr/bin/readlink "$destination")" = "$stage/route.fs" ]; then
        local actual
        actual=$(jxa receipt "$stage/route.fs/Contents/Info.plist") || return 1
        [ "${actual%% *}" = "$token" ] || return 1
        /bin/rm "$destination" || return 1
    fi
}

remove_stage() {
    [ -n "$stage" ] && [ -d "$stage" ] && [ ! -L "$stage" ] || return 0
    # Fixed filenames only; do not recursively delete a supplied directory.
    /bin/rm -f "$stage/route.fs/Contents/Info.plist" "$stage/disk.plist" "$stage/media.plist" "$stage/mounts.txt" "$stage/state.txt"
    /bin/rmdir "$stage/route.fs/Contents" "$stage/route.fs" "$stage" 2>/dev/null || true
}

cleanup_inactive() {
    local entry_stage='' entry_receipt='' old_token old_boot old_pid old_expiry
    if ! read_entry; then return 0; fi
    if [ -z "$entry_receipt" ]; then
        /bin/rm "$destination"
        printf 'Removed a dangling compatibility link.\n'
        return
    fi
    read -r old_token old_boot old_pid old_expiry <<< "$entry_receipt"
    if [ "$old_boot" = "$boot" ] && [ "$(date +%s)" -lt "$old_expiry" ] && kill -0 "$old_pid" 2>/dev/null; then
        fail 'Another compatibility operation is still active. Wait for it to finish.'
    fi
    stage="$entry_stage" token="$old_token"
    remove_own_entry || fail 'Could not remove the inactive routing entry.'
    remove_stage
    stage='' token=''
    printf 'Removed an inactive compatibility entry. Mounted volumes were not changed.\n'
}

finish() {
    local status=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ -n "$command_pid" ]; then
        kill -TERM "$command_pid" 2>/dev/null
        sleep 1
        kill -KILL "$command_pid" 2>/dev/null
        wait "$command_pid" 2>/dev/null
    fi
    if [ -n "$stage" ]; then
        if remove_own_entry; then
            # Remove the entry BEFORE stopping the watchdog, including on success.
            if [ -n "$watchdog" ]; then kill -TERM "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null; fi
            remove_stage
            printf 'Temporary routing entry removed. No permanent mount rule was installed.\n'
        else
            printf 'CLEANUP FAILED. Run the Cleanup command in the app before retrying.\n' >&2
            status=1
        fi
    fi
    exit "$status"
}

start_watchdog() {
    local parent=$$
    (
        trap - EXIT INT TERM
        trap '' HUP
        while kill -0 "$parent" 2>/dev/null && [ "$(date +%s)" -lt "$expires" ]; do sleep 1 9>&-; done
        if remove_own_entry; then remove_stage; fi
    ) </dev/null >/dev/null 2>&1 &
    watchdog=$!
}

acquire_operation_lock() {
    local file="$root_temp/xntfs-macos15.lock"
    [ ! -L "$file" ] || fail 'Unexpected symlink at the operation lock.'
    if [ -e "$file" ]; then
        [ -f "$file" ] && [ "$(/usr/bin/stat -f '%u' "$file")" = "$EUID" ] || fail 'Unexpected operation lock owner or type.'
    fi
    exec 9>>"$file"
    # The controller and watchdog retain this descriptor; exit releases the lock.
    /usr/bin/lockf -s -t 0 9 || fail 'Another mount or cleanup is active. Wait for it to finish.'
}

# Tests source the same cleanup/watchdog functions without entering the privileged flow.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return; fi

if [ "${1:-}" = '--self-test' ]; then jxa self-test; exit; fi
if [ "${1:-}" != '--authorized' ]; then
    [ "$EUID" -ne 0 ] || fail 'Start this command as your logged-in user, not with sudo.'
    case "${1:-}" in
        mount) [ "$#" -eq 7 ] || fail 'Invalid mount arguments.' ;;
        cleanup) [ "$#" -eq 1 ] || fail 'Invalid cleanup arguments.' ;;
        *) fail 'Usage: macos15-mount.sh mount BSD ID SIZE BOOT_UUID ro|auto APP_PATH, or cleanup.' ;;
    esac
    printf '%s\n' 'xntfs macOS 15 compatibility operation (Terminal only).' \
        'Mount: normally unmount ONLY the selected volume, then mount it with xntfs under /Volumes.' \
        'Temporarily adds /Library/Filesystems/xntfs-macos15-session.fs; removes it afterwards.' \
        'Cleanup: removes only an inactive entry. No enable settings or startup items are changed.'
    printf 'Requested operation:'; printf ' %q' "$@"; printf '\n'
    printf 'Continue? Type yes: '
    read -r answer </dev/tty || fail 'Run this command in an interactive Terminal.'
    [ "$answer" = yes ] || { printf 'Cancelled. Nothing changed.\n'; exit 0; }
    exec /usr/bin/sudo /bin/bash "$script" --authorized "$(/usr/bin/id -u)" "$@"
fi

[ "$EUID" -eq 0 ] && [ "$#" -ge 3 ] || fail 'Administrator authorization is required.'
owner="$2"
[[ "$owner" =~ ^[0-9]+$ ]] && [ "$owner" -gt 0 ] && [ "${SUDO_UID:-}" = "$owner" ] || fail 'Invalid originating user.'
[ "$(/usr/bin/stat -f '%u' /dev/console)" = "$owner" ] || fail 'Run this from the currently logged-in desktop user.'
shift 2
boot=$(/usr/sbin/sysctl -n kern.bootsessionuuid)
root_temp=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)
root_temp=$(cd "$root_temp" && pwd -P)
[[ "$root_temp" =~ ^/private/var/folders/[A-Za-z0-9_]+/[A-Za-z0-9_]+/T$ ]] || fail 'Unexpected root temporary directory.'
[ "$(/usr/bin/stat -f '%u:%Lp' "$root_temp")" = '0:700' ] || fail 'Root temporary directory ownership or permissions are unsafe.'
acquire_operation_lock
case "$1" in
    cleanup) [ "$#" -eq 1 ] || fail 'Invalid cleanup arguments.'; cleanup_inactive; printf 'Cleanup complete.\n'; exit ;;
    mount) [ "$#" -eq 7 ] || fail 'Invalid mount arguments.' ;;
    *) fail 'Unknown operation.' ;;
esac
[[ "$(/usr/bin/sw_vers -productVersion)" = 15.* ]] || fail 'This workaround is only for macOS 15.'
device="$2" entry_id="$3" size="$4" expected_boot="$5" access="$6" app="$7"
[[ "$device" =~ ^disk[0-9]+(s[0-9]+)*$ ]] || fail 'Invalid BSD device.'
[[ "$entry_id" =~ ^[0-9]+$ ]] && [[ "$size" =~ ^[0-9]+$ ]] || fail 'Invalid connection identity.'
[ "$expected_boot" = "$boot" ] || fail 'This command is from a previous boot. Copy a new command from the app.'
[ "$access" = ro ] || [ "$access" = auto ] || fail 'Invalid access mode.'
[[ "$app" = /*.app ]] && [ -d "$app" ] || fail 'The original app bundle is no longer at this path.'
[ -d /Library/Filesystems ] && [ ! -L /Library/Filesystems ] || fail 'Unexpected filesystem directory.'
cleanup_inactive

stage=$(/usr/bin/mktemp -d "$root_temp/xntfs-macos15.XXXXXX")
token=$(/usr/bin/uuidgen)
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
/bin/mkdir -p "$stage/route.fs/Contents"
expires=$(( $(date +%s) + 120 ))

snapshot() {
    [ "$(/usr/sbin/sysctl -n kern.bootsessionuuid)" = "$expected_boot" ] || fail 'Boot identity changed.'
    bounded 10 /usr/sbin/diskutil info -plist "$device" > "$stage/disk.plist"
    bounded 10 /usr/sbin/ioreg -a -r -c IOMedia -l > "$stage/media.plist"
    bounded 15 jxa validate "$device" "$entry_id" "$size" "$stage/disk.plist" "$stage/media.plist" > "$stage/state.txt"
    read -r mount_state < "$stage/state.txt"
}
as_user() { /usr/bin/sudo -H -u "#$owner" "$@"; }
snapshot
bounded 15 jxa create "$device" "$entry_id" "$size" "$stage/disk.plist" "$stage/media.plist" \
    "$app" "$token" "$boot" "$$" "$expires" "$stage/route.fs/Contents/Info.plist"
/bin/chmod 0755 "$stage/route.fs" "$stage/route.fs/Contents"
/bin/chmod 0644 "$stage/route.fs/Contents/Info.plist"

if [ "$mount_state" = mounted ]; then
    printf 'Normally unmounting %s. A busy volume will not be forced.\n' "$device"
    bounded 30 as_user /usr/sbin/diskutil unmount "$device" || fail 'Normal unmount failed. Close files and try again.'
fi
snapshot
[ "$mount_state" = unmounted ] || fail 'Another process mounted the volume; refusing to replace it.'
[ "$(date +%s)" -lt "$expires" ] || fail 'Preflight expired. Copy and run the command again.'

# A bounded, user-consented watchdog survives loss of the parent Terminal process.
# The actual plist is in root's boot-cleaned T directory, not a persistent .fs bundle.
start_watchdog

# link(2) refuses an existing entry; no overwrite or broad NTFS matching.
/bin/ln -s "$stage/route.fs" "$destination" || fail 'Another operation installed a routing entry.'
printf 'Temporary route installed for %s, IOMedia %s only.\n' "$device" "$entry_id"
snapshot
[ "$mount_state" = unmounted ] || fail 'The volume was mounted concurrently; not remounting it.'
if [ "$access" = ro ]; then
    bounded 45 as_user /usr/sbin/diskutil mount readOnly "$device" || fail 'Mount failed. Check ntfs3g in System Settings.'
else
    bounded 45 as_user /usr/sbin/diskutil mount "$device" || fail 'Mount failed. Check ntfs3g in System Settings.'
fi
snapshot
/sbin/mount > "$stage/mounts.txt"
if ! jxa mounted "$stage/disk.plist" "$stage/mounts.txt" "$device" "$access"; then
    if [ "$access" = ro ]; then
        # Identity was revalidated by snapshot; never leave an unexpected RW mount silently.
        bounded 30 as_user /usr/sbin/diskutil unmount "$device" || printf 'Could not unmount. Stop using this volume and check its access in the app.\n' >&2
    fi
    fail 'Mount verification failed. Re-check the app; no successful xntfs mount is claimed.'
fi
printf 'Verified xntfs mount. Returning to the app will refresh the device status.\n'
