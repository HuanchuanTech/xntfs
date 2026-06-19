#!/bin/sh
# Build libntfs-3g.a (static, arm64 macOS) for the FSKit extension.
#
# Run this ON macOS — it uses xcrun + clang to produce an arm64 Mach-O archive.
# (Do NOT run it in a Linux container; you'd get a Linux ELF .a that won't link.)
#
# ntfs-3g/ is a pristine git submodule (tuxera/ntfs-3g, tag 2026.2.25). The
# upstream tree has no m4/libgcrypt.m4, so we drop in our no-op stub before
# autoreconf to resolve AM_PATH_LIBGCRYPT. We build --disable-crypto, so the
# real libgcrypt is never used.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ntfs-3g"

cp "$ROOT/scripts/ntfs3g/libgcrypt.m4" m4/libgcrypt.m4

glibtoolize --force --copy --install
LIBTOOLIZE=glibtoolize autoreconf -fi -I m4
./configure --disable-shared --enable-static \
  --disable-ntfs-3g --disable-ntfsprogs --disable-crypto --disable-nls \
  CC=clang \
  CFLAGS="-arch arm64 -isysroot $(xcrun --show-sdk-path) -mmacosx-version-min=13.0 -O2"
make -C libntfs-3g

echo "Built: $ROOT/ntfs-3g/libntfs-3g/.libs/libntfs-3g.a"
