#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/xntfs-report-tests.XXXXXX")"
trap 'rm -r -- "$work"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -target "$(uname -m)-apple-macos15.4" \
    "$root/Shared/DiagnosticRecorder.swift" \
    "$root/xntfs/Model/NTFSDevice.swift" \
    "$root/xntfs/Services/"*.swift \
    "$root/tests/test_problem_reports.swift" \
    -o "$work/test-reports"
"$work/test-reports" "$work"
