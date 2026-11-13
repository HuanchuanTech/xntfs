#!/usr/bin/env python3
"""Run bounded diagnostic lifecycle/fault tests against a frozen instrumented copy."""
import argparse
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
from diagnostic_harness import ROOT, build

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--source', type=Path, default=ROOT / 'Shared/DiagnosticRecorder.swift')
parser.add_argument('--sanitize', choices=['address', 'thread'])
parser.add_argument('--suite', choices=['batches', 'memory'], default='batches')
parser.add_argument('--measure-only', action='store_true', help='Clean memory-cycle observation without injected gates')
args = parser.parse_args()
if args.measure_only and (args.suite != 'memory' or args.sanitize):
    parser.error('--measure-only requires --suite memory without a sanitizer')
output = args.output.resolve()
harness = 'test_diagnostic_memory.swift' if args.suite == 'memory' else 'test_diagnostic_batches.swift'
binary = build(output, args.source, harness, trace=not args.measure_only, sanitize=args.sanitize)
with (output / 'results.log').open('w') as log:
    command = [str(binary), str(output / 'stores')]
    if args.measure_only: command.append('--measure-only')
    result = subprocess.run(command, stdout=log, stderr=log, timeout=75)
print((output / 'results.log').read_text())
raise SystemExit(result.returncode)
