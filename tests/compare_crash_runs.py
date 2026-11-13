#!/usr/bin/env python3
"""Compare split-write runs at equivalent persisted byte ranges.

A resource write is not assumed atomic. Candidate cuts are projected onto the
baseline's contiguous write ranges, including partial/reordered subranges of a
larger baseline write. This is a declared model, not hardware behavior proof.
The independent oracle compares structure and test-file contents, not timestamps
or every NTFS field. Raw inherited structural failures remain failures.
"""
import argparse
import json
from pathlib import Path

from run_crash_consistency import (ROOT, MAX_EVENTS, MAX_PAYLOAD, MAX_STATES,
                                  cases, clone, compress, demand, digest, expand,
                                  observe, read_trace, save)


def grouped(events, payload):
    demand(payload.stat().st_size <= MAX_PAYLOAD, "payload limit")
    data = payload.read_bytes()
    groups, positions = [], {}
    for event in events:
        if event["kind"] == "write":
            demand(event["error"] == 0 and event["accepted"] == event["length"], "healthy traces only")
            if groups and groups[-1]["kind"] == "write" and groups[-1]["offset"] + len(groups[-1]["data"]) == event["offset"]:
                group = groups[-1]
            else:
                group = {"kind": "write", "offset": event["offset"], "data": bytearray()}
                groups.append(group)
            positions[event["event"]] = (len(groups) - 1, len(group["data"]), event["length"])
            group["data"].extend(data[event["payload"]:event["payload"] + event["length"]])
        else:
            groups.append({k: v for k, v in event.items() if k not in ("event", "writes", "flushes")})
    demand(len(groups) <= MAX_EVENTS, "group limit")
    return groups, positions


def ranges(row, positions, groups):
    demand(len(row["writes"]) <= MAX_EVENTS, "selection limit")
    selected = []
    for event, length in row["writes"]:
        demand(event in positions, "selected write exists")
        group, start, accepted = positions[event]
        demand(0 < length <= accepted, "selected range bounds")
        if selected and selected[-1][0] == group and selected[-1][1] + selected[-1][2] == start:
            selected[-1][2] += length
        else:
            selected.append([group, start, length])
    return selected


def render(seed, path, groups, selected):
    clone(seed, path)
    with path.open("r+b", buffering=0) as out:
        for index, start, length in selected:
            group = groups[index]
            out.seek(group["offset"] + start)
            demand(out.write(group["data"][start:start + length]) == length, "image write")


