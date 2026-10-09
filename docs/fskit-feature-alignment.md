# FSKit feature alignment

## Scope and invariants

This work aligns the xntfs bridge with the FSKit interfaces for open-file
lifetime, metadata, volume names, preallocation, sparse-region queries and
maintenance. It does not modify the vendored ntfs-3g implementation, enablement
configuration or ownership/ACL policy. Integration testing temporarily replaced
the installed application with the user's permission; restoration is recorded
separately below.

All libntfs calls remain serialized by the existing volume lock. Every new
mutation must reject read-only volumes and reserved NTFS metadata, preserve
unrelated metadata, report writeback errors, and survive a close/remount test.

## Design

| Area | Design | Deliberate boundary |
| --- | --- | --- |
| Open-file lifetime | macOS 15 retains an internal hard link when the last visible name of an open file is removed or overwritten. Final close removes that link. macOS 26+ keeps FSKit's built-in emulation. | Hidden retention links left by an extension crash are preserved for recovery, not blindly deleted on a later mount. |
| Item types | Use the same classification for enumeration and attributes, including Interix special files. | Do not expose unsupported special-file creation as ordinary-file creation. |
| Symbolic links | Create WSL-format NTFS symlinks; preserve relative and absolute POSIX targets, and continue reading Interix symlinks. | Reject targets exceeding the readlink buffer before changing the namespace. Windows-native link path translation remains best effort. |
| Timestamps | Apply creation, modification and access times, including creation-time requests. | NTFS has no native backup-time field. Do not substitute ctime or claim an unsupported time was applied. |
| BSD flags | Map the NTFS hidden attribute to `UF_HIDDEN` and round-trip it. | Unsupported immutable/append/system flags must not be silently accepted. Ownership and ACL mapping remain outside this work. |
| Creation attributes | Apply supported requested attributes before returning the new item; clean up a newly created item if initialization fails. | Synthesized permission bits and ignored ownership remain the existing policy, not a Windows ACL implementation. |
| Volume name | Use `ntfs_volume_rename`, update the FSKit-visible name only after success, and preserve the boot-sector identity. | Reject invalid/oversized names and read-only changes. |
| Preallocation | Reserve storage for ordinary uncompressed files without changing logical EOF or existing data. Report actual allocation. | Reject unsupported contiguous-allocation guarantees and sparse/compressed/encrypted cases rather than pretending to honor them. |
| Sparse seek | On macOS 27, map `SeekRegionHandler` to NTFS runlists and handle EOF/holes/data. | Compressed storage holes are not logical file holes. Older systems retain their existing interfaces. |
| Quick check | Keep `-q`; inspect core metadata, dirty state, hibernation and journal state through a strictly read-only backend. | This is mount preflight, not a full filesystem scan. |
| Repair/full verification | Reject requests the module cannot perform, with a useful task log. | Do not clear dirty bits, reset journals or report a repair that never happened. |

`startCheck` is part of Disk Arbitration's mount path, not merely Disk Utility's
First Aid action. Rejecting a quick check indiscriminately can prevent writable
automatic mounting. A genuinely unsafe volume failing preflight is expected;
automatic read-only fallback is not guaranteed. Direct image mounting is a distinct path and
must not be presented as proof that automatic block-device mounting works.

Sources:

