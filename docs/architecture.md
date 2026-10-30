# Architecture and code structure

xntfs has two targets: a small SwiftUI control panel and a sandboxed FSKit file-system extension. The app detects devices, presents status, opens system settings, and provides version-specific mounting guidance. The extension is the component that implements the NTFS file-system operations.

```text
xntfs.app                         SwiftUI app and control panel
  ContentView.swift               device and disk-image views
  Model/NTFSDevice.swift          device identity, mount state, and driver labels
  Services/AppModel.swift         app coordinator
  Services/DiskArbitrationMonitor.swift
                                  device discovery and actual statfs checks
  Services/MountService.swift     macOS 27 mount/unmount path
  Services/ImageMountService.swift
                                  raw single-volume image workflow
  Services/ExtensionStatus.swift  FSKit status and diagnostics
  LegacyMountSheet.swift          macOS 15 manual-mount guidance
  DiagnosticsView.swift           extension diagnostics

ntfs3g.appex                      FSKit file-system extension
  ntfs3gFileSystem.swift          probe, load, unload, and check behavior
  ntfs3gVolume.swift              FSVolume operations
  ntfs3gItem.swift                FSItem operations
  bridge/ntfs_fskit.c             FSKit-to-libntfs operation bridge
  bridge/ntfs_device_fskit.m      block I/O through FSBlockDeviceResource
  libntfs-3g.a                    statically linked NTFS engine
```

## Runtime flow

1. Disk Arbitration reports an NTFS device to the app and the app records its BSD identity.
2. macOS selects the enabled FSKit module for supported NTFS media and mounts it under `/Volumes`.
3. The app reads the actual mount table and `statfs` result before labeling a volume as `xntfs`, `System`, or another driver.
4. The FSKit extension maps file-system requests to the ntfs-3g bridge and performs block I/O through the resource supplied by FSKit.

The app is not a background agent and is not required for normal system auto-mounting after the extension has been enabled. Mounting controls that require additional authorization are kept explicit and follow the macOS version-specific workflows documented in [macOS 15 compatibility](macos15-compatibility.md), [macOS 27 support](macos27-support.md), and the main README.

## Design boundaries

- The extension uses Apple's FSKit user-space model rather than macFUSE or a kernel extension.
- The app does not treat an enabled extension as proof that a particular volume is using it; the mounted file-system type is checked separately.
- Filesystem check and repair are not advertised as supported operations.
- Image support is deliberately limited to the raw, single-volume workflow documented in [macOS 27 support](macos27-support.md).
