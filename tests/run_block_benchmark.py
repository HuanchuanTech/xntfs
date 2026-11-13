#!/usr/bin/env python3
"""Seven alternating comparisons of the memory resource, not a physical device."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import shutil

ROOT = Path(__file__).resolve().parent.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-dir", required=True, type=Path)
    parser.add_argument("--candidate-dir", type=Path, default=ROOT / "ntfs3g/bridge")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=7)
    args = parser.parse_args()
    if args.rounds < 1: parser.error('rounds must be positive')
    args.baseline_dir = args.baseline_dir.resolve()
    args.candidate_dir = args.candidate_dir.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    harness = args.output / "test_block_backend.m"
    shutil.copyfile(ROOT / "tests/test_block_backend.m", harness)
    shutil.copyfile(Path(__file__), args.output / "run_block_benchmark.py")
    shutil.copyfile(ROOT / "tests/run_block_backend.sh", args.output / "run_block_backend.sh")
    manifest = {"backend": "memory selectors, no FSKit resource", "rounds": args.rounds,
                "flags": "-O2 -g -fobjc-arc -mmacosx-version-min=15.4, native architecture",
                "timing": "No backend allocation hooks; memory-resource selector counters remain; 50 ms CPU warm-up per phase",
                "diagnostics": "Separate binaries with allocator hooks; counters only, not timing claims",
                "harness_sha256": sha(harness)}
    env = dict(os.environ)
    env.pop("SDKROOT", None)
    manifest["compiler"] = subprocess.check_output(["xcrun", "clang", "--version"], env=env, text=True)
    manifest["sdk"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
    binaries = {}
    for label, source in (("baseline", args.baseline_dir), ("candidate", args.candidate_dir)):
        frozen_source = args.output / (label + "-source")
        frozen_source.mkdir()
        for name in ("ntfs_device_fskit.m", "ntfs_fskit.h"):
            shutil.copyfile(source / name, frozen_source / name)
        source = frozen_source
        for mode in ['clean', 'trace']:
            output = args.output / (label + '-' + mode)
            env = dict(os.environ, NFSK_BLOCK_OUTPUT=str(output), NFSK_BLOCK_HARNESS=str(harness),
                       NFSK_BLOCK_ALLOCATION_HOOKS='0' if mode == 'clean' else '1')
            env.pop("NFSK_SANITIZE", None)
            env.pop("SDKROOT", None)
            subprocess.run(["bash", "tests/run_block_backend.sh", "build", str(source)],
                           cwd=ROOT, env=env, check=True, timeout=120)
            binaries[label, mode] = output / "test-backend"
            manifest[label + '-' + mode] = {"source_sha256": sha(source / "ntfs_device_fskit.m"),
                                           "header_sha256": sha(source / 'ntfs_fskit.h'),
                                           "binary_sha256": sha(binaries[label, mode])}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    results, diagnostics = {}, {}
    for iteration in range(args.rounds):
        order = ("baseline", "candidate") if iteration % 2 == 0 else ("candidate", "baseline")
        for label in order:
            result = args.output / (str(iteration + 1) + "-" + label + ".csv")
            with result.open("w") as stream:
                subprocess.run([str(binaries[label, 'clean']), "benchmark"], cwd=ROOT, stdout=stream, check=True, timeout=120)
            with result.open() as stream:
                for row in csv.DictReader(stream):
                    key = row["sector"] + "/" + row["workload"]
                    results.setdefault(key, {}).setdefault(label, []).append(row)
            print("PASS", iteration + 1, label, flush=True)
    for label in ['baseline', 'candidate']:
        result = args.output / ('diagnostic-' + label + '.csv')
        with result.open('w') as stream:
            subprocess.run([str(binaries[label, 'trace']), 'benchmark'], cwd=ROOT, stdout=stream, check=True, timeout=120)
        with result.open() as stream:
            for row in csv.DictReader(stream):
                key = row['sector'] + '/' + row['workload']
                diagnostics.setdefault(key, {})[label] = row
    summary = {}
    for key, result in results.items():
        pairs = [(int(a["wall_ns"]) - int(b["wall_ns"])) / int(a["wall_ns"]) * 100
                 for a, b in zip(result["baseline"], result["candidate"])]
        cpu_pairs = [(int(a["cpu_ns"]) - int(b["cpu_ns"])) / int(a["cpu_ns"]) * 100
                     for a, b in zip(result["baseline"], result["candidate"])]
        rng = random.Random(20261107)
        estimates = sorted(statistics.median(rng.choices(pairs, k=len(pairs))) for _ in range(10000))
        summary[key] = {"median_improvement_pct": statistics.median(pairs), "paired_improvement_pct": pairs,
                        "paired_median_bootstrap_95_pct": [estimates[249], estimates[9749]],
                        "median_cpu_improvement_pct": statistics.median(cpu_pairs), "paired_cpu_improvement_pct": cpu_pairs,
                        "timing_medians": {label: {metric: statistics.median(int(row[metric]) for row in result[label])
                                                   for metric in ['wall_ns', 'cpu_ns']}
                                           for label in ['baseline', 'candidate']},
                        "baseline": diagnostics[key]['baseline'], "candidate": diagnostics[key]['candidate']}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: round(v["median_improvement_pct"], 2) for k, v in summary.items()}, indent=2))


if __name__ == "__main__":
    main()
