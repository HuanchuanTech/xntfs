# macOS 27 support

## Implemented

- Open File System Extensions through `FSClient.openFileSystemExtensionsSettings()`.
- Copy diagnostics with app/OS versions, extension paths, enablement state, and query errors.
- Hide the macOS 26 enablement plist workaround on macOS 27.
- Select a raw NTFS volume image using the app's `+` button, choose read-only or read/write, and mount it under `/Volumes` using `FSClient.mountSingleVolume`.
- Keep the user's selected image URL security-scoped while mounting. FSKit forwards a scoped bookmark to the extension; the extension holds access until unload.
- List direct image mounts separately from block devices, with their source path, capacity, and actual access mode. Read the mount table to rediscover these images after restarting the app.
- Reveal mounted images in Finder and unmount them from the app. Refresh after system mount/unmount notifications.
- Report mount errors with the NSError domain and code, and reject duplicate direct mounts, including a second selection through a symlink.
- Mount an unmounted sidebar device or an image partition already attached in Disk Utility using the in-app Mount sheet. Choose read-only or read/write; read-only media always stays read-only.
- Use public Disk Arbitration for BSD devices, and confirm the returned path, actual xntfs driver, and actual access mode before reporting success. Reject stale I/O Registry identities and already-mounted volumes.

The host app needs `com.apple.developer.fskit.mount` in its signature and provisioning profile, user-selected read/write access, and app-scoped bookmarks. The minimum deployment target remains macOS 15.4; direct mounting is gated to macOS 27.

## Boundaries

Direct mounting currently accepts raw, single NTFS volume images. A partitioned whole-disk image, compressed DMG, or another filesystem must first be opened in Disk Utility. This does not add a disk-image container parser or change device mounting on macOS 15/26.

`FSBlockDeviceResource` has no public constructor in the inspected SDK. For already-attached volumes, the app uses `DADiskMountWithArguments`, not a private FSKit initializer. This path has now passed sandboxed tests against the enabled extension installed in `/Applications`. macOS 15/26 retain their existing compatibility / Disk Utility paths.

The macOS 27 device tests found that Disk Arbitration delivers explicit `rdonly`/`rw` arguments in `activate(options:)`, while `loadResource` receives no mount arguments. The extension now loads metadata read-only, then resolves the access mode at activation. Explicit choices take precedence over preferences; mounts with no explicit choice retain the per-scenario default. Merely enabling the old button would have left read/write image mounts read-only.

This load/activate ordering is shared by macOS 15, 26 and 27; it is not gated to
macOS 27. Only the host app's mounting entry points differ by OS version.

## Verification

On macOS 27.0 (26A428), with Xcode 27.0 (27A266a):

- The sandboxed test calls the production image-mount service and AppModel against the enabled extension installed under `/Applications`.
- Actual `statfs` reports `xntfs` and the requested read-only/read-write flags.
- A read-only mount rejects host writes with `EROFS`; the image hash is unchanged after unmount.
- A read/write mount supports create, rename, and readback. Its content survives unmount and a subsequent read-only mount.
- A fresh AppModel rediscovers the mount. Unmount removes it from the list.
- Tests cover spaces, apostrophes, Chinese characters, duplicate/symlink selection, and rejection of non-raw inputs.
- The existing macOS 15 compatibility tests pass on the macOS 27 host. This is not another on-device macOS 15 run.
- Attached MBR image partitions pass the same read-only hash, write/rename/readback, persistence, and actual mode checks through AppModel and MountService. Tests also reject a stale registry ID and duplicate mounts, and recover mounted state in a new model.
- Releasing a started disk monitor and continuing to mount exposed a dangling callback. Callbacks now use a weak owner and are unregistered on their queue before releasing their context.

Reproduce with a signed app carrying the mount entitlement, an available signing identity, and a raw NTFS fixture:

```bash
bash tests/run_macos27_images.sh /Applications/xntfs.app 'Apple Development: your identity' /path/to/raw-ntfs.img
bash tests/run_macos27_images.sh /Applications/xntfs.app 'Apple Development: your identity' /path/to/ntfs-mbr.img device
bash tests/run_macos27_images.sh /Applications/xntfs.app 'Apple Development: your identity' /path/to/ntfs-mbr.img device-ro
```

The runner uses disposable copies with new NTFS serials, cleans up mounts and temporary bundles, and leaves logs under `_tmp`. It tests the service/model and real filesystem I/O; it does not automate SwiftUI clicks. Device-mode fixtures must have an MBR with NTFS in the first partition. Physical USB media and macOS 26 have not been retested on-device for this change.

The macOS 15.8 Intel VM retest now passes using the user-installed TestFlight
`1.0.5 (8)` build. Process samples confirm the running extension's new x86_64
Mach-O UUID. The shipped compatibility command passes explicit read-only hash
checks, normal-user write/rename/readback, persistence across unmount/remount,
read-only media, stale device rejection and temporary route cleanup. TestFlight
avoids the earlier development-profile blocker without changing VM security
settings. See [macOS 15 compatibility](macos15-compatibility.md#unified-lifecycle-retest-2026-09-27).
