#!/usr/bin/env python3
"""Check the bounded EOF-restoration regression against paired image reports.

Inputs: run_compressed_xattr_matrix.py and run_compressed_prefix.py --compare-all
summaries. The five demonstrated rollback improvements are required; every other
outcome and all backend I/O counts must stay unchanged. Full recovery is separate.
"""
import argparse
from copy import deepcopy
import json
from pathlib import Path

from compare_allocation_recovery import cases, need, without_time
from run_compressed_prefix import intact

EXPECTED = {("a-zero", "rollback-fail"), ("tiny-zero", "rollback-fail"),
            ("growth", "rollback-fail"), ("random", "rollback-fail"), ("mixed", "rollback-fail")}


def compare(before, after, expected):
    a, b = before["event"], after["event"]
    old, new = before["observation"], after["observation"]
    recovered_before, recovered_after = intact(old, expected), intact(new, expected)
    need(not recovered_before or recovered_after, "lost_recovery")
    improved = not recovered_before and recovered_after
    ignored = {"mapping_calls", "truncate_calls"} if improved else set()
    need({k: v for k, v in a.items() if k not in ignored} ==
         {k: v for k, v in b.items() if k not in ignored}, "changed_status_io_or_ownership")
    need(b["attrs_live"] == 0 and b["attrs_peak"] <= 1 and b["later_pclose"] == 0, "attribute_ownership")
    need(all(new["unrelated"].values()) and old["unrelated"] == new["unrelated"] and
         old["native_main"] == new["native_main"], "unrelated_content")
    if improved:
        need(all(b[f] == -5 for f in ("result", "first_sync", "second_sync", "release")) and
             b["later_io"] == 0, "persistent_error")
        need(not old["structure"] and old["named"]["size"] > expected["size"], "unexpected_baseline")
        need(b["mapping_calls"] == a["mapping_calls"] + 1 and
             b["truncate_calls"] == a["truncate_calls"] + 1, "bounded_restore_work")
    else:
        need(without_time(old) == without_time(new), "changed_control")
    return improved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="+")
    args = parser.parse_args()
    found, total, gaps, sample = set(), 0, {}, None
    for path in args.reports:
        remaining = []
        for profile, mode, before, after, expected in cases(json.loads(path.read_text())):
            try:
                improved = compare(before, after, expected)
            except ValueError as error:
                raise ValueError(f"{path.parent.name}/{profile}/{mode}: {error}") from error
            total += 1
            if improved:
                need((profile, mode) not in found, "duplicate_case")
                found.add((profile, mode))
                sample = before, after, expected
            if not intact(after["observation"], expected):
                remaining.append(profile + "/" + mode)
        gaps[str(path)] = remaining
    need(found == EXPECTED, "expected_five_restorations:" + repr(found))
    negative_checks = 0
    for fault in ("unchanged_old", "bad_size", "bad_content", "false_sync", "extra_io",
                  "extra_mapping", "structure", "ownership"):
        before, after, expected = deepcopy(sample)
        if fault == "unchanged_old": after = deepcopy(before)
        elif fault == "bad_size": after["observation"]["named"]["size"] += 1
        elif fault == "bad_content": after["observation"]["native_named"]["content"]["sha256"] = "bad"
        elif fault == "false_sync": after["event"]["first_sync"] = 0
        elif fault == "extra_io": after["event"]["operation_io"] += 1
        elif fault == "extra_mapping": after["event"]["mapping_calls"] += 1
        elif fault == "structure": after["observation"]["structure"] = [{"code": "referenced_cluster_free"}]
        elif fault == "ownership": after["event"]["attrs_live"] = 1
        try:
            need(compare(before, after, expected), "missing_restoration")
        except ValueError:
            negative_checks += 1
        else:
            raise ValueError("negative_control_accepted:" + fault)
    print(json.dumps({"result": "PASS_LOCAL_BOUNDED_EOF_RESTORATION", "pairs": total,
                      "improved": sorted(found), "negative_checks": negative_checks,
                      "remaining_recovery_gaps": gaps,
                      "scope": "paired returned-error checks; not full recovery or power-loss acceptance"}, indent=2))


if __name__ == "__main__":
    main()
