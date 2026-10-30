# Build and development

## Requirements

- macOS 15.4 or later
- Xcode with the macOS SDK used by the project
- Autotools and GNU libtool for rebuilding the bundled ntfs-3g static library
- A signing team whose provisioning profile authorizes the restricted FSKit module entitlement

## Build the NTFS engine

From the repository root:

```sh
./scripts/build-libntfs.sh
lipo -archs build/libntfs-universal/libntfs-3g.a
```

The script builds the ntfs-3g library for `arm64` and `x86_64`, then combines the outputs in `build/libntfs-universal/`. The build directory is ignored by Git and must be regenerated after a clean checkout or an ntfs-3g submodule update.

## Build the Xcode project

Open `xntfs.xcodeproj` and build the `xntfs` scheme. The project already contains the bridging header, library link settings, header search paths, `HAVE_CONFIG_H`, app sandbox settings, and the FSKit extension target.

Before running a local build, select your own signing team in Xcode and configure the FSKit capability. The extension declares `com.apple.developer.fskit.fsmodule`; a successful compile alone does not mean that macOS will load the extension.

For local testing, install the signed app in `/Applications`, enable `ntfs3g` in System Settings, and confirm the module path in the app diagnostics. Do not treat a development build in DerivedData as the production registration.

## Tests

The repository contains bridge, volume, device classification, compatibility, and mounted-image test runners under `tests/`. The mounted tests require an appropriately signed app, an enabled extension, and disposable NTFS fixtures. Read the relevant test script and compatibility document before testing a physical disk.

Examples:

```sh
bash tests/run_bridge_regressions.sh /path/to/ntfs-clean.img
bash tests/run_volume_regressions.sh /path/to/ntfs-clean.img
bash tests/run_feature_regressions.sh /path/to/ntfs-clean.img
```

Mounted macOS 27 image tests require the signed app and a raw single-volume NTFS image; see [macOS 27 support](macos27-support.md). macOS 15's manual mounting behavior is documented separately in [macOS 15 compatibility](macos15-compatibility.md).

## Signing and distribution boundary

The App Store build and local development build have different signing and provisioning requirements. The FSKit entitlement is restricted, and the user must enable the extension in System Settings. See [the compatibility and App Review notes](macos15-compatibility.md) before adding privileged commands or filesystem resources to a distribution build.
