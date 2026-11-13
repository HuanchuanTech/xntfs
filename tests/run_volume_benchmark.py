#!/usr/bin/env python3
"""Uninstrumented Swift volume A/B, followed by separate diagnostic traces.

Uses disposable regular images with the production file backend, never OS mounts.
Baseline directory contains ntfs3gVolume.swift and the three bridge source files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with path.open("rb") as stream:
        h = hashlib.sha256()
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(part)
        return h.hexdigest()


def trace_source(source):
    start = source.index("    private func withIO<T>")
    end = source.index("    private func refreshStatistics()", start)
    part = source[start:end]
    substitutions = [
        ("            ioQueue.async(execute:",
         "            let perfEnqueued = VolumeTrace.now(), perfID = VolumeTrace.requestID\n"
         "            ioQueue.async(execute:"),
        ("                let result =", "                let perfStarted = VolumeTrace.now()\n                let result ="),
        ("                refreshStatistics()", "                let perfBody = VolumeTrace.now()\n                refreshStatistics()"),
        # Match the queued completion's exact indentation. An admission failure
        # resumes earlier, before any perfID/work-item timestamps exist.
        ("\n                continuation.resume", "\n                VolumeTrace.record(perfID, perfEnqueued, perfStarted, perfBody, VolumeTrace.now())\n"
         "                continuation.resume"),
    ]
    for before, after in substitutions:
        if part.count(before) != 2:
            raise RuntimeError("withIO changed; review diagnostic injection: " + before)
        part = part.replace(before, after)
    source = source[:start] + part + source[end:]
    start = source.index("    private func replyWithItem(")
    end = source.index("    private func item(", start)
    part = source[start:end]
    for before, after in [
        ("        ioQueue.async(execute:",
         "        let perfEnqueued = VolumeTrace.now(), perfID = VolumeTrace.requestID\n        ioQueue.async(execute:"),
        ("            let result = Result", "            let perfStarted = VolumeTrace.now()\n            let result = Result"),
        ("            refreshStatistics()", "            let perfBody = VolumeTrace.now()\n            refreshStatistics()"),
        ("            switch result {", "            VolumeTrace.record(perfID, perfEnqueued, perfStarted, perfBody, VolumeTrace.now())\n            switch result {"),
    ]:
        if part.count(before) != 1:
            raise RuntimeError("replyWithItem changed; review diagnostic injection: " + before)
        part = part.replace(before, after)
    return source[:start] + part + source[end:]


def summary_record(record, diagnostic):
    # Raw samples stay in the per-run JSONL. Keeping every latency/trace array
    # across rounds makes the analysis process grow with the full sample count.
    result = {key: value for key, value in record.items() if key not in ("samples_ns", "traces")}
    if diagnostic:
        result["mean_phase_ns"] = dict(zip(record["trace_columns"],
            [statistics.mean(column) for column in zip(*record["traces"])]))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--baseline-dir", required=True, type=Path)
    parser.add_argument("--candidate-dir", type=Path, default=ROOT / "ntfs3g")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--suite", choices=("xattrs", "directory", "lookup"), default="xattrs")
    parser.add_argument("--samples", type=int, help="per-workload samples (128...16384); keeps historical defaults when omitted")
    parser.add_argument("--diagnostic-samples", type=int, help="separate trace sample count (128...16384)")
    parser.add_argument("--workload", action="append", help="select a workload in the suite; may be repeated")
    parser.add_argument("--library-dir", type=Path, default=ROOT / "build/libntfs-universal")
    args = parser.parse_args()
    # Check the supplied path before resolve(), which would hide a symlink.
    if not args.fixture.is_file() or args.fixture.is_symlink() or not 1 <= args.rounds <= 31:
        parser.error("expected a regular image and 1...31 rounds")
    for count in (args.samples, args.diagnostic_samples):
        if count is not None and not 128 <= count <= 16384:
            parser.error("sample counts must be 128...16384")
    available = ({"lookup." + name for name in ("ascii", "casefold", "long-ascii", "unicode", "long-unicode", "prefix-unicode", "miss")}
                 if args.suite == "lookup" else {f"directory.{kind}.{mode}" for kind in ("ordinary", "mixed", "links")
                  for mode in ("names7", "attrs7", "attrs64")} if args.suite == "directory"
                 else {"attributes", "bench.small", "bench.large", "bench.empty", "list"})
    if args.workload and (len(set(args.workload)) != len(args.workload) or not set(args.workload) <= available):
        parser.error("workloads must be unique members of the selected suite")
    for name in ("fixture", "baseline_dir", "candidate_dir", "output", "library_dir"):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=False)
    harness = args.output / "harness"
    harness.mkdir()
    for name in ("benchmark_volume.swift", "volume_performance.c", "volume_performance.h", "directory_packer.h", "directory_packer.m", "run_volume_benchmark.py"):
        shutil.copyfile(ROOT / "tests" / name, harness / name)
    for path in (ROOT / "ntfs3g/ntfs3gFileSystem.swift", ROOT / "ntfs3g/ntfs3gItem.swift", ROOT / "Shared/DiagnosticRecorder.swift"):
        shutil.copyfile(path, harness / path.name)
    env = dict(os.environ)
    env["NFSK_BENCH_SUITE"] = args.suite
    for key in ("NFSK_BENCH_SAMPLES", "NFSK_BENCH_WORKLOADS"):
        env.pop(key, None)
    if args.samples is not None:
        env["NFSK_BENCH_SAMPLES"] = str(args.samples)
    if args.workload:
        env["NFSK_BENCH_WORKLOADS"] = ",".join(args.workload)
    env.pop("SDKROOT", None)
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()

    def run(command, **kwargs):
        command = [str(x) for x in command]
        cwd = kwargs.pop("cwd", args.output)
        local_env = kwargs.pop("env", env)
        manifest["commands"].append({"argv": command, "cwd": str(cwd),
            "benchmark_env": {k: local_env[k] for k in ("NFSK_BENCH_SUITE", "NFSK_BENCH_SAMPLES", "NFSK_BENCH_WORKLOADS") if k in local_env}})
        (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return subprocess.run(command, cwd=cwd, env=local_env, check=True, timeout=300, **kwargs)

    arch = platform.machine()
    cflags = ["-O2", "-g", "-Werror", "-arch", arch, "-mmacosx-version-min=15.4", "-DHAVE_CONFIG_H=1",
              "-I" + str(args.library_dir), "-I" + str(ROOT / "ntfs-3g/include")]
    swiftflags = ["-O", "-warnings-as-errors", "-whole-module-optimization", "-swift-version", "5", "-parse-as-library",
                  "-target", arch + "-apple-macos15.4"]
    manifest = {"created": time.time(), "platform": platform.platform(), "cflags": cflags,
                "swiftflags": swiftflags, "sdk": env["SDKROOT"], "rounds": args.rounds, "suite": args.suite,
                "fixture_sha256": digest(args.fixture), "library_sha256": digest(args.library_dir / "libntfs-3g.a"),
                "config_sha256": digest(args.library_dir / "config.h"), "sources": {}, "binaries": {},
                "harness": {p.name: digest(p) for p in harness.iterdir()},
                "scope": "warm ordinary-file backend; actual Swift volume, not physical FSKit dispatch",
                "timing": "uninstrumented; includes payload/name correctness checks; alternating pairs",
                "trace": "separate diagnostics; direct bridge calls with inclusive durations; internal library calls are not redirected; observer overhead included",
                "samples": args.samples, "diagnostic_samples": args.diagnostic_samples, "workloads": args.workload,
                "commands": [], "readonly_image_sha256": {}}
    for compiler in ("clang", "swiftc"):
        manifest[compiler] = subprocess.check_output(["xcrun", compiler, "--version"], env=env, text=True)
    binaries = {}
    for label, source in (("baseline", args.baseline_dir), ("candidate", args.candidate_dir)):
        folder = args.output / label
        folder.mkdir()
        frozen = folder / "source"
        frozen.mkdir()
        shutil.copyfile(source / "ntfs3gVolume.swift", frozen / "ntfs3gVolume.swift")
        bridge = source / "bridge" if (source / "bridge").is_dir() else source
        for name in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m"):
            shutil.copyfile(bridge / name, frozen / name)
        manifest["sources"][label] = {p.name: digest(p) for p in frozen.iterdir()}
        numeric_statistics = "nfsk_statfs_counters_t" in (frozen / "ntfs_fskit.h").read_text()
        for mode in ("clean", "trace"):
            build = folder / mode
            build.mkdir()
            trace = mode == "trace"
            local = cflags + ["-I" + str(frozen), "-I" + str(harness)]
            redirects = ["-Dntfs_inode_open=nfsk_perf_inode_open", "-Dntfs_inode_close=nfsk_perf_inode_close",
                         "-Dntfs_inode_real_close=nfsk_perf_inode_real_close", "-Dntfs_attr_open=nfsk_perf_attr_open",
                         "-Dntfs_attr_close=nfsk_perf_attr_close",
                         "-Dntfs_mbstoucs=nfsk_perf_mbstoucs",
                         "-Dnfsk_statfs=nfsk_perf_original_statfs", "-Dntfs_make_symlink=nfsk_perf_make_symlink",
                         "-Dntfs_get_reparse_point=nfsk_perf_get_reparse_point"] if trace else []
            if trace and numeric_statistics:
                redirects.append("-Dnfsk_statfs_counters=nfsk_perf_original_statfs_counters")
            with (build / "build.log").open("w") as log:
                run(["xcrun", "clang", *local, *redirects, "-c", frozen / "ntfs_fskit.c", "-o", build / "bridge.o"], stdout=log, stderr=log)
                run(["xcrun", "clang", *local, "-fobjc-arc", "-fmodules", *(["-Dpread=nfsk_perf_pread"] if trace else []),
                     "-c", frozen / "ntfs_device_fskit.m", "-o", build / "backend.o"], stdout=log, stderr=log)
                run(["xcrun", "clang", *local, *(["-DNFSK_PERF_TRACE"] if trace else []),
                     *(["-DNFSK_PERF_STATFS_COUNTERS"] if trace and numeric_statistics else []),
                     "-c", harness / "volume_performance.c", "-o", build / "counters.o"], stdout=log, stderr=log)
                run(["xcrun", "clang", *local, "-fobjc-arc", "-fmodules", "-c", harness / "directory_packer.m",
                     "-o", build / "packer.o"], stdout=log, stderr=log)
                volume = frozen / "ntfs3gVolume.swift"
                if trace:
                    volume = build / "ntfs3gVolume.swift"
                    volume.write_text(trace_source((frozen / volume.name).read_text()))
                binary = build / "benchmark"
                run(["xcrun", "swiftc", *swiftflags, *(["-DNFSK_PERF_TRACE"] if trace else []),
                     "-import-objc-header", harness / "volume_performance.h", "-I" + str(frozen),
                     harness / "benchmark_volume.swift", volume, harness / "ntfs3gFileSystem.swift",
                     harness / "ntfs3gItem.swift", harness / "DiagnosticRecorder.swift",
                     build / "bridge.o", build / "backend.o", build / "counters.o", build / "packer.o",
                     args.library_dir / "libntfs-3g.a", "-framework", "FSKit", "-framework", "Foundation",
                     "-framework", "DiskArbitration", "-o", binary], stdout=log, stderr=log)
            binaries[label, mode] = binary
            manifest["binaries"][label + "-" + mode] = digest(binary)
    prepared, disposable = args.output / "prepared.img", args.output / "measure.img"
    rows, diagnostics = [], []
    try:
        shutil.copyfile(args.fixture, prepared)
        with (args.output / "prepare.log").open("w") as log:
            run([binaries["baseline", "clean"], "prepare", prepared], stdout=log, stderr=log)
        manifest["prepared_sha256"] = digest(prepared)
        (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        runs = [(str(i + 1), label, "clean") for i in range(args.rounds)
                for label in (("baseline", "candidate") if i % 2 == 0 else ("candidate", "baseline"))]
        runs += [("diagnostic", label, "trace") for label in ("baseline", "candidate")]
        for repetition, label, mode in runs:
            shutil.copyfile(prepared, disposable)
            prefix = args.output / (repetition + "-" + label)
            with prefix.with_suffix(".jsonl").open("w") as result, prefix.with_suffix(".log").open("w") as log:
                local_env = dict(env)
                if mode == "trace" and args.diagnostic_samples is not None:
                    local_env["NFSK_BENCH_SAMPLES"] = str(args.diagnostic_samples)
                run([binaries[label, mode], "measure", disposable], env=local_env, stdout=result, stderr=log)
            after = digest(disposable)
            manifest["readonly_image_sha256"][prefix.name] = after
            if after != manifest["prepared_sha256"]:
                raise RuntimeError("read-only measurement changed its image: " + prefix.name)
            with prefix.with_suffix(".jsonl").open() as result:
                for line in result:
                    record = dict(round=repetition, variant=label, **json.loads(line))
                    (rows if mode == "clean" else diagnostics).append(summary_record(record, mode == "trace"))
            print("PASS", repetition, label, flush=True)
        summary = {}
        for workload, concurrency in sorted({(r["workload"], r["concurrency"]) for r in rows}):
            matching = [r for r in rows if (r["workload"], r["concurrency"]) == (workload, concurrency)]
            result = {}
            for metric in ("wall_ns", "cpu_ns", "p50_ns", "p95_ns", "p99_ns", "rss_bytes"):
                a, b = [[r[metric] for r in sorted(matching, key=lambda r: int(r["round"])) if r["variant"] == label]
                        for label in ("baseline", "candidate")]
                changes = [100 * (x - y) / x for x, y in zip(a, b)]
                result[metric] = {"baseline_median": statistics.median(a), "candidate_median": statistics.median(b),
                                  "paired_improvement_pct": changes, "median_improvement_pct": statistics.median(changes)}
            result["diagnostics"] = {}
            for row in diagnostics:
                if (row["workload"], row["concurrency"]) != (workload, concurrency):
                    continue
                d = {k: row[k] for k in ("operations", "pread_calls", "pread_bytes", "pread_ns", "inode_opens", "attr_opens", "statfs_calls", "statfs_ns", "symlink_parses",
                    "inode_open_ns", "inode_closes", "inode_close_ns", "attr_open_ns", "attr_closes", "attr_close_ns",
                    "mbstoucs_calls", "mbstoucs_ns", "reparse_validations", "reparse_validation_ns")}
                d["mean_phase_ns"] = row["mean_phase_ns"]
                result["diagnostics"][row["variant"]] = d
            summary[workload + "/" + str(concurrency)] = result
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        for name, result in summary.items():
            print(name, "wall improvement %.1f%%" % result["wall_ns"]["median_improvement_pct"])
    finally:
        prepared.unlink(missing_ok=True)
        disposable.unlink(missing_ok=True)
        manifest["fixture_unchanged"] = digest(args.fixture) == manifest["fixture_sha256"]
        (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if digest(args.fixture) != manifest["fixture_sha256"]:
        raise RuntimeError("fixture changed")


if __name__ == "__main__":
    main()
