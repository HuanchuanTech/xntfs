# Issue 7: EINVAL when creating files and directories

## Finding

[xntfs issue #7](https://github.com/HuanchuanTech/xntfs/issues/7) reports that
xntfs 1.0.7 can read, overwrite and extend existing files on a Windows-formatted
NTFS volume, but cannot create files or directories. The reported errno is
`EINVAL` (22).

The original local 1.0.7 source pinned ntfs-3g to `2026.9.18` (`a784bba`). That release
introduced a regression in `ntfs_attr_mst_pread()`: an invalid multi-sector
transfer (MST) header became a hard read failure, including when the MFT
allocator was reading an unused record that it was about to initialize.

If the allocation bitmap marks the next record free but that record contains
zeroes, its update-sequence-array header is absent. The read returns `EINVAL`
before `ntfs_mft_record_layout()` can initialize it. Allocation rolls back, so
the next create selects the same free record and fails again. Writing an
existing file need not allocate a new MFT record and can still work.

Upstream tracked this in [issue #217](https://github.com/tuxera/ntfs-3g/issues/217)
and [issue #218](https://github.com/tuxera/ntfs-3g/issues/218), reverted the check in
[9398030](https://github.com/tuxera/ntfs-3g/commit/9398030d978b064c62f304b1a514c7a494d37b62),
and released the fix in
[2026.9.28](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28).

The issue reporter's successful Linux comparison used the older `d1cb9e8`
engine, not the engine bundled with 1.0.7. It therefore does not exclude this
regression. FSKit, sandbox permissions and block alignment are not required
to reproduce the failure locally.

## Local Change

- Pin the pristine upstream submodule to release `2026.9.28`
  (`7f0f841fc52cf719106c5c93bafe465004e36816`). No local upstream source patch.
- Rebuild `build/libntfs-universal/libntfs-3g.a` and `config.h` for arm64 and
  x86_64. These generated files are ignored by Git; a checkout must run
  `bash scripts/build-libntfs.sh` before building the app.
- Add `tests/test_mft_allocation.c` and its runner. Keep the FSKit bridge,
  mounting flows, entitlements and system configuration unchanged.

## Reproduction

```sh
bash scripts/build-libntfs.sh
bash tests/run_mft_allocation_regressions.sh /path/to/clean-NTFS.img
bash tests/run_mft_allocation_regressions.sh /path/to/clean-NTFS.img x86_64
```

The runner accepts a regular raw-volume image, copies it into `_tmp`, and deletes
the image copy afterward. It never mounts or writes a physical disk. The test:

1. Creates an existing file and three placeholders in the copy, then deletes
   the placeholders. Checks that their MFT bitmap bits are free and their
   records are within the initialized MFT data before zeroing only those slots.
2. Opens the volume through the production C bridge and Objective-C image
   backend. Checks that existing-file writes and an 8 KiB append work.
3. Creates two files and a directory, requiring allocation of exactly the three
   zero-filled slots. Checks attributes, new-file I/O and child creation.
4. Synchronizes, remounts, verifies names and contents, and deletes new items.

With the original 2026.9.18 library on macOS 27 arm64, the test reproduced:

```text
Fixture: sector=512 cluster=4096 record=1024 zeroed free records=70,71,72
Failed to read of MFT, mft=70 count=1 br=-1: Invalid argument
create Issue7NewFile.txt: inode=0 errno=22
create Issue7NewDirectory: inode=0 errno=22
create Issue7SecondFile.txt: inode=0 errno=22
11 checks, 6 failures
```

Existing-file overwrite, append, sync and readback passed in that failing run.

## Results (2026-10-05)

- Host: macOS 27.0 (26A428), Xcode 27.0 (27A266a).
- Rebuilt the universal static library from the pinned 2026.9.28 source.
- New allocation regression: 21 checks, zero failures on arm64 and on x86_64
  under Rosetta. The same test that failed above now allocates records 70, 71
  and 72 successfully. The arm64 AddressSanitizer configuration also passed.
- Existing bridge tests: 37 regression checks, 41 extended checks and 24
  directory checks passed on arm64, x86_64 under Rosetta, and the arm64
  AddressSanitizer configuration. ASan instruments the bridge and test code,
  not the prebuilt upstream library.
- Swift volume regressions passed, including free space, effective read-only
  fallback, case-preserving lookup and mount capability reporting.
- A clean Xcode Release build with code signing disabled passed for both the
  host and extension. Both Mach-O executables contain arm64 and x86_64 slices.
  Existing warnings remain about upstream header comments, skipped App Intents
  extraction and the extension/host build-number mismatch (1 versus 11).

The Xcode build was not installed or launched. Build logs and regression logs
are retained under `_tmp`; generated test image copies are removed by the runners.

## Validation Boundary

The reporter's Samsung SSD and metadata image were not available. This is a
local reproduction of the matching upstream regression, not confirmation on
that exact volume. A candidate build still needs the reporter to verify new
file and directory creation on the originally affected drive. Do not describe
that hardware retest as completed or ask the user to reformat/repair the disk
to work around this allocation bug.

No installed application, extension registration or enablement plist is changed
by these standalone tests.
