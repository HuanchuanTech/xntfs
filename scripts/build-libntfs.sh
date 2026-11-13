#!/bin/bash
# Build a universal macOS libntfs-3g archive for the FSKit extension.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/ntfs-3g"
OUTPUT="$ROOT/build/libntfs-universal"
PROFILE=o2
EXPLICIT_OUTPUT=false

usage() {
  cat <<'EOF'
Usage: scripts/build-libntfs.sh [--profile o2|o3|o2-thinlto|o3-thinlto] [--output DIR]

With no arguments, rebuild the formal O2 universal archive as before.
Experimental profiles require a new, explicit output directory outside the
formal build/libntfs-universal directory. They do not change Xcode settings.
ThinLTO consumers must also enable ThinLTO for bridge compilation and final link.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      PROFILE="$2"; shift 2 ;;
    --output)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      OUTPUT="$2"; EXPLICIT_OUTPUT=true; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$PROFILE" in
  o2) OPT_FLAGS=(-O2) ;;
  o3) OPT_FLAGS=(-O3) ;;
  o2-thinlto) OPT_FLAGS=(-O2 -flto=thin) ;;
  o3-thinlto) OPT_FLAGS=(-O3 -flto=thin) ;;
  *) usage >&2; exit 2 ;;
esac
if [[ "$PROFILE" != o2 && "$EXPLICIT_OUTPUT" != true ]]; then
  echo 'Experimental profiles require --output with a new directory.' >&2
  exit 2
fi
OUTPUT="$(python3 - "$ROOT/build/libntfs-universal" "$OUTPUT" "$PROFILE" "$EXPLICIT_OUTPUT" <<'PY'
from pathlib import Path
import sys
formal, output = (Path(p).resolve() for p in sys.argv[1:3])
if sys.argv[3] != 'o2' and (output == formal or output.is_relative_to(formal)):
    raise SystemExit('Experimental output must be outside the formal library directory.')
if sys.argv[4] == 'true' and output.exists():
    raise SystemExit('Explicit output must be a new directory; refusing to overwrite existing files.')
print(output)
PY
)"

if ! git -C "$SOURCE" diff --quiet || ! git -C "$SOURCE" diff --cached --quiet; then
  echo 'ntfs-3g has tracked changes; the clean source copy would omit them.' >&2
  exit 1
fi
SOURCE_REV="$(git -C "$SOURCE" rev-parse HEAD)"

mkdir -p "$ROOT/_tmp"
WORK="$(mktemp -d "$ROOT/_tmp/libntfs-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source"

git -C "$SOURCE" archive "$SOURCE_REV" | tar -xf - -C "$WORK/source"
cp "$ROOT/scripts/ntfs3g/libgcrypt.m4" "$WORK/source/m4/libgcrypt.m4"
(
  cd "$WORK/source"
  glibtoolize --force --copy --install
  LIBTOOLIZE=glibtoolize autoreconf -fi -I m4
)

SDK="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
COMPILER="$(env -u SDKROOT xcrun --find clang)"
BUILD_TRIPLET="$("$WORK/source/config.guess")"
NATIVE_ARCH="$(uname -m)"
if [[ "$NATIVE_ARCH" == aarch64 ]]; then
  NATIVE_ARCH=arm64
fi
for ARCH in arm64 x86_64; do
  case "$ARCH" in
    arm64) HOST_TRIPLET=aarch64-apple-darwin ;;
    x86_64) HOST_TRIPLET=x86_64-apple-darwin ;;
  esac
  CONFIGURE_CACHE=("CC=$COMPILER")
  if [[ "$ARCH" == "$NATIVE_ARCH" ]]; then
    HOST_TRIPLET="$BUILD_TRIPLET"
  else
    # These runtime checks default to incorrect guesses during a cross-build.
    CONFIGURE_CACHE+=(
      ac_cv_func_memcmp_working=yes
      ac_cv_func_lstat_dereferences_slashed_symlink=yes
      ac_cv_func_stat_empty_string_bug=no
    )
  fi
  mkdir -p "$WORK/$ARCH"
  (
    cd "$WORK/$ARCH"
    env -u SDKROOT "${CONFIGURE_CACHE[@]}" \
      CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=15.4 ${OPT_FLAGS[*]}" \
      "$WORK/source/configure" \
        --build="$BUILD_TRIPLET" --host="$HOST_TRIPLET" \
        --disable-shared --enable-static \
        --disable-ntfs-3g --disable-ntfsprogs --disable-crypto --disable-nls
    env -u SDKROOT make -C libntfs-3g
  )
done

