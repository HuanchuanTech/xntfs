# Build and development

## Requirements

- macOS 15.4 or later
- Xcode with the macOS SDK used by the project
- Python 3.9 or later for local validation scripts and timing reports
- Autotools and GNU libtool for rebuilding the bundled ntfs-3g static library
- A signing team whose provisioning profile authorizes the restricted FSKit module entitlement

## Build the NTFS engine

From the repository root:

```sh
./scripts/build-libntfs.sh
lipo -archs build/libntfs-universal/libntfs-3g.a
```

The script builds the ntfs-3g library for `arm64` and `x86_64`, then combines the outputs in `build/libntfs-universal/`. The build directory is ignored by Git and must be regenerated after a clean checkout or an ntfs-3g submodule update.

For an isolated compiler experiment, select a profile and a new output directory:

```sh
./scripts/build-libntfs.sh --profile o3 --output _tmp/libntfs-o3
```

Profiles are `o2` (the default), `o3`, `o2-thinlto`, and `o3-thinlto`. An experimental profile requires explicit output outside `build/libntfs-universal/`; an explicit output directory must not already exist. The script copies clean upstream sources, preserves the feature/cache configuration, and writes `build-manifest.json` with compiler, SDK, flags, source/config/archive hashes, and object types. It does not select the experimental library in Xcode or install an app.

ThinLTO archives contain LLVM bitcode. A consumer must also compile the C/ObjC bridge and perform the final Clang link with `-flto=thin`; an archive alone does not establish an optimized final executable. Keep Swift's optimization setting unchanged when comparing these profiles. The bridge benchmark supports separate libraries and bridge profiles, records final link commands/maps/native LTO objects, limits LTO link workers to two, and removes its private link cache:

```sh
python3 tests/run_bridge_benchmark.py tests/work.ntfs \
  --baseline-dir ntfs3g/bridge \
  --baseline-library-dir _tmp/libntfs-o2 \
  --candidate-library-dir _tmp/libntfs-o3 \
  --candidate-profile o3 --uninstrumented --rounds 7 \
  --output _tmp/libntfs-o2-o3-comparison
```

Build both library directories first. The benchmark also accepts `--baseline-profile os` for a size-optimized bridge while selecting the library independently; check the resolved Xcode/compiler defaults before comparing a Release configuration. `--uninstrumented` omits call counters from timing runs; the harness/checksum code stays native O2 in both variants. Run a separate instrumented comparison for I/O counts. Timings use disposable ordinary files and warm host caches, not an activated FSKit extension or a physical disk. Compare repeated pairs, memory, code size, correctness, and fault results before changing a default.

## Build the Xcode project

Open `xntfs.xcodeproj` and build the `xntfs` scheme. The project already contains the bridging header, library link settings, header search paths, `HAVE_CONFIG_H`, app sandbox settings, and the FSKit extension target.

Before running a local build, select your own signing team in Xcode and configure the FSKit capability. The extension declares `com.apple.developer.fskit.fsmodule`; a successful compile alone does not mean that macOS will load the extension.

For local testing, install the signed app in `/Applications`, enable `ntfs3g` in System Settings, and confirm the module path in the app diagnostics. Do not treat a development build in DerivedData as the production registration.

## Tests

Use [the validation selection guide](testing.md) to choose edit-level checks,
one related batch acceptance pass, and separate installed-system/device tests.
The examples below are independent entry points, not a mandatory full run after
every change. Build the engine again only when its build inputs change.

The repository contains bridge, volume, device classification, compatibility, and mounted-image test runners under `tests/`. The mounted tests require an appropriately signed app, an enabled extension, and disposable NTFS fixtures. Read the relevant test script and compatibility document before testing a physical disk.

Examples:

```sh
bash tests/run_bridge_regressions.sh /path/to/ntfs-clean.img
bash tests/run_volume_regressions.sh /path/to/ntfs-clean.img
bash tests/run_feature_regressions.sh /path/to/ntfs-clean.img
```

An isolated library can also be selected for bridge regression and crash-model checks:

```sh
NFSK_LIBNTFS_DIR=_tmp/libntfs-o3 NFSK_BRIDGE_PROFILE=o3 \
  bash tests/run_bridge_regressions.sh tests/work.ntfs
python3 tests/run_crash_consistency.py --library-dir _tmp/libntfs-o3 \
  --bridge-profile o3 --output _tmp/libntfs-o3-crash
```

These options preserve the default library when omitted. The crash runner reports known baseline power-loss findings as failures; compare recorded states with the baseline rather than treating every interrupted state as guaranteed recoverable. A caller-only sanitizer build does not instrument a prebuilt library.

Mounted macOS 27 image tests require the signed app and a raw single-volume NTFS image; see [macOS 27 support](macos27-support.md). macOS 15's manual mounting behavior is documented separately in [macOS 15 compatibility](macos15-compatibility.md).

## Signing and distribution boundary

The App Store build and local development build have different signing and provisioning requirements. The FSKit entitlement is restricted, and the user must enable the extension in System Settings. See [the compatibility and App Review notes](macos15-compatibility.md) before adding privileged commands or filesystem resources to a distribution build.
