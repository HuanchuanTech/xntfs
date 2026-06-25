# xntfs — NTFS for macOS (FSKit + ntfs-3g)

> 📖 Also available in [Simplified Chinese](README_CN.md).

A macOS app + **FSKit file-system extension** that reads and writes NTFS volumes using the
[ntfs-3g](https://github.com/tuxera/ntfs-3g) engine. No kernel extension, no macFUSE.

The `ntfs3g` app-extension reuses the portable **`libntfs-3g`** core (all the NTFS logic — MFT,
runlists, compression, security descriptors, `$LogFile`) behind a thin FSKit `FSVolume` mapping
layer, the same way ntfs-3g's own `src/ntfs-3g.c` maps FUSE onto libntfs.

NTFS drives **auto-mount under `/Volumes` by the system** (DiskArbitration probes the extension's
registered `FSMediaTypes` — no app process needed, exactly like the built-in exFAT/MSDOS modules).
The `xntfs` app is a **control panel**: it lists NTFS drives and attached disk images, ejects and
reveals mounted volumes, and shows an extension-status diagnostics page. A sandboxed app can't
mount a third-party FSKit volume or attach a disk image itself, so for those the app opens **Disk
Utility**; everyday drives auto-mount via the system.

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
        + libntfs-3g.a (arm64, statically linked)
```

## Status

| Piece | State |
|-------|-------|
| `ntfs3g` extension (NTFS read/write engine) | ✅ builds; engine statically linked; FSKit conformances complete |
| `xntfs` app (UI, monitor, mount service, settings) | ✅ builds |
| English + Simplified Chinese localization | ✅ `Localizable.xcstrings` (en, zh-Hans) |
| App icon | ✅ generated, full AppIcon set |
| End-to-end mount on a Mac | ⛔ requires the FSKit entitlement to be provisioned for your team — see below |

The NTFS engine itself is independently proven correct (mount / enumerate / read / write /
create, cross-checked with upstream `ntfsls`/`ntfsfix`); only the OS *loading* of the extension
depends on code-signing/provisioning that's tied to your Apple Developer account.

## The six features

1. **Localization (English + Simplified Chinese)** — `xntfs/Localizable.xcstrings` (String Catalog). Add more
   languages by adding `localizations` entries.
2. **Auto-mount removable NTFS** — handled by the **system**, not the app: the extension's
   `Info.plist` registers NTFS `FSMediaTypes` (`Windows_NTFS`, MS Basic-Data GUID, partitionless),
   so DiskArbitration auto-mounts NTFS drives read-write under `/Volumes` using our module — with
   no app process running (same model as the built-in exFAT/MSDOS modules). `FSProbeOrder` governs
   priority over the legacy read-only NTFS driver. The app only *detects/lists* drives for the UI.
3. **Mount location** — drives mount under `/Volumes/<name>`; the system picks the path and
   de-duplicates names. Mounting to a **custom folder is not possible** for a sandboxed FSKit
   volume (the extension can only reach `/Volumes` and its own sandbox temp paths), so
   `/Volumes` is the only target.
4. **Multiple drives at once** — devices are tracked by BSD name and mounted independently.
5. **Manual mount / unmount** — per-device *Eject* and *Reveal in Finder*. A sandboxed app can't
   mount a third-party FSKit volume itself, so to (re)mount an unmounted NTFS volume the app
   offers an *Open Disk Utility* button — mount it there (Disk Utility mounts via
   `diskarbitrationd`, the same path the system auto-mounts with).
6. **Disk images** — attach a raw NTFS image in **Disk Utility** (*File ▸ Open Disk Image…*, or
   double-click it); xntfs then auto-mounts the NTFS volume on the attached device and lists it
   under *Disk Images*. The app links to Disk Utility rather than running `hdiutil` itself (the
   sandbox blocks `Process`).

## Build

The repo is a normal Xcode project — open `xntfs.xcodeproj` and build the `xntfs` scheme.
Build settings for the extension (bridging header, `libntfs-3g.a` link, header search paths,
`HAVE_CONFIG_H`, arm64) and the app (entitlements, zh-Hans region) are already committed; they
were applied with `scripts/wire_project.rb` (re-runnable, idempotent, needs the `xcodeproj` gem).

`libntfs-3g.a` is prebuilt at `ntfs-3g/libntfs-3g/.libs/`. To rebuild it (arm64):
```sh
cd ntfs-3g
glibtoolize --force --copy --install
LIBTOOLIZE=glibtoolize autoreconf -fi -I m4
./configure --disable-shared --enable-static --disable-ntfs-3g --disable-ntfsprogs \
            --disable-crypto --disable-nls \
            CC=clang CFLAGS="-arch arm64 -isysroot $(xcrun --show-sdk-path) -mmacosx-version-min=13.0 -O2"
make -C libntfs-3g
```
> Currently **arm64 only** (that's what `libntfs-3g.a` is built for; the `ntfs3g` target is
> pinned to `arm64`). For Intel/universal, build libntfs-3g for `x86_64` too and `lipo` them,
> then drop the `ARCHS=arm64` pin.

## Provisioning (required to actually run the extension)

The extension declares the **restricted** entitlement `com.apple.developer.fskit.fsmodule`
(`ntfs3g/ntfs3g.entitlements`). macOS (AMFI) refuses to load the extension unless that entitlement
is authorized by a provisioning profile. With **automatic signing** and team `529LJDH392`, this
works only if that team's App ID has the **FSKit File System Module** capability enabled in the
Apple Developer portal. Once provisioned, enable the module under **System Settings → General →
Login Items & Extensions → File System Extensions**.

## Sandbox & mounting

Verified on macOS 26.5 with the sandboxed build:

- **Auto-mount is the main path.** The system mounts NTFS drives read-write under `/Volumes` via
  the extension's `FSMediaTypes` — no app process, no extra entitlement. Fully working.
- **A sandboxed app can't mount a third-party FSKit volume itself.** A DiskArbitration mount is
  refused (`kDAReturnNotPrivileged`) and `mount -F -t xntfs …` is denied at the FSKit probe
  ("Permission denied"). So manual (re)mounting and attaching disk images are delegated to
  **Disk Utility**, which mounts via `diskarbitrationd` — the same path auto-mount uses.
- **The app never shells out.** The sandbox blocks `Process` (`hdiutil`, `mount`, …); the app's
  role is detection, listing, and a one-click jump to Disk Utility.

> This is a *technical* capability result; App Review is a separate policy gate.

## Layout

```
xntfs/                     app target (SwiftUI)
  xntfsApp.swift           @main App + Settings scene
  ContentView.swift        device/image list + detail; opens Disk Utility for mount/attach
  DiskUtility.swift        opens Apple's Disk Utility (mount / attach images)
  MountSheet.swift         in-app mount sheet (currently disabled)
  CopyableCommand.swift    copyable-command control (used by the diagnostics page)
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
