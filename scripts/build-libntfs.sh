#!/bin/bash
# Build a universal macOS libntfs-3g archive for the FSKit extension.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/ntfs-3g"
OUTPUT="$ROOT/build/libntfs-universal"

if ! git -C "$SOURCE" diff --quiet || ! git -C "$SOURCE" diff --cached --quiet; then
  echo 'ntfs-3g has tracked changes; the clean source copy would omit them.' >&2
  exit 1
fi

mkdir -p "$ROOT/_tmp"
WORK="$(mktemp -d "$ROOT/_tmp/libntfs-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source"

git -C "$SOURCE" archive HEAD | tar -xf - -C "$WORK/source"
cp "$ROOT/scripts/ntfs3g/libgcrypt.m4" "$WORK/source/m4/libgcrypt.m4"
(
  cd "$WORK/source"
  glibtoolize --force --copy --install
  LIBTOOLIZE=glibtoolize autoreconf -fi -I m4
)

SDK="$(xcrun --sdk macosx --show-sdk-path)"
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
  CONFIGURE_CACHE=(CC=clang)
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
    env "${CONFIGURE_CACHE[@]}" \
      CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=15.4 -O2" \
      "$WORK/source/configure" \
        --build="$BUILD_TRIPLET" --host="$HOST_TRIPLET" \
        --disable-shared --enable-static \
        --disable-ntfs-3g --disable-ntfsprogs --disable-crypto --disable-nls
    make -C libntfs-3g
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

mkdir -p "$OUTPUT"
cp "$WORK/arm64/config.h" "$OUTPUT/config.h.tmp.$$"
cp "$WORK/libntfs-3g.a" "$OUTPUT/libntfs-3g.a.tmp.$$"
mv "$OUTPUT/config.h.tmp.$$" "$OUTPUT/config.h"
mv "$OUTPUT/libntfs-3g.a.tmp.$$" "$OUTPUT/libntfs-3g.a"

echo "Built: $OUTPUT/libntfs-3g.a ($(lipo -archs "$OUTPUT/libntfs-3g.a"))"
