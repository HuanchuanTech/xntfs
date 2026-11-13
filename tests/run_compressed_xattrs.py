#!/usr/bin/env python3
"""Bounded compressed named-DATA checks through the existing xattr bridge.

Ordinary images only. This tests returned I/O errors and recovery, not power loss.
Exit 1 retains observed recovery gaps; exit 2 means a harness/contract failure.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from ntfs_compressed_check import CompressedImage
from ntfs_image_check import DATA, Invalid, need
from run_crash_consistency import clone

ROOT = Path(__file__).resolve().parent.parent
KEY = "com.apple.testCompressed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=ROOT / "ntfs3g/bridge")
    parser.add_argument("--sanitize", choices=("address", "undefined"))
    args = parser.parse_args()
    output = args.output.resolve()
    need(output.is_relative_to(ROOT / "_tmp") and not output.exists(), "new_project_output")
    output.mkdir(parents=True)
    env = dict(os.environ)
    env.pop("SDKROOT", None)

    def run(command, label):
        result = subprocess.run([str(x) for x in command], env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=90)
        (output / (label + ".log")).write_text(result.stdout)
        need(result.returncode == 0, "subprocess:" + label + ":" + result.stdout[-1000:])
        return result.stdout

    build = [sys.executable, ROOT / "tests/run_compressed_regressions.py", args.fixture.resolve(),
             "--output", output / "build", "--source", args.source.resolve(), "--fixtures-only"]
    if args.sanitize:
        build += ["--sanitize", args.sanitize]
    run(build, "fixture-build")
    shutil.copy2(__file__, output / Path(__file__).name)
    tool = output / "build/fixture-tool"
    seed = output / "build/seeded.img"
    source_hash = hashlib.sha256(seed.read_bytes()).hexdigest()
    original, replacement = b"A" * 66236, b"R" * 67237
    baseline = CompressedImage(seed)
    try:
        baseline.scan()
        unaffected = {name: baseline.stream(baseline.attr(baseline.records[baseline.paths["/" + name]], DATA))
                      for name in ("High", "Mixed", "Random", "Plain")}
    finally:
        baseline.close()
    report = {"normal": [], "faults": {}, "recovery_gaps": [],
              "scope": "local returned-error recovery; no power-loss/Windows/hardware acceptance"}

    def inspect(path, expected, label):
        check = CompressedImage(path)
        try:
            check.scan()
            need(not check.errors, "structure:" + label + ":" + str(check.errors[:3]))
            for name, data in unaffected.items():
                need(check.stream(check.attr(check.records[check.paths["/" + name]], DATA)) == data,
                     "unrelated_content:" + label + ":" + name)
            inode = check.records[check.paths["/High"]]
            attr = check.attr(inode, DATA, KEY, optional=True)
            if expected is None:
                need(attr is None, "deleted_stream_present")
                return {"removed": True}
            need(attr is not None and attr["compression"] == 1, "genuine_named_compression")
            value = check.stream(attr)
            need(value == expected, "independent_named_bytes:" + label)
            result = {"size": len(value), "physical": attr.get("compressed_size"), "layout": check.layout(attr),
                      "sha256": hashlib.sha256(value).hexdigest()}
        finally:
            check.close()
        readback = output / "readback.data"
        result["native"] = json.loads(run([tool, "read-stream", path, "High", KEY, readback], label + "-native"))
        need(readback.read_bytes() == expected, "native_named_bytes:" + label)
        readback.unlink()
        return result

    def action(path, data, mode, label):
        payload = output / "payload.data"
        payload.write_bytes(data)
        event = json.loads(run([tool, "xattr", path, "High", payload, mode], label))
        need(event["attrs_live"] == 0 and event["attrs_peak"] <= 1 and event["later_pclose"] == 0,
             "attribute_lifetime:" + label)
        return event

    def observe_failed_recovery(path, label):
        check = CompressedImage(path)
        observed = {}
        try:
            check.scan()
            observed["structure_findings"] = check.errors
            observed["inode_parseable"] = check.paths.get("/High") in check.records
            for name, data in unaffected.items():
                # A malformed named attribute makes this oracle skip the whole
                # inode. Check High's unnamed DATA through a native read below.
                if name == "High" and not observed["inode_parseable"]:
                    continue
                need(check.stream(check.attr(check.records[check.paths["/" + name]], DATA)) == data,
                     "failed_recovery_unrelated_content:" + label + ":" + name)
            if observed["inode_parseable"]:
                attr = check.attr(check.records[check.paths["/High"]], DATA, KEY)
                data = check.stream(attr)
                observed["named"] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                     "old": data == original, "new": data == replacement}
        finally:
            check.close()
        readback = output / "readback.data"
        run([tool, "read", path, "High", readback], label + "-unnamed-native")
        need(readback.read_bytes() == unaffected["High"], "failed_recovery_unnamed:" + label)
        readback.unlink()
        observed["unrelated_content"] = "PASS"
        return observed

    active = output / "normal.img"
    clone(seed, active)
    for index, data in enumerate((original, b"B" * 32769, replacement, b"", b"tiny", bytes(131072))):
        label = "normal-" + str(index)
        event = action(active, data, "normal", label)
        need(event["result"] == event["first_sync"] == event["second_sync"] == event["release"] == 0,
             "normal_status:" + label)
        event["oracle"] = inspect(active, data, label)
        report["normal"].append(event)
    event = action(active, b"", "delete", "delete")
    need(event["result"] == event["first_sync"] == event["second_sync"] == event["release"] == 0, "delete_status")
    inspect(active, None, "delete")
    active.unlink()

    prepared = output / "prepared.img"
    clone(seed, prepared)
    event = action(prepared, original, "normal", "prepare")
    need(event["result"] == event["first_sync"] == event["second_sync"] == event["release"] == 0, "prepare_status")
    inspect(prepared, original, "prepared")
    modes = ["normal", "pclose-fail", "rollback-fail", "metadata-fail", "flush-fail"]
    for mode in modes:
        active = output / "fault.img"
        clone(prepared, active)
        event = action(active, replacement, mode, "fault-" + mode)
        report["faults"][mode] = event
        if mode == "normal":
            need(event["pclose_calls"] == 1 and max(event["pclose_reads"], event["pclose_writes"]) <= 16,
                 "bounded_real_pclose_calls")
            need(0 < event["data_reads"] <= 128 and 0 < event["data_writes"] <= 128,
                 "bounded_real_data_calls")
            modes.extend("read-fail-" + str(i) for i in range(1, event["pclose_reads"] + 1))
            modes.extend("write-fail-" + str(i) for i in range(1, event["pclose_writes"] + 1))
            modes.extend("data-read-fail-" + str(i) for i in range(1, event["data_reads"] + 1))
            modes.extend("data-write-fail-" + str(i) for i in range(1, event["data_writes"] + 1))
        if mode.startswith("data-"):
            need(event["data_read_injected"] + event["data_write_injected"] == 1, "data_fault_reached:" + mode)
        if mode == "rollback-fail":
            need(event["result"] < 0 and event["first_sync"] < 0 and event["second_sync"] < 0 and
                 event["release"] < 0 and event["later_io"] == 0, "failed_rollback_remains_failed")
            # A failed rollback is not promised to restore old/new bytes.
            event["content_acceptance"] = "NOT_CLAIMED: failed rollback; error containment only"
            event["observation"] = observe_failed_recovery(active, mode)
        elif mode == "metadata-fail":
            need(event["result"] < 0 and event["first_sync"] < 0 and
                 event["second_sync"] == event["release"] == 0, "metadata_failure_and_retry")
            event["oracle"] = inspect(active, replacement, "fault-" + mode)
        elif mode == "flush-fail":
            need(event["result"] == 0 and event["first_sync"] < 0 and
                 event["second_sync"] < 0 and event["release"] == 0, "flush_failure_and_saved_error")
            event["oracle"] = inspect(active, replacement, "fault-" + mode)
        elif mode.startswith("data-"):
            # libntfs can return partial progress after an internal I/O error;
            # completing the remaining bytes may legitimately recover it.
            if event["release"] == 0:
                need(event["result"] <= 0, "data_result:" + mode)
                event["oracle"] = inspect(active, replacement if event["result"] == 0 else original, "fault-" + mode)
            else:
                need(event["result"] < 0 and event["first_sync"] < 0 and event["second_sync"] < 0 and
                     event["later_io"] == 0, "data_failure_remains_visible:" + mode)
                event["observation"] = observe_failed_recovery(active, mode)
                event["content_acceptance"] = "FAIL_RECOVERY: error containment is not restored content"
                report["recovery_gaps"].append(mode)
        else:
            need(event["result"] == 0 if mode == "normal" else event["result"] < 0, "xattr_result:" + mode)
            need(event["first_sync"] == event["second_sync"] == event["release"] == 0, "rollback_sync:" + mode)
            event["oracle"] = inspect(active, replacement if mode == "normal" else original, "fault-" + mode)
        # Preserve all injected-error outcomes before removing the disposable image.
        if mode != "normal":
            event["image_sha256"] = hashlib.sha256(active.read_bytes()).hexdigest()
            with active.open("rb") as src, gzip.open(output / (mode + ".img.gz"), "wb") as dest:
                shutil.copyfileobj(src, dest)
        active.unlink()
    prepared.unlink()
    need(hashlib.sha256(seed.read_bytes()).hexdigest() == source_hash, "seed_changed")
    report["seed_sha256"] = source_hash
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"normal": len(report["normal"]) + 1, "fault_scenarios": len(report["faults"]),
                      "result": "FAIL_RECOVERY" if report["recovery_gaps"] else "PASS_LOCAL_RETURNED_ERROR_CHECKS",
                      "recovery_gaps": report["recovery_gaps"], "scope": report["scope"]}, indent=2))
    return int(bool(report["recovery_gaps"]))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Invalid, OSError, subprocess.SubprocessError) as error:
        print("CHECK FAILED:", error, file=sys.stderr)
        sys.exit(2)
