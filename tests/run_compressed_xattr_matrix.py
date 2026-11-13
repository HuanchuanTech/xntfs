#!/usr/bin/env python3
"""Paired compressed-xattr fault checks on disposable regular images.

Exit 0 means the candidate comparison passed, not that all recovery succeeded.
Known recovery gaps are reported separately. Exit 1 is a regression or invalid
successful outcome; exit 2 is a harness/input/unsupported-fixture failure.
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
from ntfs_image_check import DATA, Invalid, bit, need
from run_compressed_regressions import noise, sha
from run_crash_consistency import clone

ROOT = Path(__file__).resolve().parent.parent
KEY = "com.apple.testCompressed"
PROFILES = ("growth", "random", "mixed", "shrink", "resident", "empty", "create", "near-full", "fragmented")


def contents(profile):
    if profile == "random" or profile == "fragmented":
        return noise(66236), noise(131072)[::-1]
    if profile == "mixed":
        return b"A" * 65536 + noise(700), noise(65536) + b"R" * 1701
    if profile == "shrink":
        return b"A" * 131072, b"R" * 32769
    if profile == "resident":
        return b"A" * 127, b"R" * 67237
    if profile == "empty":
        return b"", b"R" * 67237
    if profile == "create":
        return None, b"R" * 67237
    return b"A" * 66236, b"R" * 67237


def fingerprint(data):
    return None if data is None else {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def matches_content(observed, expected):
    named = observed["named"]
    independent = None if named is None else {key: named.get(key) for key in ("size", "sha256")}
    # Native read failure is not evidence that a newly created stream was
    # removed. Require the independent oracle to confirm absence as well.
    return independent == expected and observed["native_named"]["content"] == expected


def comparison_issues(before, after, mode):
    issues = []
    for field in ("result", "first_sync", "second_sync", "release", "later_io"):
        if before["event"][field] != after["event"][field]:
            issues.append("changed_status:" + field)
    if after["event"]["operation_io"] > before["event"]["operation_io"]:
        issues.append("added_operation_io")
    if before["recovered"] and not after["recovered"]:
        issues.append("lost_recovery")
    if before["observation"]["unrelated"] != after["observation"]["unrelated"]:
        issues.append("changed_unrelated_content")
    old_findings = {json.dumps(x, sort_keys=True) for x in before["observation"]["structure"]}
    new_findings = {json.dumps(x, sort_keys=True) for x in after["observation"]["structure"]}
    if new_findings - old_findings:
        issues.append("new_structure_findings")
    if not after["recovered"]:
        for field in ("native_named", "named"):
            if before["observation"][field] != after["observation"][field]:
                issues.append("changed_unrecovered_content_requires_review:" + field)
    if mode == "normal" and after["event"]["result"] == 0 and not after["recovered"]:
        issues.append("invalid_successful_write")
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--baseline-dir", required=True, type=Path)
    parser.add_argument("--candidate-dir", type=Path, default=ROOT / "ntfs3g/bridge")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sanitize", choices=("address", "undefined"))
    parser.add_argument("--profiles", choices=PROFILES, nargs="+", default=list(PROFILES))
    args = parser.parse_args()
    work = args.output.resolve()
    need(work.is_relative_to(ROOT / "_tmp") and not work.exists(), "new_project_output")
    work.mkdir(parents=True)
    shutil.copy2(__file__, work / Path(__file__).name)
    env = dict(os.environ)
    env.pop("SDKROOT", None)
    fixture_hash = sha(args.fixture)
    report = {"profiles": {}, "regressions": [], "improvements": [], "saved_fault_images": 0,
              "scope": "paired returned-error comparison; not power-loss, Windows or installed FSKit acceptance"}

    def run(command, label, allow_failure=False):
        result = subprocess.run([str(x) for x in command], env=env, text=True, capture_output=True, timeout=90)
        (work / (label + ".log")).write_text(result.stdout + result.stderr)
        if not allow_failure:
            need(result.returncode == 0, "subprocess:" + label + ":" + result.stderr[-500:])
        return result

    tools = {}
    for variant, source in (("baseline", args.baseline_dir), ("candidate", args.candidate_dir)):
        build = work / (variant + "-build")
        command = [sys.executable, ROOT / "tests/run_compressed_regressions.py", args.fixture.resolve(),
                   "--source", source.resolve(), "--output", build,
                   "--fixtures-only" if variant == "baseline" else "--build-only"]
        if args.sanitize:
            command += ["--sanitize", args.sanitize]
        run(command, variant + "-build")
        tools[variant] = build / "fixture-tool"
    seed = work / "baseline-build/seeded.img"
    seed_hash = sha(seed)
    check = CompressedImage(seed)
    try:
        check.scan()
        need(not check.errors, "seed_integrity")
        unaffected = {name: fingerprint(check.stream(check.attr(check.records[check.paths["/" + name]], DATA)))
                      for name in ("Empty", "Small", "High", "Mixed", "Random", "Zero", "Plain")}
    finally:
        check.close()

    def native(image, variant, name, stream, label):
        target = work / "readback.data"
        target.unlink(missing_ok=True)
        command = [tools[variant], "read-stream" if stream else "read", image, name]
        if stream:
            command.append(stream)
        result = run(command + [target], label, allow_failure=True)
        data = fingerprint(target.read_bytes()) if target.exists() else None
        target.unlink(missing_ok=True)
        return {"exit": result.returncode, "content": data}

    def observe(image, variant, label):
        result = {"unrelated": {}, "named": None}
        check = CompressedImage(image)
        try:
            check.scan()
            result["structure"] = check.errors
            for name, expected in unaffected.items():
                try:
                    actual = fingerprint(check.stream(check.attr(check.records[check.paths["/" + name]], DATA)))
                    result["unrelated"][name] = actual == expected
                except (Invalid, KeyError):
                    result["unrelated"][name] = False
            try:
                record = check.records[check.paths["/High"]]
                attr = check.attr(record, DATA, KEY, optional=True)
                if attr is not None:
                    result["named"] = fingerprint(check.stream(attr))
                    result["named"].update(compression=attr["compression"],
                                           layout=check.layout(attr) if attr["nonresident"] else ["resident"])
            except (Invalid, KeyError) as error:
                result["named"] = {"error": str(error)}
        finally:
            check.close()
        need(not any(x["code"].startswith("unsupported:") for x in result["structure"]), "unsupported_case:" + label)
        result["native_main"] = native(image, variant, "High", None, label + "-main")
        if result["native_main"]["exit"] == 0:
            result["unrelated"]["High"] = result["native_main"]["content"] == unaffected["High"]
        result["native_named"] = native(image, variant, "High", KEY, label + "-named")
        return result

    def save_image(image, name):
        with image.open("rb") as src, gzip.open(work / (name + ".img.gz"), "wb") as dst:
            shutil.copyfileobj(src, dst, 1 << 20)

    def action(image, variant, payload, mode, label):
        event = json.loads(run([tools[variant], "xattr", image, "High", payload, mode], label).stdout)
        need(event["attrs_live"] == 0 and event["attrs_peak"] <= 1 and event["later_pclose"] == 0, "attribute_ownership:" + label)
        if mode.startswith("data-"):
            need(event["data_read_injected"] + event["data_write_injected"] == 1, "data_fault_reached:" + label)
        elif mode != "normal":
            field = ("read_injected" if mode.startswith("read-fail-") else
                     "write_injected" if mode.startswith("write-fail-") else
                     "metadata_injected" if mode == "metadata-fail" else
                     "flush_injected" if mode == "flush-fail" else "pclose_fail_injected")
            need(event[field] > 0, "fault_reached:" + label)
            if variant == "candidate" and mode.startswith("mapping-oom-"):
                need(event["mapping_oom_injected"] == 1, "mapping_oom_reached:" + label)
        return event

    prepared, image = work / "prepared.img", work / "case.img"
    for profile in args.profiles:
        old, new = contents(profile)
        expected_old, expected_new = fingerprint(old), fingerprint(new)
        payload = work / (profile + ".data")
        clone(seed, prepared)
        if old is not None:
            payload.write_bytes(old)
            event = action(prepared, "baseline", payload, "normal", profile + "-prepare")
            need(event["result"] == event["first_sync"] == event["second_sync"] == event["release"] == 0, "prepare_status")
        payload.write_bytes(new)
        layout = None
        if profile in ("near-full", "fragmented"):
            layout = json.loads(run([tools["baseline"], "space", prepared, profile], profile + "-layout").stdout)
        initial = observe(prepared, "baseline", profile + "-initial")
        need(not initial["structure"] and all(initial["unrelated"].values()), "prepared_integrity:" + profile)
        need(matches_content(initial, expected_old), "prepared_old_value:" + profile)
        if old is not None:
            need(initial["named"]["compression"] == 1, "genuine_compressed_attribute:" + profile)
            false_absence = dict(initial, native_named={"exit": 2, "content": None})
            need(not matches_content(false_absence, None), "absence_negative_control:" + profile)
        check = CompressedImage(prepared)
        try:
            check.scan()
            bitmap = check.stream(check.attr(check.records[6], DATA))
            free = [i for i in range(check.clusters) if not bit(bitmap, i)]
            runs, current, previous = [], 0, -2
            for cluster in free:
                if cluster != previous + 1:
                    if current:
                        runs.append(current)
                    current = 0
                current += 1
                previous = cluster
            if current:
                runs.append(current)
            space = {"free_clusters": len(free), "free_runs": len(runs), "largest_free_run": max(runs, default=0)}
            if profile == "near-full":
                need(len(free) <= 8, "near_full_fixture")
            if profile == "fragmented":
                need(len(runs) >= 32 and max(runs) <= 16, "fragmented_fixture")
        finally:
            check.close()
        save_image(prepared, profile + "-prepared")
        record = {"old": expected_old, "new": expected_new, "layout": layout, "space": space,
                  "prepared_sha256": sha(prepared), "cases": {}, "recovery_gaps": {"baseline": [], "candidate": []}}
        report["profiles"][profile] = record
        modes = ["normal"]
        for mode in modes:
            pair = {}
            for variant in ("baseline", "candidate"):
                clone(prepared, image)
                label = profile + "-" + mode + "-" + variant
                event = action(image, variant, payload, mode, label)
                observed = observe(image, variant, label)
                metadata_after_success = mode == "metadata-fail" and record["cases"]["normal"]["baseline"]["event"]["result"] == 0
                expected = expected_new if event["result"] == 0 or metadata_after_success else expected_old
                recovered = (not observed["structure"] and all(observed["unrelated"].values()) and
                             matches_content(observed, expected))
                if not recovered:
                    record["recovery_gaps"][variant].append(mode)
                    if report["saved_fault_images"] < 12:
                        save_image(image, label)
                        report["saved_fault_images"] += 1
                pair[variant] = {"event": event, "observation": observed, "recovered": recovered,
                                 "image_sha256": sha(image)}
                image.unlink()
            record["cases"][mode] = pair
            a, b = pair["baseline"], pair["candidate"]
            issues = comparison_issues(a, b, mode)
            old_findings = {json.dumps(x, sort_keys=True) for x in a["observation"]["structure"]}
            new_findings = {json.dumps(x, sort_keys=True) for x in b["observation"]["structure"]}
            if issues:
                report["regressions"].append({"profile": profile, "mode": mode, "issues": issues})
            if not issues and (new_findings < old_findings or b["event"]["operation_io"] < a["event"]["operation_io"]):
                report["improvements"].append({"profile": profile, "mode": mode,
                                               "io_before": a["event"]["operation_io"], "io_after": b["event"]["operation_io"],
                                               "findings_before": len(old_findings), "findings_after": len(new_findings)})
            if mode == "normal":
                if a["event"]["pclose_calls"]:
                    modes.append("pclose-fail")
                    if old is not None:
                        modes.extend(("rollback-fail", "mapping-oom-pclose-fail"))
                if a["event"]["result"] == 0:
                    modes.extend(("metadata-fail", "flush-fail"))
                for prefix, field in (("read-fail-", "pclose_reads"), ("write-fail-", "pclose_writes"),
                                      ("data-read-fail-", "data_reads"), ("data-write-fail-", "data_writes")):
                    count = a["event"][field]
                    need(0 <= count <= 128 and count == b["event"][field], "same_bounded_fault_schedule:" + field)
                    modes.extend(prefix + str(i) for i in range(1, count + 1))
            (work / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print(profile, "cases", len(record["cases"]), "gaps", {k: len(v) for k, v in record["recovery_gaps"].items()}, flush=True)
        prepared.unlink()
    need(sha(args.fixture) == fixture_hash and sha(seed) == seed_hash, "original_inputs_unchanged")
    report["result"] = "FAIL_COMPARISON" if report["regressions"] else "PASS_LOCAL_COMPARISON"
    (work / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ("result", "regressions", "improvements", "scope")}, indent=2))
    return int(bool(report["regressions"]))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Invalid, OSError, subprocess.SubprocessError, ValueError) as error:
        print("CHECK FAILED:", error, file=sys.stderr)
        sys.exit(2)
