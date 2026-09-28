# macOS 15 compatibility

## Known filesystem defect

Deleting an open file, or replacing an open destination by rename, can invalidate
its existing handles on macOS 15. Later reads or metadata queries may fail with
`ENOENT`. This remains unresolved and its fix is deferred. Close files in all apps
before deleting or replacing them; the mounting workaround below does not address
this defect. See [the scope and validation details](issue-2-3-4-validation.md#known-defect-macos-15-open-file-lifetime).

## Behavior

- On macOS 15, the app checks its embedded `ntfs3g.appex` instead of treating an
  empty `FSClient.installedExtensions` result as proof of missing installation.
  Bundle presence, registration and enablement are separate facts. Registration
  and enablement remain unknown in-app; Settings and the copyable `pluginkit`
  diagnostic are provided. macOS 26+ retains the FSClient path.
- Select an NTFS volume, then **Mount with xntfs**. This works with an attached
  image or a disk volume, whether currently mounted or unmounted. The app only
  displays/copies a command. It never launches Terminal, a shell, `sudo`, an
  AppleScript authorization request, or a privileged helper.
- The user enables ntfs3g in Settings, closes open files, then runs the command
  in Terminal and confirms the operation and administrator authentication there.
- The script revalidates the boot UUID, IOMedia registry ID, BSD name and size,
  verifies the NTFS boot sector, normally unmounts if needed, then asks Disk
  Arbitration to mount under `/Volumes`. Busy volumes are not force-unmounted.
  It checks the actual mount table for `xntfs`; Disk Utility's filesystem label
  is not sufficient evidence. Failure can leave the selected volume unmounted;
  after cleanup, Disk Utility can mount it with the default system driver.
- Read-only preferences still apply in the extension. A read-only request also
  passes `diskutil mount readOnly` and verifies the resulting mount flags. The
  command does not change shared preferences or make read-only media writable.

## Temporary routing and cleanup

The only shared entry is `/Library/Filesystems/xntfs-macos15-session.fs`, a
root-owned symlink to a unique root-owned directory in root's
`DARWIN_USER_TEMP_DIR`. No executable is installed there. The plist directs
Disk Arbitration to the already-installed FSKit extension, with an exact
IOMedia connection match, not a rule for all NTFS media. Partitionless NTFS
media are accepted only when the selected object is a leaf and its boot sector
is NTFS. Nothing attaches, formats, repairs or detaches a disk/image.

Success, failure, Ctrl-C, HUP and TERM remove the link before the bounded
watchdog is stopped. The watchdog removes it if the controlling process dies
or the 120-second operation lifetime expires. Normal cleanup removes the
temporary files too. Killing a diskutil client does not cancel a request
already accepted by Disk Arbitration: re-check the actual mount before retrying.

The Cleanup command refuses an active session, a foreign object at the path,
an unexpected link target, or an invalid receipt. It removes only this
workaround's inactive entry; it does not alter mounted volumes or other drivers.
Concurrent invocations cannot overwrite the fixed routing link.
An OS file lock serializes mount and cleanup operations, including the
watchdog's final removal. Its zero-byte file stays in root's temporary directory,
not in `/Library/Filesystems`; no process or active lock remains after completion.

No script can trap power loss or SIGKILL of all its processes. Using the
OS boot-cleaned temporary directory avoids retaining a valid routing plist in
`/Library/Filesystems` across normal reboots; a dangling link can be removed by
Cleanup. This relies on macOS startup cleanup, not on an IORegistry ID being
globally unique across boots. Do not replace the symlink with a persistent
copied `.fs` bundle. Reboot/crash behavior needs separate system-level testing.

The script does **not** modify `enabledModules.plist`, `probeOrder.plist`,
`livefsd/settings.plist`, registrations, system NTFS, entitlements, SIP, or
launch items. Reconnecting a drive requires a newly generated command.

## App Review Notes (English)

The app and its FSKit extension remain sandboxed. On macOS 15, third-party
extension status is not reliably returned by FSClient, and the built-in NTFS
driver takes priority during automatic mounting. The app explains these
limitations without reporting the extension as absent or disabled.

For macOS 15 only, the selected-volume screen offers an optional, inspectable
Terminal command from a script included in the app bundle. The app does not
execute it, open Terminal, request administrator privileges or install a helper.
On affected macOS 15 systems, choosing xntfs for an NTFS volume requires this
external step; without it, the system's built-in NTFS driver normally remains
in use with read-only access.
The user explicitly confirms it and authenticates with sudo in Terminal. The
script briefly creates a disk-specific routing symlink in
`/Library/Filesystems`, invokes Disk Arbitration, verifies the xntfs mount, and
removes the entry on completion or error. It includes bounded timeout cleanup
and a manual recovery command. No daemon, driver executable or persistent
automount rule is installed. Extension enablement remains user-controlled.
The descriptor uses Disk Arbitration implementation details, not a documented
public API contract for overriding the system's filesystem selection.

We disclose this workflow for review rather than representing it as an approved
exception. Please evaluate it against the Mac App Store requirements.

## 上架与操作边界

用户已选择在应用内提供手动命令，并向审核完整披露。此方案并不等于保证过审。
Apple 规则 2.4.5 要求沙盒、自包含安装，禁止在共享位置安装代码或资源以及请求
root 提权。由用户在终端执行，也不意味着可以规避这些要求。审核需要知道
临时 `.fs` 的位置、用途、权限、生命周期及清理流程；若该工作流不被接受，
应调整商店版支持范围或移除该入口，不能隐藏功能。

## Verification (2026-09-26)

- Xcode 27 / macOS 27 SDK: unsigned Release build succeeds for `arm64` and
  `x86_64`, including the app, extension and bundled command resource. Deployment
  target remains macOS 15.4. This is a build check, not App Store validation.
- Standalone Swift tests pass on macOS 27 arm64 and macOS 15.8 x86_64: embedded
  extension detection, unknown registration/enablement, shell argument round trips
  with quoted paths, connection identity and read-only command generation.
- The script's 24 validation checks and the six cleanup/lifecycle checks pass.
  Lifecycle checks use temporary fixtures, including concurrent invocation,
  actual controller SIGKILL, and expiry while the controller is still alive.
- A Developer-signed probe with only `com.apple.security.app-sandbox` enabled
  reads the embedded extension, boot-session UUID and IOMedia registry ID on
  macOS 15.8. No additional entitlement is needed for these reads.
- Live macOS 15.8 Intel tests use a private copy of an NTFS image and the existing
  `/Applications/xntfs.app` extension: mounted native NTFS switches to xntfs,
  an attached but unmounted volume mounts with xntfs, a busy volume is not forced,
  stale connection identity is rejected, explicit read-only and read-only media
  stay read-only, and a subsequent attachment without the temporary rule uses
  native NTFS again. Mounts use `/Volumes`; the original image's hash is unchanged.
  The final run also verifies the actual privileged controller PID before sending
  SIGKILL; the watchdog removes its routing entry and the suite exits with zero.
- These checks do not cover physical USB media, clicking through Disk Utility,
  the complete new app UI on macOS 15, or reboot/power-loss recovery. A fixture
  watchdog test is not a substitute for system-level crash testing.

Run the non-privileged tests from the repository root on macOS:

```bash
mkdir -p _tmp
/bin/bash xntfs/Resources/macos15-mount.sh --self-test
/bin/bash tests/test_macos15_lifecycle.sh
xcrun swiftc -parse-as-library -o _tmp/test-macos15-compat \
  tests/test_macos15_compat.swift \
  xntfs/Services/ExtensionStatus.swift \
  xntfs/Services/LegacyMountCommand.swift \
  xntfs/Model/NTFSDevice.swift
_tmp/test-macos15-compat _tmp
```

Cross-compiling the Swift test with `-target x86_64-apple-macos15.4` allows it to
run on the Intel test machine without installing Xcode there. Build tests with
assertions enabled (do not use `-O`). The lifecycle test does not touch real disks
or `/Library/Filesystems` and does not need administrator privileges.

Earlier build validation reported differing app/extension build numbers (`6` /
`1`). The TestFlight retest below uses version `1.0.5`, build `8`, for both bundles.

## Unified lifecycle retest (2026-09-27)

The extension uses the same lifecycle on all supported releases: probe and load
metadata read-only, then resolve the effective access mode in `activate(options:)`.
There is no macOS 27-only branch for this ordering. The macOS 15 Terminal workflow
and the macOS 26 Disk Utility workflow remain unchanged.

Current on-device status for macOS 15.8 (24H23), x86_64:

- The current universal Release build succeeds with deployment target 15.4.
- The standalone compatibility tests, 24 command validation checks and six
  cleanup/lifecycle checks pass on the test machine.
- The user installed TestFlight `1.0.5 (8)` in `/Applications/xntfs.app`. Both
  bundles have a `TestFlight Beta Distribution` signature and pass static code
  signature verification. Neither bundle was replaced or re-signed for this run.
- The installed extension contains the new read-only-load/activation-backend
  markers. Its running x86_64 Mach-O UUID is
  `2762E2F7-9170-3FD0-B33B-4058653BAAE3`, verified by process samples during the
  live mount, so these results are not from the previously installed extension.
- The complete unified lifecycle runner passes with exit status `0`: explicit
  read-only mounts reject writes with `EROFS` and leave the whole image hash
  unchanged; the writable image default permits normal-user create, rename and
  readback; content survives unmount and read-only remount; read-only media stays
  read-only despite that writable default. Actual `statfs` reports `xntfs`.
- A stale device identity is rejected without replacing the native NTFS mount.
  Each successful compatibility mount removes its temporary `.fs` route; a
  subsequent attachment without that route uses native NTFS again.
- Final checks confirm that the fixture hash and pre-existing mount table are
  unchanged, the disposable copy and temporary route are absent, no test
  processes remain, and only the `/Applications` extension is registered. The
  test does not modify enablement plists or app preferences.

Evidence is in
`_tmp/macos15-unified-20260927/testflight-results-20260927-154538-14508/`, including
`report.txt`, `exit.txt`, before/after hashes and mount tables, and process samples.
This is a QEMU macOS 15.8 Intel test of the shipped compatibility command and real
filesystem I/O, not a physical USB test or automated SwiftUI interaction test.

The earlier development-signed build was blocked before its extension could run:
the device was not authorized by its development profile, and AMFI reported
`No matching profile found`. TestFlight allowed this retest to complete without
registering the VM's UDID or changing its security configuration. This does not
resolve the separate Developer portal registration error.

`tests/run_macos15_unified_flow.sh` exercises the shipped compatibility command
against an independent, unique-serial MBR image. It checks explicit read-only
mounts and image hashes, normal-user create/rename/readback, persistence across
unmount/remount, read-only media, stale device identity, route cleanup and the
running extension's Mach-O UUID. It never installs apps or changes preferences.
Run it only with an installed, enabled extension whose signing authorizes the
test machine, and with the app's image read-only preference turned off for the
writable case. Use `tests/prepare_macos27_device.swift` to prepare the disposable
fixture; despite its name, it performs no macOS 27-specific calls.

```bash
xcrun swiftc -target x86_64-apple-macos15.4 \
  tests/verify_macos15_mount.swift -o _tmp/verify-macos15-mount
# On the macOS 15 Intel test machine, with transferred fixture and verifier:
sudo bash tests/run_macos15_unified_flow.sh \
  /path/to/disposable-fixture.img /Applications/xntfs.app \
  /path/to/verify-macos15-mount /path/to/new-results-directory \
  EXPECTED-X86-EXTENSION-MACH-O-UUID
```

Updating an app's extension registration can terminate its existing FSKit
instances and unmount their volumes. Close files and normally unmount those
volumes before replacing/registering the app. The test runner itself does not
replace registrations or operate on pre-existing mounts.

## Sources

- [Apple App Review Guidelines, 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)
- [Apple Disk Arbitration probe selection](https://github.com/apple-oss-distributions/DiskArbitration/blob/DiskArbitration-490.140.8/diskarbitrationd/DAProbe.c)
- [Apple Disk Arbitration FSKit and UserFS routing](https://github.com/apple-oss-distributions/DiskArbitration/blob/DiskArbitration-490.140.8/diskarbitrationd/DAFileSystem.c)
- [Apple dirhelper boot cleanup source (historical implementation)](https://github.com/apple-oss-distributions/system_cmds/blob/system_cmds-597.90.1/dirhelper.tproj/dirhelper.c)
