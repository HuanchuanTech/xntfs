#!/usr/bin/env python3
"""Compressed named-DATA prefix regression and returned-error observations.

Normal writes require exact native/independent bytes and clean allocation maps.
Fault schedules come from the candidate's actual I/O, not baseline call indices.
Exit 0: requested checks pass; 1: product integrity/recovery findings;
2: harness/input failure. No power-loss, installed FSKit or device acceptance.
"""
import argparse
import gzip
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from ntfs_compressed_check import CompressedImage
from ntfs_image_check import DATA, Invalid, bit, need, uint
from run_compressed_regressions import noise, sha
from run_compressed_xattr_matrix import KEY, comparison_issues, fingerprint, matches_content
from run_crash_consistency import clone

ROOT = Path(__file__).resolve().parent.parent
NAMES = ("Empty", "Small", "High", "Mixed", "Random", "Zero", "Plain")


def profiles():
    result = {
        "zero-zero": (bytes(131072), bytes(131072)),
        "zero-zero_r": (bytes(131072), bytes(65536) + b"R" * 65536),
        "zero-r_zero": (bytes(131072), b"R" * 65536 + bytes(65536)),
        "a-zero": (b"A" * 66236, bytes(131072)),
        "tiny-zero": (b"tiny", bytes(131072)),
        "zero-tail": (bytes(66236), bytes(65536) + b"R" * 700),
        "zero-grow": (bytes(65536), bytes(65536) + b"R" * 700),
        "zero-shrink": (bytes(131072), bytes(65536)),
        "a-a_r": (b"A" * 131072, b"A" * 65536 + b"R" * 65536),
    }
    for size in (1, 127, 4096, 32769, 65535, 65536, 65537, 66236, 131071):
        result["repeat-" + str(size)] = (bytes(size), bytes(size))
    for size in (4096, 32769, 65535, 66236, 131071):
        result["repeat-a-" + str(size)] = (b"A" * size, b"A" * size)
    for size in (4096, 32769, 65535, 66236):
        result["repeat-random-" + str(size)] = (noise(size), noise(size))
    mixed = b"A" * 65536 + noise(700)
    result["repeat-mixed"] = (mixed, mixed)
    result["raw-tail"] = (b"R" * 32769, b"R" * 32769)
    result["raw-random-tail"] = (noise(32769), noise(32769))
    result["raw-two-unit-tail"] = (b"R" * 66236, b"R" * 66236)
    result["raw-random-two-unit-tail"] = (noise(66236), noise(66236))
    uninitialized = b"A" * 32769 + bytes(65536 - 32769)
    result["uninitialized-repeat"] = (uninitialized, uninitialized)
    result["changed-last-byte"] = (bytes(4096), bytes(4095) + b"R")
    result["space-repeat-zero"] = (bytes(4096), bytes(4096))
    result["space-repeat-a"] = (b"A" * 32769, b"A" * 32769)
    result["space-repeat-raw"] = (noise(65535), noise(65535))
    return result


def observe(image, tool, run, work, expected, label):
    result = {"unrelated": {}, "named": None}
    check = CompressedImage(image)
    try:
        check.scan()
        result["structure"] = check.errors
        for name in NAMES:
            try:
                actual = fingerprint(check.stream(check.attr(check.records[check.paths["/" + name]], DATA)))
                result["unrelated"][name] = actual == expected[name]
            except (Invalid, KeyError):
                result["unrelated"][name] = False
        try:
            attr = check.attr(check.records[check.paths["/High"]], DATA, KEY)
            result["named"] = fingerprint(check.stream(attr))
            result["named"].update(compression=attr["compression"], initialized=attr["initialized"],
                                   layout=check.layout(attr) if attr["nonresident"] else ["resident"])
            standard = check.stream(check.attr(check.records[check.paths["/High"]], 0x10))
            result["metadata"] = {"ctime": uint(standard, 16, 8), "archive": bool(uint(standard, 32) & 0x20)}
        except (Invalid, KeyError) as error:
            result["named"] = {"error": str(error)}
    finally:
        check.close()
    need(not any(x["code"].startswith("unsupported:") for x in result["structure"]), "unsupported:" + label)
    for field, stream in (("native_main", None), ("native_named", KEY)):
        target = work / "readback.data"
        target.unlink(missing_ok=True)
        command = [tool, "read-stream" if stream else "read", image, "High"]
        if stream:
            command.append(stream)
        read = run(command + [target], label + "-" + field, allow_failure=True)
        result[field] = {"exit": read.returncode,
                         "content": fingerprint(target.read_bytes()) if target.exists() else None}
        target.unlink(missing_ok=True)
    # A malformed named attr may make the independent parser skip this inode.
    # A native read distinguishes that from damage to the unnamed stream.
    if result["native_main"]["exit"] == 0:
        result["unrelated"]["High"] = result["native_main"]["content"] == expected["High"]
    return result


