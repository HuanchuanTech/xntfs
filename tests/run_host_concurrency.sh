#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "$root/_tmp"
work="$(mktemp -d "$root/_tmp/host-concurrency.XXXXXX")"
xcrun clang -Wall -Wextra -mmacosx-version-min=15.4 -dynamiclib "$root/tests/host_query_guard.c" \
    -install_name "$work/query-guard.dylib" -o "$work/query-guard.dylib"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -import-objc-header "$root/tests/host_query_guard.h" "$work/query-guard.dylib" \
    -target "$(uname -m)-apple-macos15.4" \
    "$root/Shared/DiagnosticRecorder.swift" "$root/xntfs/Model/NTFSDevice.swift" \
    "$root/xntfs/Services/"*.swift "$root/tests/test_host_concurrency.swift" \
    -o "$work/test-host-concurrency"
"$work/test-host-concurrency" 2>&1 | tee "$work/results.log"
printf 'Test artifacts: %s\n' "$work"
