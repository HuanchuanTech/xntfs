#!/usr/bin/env python3
"""Gate bounded bitmap validation separately from the unchanged strict reports.

Accept only evidenced recovery improvements and bounded extra validation reads.
Full recovery remains a separate, possibly failing result. Prefix inputs must
use --compare-all so a missing control cannot silently escape comparison.
"""
import argparse
from copy import deepcopy
import json
from pathlib import Path

from ntfs_image_check import Invalid
from run_compressed_prefix import intact, verify_controls


def need(condition, message):
    if not condition:
        raise ValueError(message)


def without_time(observed):
    result = deepcopy(observed)
    if "metadata" in result:
        result["metadata"].pop("ctime", None)
    return result


def compare(before, after, expected, mode):
    a, b = before["event"], after["event"]
    old, new = before["observation"], after["observation"]
    reads = b["allocation_reads"]
    need(a["allocation_reads"] == 0 and 0 <= reads <= 272, "bounded_validation_reads")
    need(a["allocation_read_injected"] == b["allocation_read_injected"] == 0, "unexpected_bitmap_fault")
    need(a["result"] == b["result"], "operation_result")
    need(b["attrs_live"] == 0 and b["attrs_peak"] <= 1 and b["later_pclose"] == 0, "ownership")
    recovered_before, recovered_after = intact(old, expected), intact(new, expected)
    need(not recovered_before or recovered_after, "lost_recovery")
    need(all(new["unrelated"].values()) and old["unrelated"] == new["unrelated"] and
         old["native_main"] == new["native_main"], "unrelated_content")
    improved = not recovered_before and recovered_after
    if improved:
        need(any(x["code"] == "referenced_cluster_free" for x in old["structure"]), "unexplained_recovery")
        need(a["result"] < 0 and reads > 0, "confirmed_failed_recovery")
        need(all(b[f] == -5 for f in ("first_sync", "second_sync", "release")) and
             b["later_io"] == 0, "persistent_error_without_later_io")
    else:
        need(without_time(old) == without_time(new), "changed_observation")
        for field in ("first_sync", "second_sync", "release", "later_io"):
            need(a[field] == b[field], "changed_status:" + field)
    need(b["operation_io"] <= a["operation_io"] + reads, "unaccounted_io")
    ignored = {"operation_io", "allocation_reads"}
    if improved:
        ignored.update(("first_sync", "second_sync", "release", "later_io", "mapping_calls"))
        need(b["mapping_calls"] <= a["mapping_calls"], "additional_mapping_work")
    need({k: v for k, v in a.items() if k not in ignored} ==
         {k: v for k, v in b.items() if k not in ignored}, "changed_event")
    if a["result"] == 0:
        need(reads == 0 and a == b, "successful_path_changed")
    if mode == "normal" and a["result"] == 0:
        need(recovered_after, "invalid_normal")
    return improved


def cases(report):
    for profile, record in report["profiles"].items():
        if "cases" in record:
            pairs = [(mode, pair["baseline"], pair["candidate"]) for mode, pair in record["cases"].items()]
        else:
            need(record["compare_baseline"], "prefix_requires_compare_all:" + profile)
            verify_controls({"profiles": {profile: record}})
            need(all(case[field] for case in record["normal"].values()
                     for field in ("valid", "metadata_updated", "no_unnecessary_rewrite")),
                 "invalid_normal_or_metadata")
            pairs = [("normal", record["normal"]["baseline"], record["normal"]["candidate"])]
            pairs += [(mode, case["baseline_control"], case) for mode, case in record["faults"].items()]
            if "space_retry" in record:
                a, b = (record["space_retry"][v] for v in ("baseline", "candidate"))
                need(a["valid"] and b["valid"] and a["event"] == b["event"] and
                     without_time(a["observation"]) == without_time(b["observation"]), "space_retry")
        for mode, before, after in pairs:
            expected = record["new"] if before["event"]["result"] == 0 or mode == "metadata-fail" else record["old"]
            yield profile, mode, before, after, expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=Path)
    args = parser.parse_args()
    result = {"result": "PASS_LOCAL_ALLOCATION_CONTAINMENT", "pairs": 0, "improved": [],
              "remaining_recovery_gaps": {}, "max_validation_reads": 0, "negative_checks": 0,
              "scope": "returned-error comparison; no full recovery, crash or installed FSKit claim"}
    samples = {}
    for path in args.reports:
        report = json.loads(path.read_text())
        for profile, record in report["profiles"].items():
            if record.get("faults"):
                missing = {"profiles": {profile: deepcopy(record)}}
                next(iter(missing["profiles"][profile]["faults"].values())).pop("baseline_control")
                try:
                    list(cases(missing))
                except Invalid:
                    result["negative_checks"] += 1
                else:
                    raise ValueError("missing_control_accepted")
                for field in ("valid", "metadata_updated", "no_unnecessary_rewrite"):
                    invalid = {"profiles": {profile: deepcopy(record)}}
                    invalid["profiles"][profile]["normal"]["candidate"][field] = False
                    try:
                        list(cases(invalid))
                    except ValueError:
                        result["negative_checks"] += 1
                    else:
                        raise ValueError("invalid_normal_accepted:" + field)
                break
        remaining = []
        for profile, mode, before, after, expected in cases(report):
            try:
                improved = compare(before, after, expected, mode)
            except ValueError as error:
                raise ValueError(f"{path.parent.name}/{profile}/{mode}: {error}") from error
            result["pairs"] += 1
            result["max_validation_reads"] = max(result["max_validation_reads"], after["event"]["allocation_reads"])
            if improved:
                result["improved"].append(f"{path.parent.name}/{profile}/{mode}")
                samples["improved"] = (before, after, expected, mode)
            if mode == "normal" and before["event"]["result"] == 0:
                samples["normal"] = (before, after, expected, mode)
            if after["event"]["operation_io"] > before["event"]["operation_io"]:
                samples["reads"] = (before, after, expected, mode)
            if not intact(after["observation"], expected):
                remaining.append(profile + "/" + mode)
        result["remaining_recovery_gaps"][str(path)] = remaining
    need(result["improved"], "no_demonstrated_improvement")
    # Mutate real observations: the gate must reject unjustified extra I/O,
    # unbounded reads, new data errors, false success and missing controls.
    mutations = [("normal", "extra_io"), ("normal", "bad_content"),
                 ("reads", "unbounded"), ("reads", "missing_read_evidence"),
                 ("reads", "extra_io"), ("improved", "false_sync"),
                 ("improved", "later_io"), ("improved", "bad_content")]
    for sample, fault in mutations:
        before, after, expected, mode = deepcopy(samples[sample])
        if fault == "extra_io": after["event"]["operation_io"] += after["event"]["allocation_reads"] + 1
        elif fault == "bad_content": after["observation"]["named"]["sha256"] = "bad"
        elif fault == "unbounded": after["event"]["allocation_reads"] = 273
        elif fault == "missing_read_evidence": after["event"]["allocation_reads"] = 0
        elif fault == "false_sync": after["event"]["first_sync"] = 0
        elif fault == "later_io": after["event"]["later_io"] = 1
        try:
            compare(before, after, expected, mode)
        except ValueError:
            result["negative_checks"] += 1
        else:
            raise ValueError("negative_control_accepted:" + fault)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
