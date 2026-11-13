#!/usr/bin/env python3
"""Paired benchmarks on disposable ordinary files; never OS-mounts images.

Example: python3 tests/run_bridge_benchmark.py tests/work.ntfs \
  --baseline-dir _tmp/perf-20261107/baseline-src --output _tmp/perf-20261107/paired
Instrumentation counts calls made by the bridge, not all libntfs internals.
The backend is production ntfs_device_fskit.m with counted POSIX calls.
"""
import argparse
import csv
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--baseline-dir", required=True, type=Path)
    parser.add_argument("--candidate-dir", type=Path, default=ROOT / "ntfs3g/bridge")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--library-dir", type=Path, default=ROOT / "build/libntfs-universal")
    parser.add_argument("--baseline-library-dir", type=Path)
    parser.add_argument("--candidate-library-dir", type=Path)
    profiles = ("os", "o2", "o3", "o2-thinlto", "o3-thinlto")
    parser.add_argument("--baseline-profile", choices=profiles, default="o2")
    parser.add_argument("--candidate-profile", choices=profiles, default="o2")
    parser.add_argument("--uninstrumented", action="store_true", help="omit call counters for timing compiler profiles")
    args = parser.parse_args()
    for name in ("fixture", "baseline_dir", "candidate_dir", "output", "library_dir"):
        setattr(args, name, getattr(args, name).resolve())
    if not args.fixture.is_file() or args.fixture.is_symlink() or args.rounds < 1:
        parser.error("expected a regular image and positive rounds")
    libraries = {label: (getattr(args, label + "_library_dir") or args.library_dir).resolve()
                 for label in ("baseline", "candidate")}
    for library in libraries.values():
        if not all((library / name).is_file() for name in ("libntfs-3g.a", "config.h")):
            parser.error("each library directory needs libntfs-3g.a and matching config.h")
    args.output.mkdir(parents=True, exist_ok=False)
    harness = args.output / "benchmark_bridge.c"
    shutil.copyfile(ROOT / "tests/benchmark_bridge.c", harness)
    shutil.copyfile(Path(__file__), args.output / "run_bridge_benchmark.py")
    env = dict(os.environ)
    env.pop("SDKROOT", None)  # Ignore a stale inherited CLT SDK; use selected Xcode.
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()

    def run(command, **kwargs):
        return subprocess.run([str(x) for x in command], cwd=ROOT, env=env, check=True, timeout=300, **kwargs)

    flags = ["-g", "-arch", platform.machine(), "-mmacosx-version-min=15.4", "-isysroot", env["SDKROOT"],
             "-DHAVE_CONFIG_H=1", "-I" + str(ROOT / "ntfs-3g/include")]
    redirects = ["ntfs_index_lookup", "ntfs_index_next", "ntfs_ucstombs", "ntfs_inode_open",
                 "ntfs_inode_real_close", "ntfs_attr_open", "ntfs_attr_close", "malloc", "calloc"]
    redirects = ["-D" + symbol + "=nfsk_bench_" + symbol.removeprefix("ntfs_") for symbol in redirects]
    binaries = {}
    manifest = {"created": time.time(), "platform": platform.platform(), "flags": flags,
                "sdk": env["SDKROOT"], "rounds": args.rounds, "cache": "warm host cache, fresh library handle per run",
                "fixture_sha256": digest(args.fixture), "sources": {}, "binaries": {},
                "counter_scope": "disabled; all counter columns are zero" if args.uninstrumented else
                                 "bridge call sites and production file backend POSIX calls; allocations exclude upstream and Foundation",
                "libraries": {}, "builds": {},
                "qos": "user initiated", "cpu_warmup_ms_per_phase": 50}
    manifest["compiler"] = subprocess.check_output(["xcrun", "clang", "--version"], env=env, text=True)
    manifest["settings_scope"] = "fixed native -O2 harness; selected bridge/library profiles; not installed application or physical device"
    manifest["timing_scope"] = "wall includes checksums/loop; call_ns sums timed API calls; directory callback includes name checks"
    for label, source in (("baseline", args.baseline_dir), ("candidate", args.candidate_dir)):
        folder = args.output / label
        folder.mkdir()
        frozen_source = folder / "source"
        frozen_source.mkdir()
        for name in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m"):
            shutil.copyfile(source / name, frozen_source / name)
        source = frozen_source
        library = libraries[label]
        profile = getattr(args, label + "_profile")
        optimization = ["-Os" if profile == "os" else "-O3" if profile.startswith("o3") else "-O2"]
        lto = profile.endswith("thinlto")
        if lto:
            optimization.append("-flto=thin")
        includes = ["-I" + str(source.resolve()), "-I" + str(library)]
        # Frozen directory names must not change __FILE__ string lengths and
        # relocate code/data between otherwise identical A/A binaries.
        local = flags + optimization + includes + ["-ffile-prefix-map=" + str(source.resolve()) + "=ntfs3g/bridge"]
        manifest["sources"][label] = {name: digest(source / name) for name in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m")}
        manifest["libraries"][label] = {"path": str(library), "library_sha256": digest(library / "libntfs-3g.a"),
                                       "config_sha256": digest(library / "config.h")}
        library_manifest = library / "build-manifest.json"
        if library_manifest.is_file():
            manifest["libraries"][label]["build_manifest"] = json.loads(library_manifest.read_text())
        backend_redirects = ["-Dpread=nfsk_bench_pread", "-Dpwrite=nfsk_bench_pwrite", "-Dfsync=nfsk_bench_fsync"]
        commands = [
            ["xcrun", "clang", *local, *([] if args.uninstrumented else redirects), "-c", source / "ntfs_fskit.c", "-o", folder / "bridge.o"],
            ["xcrun", "clang", *local, "-fobjc-arc", *([] if args.uninstrumented else backend_redirects),
             "-c", source / "ntfs_device_fskit.m", "-o", folder / "backend.o"],
            # Native O2 test/checksum code stays outside LTO and identical for both variants.
            ["xcrun", "clang", *flags, "-O2", *includes, "-c", harness, "-o", folder / "harness.o"],
        ]
        binary = folder / "benchmark"
        link_flags = ["-Xlinker", "-map", "-Xlinker", str(folder / "link.map")]
        cache = folder / "lto-cache"
        if lto:
            cache.mkdir()
            link_flags += ["-Wl,-mllvm,-threads=2", "-Xlinker", "-object_path_lto", "-Xlinker", str(folder / "lto-objects"),
                           "-Xlinker", "-cache_path_lto", "-Xlinker", str(cache)]
        commands.append(["xcrun", "clang", *local, folder / "harness.o", folder / "bridge.o", folder / "backend.o",
                         library / "libntfs-3g.a", "-framework", "CoreFoundation", "-framework", "Foundation",
                         "-framework", "FSKit", *link_flags, "-o", binary])
        commands = [[str(x) for x in command] for command in commands]
        (folder / "build-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        try:
            for i, command in enumerate(commands):
                with (folder / ("build-%d.log" % i)).open("w") as log:
                    run(["/usr/bin/time", "-l", *command], stdout=log, stderr=log)
        finally:
            if cache.exists():
                shutil.rmtree(cache)
        objects = sorted((folder / "lto-objects").glob("*.o")) if lto else []
        if lto and not objects:
            raise RuntimeError("ThinLTO link produced no retained native object evidence")
        manifest["builds"][label] = {
            "bridge_profile": profile, "commands": commands, "binary_bytes": binary.stat().st_size,
            "lto_native_objects": {p.name: {"sha256": digest(p), "type": subprocess.check_output(["file", "-b", p], text=True).strip()}
                                   for p in objects},
        }
        with (folder / "binary-size.txt").open("w") as log:
            run(["xcrun", "size", "-m", binary], stdout=log)
        binaries[label] = binary
        manifest["binaries"][label] = digest(binary)
    manifest["harness_sha256"] = digest(harness)
    prepared = args.output / "prepared.img"
    disposable = args.output / "measure.img"
    rows = []
    try:
        shutil.copyfile(args.fixture, prepared)
        with (args.output / "prepare.log").open("w") as log:
            run([binaries["baseline"], "prepare", prepared, "unused"], stdout=log, stderr=log)
        manifest["prepared_sha256"] = digest(prepared)
        (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for repetition in range(args.rounds):
            order = ("baseline", "candidate") if repetition % 2 == 0 else ("candidate", "baseline")
            for label in order:
                shutil.copyfile(prepared, disposable)
                prefix = args.output / (str(repetition + 1) + "-" + label)
                with prefix.with_suffix(".csv").open("w") as result, prefix.with_suffix(".log").open("w") as log:
                    run([binaries[label], "measure", disposable, str(prefix) + "-samples.csv"], stdout=result, stderr=log)
                with prefix.with_suffix(".csv").open() as stream:
                    for row in csv.DictReader(stream):
                        rows.append({"round": repetition + 1, "variant": label, **row})
                print("PASS", repetition + 1, label, flush=True)
        summary = {}
        for workload in sorted({r["workload"] for r in rows}):
            pairs = []
            call_pairs = []
            baseline, candidate = [], []
            for repetition in range(1, args.rounds + 1):
                a, b = [next(r for r in rows if r["workload"] == workload and r["round"] == repetition and r["variant"] == label)
                        for label in ("baseline", "candidate")]
                baseline.append(float(a["wall_ns"]) / 1e6)
                candidate.append(float(b["wall_ns"]) / 1e6)
                pairs.append((float(a["wall_ns"]) - float(b["wall_ns"])) / float(a["wall_ns"]) * 100)
                call_pairs.append((float(a["call_ns"]) - float(b["call_ns"])) / float(a["call_ns"]) * 100)
            summary[workload] = {"baseline_median_ms": statistics.median(baseline),
                                 "candidate_median_ms": statistics.median(candidate),
                                 "paired_improvement_pct": pairs, "median_improvement_pct": statistics.median(pairs),
                                 "paired_call_improvement_pct": call_pairs, "median_call_improvement_pct": statistics.median(call_pairs)}
            metrics = {}
            for metric in ("cpu_ns", "p50_ns", "p95_ns", "p99_ns", "rss_bytes"):
                a, b = [[int(r[metric]) for r in rows if r["workload"] == workload and r["variant"] == label]
                        for label in ("baseline", "candidate")]
                changes = [100 * (x - y) / x for x, y in zip(a, b)]
                metrics[metric] = {"baseline_median": statistics.median(a), "candidate_median": statistics.median(b),
                                   "paired_improvement_pct": changes, "median_improvement_pct": statistics.median(changes)}
            summary[workload]["metrics"] = metrics
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
    finally:
        prepared.unlink(missing_ok=True)
        disposable.unlink(missing_ok=True)
    if digest(args.fixture) != manifest["fixture_sha256"]:
        raise RuntimeError("fixture changed")
    for label, library in libraries.items():
        for name, key in (("libntfs-3g.a", "library_sha256"), ("config.h", "config_sha256")):
            if digest(library / name) != manifest["libraries"][label][key]:
                raise RuntimeError("library/config changed: " + label)


if __name__ == "__main__":
    main()
