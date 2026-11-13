#!/usr/bin/env python3
"""Compare rollback containment without treating unrecovered bytes as passing.

Inputs are summary.json files from run_compressed_xattrs.py on the same fixture.
Both full runs may exit 1 for recovery gaps. This separate gate requires unchanged
normal/recovered outcomes and parseable records in every still-fatal candidate.
"""
import argparse
import json
from pathlib import Path


def demand(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    old, new = [json.loads(p.read_text()) for p in (args.baseline, args.candidate)]
    demand(old["normal"] == new["normal"], "normal replacement outcomes changed")
    demand(set(old["faults"]) == set(new["faults"]), "fault matrix differs")
    demand(old["recovery_gaps"] == new["recovery_gaps"], "recovery gap set changed; review separately")
    improved = []
    for name, before in old["faults"].items():
        after = new["faults"][name]
        if name not in old["recovery_gaps"]:
            # Raw disk hashes include wall-clock timestamps. The candidate may
            # inspect mapping pairs earlier; bytes, errors, actual backend I/O
            # and ownership still have to match.
            ignored = {"image_sha256", "mapping_calls"}
            demand({k: v for k, v in before.items() if k not in ignored} ==
                   {k: v for k, v in after.items() if k not in ignored}, "changed control: " + name)
            continue
        for field in ("result", "first_sync", "second_sync", "release", "later_io", "attrs_live", "attrs_peak"):
            demand(before[field] == after[field], "changed error/lifetime: " + name + ":" + field)
        a, b = before["observation"], after["observation"]
        demand(b["inode_parseable"] and b["unrelated_content"] == "PASS", "record/other data: " + name)
        if a["inode_parseable"]:
            demand(a["named"] == b["named"], "changed unrecovered content: " + name)
        demand(after["operation_io"] <= before["operation_io"], "added error-path I/O: " + name)
        old_orphans = {x["cluster"] for x in a["structure_findings"] if x["code"] == "allocated_cluster_unowned"}
        demand(all(x["code"] == "allocated_cluster_unowned" and x["cluster"] in old_orphans
                   for x in b["structure_findings"]), "new structure finding: " + name)
        if (not a["inode_parseable"] or len(b["structure_findings"]) < len(a["structure_findings"]) or
                after["operation_io"] < before["operation_io"]):
            improved.append(name)
    demand(improved, "no demonstrated containment improvement")
    print(json.dumps({"result": "PASS_LOCAL_MAPPING_CONTAINMENT", "improved": improved,
                      "remaining_recovery_gaps": new["recovery_gaps"],
                      "scope": "returned-error containment only; no full recovery or power-loss claim"}, indent=2))


if __name__ == "__main__":
    main()