def intact(observed, expected):
    return (not observed["structure"] and all(observed["unrelated"].values()) and
            matches_content(observed, expected))


def verify_controls(report):
    expected = sum(len(p["faults"]) for p in report["profiles"].values() if p["compare_baseline"])
    actual = sum("baseline_control" in c for p in report["profiles"].values() for c in p["faults"].values())
    for name, profile in report["profiles"].items():
        if profile["compare_baseline"]:
            need(all("baseline_control" in c for c in profile["faults"].values()), "baseline_controls_executed:" + name)
    need(expected == actual, "baseline_control_count")
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--baseline-dir", type=Path, required=True)
    parser.add_argument("--candidate-dir", type=Path, default=ROOT / "ntfs3g/bridge")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sanitize", choices=("address", "undefined"))
    parser.add_argument("--normal-only", action="store_true")
    parser.add_argument("--compare-all", action="store_true",
                        help="execute baseline controls even for unchanged encoded partial tails")
    args = parser.parse_args()
    work = args.output.resolve()
    need(work.is_relative_to(ROOT / "_tmp") and not work.exists(), "new_project_output")
    need(not args.fixture.is_symlink() and args.fixture.is_file() and
         512 <= args.fixture.stat().st_size <= 128 << 20, "bounded_regular_fixture")
    with args.fixture.open("rb") as stream:
        boot = stream.read(512)
    need(boot[13] * int.from_bytes(boot[11:13], "little") * 16 == 65536, "64k_unit_fixture")
    work.mkdir(parents=True)
    shutil.copy2(__file__, work / Path(__file__).name)
    env = dict(os.environ)
    env.pop("SDKROOT", None)
    fixture_hash = sha(args.fixture)

    def run(command, label, allow_failure=False):
        process = subprocess.run([str(x) for x in command], env=env, text=True, capture_output=True, timeout=90)
        (work / (label + ".log")).write_text(process.stdout + process.stderr)
        if not allow_failure:
            need(process.returncode == 0, "subprocess:" + label + ":" + process.stderr[-500:])
        return process

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
        unrelated = {name: fingerprint(check.stream(check.attr(check.records[check.paths["/" + name]], DATA)))
                     for name in NAMES}
    finally:
        check.close()
    report = {"profiles": {}, "normal_issues": [], "recovery_gaps": [], "containment_issues": [],
              "control_regressions": [], "control_negative_checks": 0, "saved": 0,
              "scope": "bounded named DATA; returned-error tests, not crash recovery or physical-device proof"}

    def save_image(image, label):
        with image.open("rb") as src, gzip.open(work / (label + ".img.gz"), "wb") as dst:
            shutil.copyfileobj(src, dst, 1 << 20)

    def action(image, variant, payload, mode, label):
        event = json.loads(run([tools[variant], "xattr", image, "High", payload, mode], label).stdout)
        need(event["attrs_live"] == 0 and event["attrs_peak"] <= 1 and event["later_pclose"] == 0,
             "attribute_ownership:" + label)
        if mode != "normal":
            field = ("data_read_injected" if mode.startswith("data-read-fail-") else
                     "data_write_injected" if mode.startswith("data-write-fail-") else
                     "read_injected" if mode.startswith("read-fail-") else
                     "write_injected" if mode.startswith("write-fail-") else
                     "metadata_injected" if mode == "metadata-fail" else
                     "flush_injected" if mode == "flush-fail" else "pclose_fail_injected")
            need(event[field] == (2 if mode == "rollback-fail" else 1), "actual_injection:" + label)
        return event

    prepared, image = work / "prepared.img", work / "case.img"
    for profile, (old, new) in profiles().items():
        clone(seed, prepared)
        payload = work / (profile + ".data")
        payload.write_bytes(old[:32769] if profile == "uninitialized-repeat" else old)
        if profile.startswith("raw-") or profile == "uninitialized-repeat":
            run([tools["baseline"], "seed-stream", prepared, "High", KEY, payload,
                 1 if profile == "uninitialized-repeat" else 0], profile + "-prepare")
            if profile == "uninitialized-repeat":
                run([tools["baseline"], "raw-truncate-stream", prepared, "High", KEY, len(old)], profile + "-extend")
        else:
            first = action(prepared, "baseline", payload, "normal", profile + "-prepare")
            need(all(first[x] == 0 for x in ("result", "first_sync", "second_sync", "release")), "prepare_status")
        if profile.startswith("space-"):
            run([tools["baseline"], "space", prepared, "near-full", 0], profile + "-space")
            check = CompressedImage(prepared)
            try:
                check.scan()
                bitmap = check.stream(check.attr(check.records[6], DATA))
                need(all(bit(bitmap, i) for i in range(check.clusters)), "zero_free_clusters")
            finally:
                check.close()
        initial = observe(prepared, tools["baseline"], run, work, unrelated, profile + "-initial")
        need(intact(initial, fingerprint(old)) and initial["named"]["compression"] == 1, "prepared_integrity")
        if profile == "uninitialized-repeat":
            need(initial["named"]["initialized"] == 32769, "real_uninitialized_tail")
        if profile.startswith("raw-"):
            need(initial["named"]["layout"][-1] == "raw", "real_unfinalized_tail")
        save_image(prepared, profile + "-prepared")
        payload.write_bytes(new)
        whole_prefix = 0
        while (whole_prefix + 65536 <= min(len(old), len(new)) and
               old[whole_prefix:whole_prefix + 65536] == new[whole_prefix:whole_prefix + 65536]):
            whole_prefix += 65536
        unchanged_encoded_value = (old == new and initial["named"]["initialized"] == len(old) and
                                   initial["named"]["layout"][-1] in ("hole", "lznt1"))
        record = {"old": fingerprint(old), "new": fingerprint(new), "prepared_sha256": sha(prepared),
                  "initial": initial, "unchanged_prefix_bytes": whole_prefix,
                  "compare_baseline": args.compare_all or not (unchanged_encoded_value and len(old) % 65536),
                  "unchanged_encoded_value": unchanged_encoded_value,
                  "normal": {}, "faults": {}}
        report["profiles"][profile] = record
        for variant in ("baseline", "candidate"):
            clone(prepared, image)
            label = profile + "-normal-" + variant
            event = action(image, variant, payload, "normal", label)
            observation = observe(image, tools[variant], run, work, unrelated, label)
            ok = intact(observation, fingerprint(new)) and all(event[x] == 0 for x in
                                                              ("result", "first_sync", "second_sync", "release"))
            metadata_ok = (observation.get("metadata", {}).get("archive", False) and
                           observation.get("metadata", {}).get("ctime") != initial["metadata"]["ctime"])
            no_rewrite = not unchanged_encoded_value or (event["data_reads"] == event["data_writes"] == 0)
            if variant == "candidate":
                ok = ok and no_rewrite and metadata_ok
            record["normal"][variant] = {"event": event, "observation": observation, "valid": ok,
                                         "metadata_updated": metadata_ok, "no_unnecessary_rewrite": no_rewrite,
                                         "image_sha256": sha(image)}
            if not ok and report["saved"] < 12:
                save_image(image, label)
                report["saved"] += 1
            if variant == "candidate" and not ok:
                report["normal_issues"].append(profile)
            image.unlink()
        if profile.startswith("space-"):
            record["space_retry"] = {}
            for variant in ("baseline", "candidate"):
                clone(prepared, image)
                label = profile + "-space-retry-" + variant
                event = json.loads(run([tools[variant], "xattr", image, "High", payload, "space-retry"], label).stdout)
                observation = observe(image, tools[variant], run, work, unrelated, label)
                ok = (all(event[x] == 0 for x in ("initial", "removed", "retried", "sync", "release")) and
                      event["attrs_live"] == 0 and event["attrs_peak"] <= 1 and intact(observation, fingerprint(new)))
                record["space_retry"][variant] = {"event": event, "observation": observation, "valid": ok}
                if variant == "candidate" and not ok:
                    report["normal_issues"].append(profile + "-same-mount-retry")
                image.unlink()
        candidate = record["normal"]["candidate"]
        modes = []
        if not args.normal_only and candidate["valid"]:
            modes = ["pclose-fail", "rollback-fail", "metadata-fail", "flush-fail"]
            for mode_prefix, field in (("read-fail-", "pclose_reads"), ("write-fail-", "pclose_writes"),
                                  ("data-read-fail-", "data_reads"), ("data-write-fail-", "data_writes")):
                count = candidate["event"][field]
                need(0 <= count <= 128, "bounded_fault_schedule")
                modes += [mode_prefix + str(i) for i in range(1, count + 1)]
        for mode in modes:
            clone(prepared, image)
            label = profile + "-" + mode
            event = action(image, "candidate", payload, mode, label)
            observation = observe(image, tools["candidate"], run, work, unrelated, label)
            expected = new if event["result"] == 0 or mode == "metadata-fail" else old
            recovered = intact(observation, fingerprint(expected))
            # Full recovery and confinement/error reporting are separate results.
            contained = (all(observation["unrelated"].values()) and not observation["structure"] and
                         (event["result"] < 0 or intact(observation, fingerprint(new))) and
                         (mode != "flush-fail" or event["first_sync"] < 0))
            if not recovered:
                report["recovery_gaps"].append(label)
                if report["saved"] < 12:
                    save_image(image, label)
                    report["saved"] += 1
            if not contained:
                report["containment_issues"].append(label)
            record["faults"][mode] = {"event": event, "observation": observation, "recovered": recovered,
                                     "contained": contained, "image_sha256": sha(image)}
            image.unlink()
            if record["compare_baseline"]:
                # These controls take the unchanged write/rollback path. Keep
                # inherited failures visible, and require exact no-regression.
                clone(prepared, image)
                baseline = action(image, "baseline", payload, mode, label + "-baseline")
                baseline_obs = observe(image, tools["baseline"], run, work, unrelated, label + "-baseline")
                expected_base = new if baseline["result"] == 0 or mode == "metadata-fail" else old
                before = {"event": baseline, "observation": baseline_obs,
                          "recovered": intact(baseline_obs, fingerprint(expected_base))}
                issues = comparison_issues(before, record["faults"][mode], mode)
                record["faults"][mode]["baseline_control"] = before
                if issues:
                    report["control_regressions"].append({"profile": profile, "mode": mode, "issues": issues})
                image.unlink()
        prepared.unlink()
        report["baseline_control_pairs"] = verify_controls(report)
        if record["compare_baseline"] and record["faults"]:
            missing = {"profiles": {profile: {"compare_baseline": True, "faults": {"normal": {}}}}}
            try:
                verify_controls(missing)
            except Invalid:
                report["control_negative_checks"] += 1
            else:
                need(False, "missing_control_was_accepted")
        (work / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print(profile, "normal", {k: v["valid"] for k, v in record["normal"].items()}, "faults", len(modes), flush=True)
    need(sha(args.fixture) == fixture_hash and sha(seed) == seed_hash, "inputs_unchanged")
    report["normal_result"] = "FAIL" if report["normal_issues"] else "PASS_LOCAL_NORMAL"
    report["containment_result"] = "NOT_RUN" if args.normal_only else ("FAIL" if report["containment_issues"] else "PASS_LOCAL_CONTAINMENT")
    report["recovery_result"] = "NOT_RUN" if args.normal_only else ("FAIL_RECOVERY" if report["recovery_gaps"] else "PASS_LOCAL_RECOVERY")
    (work / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "profiles"}, indent=2))
    return int(bool(report["normal_issues"] or report["containment_issues"] or report["recovery_gaps"] or
                    report["control_regressions"]))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Invalid, OSError, subprocess.SubprocessError, ValueError, RuntimeError) as error:
        print("HARNESS ERROR:", error, file=sys.stderr)
        sys.exit(2)