def canonical(structure, state):
    result = dict(structure)
    result["errors"] = sorted(result["errors"], key=lambda x: json.dumps(x, sort_keys=True))
    return {"structure": result, "state": state}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    work = args.output.absolute()
    demand(work.parent.resolve().is_relative_to((ROOT / "_tmp").resolve()) and not work.exists(), "new output beneath _tmp")
    work.mkdir(parents=True)
    sources = [args.baseline, args.candidate]
    manifests = [json.loads((p / "manifest.json").read_text()) for p in sources]
    for key in ("seed_sha256", "large_seed", "scenarios", "sectors"):
        demand(manifests[0].get(key) == manifests[1].get(key), "matching run " + key)
    source = args.candidate / "case-results.jsonl"
    demand(source.stat().st_size <= 64 << 20, "case result input limit")
    rows = [json.loads(line) for line in source.read_text().splitlines()]
    demand(0 < len(rows) <= MAX_STATES, "case count limit")
    expected_traces = {f"{scenario}-{sector}" for scenario in manifests[0]["scenarios"]
                       for sector in manifests[0]["sectors"]}
    demand({row["trace"] for row in rows} == expected_traces, "exact trace coverage")
    demand([row["case"] for row in rows] == list(range(1, len(rows) + 1)), "case sequence")
    demand(json.loads((args.candidate / "summary.json").read_text())["states"] == len(rows), "complete candidate cases")
    seed, left, right = (work / name for name in ("seed.img", "baseline.img", "candidate.img"))
    summary = {"cases": 0, "different": 0, "inherited_structural_findings": 0,
               "sync_cases": 0, "traces": [], "limits": "two traces at most 64 MiB each; at most 4096 cases; three 128 MiB images",
               "model": "equivalent persisted byte ranges; independent structure/content oracle; metadata timestamps not compared",
               "sources": {p.name: digest(p) for p in (Path(__file__), ROOT / "tests/ntfs_image_check.py", ROOT / "tests/run_crash_consistency.py")}}
    try:
        expand(args.baseline / "seed.img.gz", seed)
        demand(digest(seed) == manifests[0]["seed_sha256"], "exact shared seed")
        seed_check = json.loads((args.baseline / "seed-check.json").read_text())
        anchor = seed_check["paths"]["/crash-model/anchor"]
        with (work / "comparison.jsonl").open("w") as log:
            for scenario in manifests[0]["scenarios"]:
                for sector in manifests[0]["sectors"]:
                    label = f"{scenario}-{sector}"
                    all_groups, positions = [], None
                    event_counts = []
                    for p, manifest in zip(sources, manifests):
                        trace, payload = p / (label + ".jsonl"), p / (label + ".payload")
                        for file in (trace, payload):
                            demand(digest(file) == manifest["trace_sha256"][file.name], "trace hash")
                        events = read_trace(trace, payload, seed.stat().st_size)
                        g, positions = grouped(events, payload)
                        all_groups.append(g)
                        event_counts.append(sum(e["kind"] == "write" for e in events))
                    base, candidate = all_groups
                    trace_rows = [row for row in rows if row["trace"] == label]
                    recorded = [(row["model"], row["boundary"], row["writes"]) for row in trace_rows]
                    expected = [(model, boundary, [list(pair) for pair in writes])
                                for model, boundary, writes, _ in cases(events)]
                    demand(recorded == expected, "complete generated cuts for trace")
                    demand(len(base) == len(candidate), "same normalized write/marker groups")
                    exact, differing = [], []
                    for i, (a, b) in enumerate(zip(base, candidate)):
                        if a["kind"] == "write":
                            demand(b["kind"] == "write" and a["offset"] == b["offset"] and len(a["data"]) == len(b["data"]), "same normalized ranges")
                            (exact if a["data"] == b["data"] else differing).append(i)
                        else:
                            demand(a == b, "same application/barrier markers")
                    summary["traces"].append({"trace": label, "write_calls": event_counts, "byte_identical_groups": exact,
                                              "nonidentical_groups_checked_by_oracle": differing})
                    for row in trace_rows:
                        selected = ranges(row, positions, candidate)
                        try:
                            render(seed, left, base, selected); render(seed, right, candidate, selected)
                            sa, a = observe(left, anchor); sb, b = observe(right, anchor)
                            demand(sb["errors"] == row["errors"] and sb["anchor"] == row["anchor_status"], "candidate replay agrees with original case")
                            same = canonical(sa, a) == canonical(sb, b)
                            summary["cases"] += 1; summary["different"] += not same
                            summary["inherited_structural_findings"] += not sa["ok"]
                            summary["sync_cases"] += row["model"].startswith("sync-return")
                            log.write(json.dumps({"case": row["case"], "trace": label, "model": row["model"], "same": same,
                                                  "ranges": selected, "baseline_errors": sa["errors"], "candidate_errors": sb["errors"]}, sort_keys=True) + "\n")
                            if not same and summary["different"] <= 4:
                                compress(left, work / f"mismatch-{row['case']}-baseline.img.gz")
                                compress(right, work / f"mismatch-{row['case']}-candidate.img.gz")
                                save(work / f"mismatch-{row['case']}.json", {"baseline": canonical(sa, a), "candidate": canonical(sb, b), "case": row})
                        finally:
                            left.unlink(missing_ok=True); right.unlink(missing_ok=True)
                    print(f"{label}: {summary['cases']} compared; {summary['different']} differences", flush=True)
        summary["status"] = "pass_local_nonregression" if not summary["different"] else "comparison_difference"
    finally:
        seed.unlink(missing_ok=True); left.unlink(missing_ok=True); right.unlink(missing_ok=True)
        save(work / "summary.json", summary)
    return 0 if summary["status"] == "pass_local_nonregression" else 1


if __name__ == "__main__":
    raise SystemExit(main())
