# xntfs — NTFS for macOS (FSKit + ntfs-3g)

> 📖 Also available in [Simplified Chinese](README_CN.md).

<a href="https://apps.apple.com/app/xntfs/id6782636021"><img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download xntfs on the App Store" height="44"></a>

A macOS app + **FSKit file-system extension** that reads and writes NTFS volumes using the
[ntfs-3g](https://github.com/tuxera/ntfs-3g) engine. No kernel extension, no macFUSE.

The `ntfs3g` app-extension reuses the portable **`libntfs-3g`** core (all the NTFS logic — MFT,
runlists, compression, security descriptors, `$LogFile`) behind a thin FSKit `FSVolume` mapping
layer, the same way ntfs-3g's own `src/ntfs-3g.c` maps FUSE onto libntfs.

The extension lets macOS mount supported NTFS drives under `/Volumes` without a background app.
The app lists drives and disk images, shows their actual mount and read-only status, and helps
diagnose extension setup. Mounting controls depend on the macOS version; see below.

```
xntfs.app  (SwiftUI, App Sandbox — control panel; not a background agent)
 ├─ AppModel ── DiskArbitrationMonitor   detect/list NTFS drives (detection only)
 │           └─ MountService             manual mount/unmount (DiskArbitration), image attach
 └─ Contents/Extensions/ntfs3g.appex     FSKit module — the actual NTFS driver (+ auto-mount)
        ntfs3g.swift            @main UnaryFileSystemExtension
        ntfs3gFileSystem.swift  probe / load / unload / fsck
        ntfs3gVolume.swift      every FSVolume operation → nfsk_* bridge
        bridge/ntfs_fskit.c     libntfs logic (mount, getattr, readdir, read, write, create…)
        bridge/ntfs_device_fskit.m  block I/O over FSBlockDeviceResource (sector-aligned RMW)
        + libntfs-3g.a (arm64 + x86_64, statically linked)
```

## Status

| Piece | State |
|-------|-------|
| `ntfs3g` extension (NTFS read/write engine) | ✅ builds; engine statically linked; [implemented operations and limits](docs/fskit-feature-alignment.md) |
| `xntfs` app (UI, monitor, mount service, settings) | ✅ builds |
| English + Simplified Chinese localization | ✅ `Localizable.xcstrings` (en, zh-Hans) |
| App icon | ✅ generated, full AppIcon set |
| End-to-end mount on a Mac | Verified on macOS 15.8 and 27.0; the extension still needs FSKit provisioning and user enablement |

The extension uses a restricted FSKit entitlement. A locally built copy requires a signing team
whose provisioning profile authorizes it; building alone does not enable the extension.

The bundled engine is pinned to [ntfs-3g 2026.9.28](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28),
which fixes the 2026.9.18 regression that could reject new files and directories with
`EINVAL`. See [issue #7 validation](docs/issue-7-validation.md).

## Known issues

- **macOS 15 open-file lifetime: native fix validated on macOS 15.8.**
  The current source retains deleted/replaced open files until final close, without
  depending on macOS 26 APIs. Bridge, direct Swift and mounted lifetime tests
  passed on macOS 15.8 x86_64 with TestFlight 1.0.9 (13). Older builds can still
  lose access through existing handles; close files before deleting or replacing
  them. macOS 26+ keeps FSKit's emulation, tested on macOS 27; its
  unlinked open files still report a link count of 1. See [issue #4](https://github.com/HuanchuanTech/xntfs/issues/4)
  and [current validation](docs/fskit-feature-alignment.md).
- **macOS 15 allocation reporting can remain stale while a file is open.**
  Mounted tests reproduced outdated allocated-space values after ordinary writes
  and preallocation, until the last descriptor closed. Data and logical file size
  remained correct in these tests. The same probe passed on macOS 27; the cause
  is not yet established. See [the focused retest](docs/fskit-feature-alignment.md#focused-allocation-retest).

## Filesystem operations

The current source supports native creation-time and hidden-flag updates,
symbolic links, volume renaming, persistent preallocation for ordinary files,
and sparse-region queries on macOS 27. It performs a read-only mount preflight,
not a full filesystem check or repair. These are source capabilities, not a
claim that every published build includes them. See the [design, tests and
remaining limits](docs/fskit-feature-alignment.md).

## Finder metadata

The current source stores extended attributes (including Finder tags and resource forks)
in same-named NTFS alternate data streams, instead of creating new AppleDouble `._` files.
Each attribute is limited to **128 KiB**, matching the limit observed in mounted FSKit
tests on macOS 27. This limit does not apply to ordinary file contents.

**Existing `._` files are not automatically migrated or deleted.** Until migrated, their
metadata is not exposed by the native xattr API. Back up the files and their `._` companions
before upgrading or migrating. With the volume mounted read/write using the new driver,
macOS's `dot_clean` can merge the old metadata into native attributes. For one directory
(without descending into subdirectories):

```sh
dot_clean -f -v "/Volumes/YourDrive/YourFolder"
```

This command changes metadata and removes successfully merged `._` files. Verify tags and
resource forks afterward, and keep the backup. Do not bulk-delete `._` files or use cleanup
options that discard them without merging. The app does not run this command automatically.

## The six features

1. **Localization (English + Simplified Chinese)** — `xntfs/Localizable.xcstrings` (String Catalog). Add more
   languages by adding `localizations` entries.
2. **Auto-mount removable NTFS** — handled by the **system**, not the app: the extension's
   `Info.plist` registers NTFS `FSMediaTypes` (`Windows_NTFS`, MS Basic-Data GUID, partitionless),
   so DiskArbitration can auto-mount supported NTFS drives under `/Volumes` without the app
   running. On macOS 15, the built-in NTFS driver may take priority; see the manual workaround.
3. **Mount location** — drives mount under `/Volumes/<name>`; the system picks the path and
   de-duplicates names. Mounting to a **custom folder is not possible** for a sandboxed FSKit
   volume (the extension can only reach `/Volumes` and its own sandbox temp paths), so
   `/Volumes` is the only target.
4. **Multiple drives at once** — devices are tracked by BSD name and mounted independently.
5. **Manual mount / unmount** — on macOS 27, the app offers in-app mounting with a read-only
   choice. On macOS 15, it shows a copyable Terminal command to mount a selected volume with
   xntfs, including volumes already attached by Disk Utility. On macOS 26, use Disk Utility.
   Mounted volumes can be revealed in Finder or ejected from the app.
6. **Disk images** — on macOS 27, the app can select and mount a raw, single-volume NTFS image.
   Partitioned or compressed images are opened in Disk Utility. On older systems, attach images
   in Disk Utility; a selected NTFS partition can then use the macOS 15 manual workaround.

## Build

The repo is a normal Xcode project — open `xntfs.xcodeproj` and build the `xntfs` scheme.
Build settings for the extension (bridging header, `libntfs-3g.a` link, header search paths,
`HAVE_CONFIG_H`) and the app (entitlements, zh-Hans region) are already committed; they
were applied with `scripts/wire_project.rb` (re-runnable, idempotent, needs the `xcodeproj` gem).

Before building in Xcode, generate the universal static library and shared `config.h`
(requires Autotools and GNU libtool):
```sh
./scripts/build-libntfs.sh
lipo -archs build/libntfs-universal/libntfs-3g.a
```
The script builds arm64 and x86_64 separately, then combines them under
`build/libntfs-universal/`. That directory is ignored by Git; run the script again after a clean
checkout or when updating the ntfs-3g submodule.

The project uses the maintainer's signing team by default. Choose your own team in Xcode and
configure the FSKit capability before running a local build.

## Provisioning (required to actually run the extension)

The extension declares the **restricted** entitlement `com.apple.developer.fskit.fsmodule`
(`ntfs3g/ntfs3g.entitlements`). macOS (AMFI) refuses to load the extension unless that entitlement
is authorized by a provisioning profile. With **automatic signing** and team `529LJDH392`, this
works only if that team's App ID has the **FSKit File System Module** capability enabled in the
Apple Developer portal. Replace the project team with your own before signing. Once provisioned,
enable the module under **System Settings → General →
Login Items & Extensions → File System Extensions**.

## Sandbox & mounting

The mounting paths differ by operating system:

- **macOS 27:** the app uses FSKit and Disk Arbitration APIs for in-app volume and image mounts.
- **macOS 26:** automatic mounting works when the extension is enabled; Disk Utility handles
  manual mounts and image attachment.
- **macOS 15:** the built-in NTFS driver can win automatic selection. The app provides a
  copyable, per-volume Terminal command that temporarily selects xntfs. It asks for confirmation
  and administrator authentication, then removes its temporary `.fs` entry. The app does not
  execute this command itself. See [the compatibility details](docs/macos15-compatibility.md).

> This is a *technical* capability result; App Review is a separate policy gate.

## Layout

```
xntfs/                     app target (SwiftUI)
  xntfsApp.swift           @main App + Settings scene
  ContentView.swift        device/image list + OS-specific mount controls
  DiskUtility.swift        opens Apple's Disk Utility (mount / attach images)
  MountSheet.swift         in-app mount sheet on macOS 27
  LegacyMountSheet.swift   manual mount guidance on macOS 15
  CopyableCommand.swift    copyable-command control
  DiagnosticsView.swift    extension-status diagnostics page
  SettingsView.swift       read-only-by-default preference
  Model/NTFSDevice.swift
  Services/                AppModel, AppSettings, DiskArbitrationMonitor, MountService,
                           ExtensionStatus
  Localizable.xcstrings    en + zh-Hans
  Assets.xcassets/AppIcon  generated icon set
ntfs3g/                    FSKit extension target
  ntfs3g*.swift            @main + FSUnaryFileSystem + FSVolume + FSItem
  bridge/                  ntfs_fskit.{h,c}, ntfs_device_fskit.m, bridging header
  Info.plist               FSShortName=xntfs, FSMediaTypes, block resources
  ntfs3g.entitlements      com.apple.developer.fskit.fsmodule + sandbox
ntfs-3g/                   upstream source + built libntfs-3g.a
scripts/wire_project.rb    applies extension/app build settings (xcodeproj gem)
assets/xntfs-icon.svg      icon source
```
