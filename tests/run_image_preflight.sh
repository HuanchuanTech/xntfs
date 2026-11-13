#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
mode="${1:-test}"
mkdir -p "$root/_tmp"
work="${2:-$(mktemp -d "$root/_tmp/image-preflight.XXXXXX")}"
mkdir -p "$work"
sources="${NFSK_HOST_SOURCE_ROOT:-$root}"
service="${NFSK_IMAGE_SERVICE_SOURCE:-$sources/xntfs/Services/ImageMountService.swift}"
cflags=(-g -Wall -Wextra -mmacosx-version-min=15.4)
swiftflags=(-g -parse-as-library -swift-version 5 -default-isolation MainActor -target "$(uname -m)-apple-macos15.4")
case "${NFSK_SANITIZE:-}" in
    # dyld can call interposed read/close before ASan initialization. Instrument
    # the production Swift, but leave this loader-visible test shim uninstrumented.
    address) swiftflags+=(-sanitize=address) ;;
    thread) cflags+=(-fsanitize=thread -fno-omit-frame-pointer); swiftflags+=(-sanitize=thread) ;;
    "") ;;
    *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
case "$mode" in
    test) harness="$sources/tests/test_image_preflight.swift" ;;
    benchmark) harness="$sources/tests/benchmark_image_preflight.swift"; cflags+=(-O2); swiftflags+=(-O) ;;
    baseline-benchmark) harness="$sources/tests/benchmark_image_preflight.swift"; cflags+=(-O2); swiftflags+=(-O -DNFSK_BASELINE) ;;
    *) printf 'Expected test, benchmark or baseline-benchmark\n' >&2; exit 2 ;;
esac
services=()
for file in "$sources/xntfs/Services/"*.swift; do
    if [[ "$file" == */ImageMountService.swift ]]; then services+=("$service"); else services+=("$file"); fi
done
xcrun clang "${cflags[@]}" -dynamiclib "$sources/tests/image_preflight_gate.c" \
    -install_name "$work/image-gate.dylib" -o "$work/image-gate.dylib"
xcrun swiftc "${swiftflags[@]}" \
    -import-objc-header "$sources/tests/image_preflight_gate.h" "$work/image-gate.dylib" \
    "$sources/Shared/DiagnosticRecorder.swift" "$sources/xntfs/Model/NTFSDevice.swift" \
    "${services[@]}" "$harness" -o "$work/runner"
if [[ "$mode" == test ]]; then
    "$work/runner" "$work" 2>&1 | tee "$work/results.log"
fi
printf 'Test artifacts: %s\n' "$work"
