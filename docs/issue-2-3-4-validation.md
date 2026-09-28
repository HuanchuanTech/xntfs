# Issues 2, 3 and 4: fixes and validation

## Confirmed findings

- [Issue 2](https://github.com/HuanchuanTech/xntfs/issues/2): the bridge read free-space counters without initializing them from the NTFS allocation bitmaps. A mostly empty test image reported no free clusters before the fix. Mount now calls `ntfs_volume_get_free_space()` and fails if initialization fails. Allocation, deletion and remount tests verify the counters. This confirms the defect, not the exact 8 KB value on the reporter's 2 TB disk.
- [Issue 3](https://github.com/HuanchuanTech/xntfs/issues/3): the `Windows_NTFS` partition hint overrode positive exFAT identification. Classification now prefers the mounted filesystem, then the identified volume kind, and uses the partition hint only when the filesystem is unknown. An ordinary directory left at a stale mount path is not treated as a mounted device.
- [Issue 4](https://github.com/HuanchuanTech/xntfs/issues/4): inode-close errors were ignored, lookup was case-sensitive, and Swift used requested backend access instead of the effective NTFS read-only state. These defects were reproduced with disposable images. Failed closes now retain dirty inodes for synchronization retries; a saved writeback failure reaches the caller. Operations cannot reopen a stale copy of a dirty inode. Unrecoverable errors inside a namespace mutation block further operations and remain visible to synchronization until the volume is remounted.

Case-insensitive lookup now uses the NTFS case table, rejects conflicting creates/links, and returns the stored spelling to FSKit. Case-only renames retain the existing no-op behavior and return the actual unchanged spelling.

Open-unlink emulation is enabled on macOS 26 and later. Mounted tests on macOS 27 verify uncached reads and `fstat` through descriptors after unlink and replacement rename. The replaced path exposes the new contents. Those tests also caught inode-number reuse returning a cached, deleted directory object; deletion now evicts that object and its later reclaim cannot evict a replacement object.

## Compatibility limits

- FSKit's public open-unlink emulation is unavailable on macOS 15. The lifetime fix described above requires macOS 26 or later; this change does not implement native deferred inode reclamation for macOS 15.
- FSKit's `requestedMountOptions` is available starting with macOS 26.4. On earlier systems, a requested writable mount that internally falls back to read-only is rejected with `EROFS`; retrying explicitly read-only avoids presenting incorrect writable mount flags.
- No ntfs-3g submodule files are modified. All changes are in the bridge, FSKit volume, app classification and tests.

## Known defect: macOS 15 open-file lifetime

**Status: unresolved on macOS 15; fix deferred (2026-09-28).** This is the open-file
lifetime part of [issue 4](https://github.com/HuanchuanTech/xntfs/issues/4), not a
claim that all of that issue's findings remain unfixed.

- Trigger: delete an open file, or rename another file over an open destination.
- Expected: existing handles continue to access the old file until their final close.
- Current limitation: the bridge deletes the underlying file without deferring its
  reclamation. Reads or metadata queries through an existing handle may then fail
  with `ENOENT`. Applications relying on this behavior may fail during those operations.
- Workaround: close the file in all applications before deleting or replacing it.
  Applications that perform these operations internally may not offer such a workaround.
- Scope: FSKit's `enableOpenUnlinkEmulation` is available from macOS 26 and is enabled
  in the current source. Mounted regression tests passed on macOS 27. The remaining
  macOS 15 defect is identified from the code path and API availability, not a fresh
  macOS 15 runtime reproduction in this validation run.

The per-volume macOS 15 mounting workaround does not fix file-handle lifetime.
No macOS 15 implementation change or fix schedule is included in this work.

## Tests

Use a small, mostly empty, raw NTFS volume image as the fixture. The standalone runners copy it into `_tmp` and modify only the copy, including a synthetic `hiberfil.sys`. They do not accept raw device nodes.

```sh
bash tests/run_bridge_regressions.sh /path/to/fixture.img
bash tests/run_bridge_regressions.sh /path/to/fixture.img x86_64
NFSK_SANITIZE=address bash tests/run_bridge_regressions.sh /path/to/fixture.img
bash tests/run_volume_regressions.sh /path/to/fixture.img

xcrun swiftc -parse-as-library tests/test_disk_classification.swift \
  xntfs/Services/DiskArbitrationMonitor.swift xntfs/Model/NTFSDevice.swift \
  -o _tmp/test_disk_classification
_tmp/test_disk_classification
```

The bridge runner executes the fault-injection regressions plus the existing rename, metadata, parent-ID and hard-link suite. Fault injection makes the file backend return `EIO` specifically during the real inode-close operation. Recovery is checked by remounting and reading the persisted payload and timestamps.

The signed macOS 27 sandbox integration runner requires the new extension to be the single registered, enabled copy. It verifies read-only and writable mounts, open-file lifetime, case lookup after remount, free space, and a writable request falling back to a read-only mount with `MNT_RDONLY` set:

```sh
bash tests/run_macos27_images.sh /path/to/signed/xntfs.app \
  'Apple Development identity' /path/to/fixture.img image
```

The integration runner creates its own image copy, unmounts it and removes it afterward. It does not replace the installed app or change extension registration itself.

## Recorded validation (2026-09-28)

- Xcode 27 Debug build: succeeded for arm64 and x86_64. Existing warnings include the extension/host build-number mismatch and skipped App Intents metadata extraction.
- Bridge tests: 31 new checks and 41 existing extended checks passed on arm64 and x86_64 (the latter under Rosetta). The AddressSanitizer run passed the same checks.
- Classification: 15 filesystem-identification cases and a stale mount-directory check passed. These replay the reported identification values; they are not a fresh physical MBR/APM drive test.
- Swift volume tests: free-space reporting, effective read-only mount options, canonical lookup and the open-unlink emulation opt-in passed.
- Signed, sandboxed macOS 27 integration: all five image phases passed (read-only, writable, read-only remount, synthetic hibernation preparation, read-only fallback). The test verified the newly built extension's URL before mounting.
- The reporter's exact 2 TB drive and macOS 15/26 runtime environments were not tested. Issue 4 must not be described as fully resolved on macOS 15.

Only issue text and comments were read remotely. No reporter-provided executable or Gist reproduction script was downloaded or run; the tests above were written and built locally.

## Local environment restoration

Registering a candidate extension for integration testing affects the current user's shared extension state. Use a dedicated test session or unmount existing test volumes first; do not assume that removing the candidate registration alone restores running services.

During this run, the pre-existing read-only test-image mount disappeared while registration was being switched. Restoration initially failed with Cocoa error 4099; the extension log showed `Invalid bundle record for current process` before NTFS mounting began. After removing temporary application registrations, refreshing the installed application's record and restarting the current user's `fskit_agent`, the original image mounted successfully again at `/Volumes/NTFS_TEST` as read-only `xntfs`.

The final PlugInKit check showed one registration for `com.huanchuan.xntfs.ntfs3g`, under `/Applications/xntfs.app`. The installed application files and enablement plists were not modified. No code was committed or pushed, and no GitHub issues were closed as part of this validation.