- [FSBlockDeviceResource](https://developer.apple.com/documentation/fskit/fsblockdeviceresource)
- [Disk Arbitration quick-check and repair calls](https://github.com/apple-oss-distributions/DiskArbitration/blob/main/diskarbitrationd/DASupport.m)
- [Disk Arbitration repair failure and read-only fallback](https://github.com/apple-oss-distributions/DiskArbitration/blob/main/diskarbitrationd/DAMount.c)

## Validation (2026-10-09)

Host: macOS 27 (26A428), Xcode 27 SDK. Universal build deployment target: 15.4.
All image writes were confined to disposable copies. No physical disk contents,
enablement plists or livefsd settings were changed. Existing mounts were left
alone during feature tests; the separately authorized agent restart affected
DeviceFS as recorded under environment restoration.

- [x] Standalone C tests on disposable raw image copies: lifetime, metadata,
  rename, allocation, sparse queries, read-only behavior and failure paths.
- [x] arm64, x86_64 under Rosetta, and bridge AddressSanitizer runs.
- [x] Direct Swift FSVolume tests for consumed attributes, API results,
  capability reporting and macOS 27 seek conformance.
- [x] Signed universal application and extension build with deployment target 15.4.
- [x] Check tests prove no image changes and no backend write/sync requests.
- [x] OS-mounted tests with the candidate extension, after explicit authorization.
- [x] Standalone bridge and direct Swift tests on macOS 15.8 x86_64.
- [x] Actual macOS 15 mounted regression executed: 34 of 35 syscall assertions
  passed; immediate post-preallocation allocation reporting still fails.
- [ ] Resolve and retest the macOS 15 open-file allocation-reporting gap,
  reproduced after both preallocation and ordinary writes.
- [ ] Actual macOS 26 mounted validation; no test machine is currently available.

### Bridge and Swift tests

The existing suite passed 37 bridge checks, 41 extended checks, 24 directory
checks and 40 xattr checks. The new suite passed 70 feature checks. Both suites
passed on arm64, x86_64/Rosetta and with the bridge/test harness instrumented by
AddressSanitizer; the prebuilt upstream library is not ASan-instrumented.

Preallocation fault injection ran 24 additional cases, three assertions each.
Eight cases actually injected a write error (five resident-file and three
nonresident-file positions); the remaining cases were non-triggering controls.
Errors reached callers, and remount confirmed unchanged logical EOF and payload.
Successful persistent reservations also survived close/remount with a seven-byte
logical file size.

Direct Swift tests passed seven groups, covering consumed attributes, ignored
mode/ownership, symlinks, volume name, preallocation, seek conformance, read-only
guards, check-option parsing and native open-file retention. The legacy branch
was explicitly selected on the macOS 27 host. This tests that code path, not
macOS 15's actual kernel/FSKit callback behavior. Clang static analysis of the
bridge completed without diagnostics.

Run against a small, clean, raw NTFS image, not a device node:

```sh
bash tests/run_bridge_regressions.sh ntfs-test.img
bash tests/run_feature_regressions.sh ntfs-test.img
bash tests/run_feature_regressions.sh ntfs-test.img x86_64
NFSK_SANITIZE=address bash tests/run_feature_regressions.sh ntfs-test.img
bash tests/run_volume_regressions.sh ntfs-test.img
```

These runners copy the input and delete their disposable image afterward.
Logs from this run are under `_tmp/feature-*-final.log`.

### Mounted macOS 27 results

The system launched the newly built extension from its build-product URL. Its
executable hash matched the candidate copied to `/Applications`; these were not
tests of the original installed binary. Logs and candidate hashes are under
`_tmp/feature-mounted-20261009/`.

- Twenty syscall checks passed: open/unlink and overwrite-rename descriptors,
  creation/modification times, hidden flags, native xattrs, symlinks,
  `F_PREALLOCATE` and `SEEK_DATA`/`SEEK_HOLE`.
- `setattrlist(ATTR_VOL_NAME)` changed the volume label. The name persisted after
  detach/reattach and the volume UUID did not change.
- Reattachment confirmed creation time, xattr data, symlink target, contents and
  a persistent allocation with unchanged seven-byte EOF.
- Both Finder copying and `cp -p` succeeded, with byte-for-byte content checks.
- Disk Arbitration reached `startCheck` with `-q`; clean-volume preflight and
  mounting succeeded. The existing image preference chose read-only for default
  attachment; explicit writable attachment/mount through Disk Arbitration also
  succeeded.
- `/sbin/fsck_fskit -t xntfs -q /dev/diskN` passed on the clean disposable volume.
  Full verification (`-n`) and repair (`-y`) returned `ENOTSUP` with explanatory
  task messages. Whole-image hashes stayed unchanged.
- A synthetic dirty volume failed quick check with `EIO`. Disk Arbitration then
  attempted repair, received `ENOTSUP`, and did not mount it writable.
  `diskutil mount readOnly` also failed in that state. Direct
  `mount -F -t xntfs -o ro,nobrowse` on that test device succeeded, with an
  unchanged whole-image hash. This is not proof of automatic read-only fallback.

Only run `tests/test_mounted_features.c` on a disposable writable xntfs volume.
It creates a unique test directory; its optional second argument changes the
volume label. It does not install or register an extension itself.

### Mounted macOS 15 results

Test environment: macOS 15.8 (24H23), x86_64. The standalone run passed 70 feature
checks, all 24 preallocation fault-injection cases, and the direct Swift volume
tests. The macOS 27 sparse-query interface is not available on this OS. These
standalone results do not substitute for kernel-mounted testing.

The mounted runs used TestFlight 1.0.9 (13), not the previously installed
1.0.5 build. The installed extension's x86_64 Mach-O UUID matched the local
2026-10-09 10:29 Archive: `82AA1B96-C3E3-3F08-BD40-0E2A56A068A7`. Process samples
also verified this UUID and `/Applications/xntfs.app/Contents/Extensions/ntfs3g.appex`
as the runtime source.

- The shipped single-device compatibility command switched a disposable image
  from native `ntfs` to `xntfs` under `/Volumes`. Both explicit read-only and
  preference-driven read-write mounting succeeded.
- The stale IOMedia identity test was rejected without changing the existing
  native mount. Explicit read-only testing preserved the entire image hash.
- Extension logs recorded Disk Arbitration's `startCheck options=["-q"]`
  during these mounts.
- Of 16 general mounted syscall checks, 15 passed: basic open/unlink, overwrite-rename
  descriptor preservation, creation/modification times, hidden flags, native
  xattr creation, symlinks, preallocation's returned byte count, and allocation
  surviving descriptor close.
- Eight macOS 15 lifetime assertions passed: unlink with independent reader and
  writer descriptors, zero link count, continued writes, closing one descriptor
  without invalidating the other, release of allocated clusters after final
  close, shared mmap surviving descriptor close/unlink, writable mmap flushing,
  and removal of the old parent directory while its unlinked child remains open.
- `cp -p` and byte-for-byte readback passed. `setattrlist(ATTR_VOL_NAME)` renamed
  the volume to `XNTFS15-FEATURES`; the name survived unmount and detach/reattach.
  The writable phase and both read-only remounts reported the same volume UUID,
  `04A84B27-1A26-42C3-8AE6-05695468AC8D`.
- Five persistence assertions passed on each of two read-only remounts:
  contents/creation time/preallocation, native xattr, the lifecycle control file,
  both isolated test directories, and absence of retained `.xntfs-open-*` links.
  The copied control file also matched on both remounts.
- The two read-only remount paths were an explicit read-only request on writable
  media and a default request on read-only attached media. Both rejected writes
  with `EROFS` and left the entire test image unchanged during that phase.
- After detach, a new attachment without the temporary route used native `ntfs`.
  The compatibility route therefore did not persist as an automatic-mount rule.

The second run executed 35 syscall assertions: 16 general checks, eight legacy
lifetime checks, one volume-label change, and five persistence checks on each
remount. Exactly one assertion failed, so the overall exit status remained 1.
The independent compatibility-script safety checks and host I/O checks are not
included in this count.

#### Outstanding allocation reporting

Immediately after successful `F_PREALLOCATE`, the instrumented test observed:

```text
allocated=65536 stat=0 errno=0 size=7 blocks=1 read=7 errno=0 payload=1
After read: stat=0 size=7 blocks=1
After fsync: sync=0 stat=0 size=7 blocks=1
```

Thus the failing field is `st_blocks`: one 512-byte block is reported while the
descriptor stays open, despite a returned allocation of 64 KiB. Logical EOF and
the seven-byte payload are correct. After descriptor close, and after both
read-only remounts, the reported allocation meets the requested 64 KiB and the
payload remains intact. No content loss was reproduced in this case.

This establishes stale-looking mounted attribute reporting, not its cause.
It does not yet distinguish an FSKit/kernel cache issue from a module integration
problem. The logs also contain `getStandardItemAttributesForItem` error 22 during
the run; that message alone does not establish a causal link. Keep the immediate
assertion failing until the cause and remedy are verified. Do not disable the
test or declare the issue fixed merely because close/remount refreshes the value.

Finder UI copying, dirty-volume system preflight, and full-check/repair dispatch
were not tested on macOS 15 in this run. Their macOS 27 results above must not be
relabelled as macOS 15 results. Native sparse-region queries are a macOS 27-only
interface and were explicitly skipped on 15.

Both runs exited with status 1 and detached their test devices, removed the
temporary `.fs` route, and verified identical original-fixture hashes and pre/post
mount tables. No application or enablement settings were changed. The installed
TestFlight application and its single `/Applications` registration were retained.
The first disposable image was deleted. The second failure image was preserved
for diagnosis and compressed locally before removing its uncompressed copies.
Logs and the compressed image are under `_tmp/feature-macos15-20261009/`, including
`mounted-results-20261009-112230-82860/`,
`mounted-results-20261009-112816-83358/`, and the two `mounted-*-extension.log` files.

#### Focused allocation retest

The same macOS 15.8 x86_64 TestFlight 1.0.9 (13) extension was retested with
`tests/test_mounted_preallocation.c`, without replacing the application. Runtime
samples again matched the Archive UUID above. The probe compares `fstat`, `stat`,
`fgetattrlist` and `getattrlist` (`ATTR_FILE_ALLOCSIZE` and
`ATTR_FILE_DATAALLOCSIZE`) while controlling descriptor lifetime.

The first focused run reproduced the immediate-reporting failure in all seven
preallocation cases. The expanded run added files closed/reopened before
preallocation and an ordinary-write control that never calls `F_PREALLOCATE`.
All nine preallocation cases and the ordinary-write control reproduced stale
allocation values while open. These are repeated observations of the reporting
gap, not ten independent defects.

The expanded mounted run completed 100 assertions: 60 in the writable phase
(50 passed, ten allocation-reporting failures), followed by 20 on each of two
read-only remounts (all passed). The overall exit status correctly remained 1.

| Case | Allocation reported before/after preallocation while open | After all descriptors close |
| --- | --- | --- |
| New 7-byte file, repeated three times | 0 / 0 bytes | 65,536 bytes |
| New 8 KiB file | 0 / 0 bytes | 73,728 bytes |
| 7-byte file with timestamps, hidden-flag changes and xattr | 512 / 512 bytes | 65,536 bytes |
| New 7-byte file, no explicit preallocation attribute warm-up | Not queried / 0 bytes | 65,536 bytes |
| New 7-byte file with a reader held across writer close | 0 / 0 bytes | 65,536 bytes, only after reader close |
| Existing 7-byte file, closed and reopened before preallocation | 512 / 512 bytes | 65,536 bytes |
| Existing 8 KiB file, closed and reopened before preallocation | 8,192 / 8,192 bytes | 73,728 bytes |
| Ordinary 8 KiB write, no preallocation call | 0 bytes after write and fsync | 8,192 bytes |

All preallocation calls returned 65,536 allocated bytes. The fd- and path-based
queries agreed on the stale values. Reading, `fsync`, waiting three seconds,
opening another descriptor, closing that reader while the writer remained open,
and closing a `dup` did not refresh them. With a pre-existing reader kept open,
closing only the writer was also insufficient; closing the final descriptor
refreshed the allocation. Logical EOF and every payload check remained correct.

The same expanded probe on the test machine's APFS volume passed all 60
assertions, including immediate allocation reporting. The initial seven-case
probe also passed all 43 assertions on the macOS 27 host's APFS volume. This
checks the probe and syscall interpretation; APFS is not an FSKit implementation,
so this comparison does not distinguish an FSKit defect from module integration.

The first focused stream logged `getStandardItemAttributesForItem` error 22 at
11:44:30.861, before the first probe case began at 11:44:30.917. It cannot be
presented as a failed response to that case's preallocation request. The stream
does not expose enough attribute values to assign responsibility for the stale
results. The next diagnostic step is to correlate module attribute callbacks
and their returned allocation sizes with the mounted queries, not to weaken the
immediate-reporting assertion or assume allocation itself failed.

Artifacts are in `_tmp/preallocation-macos15-20261009/`: the APFS control logs,
`mounted-results-20261009-114350-84237/`,
`mounted-results-20261009-114713-84920/`, and `extension-stream-*.log`.
Both runs detached their disposable images and removed the temporary `.fs`
route. Original-fixture hashes and before/after mount tables matched. The
installed extension hash and single `/Applications` registration were unchanged;
no enablement or application preferences were modified. Failure images were
compressed and verified before removing their raw copies; APFS scratch files
were also removed. No production driver code changed during this retest.

### Focused macOS 27 comparison

The same expanded probe was run on the local macOS 27.0 (26A428) arm64 host.
With permission, `/Applications/xntfs.app` 1.0.8 (12) was backed up and temporarily
replaced by the 2026-10-09 10:29 Archive of host version 1.0.9 (13). This Archive's
arm64 extension UUID is `FA8F932F-7C31-3519-8152-5E95085272A4`, matching the arm64
slice in the macOS 15 TestFlight package. Runtime samples verified this UUID at
`/Applications/xntfs.app/Contents/Extensions/ntfs3g.appex/Contents/MacOS/ntfs3g`.
The local Archive extension still carries bundle version 1.0 (1); TestFlight
uses 1.0.9 (13). The executable UUID, not just the bundle's version string,
establishes which compiled implementation was tested.

The input was a copy of the same clean MBR fixture used on macOS 15, SHA-256
`33ba5a75ce5938ef43e7c92009cd89d60d2b17076eabe836f1afa03fe678d5ef`.
It was attached as a block device, then mounted through Disk Arbitration using
`diskutil mount -mountOptions rw`. This comparison did not use direct FSKit
path-URL image mounting. `statfs` confirmed `xntfs` and a writable mount before
running the probe.

All 100 assertions passed: 60 in the writable phase, 20 after an explicit
read-only remount, and 20 after detaching and reattaching the image as read-only
media. The identical 60-assertion APFS control also passed on this host.

| Query while the file is still open | macOS 15.8 x86_64 | macOS 27.0 arm64 |
| --- | --- | --- |
| New 7-byte file, after reserving 64 KiB | 0 bytes reported | 65,536 bytes reported immediately |
| Existing 8 KiB file, after reserving another 64 KiB | 8,192 bytes reported | 73,728 bytes reported immediately |
| Ordinary 8 KiB write, no preallocation | 0 bytes reported | 8,192 bytes reported immediately |

On macOS 27, all nine preallocation cases and the ordinary-write control reported
the updated allocation without requiring descriptor close. Contents and EOF
were correct throughout, and read-only phases left the entire image unchanged.
The macOS 15 stale-reporting behavior was not reproduced in this macOS 27
configuration. OS version, CPU architecture and distribution signing differ,
so this comparison alone does not establish a specific Apple defect or fix.

This is an allocation-attribute correctness/compatibility issue, not demonstrated
data loss or failed reservation: callers relying on occupied-space values may
temporarily undercount an open file. Apple documents `st_blocks` as allocated
blocks, separately from logical size; see
[stat(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/stat.2.html).
No Finder UI malfunction or application-level failure was reproduced by this
probe. Keep the macOS 15 issue open without treating it as proven corruption.

Setup initially encountered stale LaunchServices registrations referring to
Archive and deleted test-build paths. Only those xntfs test registrations were
removed, and the current user's `fskit_agent` was restarted with separate
permission. Normal app launch completed registration before the successful
mounted test. Neither enablement plists nor livefsd settings were edited.

After testing, the original 1.0.8 (12) application was restored and its two
executable hashes and strict signature verified. A fresh read-only mount loaded
the original arm64 extension UUID `05216F3A-26B9-3241-A435-ADBACCD16BF8`, and all 20
readback assertions passed. The test image was ejected, the host app quit, and
the final mount table matched the initial one. PlugInKit and LaunchServices
both showed only the `/Applications` extension registration. Logs, runtime
samples and the original-app ZIP backup are in
`_tmp/preallocation-macos27-20261009/`. Production driver code was not modified.

### Defects caught during implementation

- A filename-index write error could be swallowed by libntfs's index-context
  destructor. The bridge now detects backend write failures while syncing an
  owned inode and retains dirty state for retry instead of reporting success.
- Creating a symlink in a small resident directory index needed the parent index
  flushed before syncing the child's filename attributes. A regression now
  covers this order.
- Rejecting synthesized mode/owner requests as a whole broke `cp -p`. Those
  fields remain unconsumed under the existing ignored-ownership policy, while
  supported times/flags are applied. Finder and `cp -p` were retested afterward.

### Remaining boundaries

- macOS 26+ still uses FSKit's open-unlink emulation. Mounted descriptor reads,
  writes and `fstat` passed, but `st_nlink` remained 1 after unlink. The native
  legacy bridge branch reports 0 in both direct and mounted macOS 15 tests. Do not claim identical
  link-count semantics or complete POSIX conformance across versions.
- `diskutil renameVolume` and `diskutil verifyVolume` rejected the `xntfs`
  filesystem before reaching the corresponding module operation. Native volume
  rename and `fsck_fskit` results above do not establish Disk Utility First Aid
  support.
- Backup time, immutable/append flags, ACL/ownership mapping, contiguous
  preallocation and allocation on sparse/compressed/encrypted files are not
  implemented. Kernel-offloaded I/O and macOS 27 cache negotiation are unchanged.
- An extension crash may leave `.xntfs-open-*` recovery links. They are hidden
  from namespace operations during the live retention session, but intentionally
  preserved on a later mount rather than risking deletion of recoverable data.
- `-q` is a mount-safety preflight, not a full NTFS integrity scan. No repair,
  formatting, journal reset or dirty-bit clearing is advertised.

### Environment restoration

The original `/Applications/xntfs.app` was restored from the saved package.
Both original executable SHA-256 values and the bundle's strict code signature
verified. PlugInKit lists one xntfs registration under `/Applications`.
Backup: `_tmp/feature-mounted-20261009/original-app.zip`.

Runtime restoration initially failed because launchd retained the test build's
old executable path inside the existing `fskit_agent` process domain. Targeted
service removal was denied: only the owning process may modify that domain.
After separate user authorization, the current user's agent was restarted.
The new service record and actual extension processes both pointed to
`/Applications/xntfs.app/Contents/Extensions/ntfs3g.appex`.

The original extension successfully mounted the disposable image read-only as
`xntfs` at `/Volumes/XNTFS-ALIGN-RENAMED`. Reading the seven-byte test payload and
its creation timestamp succeeded. The test device was then ejected and the
temporary image removed. Evidence is saved as `restored-final-*` files alongside
the backup. The standalone FSClient probe returned zero matching modules, so it
was not used as positive enablement evidence; successful mounting and the
verified runtime executable path establish that the restored extension ran.

The authorized restart removed the pre-existing Xcode DeviceFS mount, which did
not automatically return during this check. `devicectl list devices` still
succeeded and listed paired devices. Other original mounts remained unchanged;
no other services were restarted. DeviceFS restoration was not verified.