if ! cmp -s "$WORK/arm64/config.h" "$WORK/x86_64/config.h"; then
  echo 'The two architectures produced different config.h files; refusing to publish one shared header.' >&2
  diff -u "$WORK/arm64/config.h" "$WORK/x86_64/config.h" >&2 || true
  exit 1
fi

lipo -create \
  "$WORK/arm64/libntfs-3g/.libs/libntfs-3g.a" \
  "$WORK/x86_64/libntfs-3g/.libs/libntfs-3g.a" \
  -output "$WORK/libntfs-3g.a"
lipo "$WORK/libntfs-3g.a" -verify_arch arm64
lipo "$WORK/libntfs-3g.a" -verify_arch x86_64

python3 - "$ROOT" "$WORK" "$PROFILE" "$SDK" "$COMPILER" "$SOURCE_REV" "${OPT_FLAGS[@]}" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
root, work = (Path(p) for p in sys.argv[1:3])
profile, sdk, compiler, source_commit = sys.argv[3:7]
optimization = sys.argv[7:]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
env = {k: v for k, v in os.environ.items() if k != 'SDKROOT'}
manifest = {
    'profile': profile,
    'source_commit': source_commit,
    'compiler': subprocess.check_output([compiler, '--version'], env=env, text=True),
    'compiler_path': compiler, 'sdk': sdk, 'deployment_target': '15.4',
    'optimization_flags': optimization,
    'configure_options': ['--disable-shared', '--enable-static', '--disable-ntfs-3g', '--disable-ntfsprogs', '--disable-crypto', '--disable-nls'],
    'script_sha256': sha(root / 'scripts/build-libntfs.sh'),
    'compatibility_m4_sha256': sha(work / 'source/m4/libgcrypt.m4'),
    'library_sha256': sha(work / 'libntfs-3g.a'), 'architectures': {},
    'consumer_requirement': 'ThinLTO profiles need -flto=thin for bridge compilation and the final Clang link; Swift optimization is unchanged.',
}
for arch in ('arm64', 'x86_64'):
    build = work / arch
    flags = ['-arch', arch, '-isysroot', sdk, '-mmacosx-version-min=15.4', *optimization]
    macros = subprocess.check_output([compiler, *flags, '-DHAVE_CONFIG_H=1', '-I' + str(build),
                                      '-I' + str(work / 'source/include'), '-dM', '-E', '-x', 'c', '-'],
                                     input='#include "config.h"\n#include "ntfs-3g/cache.h"\n', env=env, text=True)
    library = build / 'libntfs-3g/.libs/libntfs-3g.a'
    objects = sorted((build / 'libntfs-3g').glob('*.o'))
    if not objects:
        raise SystemExit('No compiled objects found for ' + arch)
    make_variables = {}
    for line in (build / 'libntfs-3g/Makefile').read_text().splitlines():
        key, sep, value = line.partition(' = ')
        if sep and key in ('CC', 'CFLAGS', 'CPPFLAGS', 'DEFS', 'AM_CFLAGS', 'AM_CPPFLAGS',
                           'libntfs_3g_la_CFLAGS', 'libntfs_3g_la_CPPFLAGS'):
            make_variables[key] = value
    manifest['architectures'][arch] = {
        'cflags': flags, 'config_sha256': sha(build / 'config.h'), 'library_sha256': sha(library),
        'cache_macros': sorted(line for line in macros.splitlines() if line.startswith('#define CACHE_')),
        'archive_members': subprocess.check_output(['ar', 't', str(library)], text=True).splitlines(),
        'object_types': {p.name: subprocess.check_output(['file', '-b', str(p)], text=True).strip() for p in objects},
        'make_variables': make_variables,
        'inherited_flags': {key: os.environ.get(key, '') for key in ('CPPFLAGS', 'LDFLAGS', 'MAKEFLAGS')},
    }
(work / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY

if [[ "$EXPLICIT_OUTPUT" == true ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  mkdir "$OUTPUT" # A concurrent creator must not silently turn this into an overwrite.
else
  mkdir -p "$OUTPUT"
fi
cp "$WORK/arm64/config.h" "$OUTPUT/config.h.tmp.$$"
cp "$WORK/libntfs-3g.a" "$OUTPUT/libntfs-3g.a.tmp.$$"
cp "$WORK/build-manifest.json" "$OUTPUT/build-manifest.json.tmp.$$"
mv "$OUTPUT/config.h.tmp.$$" "$OUTPUT/config.h"
mv "$OUTPUT/libntfs-3g.a.tmp.$$" "$OUTPUT/libntfs-3g.a"
mv "$OUTPUT/build-manifest.json.tmp.$$" "$OUTPUT/build-manifest.json"

echo "Built: $OUTPUT/libntfs-3g.a ($(lipo -archs "$OUTPUT/libntfs-3g.a"))"
