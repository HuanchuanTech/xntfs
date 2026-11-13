#!/usr/bin/env python3
"""Bounded compressed-file interruption model, using the existing trace replayer.

Exit 0: no modeled findings; 1: integrity findings (not a product pass);
2: harness failure. No OS mount, physical device, repair, or durability claim.
"""
import argparse
import collections
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

from ntfs_compressed_check import CompressedImage
from ntfs_image_check import DATA, Invalid
from run_crash_consistency import (ROOT, build, cases, clone, demand, digest,
                                   materialize, read_trace, run, save)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seed", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=ROOT / "ntfs3g/bridge")
    parser.add_argument("--scenario", choices=("compressed-append", "compressed-grow"), action="append")
    args = parser.parse_args()
    work, seed, source = args.output.resolve(), args.seed.resolve(), args.source.resolve()
    demand(work.is_relative_to(ROOT / "_tmp") and not work.exists(), "new project _tmp output")
    demand(seed.is_file() and not args.seed.is_symlink() and seed.stat().st_size <= 128 << 20, "bounded file seed")
    work.mkdir(parents=True)
    frozen = work / "source"
    frozen.mkdir()
    for name in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m"):
        shutil.copy2(source / name, frozen / name)
    for name in ("crash_resource.m", "run_crash_consistency.py", "ntfs_image_check.py",
                 "ntfs_compressed_check.py", Path(__file__).name):
        shutil.copy2(ROOT / "tests" / name, frozen / name)
    library = ROOT / "build/libntfs-universal"
    manifest = {"seed": digest(seed), "library": digest(library / "libntfs-3g.a"),
                "config": digest(library / "config.h"), "source": {p.name: digest(p) for p in frozen.iterdir()},
                "limits": {"states": 2048, "saved_images": 12}, "traces": {},
                "scope": "local conditional full-flush, sampled tear/reorder; not hardware or Windows recovery"}
    with seed.open("rb") as src, gzip.open(work / "seed.img.gz", "wb") as dest:
        shutil.copyfileobj(src, dest)
    image = CompressedImage(seed)
    try:
        image.scan()
        demand(not image.errors, "clean seed structure")
        expected = {name: image.stream(image.attr(image.records[image.paths["/" + name]], DATA))
                    for name in ("High", "Mixed", "Random", "Plain")}
        inodes = {name: image.paths["/" + name] for name in expected}
        demand(expected["High"] == b"Q" * 196731, "expected compressed seed content")
    finally:
        image.close()

    def observe(path, required):
        check = CompressedImage(path)
        findings = []
        contents = {}
        try:
            try:
                check.scan()
                findings.extend(check.errors)
            except Invalid as error:
                findings.append({"code": str(error)})
            for name, ino in inodes.items():
                # Inspect the actual seeded record even if namespace checks fail.
                # A broken name is not by itself proof of unrelated data corruption.
                try:
                    record = check.records.get(ino)
                    if record is None:
                        findings.append({"code": "unreadable_record", "name": name})
                        continue
                    value = check.stream(check.attr(record, DATA))
                    contents[name] = {"size": len(value), "sha256": hashlib.sha256(value).hexdigest()}
                    if name == "High":
                        if value[:len(expected[name])] != expected[name]:
                            findings.append({"code": "previous_content_changed", "name": name})
                        if required is not None and value != required:
                            findings.append({"code": "sync_content_mismatch", "name": name})
                    elif value != expected[name]:
                        findings.append({"code": "unrelated_content_changed", "name": name})
                except Invalid as error:
                    findings.append({"code": "content_decode:" + str(error), "name": name})
            return {"findings": findings, "contents": contents}
        finally:
            check.close()

    save(work / "manifest.json", manifest)
    binary = build(work, None, frozen, library, "o2")
    summary = {"states": 0, "finding_states": 0, "saved": 0, "negative_controls": 0, "traces": {}}
    counts = collections.Counter()
    with (work / "cases.jsonl").open("w") as records:
        for scenario in args.scenario or ("compressed-append", "compressed-grow"):
            target = expected["High"] + (b"R" * 700 if scenario.endswith("append") else bytes(328457 - 196731))
            for sector in (512, 4096):
                label = scenario + "-" + str(sector)
                visible, log, payload = (work / (label + suffix) for suffix in (".img", ".jsonl", ".bin"))
                clone(seed, visible)
                run([binary, "trace", visible, log, payload, scenario, sector, 0, 0], work / (label + ".log"))
                events = read_trace(log, payload, seed.stat().st_size)
                demand(next(e for e in events if e["kind"] == "operation")["ok"], "normal operation failed")
                demand(next(e for e in events if e["kind"] == "sync-result")["result"] == 0, "normal sync failed")
                normal = observe(visible, target)
                demand(not normal["findings"], "normal image integrity:" + json.dumps(normal["findings"][:3]))
                summary["traces"][label] = {"events": len(events), "normal": normal}
                manifest["traces"][label] = {"log": digest(log), "payload": digest(payload)}
                visible.unlink()
                for model, boundary, writes, require_complete in cases(events):
                    summary["states"] += 1
                    demand(summary["states"] <= 2048, "state limit")
                    image_path = work / "replay.img"
                    materialize(seed, image_path, events, payload, writes)
                    row = {"case": summary["states"], "trace": label, "model": model, "boundary": boundary,
                           "writes": writes, "required_complete": require_complete,
                           **observe(image_path, target if require_complete else None)}
                    if model == "cache-only-flush-negative-control":
                        demand(any(f["code"] == "sync_content_mismatch" for f in row["findings"]), "false durability undetected")
                        summary["negative_controls"] += 1
                    elif row["findings"]:
                        summary["finding_states"] += 1
                        for finding in row["findings"]:
                            counts[finding["code"]] += 1
                        if summary["saved"] < 12:
                            saved = "failure-" + str(row["case"]) + ".img.gz"
                            with image_path.open("rb") as src, gzip.open(work / saved, "wb") as dest:
                                shutil.copyfileobj(src, dest)
                            row["saved"] = saved
                            row["sha256"] = digest(image_path)
                            summary["saved"] += 1
                    records.write(json.dumps(row, sort_keys=True) + "\n")
                    image_path.unlink()
    summary["findings"] = dict(counts)
    summary["status"] = "FINDINGS" if summary["finding_states"] else "PASS_LOCAL_MODEL"
    save(work / "summary.json", summary)
    save(work / "manifest.json", manifest)
    demand(digest(seed) == manifest["seed"] and digest(library / "libntfs-3g.a") == manifest["library"], "input changed")
    print(json.dumps(summary, indent=2))
    return 1 if summary["finding_states"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, Invalid, subprocess.SubprocessError) as error:
        print("HARNESS ERROR:", error, file=sys.stderr)
        sys.exit(2)
