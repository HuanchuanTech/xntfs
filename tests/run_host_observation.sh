#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
parent="${OBSERVATION_WORK_PARENT:-$root/_tmp}"
mkdir -p "$parent"
work="$(mktemp -d "$parent/host-observation.XXXXXX")"
printf 'Test artifacts: %s\n' "$work"
flags=(-g)
if [[ -n "${SANITIZE:-}" ]]; then flags+=("-fsanitize=$SANITIZE"); fi
xcrun clang -fblocks -Wall -Wextra -Werror -mmacosx-version-min=15.4 "${flags[@]}" \
    -c "$root/tests/host_observation_shim.c" -o "$work/observation.o"
# stat can run during sanitizer initialization. Keep that small atomic-only guard
# uninstrumented; the DA fixture and production Swift remain instrumented.
xcrun clang -g -Wall -Wextra -Werror -mmacosx-version-min=15.4 \
    -c "$root/tests/host_query_guard.c" -o "$work/query-guard.o"
xcrun clang -mmacosx-version-min=15.4 "${flags[@]}" \
    -dynamiclib "$work/observation.o" "$work/query-guard.o" \
    -framework DiskArbitration -framework IOKit -framework CoreFoundation \
    -install_name "$work/observation-shim.dylib" -o "$work/observation-shim.dylib"
flags=(-g)
if [[ -n "${SANITIZE:-}" ]]; then flags+=("-sanitize=$SANITIZE"); fi
xcrun swiftc -O -parse-as-library -swift-version 5 -default-isolation MainActor "${flags[@]}" \
    -target "$(uname -m)-apple-macos15.4" -import-objc-header "$root/tests/host_observation_shim.h" \
    "$work/observation-shim.dylib" "$root/xntfs/Model/NTFSDevice.swift" \
    "${OBSERVATION_MONITOR_SOURCE:-$root/xntfs/Services/DiskArbitrationMonitor.swift}" \
    "$root/tests/test_host_observation.swift" -o "$work/test-host-observation"
"$work/test-host-observation" "$@" 2>&1 | tee "$work/results.log"
