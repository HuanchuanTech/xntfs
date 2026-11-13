#!/usr/bin/env python3
"""Trace real bridge writes on disposable files; replay bounded power-loss states.

No disk device, OS mount, installed extension, upstream rebuild, or repair is
used. An abstract full-flush model is a conditional guarantee, not a claim that
FSKit/USB/device caches actually implement that guarantee. Exit 1 means baseline
integrity failures were found; exit 2 means the harness itself failed.
"""
import argparse
import collections
import copy
import ctypes
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys

from ntfs_image_check import Image, Invalid, MAX_IMAGE, DATA, INDEX_ALLOC, uint

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = ("overwrite", "create", "extend", "truncate", "unlink", "link", "rename", "move",
             "xattr-small", "xattr-large", "index-growth")
LARGE_SCENARIOS = ("large-overwrite", "large-extend")
MAX_EVENTS, MAX_PAYLOAD, MAX_STATES, MAX_SAVED = 4096, 64 << 20, 4096, 12
PREFIX = "/crash-model/"


def demand(ok, message):
    if not ok:
        raise RuntimeError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as src:
        for data in iter(lambda: src.read(1 << 20), b""):
            h.update(data)
    return h.hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def compress(source, dest):
    with source.open("rb") as src, gzip.open(dest, "wb", compresslevel=1) as dst:
        shutil.copyfileobj(src, dst, 1 << 20)


def expand(source, dest):
    total = 0
    with gzip.open(source, "rb") as src, dest.open("xb") as dst:
        while data := src.read(1 << 20):
            total += len(data)
            demand(total <= MAX_IMAGE, "decompressed image limit")
            dst.write(data)


def clone(source, dest):
    st = source.lstat()
    demand(stat.S_ISREG(st.st_mode) and st.st_size <= MAX_IMAGE and not dest.exists(), "regular, bounded, new image copy")
    libc = ctypes.CDLL(None, use_errno=True)
    clonefile = libc.clonefile
    clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    clonefile.restype = ctypes.c_int
    if clonefile(os.fsencode(source), os.fsencode(dest), 0):
        # Copying ordinary files is safe on a filesystem without clone support.
        demand(not dest.exists(), "failed clone left destination")
        shutil.copyfile(source, dest)
    demand(dest.stat().st_ino != st.st_ino or dest.stat().st_dev != st.st_dev, "never modify fixture through hard link")


def run(command, log, timeout=45):
    with log.open("w") as output:
        subprocess.run([str(x) for x in command], cwd=ROOT, check=True, stdout=output,
                       stderr=subprocess.STDOUT, timeout=timeout,
                       env={k: v for k, v in os.environ.items() if k != "SDKROOT"})


def build(work, sanitizer, bridge_source, library, profile):
    sdk = subprocess.check_output(["env", "-u", "SDKROOT", "xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    flags = ["-O3" if profile.startswith("o3") else "-O2", "-g", "-Werror", "-arch", platform.machine(), "-mmacosx-version-min=15.4", "-isysroot", sdk,
             "-DHAVE_CONFIG_H=1", "-I" + str(library),
             "-I" + str(ROOT / "ntfs-3g/include"), "-I" + str(bridge_source)]
    link_flags = []
    if profile.endswith("thinlto"):
        flags.append("-flto=thin")
        link_flags = ["-Wl,-mllvm,-threads=2", "-Xlinker", "-object_path_lto", "-Xlinker", str(work / "lto-objects")]
    if sanitizer:
        flags += ["-fsanitize=" + sanitizer, "-fno-omit-frame-pointer"]
    commands = [
        ["xcrun", "clang", *flags, "-c", bridge_source / "ntfs_fskit.c", "-o", work / "bridge.o"],
        ["xcrun", "clang", *flags, "-fobjc-arc", "-c", bridge_source / "ntfs_device_fskit.m", "-o", work / "backend.o"],
        ["xcrun", "clang", *flags, "-fobjc-arc", "tests/crash_resource.m", work / "bridge.o", work / "backend.o",
         library / "libntfs-3g.a", "-framework", "Foundation", "-framework", "FSKit", *link_flags, "-o", work / "crash-resource"]]
    save(work / "build-commands.json", [[str(x) for x in c] for c in commands])
    for i, command in enumerate(commands):
        run(command, work / f"build-{i}.log", 90)
    return work / "crash-resource"


def pattern(size, seed):
    period = bytes((seed + i * 17) % 251 for i in range(251))
    return (period * (size // 251 + 1))[:size]


def content(data):
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def expected_seed(large=False):
    state = {"/crash-model": {"dir": True}}
    for name in ("left", "right", "busy"):
        state[PREFIX + name] = {"dir": True}
    for name, size, seed in (("anchor", 65536, 0x20), ("source", 65536, 0x31), ("target", 65536, 0x42),
                             ("grow", 4096, 0x53), ("attrs", 128, 0x64), ("delete", 8192, 0x77), ("left/move", 4096, 0x88)):
        state[PREFIX + name] = {"dir": False, "streams": {"": content(pattern(size, seed))}}
    state[PREFIX + "attrs"]["streams"].update({"crash.small": content(pattern(32, 0x65)), "crash.large": content(pattern(32768, 0x66))})
    if large:
        state[PREFIX + "large"] = {"dir": False, "streams": {"": content(pattern(2 << 20, 0x9a))}}
    return state


def expected_after(scenario, large=False):
    result = expected_seed(large)
    def data(name, value):
        result[PREFIX + name] = {"dir": False, "streams": {"": content(value)}}
    if scenario == "large-overwrite":
        old = pattern(2 << 20, 0x9a)
        data("large", old[:1] + pattern(1 << 20, 0xc1) + old[(1 << 20) + 1:])
    elif scenario == "large-extend":
        data("grow", pattern(4096, 0x53) + b"\x00" + pattern(1 << 20, 0xc2))
    elif scenario == "overwrite":
        data("target", pattern(4096, 0x90) + pattern(65536, 0x42)[4096:])
    elif scenario == "create":
        data("new-file", pattern(8192, 0x99))
    elif scenario == "extend":
        data("grow", pattern(4096, 0x53) + pattern(32768, 0xAA))
    elif scenario == "truncate":
        data("target", pattern(2048, 0x42))
    elif scenario == "unlink":
        del result[PREFIX + "delete"]
    elif scenario == "link":
        result[PREFIX + "alias"] = copy.deepcopy(result[PREFIX + "source"])
    elif scenario == "rename":
        result[PREFIX + "target"] = result.pop(PREFIX + "source")
    elif scenario == "move":
        result[PREFIX + "right/moved"] = result.pop(PREFIX + "left/move")
    elif scenario.startswith("xattr-"):
        small = scenario == "xattr-small"
        result[PREFIX + "attrs"]["streams"]["crash.small" if small else "crash.large"] = content(pattern(96 if small else 65536, 0xB1 if small else 0xB2))
    elif scenario == "index-growth":
        for i in range(32):
            data(f"busy/entry-{i:03d}-abcdefghijklmnopqrstuvwxyz-0123456789", b"")
    return result


def observe(path, anchor_ino=None):
    image = None
    state = None
    result = None
    try:
        image = Image(path)
        image.scan()
        state = {}
        for path, ino in image.paths.items():
            if path == "/crash-model" or path.startswith(PREFIX):
                r = image.records.get(ino)
                if r is None:
                    state[path] = {"unreadable": "missing_record"}
                    continue
                state[path] = {"dir": r["dir"]}
                if not r["dir"]:
                    state[path]["streams"] = {a["name"]: content(image.stream(a)) for a in r["attrs"] if a["type"] == DATA}
        result = image.result()
    except (Invalid, UnicodeError) as exc:
        result = {"ok": False, "errors": (image.errors if image else []) + [{"code": str(exc)}]}
    finally:
        if image:
            try:
                # Namespace loss is not proof of file-content damage. Check
                # the seeded MFT record directly when possible. A host read
                # error must escape as a harness error, not a crash finding.
                if result is not None:
                    ino = anchor_ino if anchor_ino is not None else image.paths.get(PREFIX + "anchor")
                    result["anchor"] = "uncheckable"
                    if ino in image.records:
                        try:
                            data = image.stream(image.attr(image.records[ino], DATA))
                            result["anchor"] = "intact" if content(data) == content(pattern(65536, 0x20)) else "damaged"
                        except (Invalid, UnicodeError):
                            pass
            finally:
                image.close()
    return result, state


def read_trace(log, payload, image_size):
    demand(log.stat().st_size <= MAX_EVENTS * 4096 and payload.stat().st_size <= MAX_PAYLOAD, "trace input bounds")
    events = [json.loads(line) for line in log.read_text().splitlines()]
    demand(0 < len(events) <= MAX_EVENTS, "event count")
    for i, event in enumerate(events, 1):
        demand(event["event"] == i, "event sequence")
        if event["kind"] == "write":
            off, size, accepted, at = (event[x] for x in ("offset", "length", "accepted", "payload"))
            demand(0 <= off <= image_size - size and 0 < size <= 16 << 20 and 0 <= accepted <= size and off % 512 == size % 512 == 0,
                   "recorded range")
            demand(0 <= at <= payload.stat().st_size - size, "recorded payload bounds")
    return events


def cases(events):
    """Every write boundary, sampled tear/reorder, and each barrier/marker.

    Duplicate physical states retain separate boundary labels in case-results.
    A case's writes are ordered event-number/accepted-length pairs.
    """
    prefix, durable = [], []
    for e in events:
        kind, i = e["kind"], e["event"]
        if kind == "write":
            yield "ordered-before", i, prefix[:], False
            for length in sorted({512, (e["accepted"] // 1024) * 512, e["accepted"] - 512}):
                if 0 < length < e["accepted"]:
                    yield "torn-prefix-sample", i, prefix + [(i, length)], False
            prefix.append((i, e["accepted"]))
            yield "ordered-after", i, prefix[:], False
            yield "latest-only-reorder-sample", i, durable + [(i, e["accepted"])], False
        elif kind == "flush":
            yield "full-flush-before", i, durable[:], False
            if e["error"] == 0:
                durable = prefix[:]
            yield "full-flush-after", i, durable[:], False
        elif kind == "operation":
            yield "operation-return-volatile-loss", i, durable[:], False
            yield "operation-return-write-through", i, prefix[:], False
        elif kind == "sync-result":
            yield "sync-return-full-flush", i, durable[:], e["result"] == 0
            yield "sync-return-write-through", i, prefix[:], e["result"] == 0
            # Negative control: a cache-only flush cannot establish direct-write
            # durability. This must be detected, not reported as an FSKit fact.
            yield "cache-only-flush-negative-control", i, [], e["result"] == 0


def materialize(seed, dest, events, payload, writes):
    clone(seed, dest)
    with dest.open("r+b", buffering=0) as out, payload.open("rb", buffering=0) as src:
        for index, length in writes:
            e = events[index - 1]
            demand(e["kind"] == "write" and 0 < length <= e["accepted"], "replay only accepted bytes")
            src.seek(e["payload"]); data = src.read(length)
            demand(len(data) == length, "payload short read")
            out.seek(e["offset"]); demand(out.write(data) == length, "durable-image short write")


def negative_controls(seed, work):
    """Independently corrupt MST, allocation, index reference, and data content."""
    im = Image(seed)
    try:
        im.scan()
        anchor = im.paths[PREFIX + "anchor"]
        attr = im.attr(im.records[anchor], DATA)
        cluster = attr["runs"][0][2]
        bitmap = im.attr(im.records[6], DATA)
        cb_offset = im.physical(bitmap, cluster // 8)
        index = im.attr(im.records[5], INDEX_ALLOC, "$I30")
        index_offset = im.physical(index, 0)
        # First root index entry begins at INDX header + entries_offset.
        block = im.read(index_offset, 4096)
        entry_offset = index_offset + 24 + int.from_bytes(block[24:28], "little")
        target = im.paths[PREFIX + "target"]
        target_attr = im.attr(im.records[target], DATA)
        raw_attr = im.records[target]["data"][target_attr["pos"]:]
        run = uint(raw_attr, 32, 2)
        widths = raw_attr[run]
        loc_offset = im.physical(im.mft, target * im.record_size + target_attr["pos"] + run + 1 + (widths & 15))
        changes = {"torn_mft": (im.physical(im.mft, anchor * im.record_size) + 510, b"\x00\x00"),
                   "free_referenced_cluster": (cb_offset, bytes([im.read(cb_offset, 1)[0] & ~(1 << (cluster % 8))])),
                   "bad_index_sequence": (entry_offset + 6, b"\xff\xff"),
                   "cluster_crosslink": (loc_offset, cluster.to_bytes(widths >> 4, "little", signed=True)),
                   "anchor_damage": (cluster * im.cluster, b"BROKEN")}
    finally:
        im.close()
    results = []
    for name, (offset, data) in changes.items():
        path = work / "negative.img"; clone(seed, path)
        try:
            with path.open("r+b", buffering=0) as out:
                out.seek(offset); demand(out.write(data) == len(data), "negative-control write")
            structure, state = observe(path, anchor)
            expected_code = {"torn_mft": "mst_torn:FILE", "free_referenced_cluster": "referenced_cluster_free",
                             "bad_index_sequence": "index_target_invalid", "cluster_crosslink": "cluster_crosslink"}
            detected = (expected_code[name] in {e["code"] for e in structure["errors"]}
                        if name != "anchor_damage" else structure["anchor"] == "damaged")
            demand(detected, "oracle missed negative control " + name)
            results.append({"name": name, "detected": detected, "errors": structure["errors"]})
        finally:
            path.unlink()
    # A host image I/O failure is a harness failure. It must keep its original
    # errno and close the image, rather than be mislabeled as a disk finding.
    from unittest.mock import patch
    closed = []
    original_close = Image.close
    def close(image):
        closed.append(image.fd)
        original_close(image)
    try:
        with patch.object(Image, "scan", side_effect=OSError(5, "injected image read failure")), patch.object(Image, "close", close):
            observe(seed)
    except OSError as exc:
        demand(exc.errno == 5 and len(closed) == 1, "host image failure and ownership")
    else:
        raise RuntimeError("host image failure was swallowed")
    results.append({"name": "host_read_error", "detected": True, "fd_closed": True})
    return results


def live_faults(binary, seed, work, sector, large=False):
    results = []
    faults = [("overwrite", 1, 0), ("extend", 1, 0), ("rename", 1, 0), ("xattr-large", 1, 0), ("overwrite", 0, 1)]
    if large:
        faults += [("large-overwrite", 1, 0), ("large-extend", 1, 0), ("large-overwrite", 0, 1)]
    for scenario, disconnect, flush in faults:
        label = f"live-{sector}-{scenario}-{disconnect}-{flush}"
        image, log, payload = (work / (label + suffix) for suffix in (".img", ".jsonl", ".payload"))
        clone(seed, image)
        try:
            run([binary, "trace", image, log, payload, scenario, sector, disconnect, flush], work / (label + ".log"))
            events = read_trace(log, payload, image.stat().st_size)
            op = next(e for e in events if e["kind"] == "operation")
            sync = next(e for e in events if e["kind"] == "sync-result")
            end = next(e for e in events if e["kind"] == "survived")
            # Retrying a failed flush may perform valid I/O. A disconnected
            # resource may only reject calls, never service the old generation.
            if disconnect:
                passed = (not op["ok"] and sync["result"] < 0 and end["retry"] < 0 and end["release"] < 0 and
                          end["serviced_before_retry"] == end["serviced_before_release"] == end["serviced_after_release"])
            else:
                passed = sync["result"] < 0 and end["retry"] < 0
            results.append({"label": label, "pass": passed, "operation": op, "sync": sync, "survived": end})
        finally:
            image.unlink(missing_ok=True)
    return results


def replay_case(source, number, work):
    demand(number is not None and 1 <= number <= MAX_STATES, "bounded case number required")
    manifest = json.loads((source / "manifest.json").read_text())
    rows = source / "case-results.jsonl"
    demand(rows.stat().st_size <= 64 << 20, "case-results limit")
    found = None
    with rows.open() as stream:
        for index, line in enumerate(stream, 1):
            demand(index <= MAX_STATES, "case count limit")
            row = json.loads(line)
            if row["case"] == number:
                found = row; break
    demand(found is not None, "case not found")
    label = found["trace"]
    demand(label in {f"{s}-{sector}" for s in SCENARIOS + LARGE_SCENARIOS for sector in (512, 4096)}, "known trace name")
    log, payload = source / (label + ".jsonl"), source / (label + ".payload")
    for path in (log, payload):
        demand(digest(path) == manifest["trace_sha256"][path.name], "trace hash mismatch")
    seed, image = work / "seed.img", work / "case.img"
    try:
        expand(source / "seed.img.gz", seed)
        demand(digest(seed) == manifest["seed_sha256"], "seed hash mismatch")
        events = read_trace(log, payload, seed.stat().st_size)
        materialize(seed, image, events, payload, found["writes"])
        original = json.loads((source / "seed-check.json").read_text())
        structure, state = observe(image, original["paths"][PREFIX + "anchor"])
        reproduced = (structure["errors"] == found["errors"] and structure["anchor"] == found["anchor_status"])
        result = {"case": found, "sha256": digest(image), "structure": structure, "state": state, "reproduced": reproduced}
        save(work / "replay.json", result)
        demand(reproduced, "replay result differed from recorded case")
        print(json.dumps({"reproduced": True, "case": number, "image": str(image)}))
    finally:
        seed.unlink(missing_ok=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new directory beneath project _tmp")
    parser.add_argument("--fixture", type=Path, default=ROOT / "tests/work.ntfs")
    parser.add_argument("--sanitize", choices=("address", "thread"))
    parser.add_argument("--bridge-source", type=Path, default=ROOT / "ntfs3g/bridge", help="frozen bridge/backend source directory for A/B runs")
    parser.add_argument("--library-dir", type=Path, default=ROOT / "build/libntfs-universal")
    parser.add_argument("--bridge-profile", choices=("o2", "o3", "o2-thinlto", "o3-thinlto"), default="o2")
    parser.add_argument("--seed-from", type=Path, help="reuse a prior run's exact archived seed, after hash/profile verification")
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS + LARGE_SCENARIOS, default=SCENARIOS)
    parser.add_argument("--sectors", nargs="+", type=int, choices=(512, 4096), default=(512, 4096))
    parser.add_argument("--replay-from", type=Path, help="rebuild one recorded case using its archived seed and trace")
    parser.add_argument("--case", type=int)
    args = parser.parse_args()
    work, fixture = args.output.absolute(), args.fixture.absolute()
    demand(work.parent.resolve().is_relative_to((ROOT / "_tmp").resolve()), "output must be beneath project _tmp")
    demand(not work.exists(), "new output directory required")
    work.mkdir(parents=True)
    if args.replay_from:
        return replay_case(args.replay_from, args.case, work)
    demand(stat.S_ISREG(fixture.lstat().st_mode) and fixture.stat().st_size <= MAX_IMAGE, "bounded regular fixture")
    bridge_source = args.bridge_source.resolve()
    library = args.library_dir.resolve()
    large = any(s in LARGE_SCENARIOS for s in args.scenarios)
    source_paths = ["tests/crash_resource.m", "tests/ntfs_image_check.py", "tests/run_crash_consistency.py"]
    source_paths += [os.path.relpath(library / name, ROOT) for name in ("libntfs-3g.a", "config.h")]
    source_paths += [os.path.relpath(bridge_source / name, ROOT) for name in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m")]
    frozen = {p: digest(ROOT / p) for p in source_paths}
    manifest = {"sources": frozen, "fixture": {"path": str(fixture), "sha256": digest(fixture), "size": fixture.stat().st_size},
                "platform": platform.platform(), "sanitizer": args.sanitize, "scenarios": list(args.scenarios), "sectors": list(args.sectors),
                "limits": {"image_bytes": MAX_IMAGE, "events_per_trace": MAX_EVENTS, "payload_bytes_per_trace": MAX_PAYLOAD,
                           "states": MAX_STATES, "saved_failure_images": MAX_SAVED},
                "scope": "local trace/replay only; no hardware, FSKit lifecycle, Windows repair, or journal-replay proof",
                "trace_sha256": {}, "large_seed": large, "bridge_source": str(bridge_source),
                "library_dir": str(library), "bridge_profile": args.bridge_profile}
    save(work / "manifest.json", manifest)
    seed = work / "seed.img"
    binary = build(work, args.sanitize, bridge_source, library, args.bridge_profile)
    summary = {"states": 0, "integrity_failures": 0, "sync_failures": 0, "anchor_failures": 0, "anchor_uncheckable": 0, "negative_controls": 0,
               "by_scenario": {}, "by_model": {}, "error_codes": {}, "saved": [], "status": "running"}
    save(work / "summary.json", summary)
    try:
        original, _ = observe(fixture)
        demand(original["ok"], "original fixture fails independent checker")
        save(work / "original-check.json", original)
        if args.seed_from:
            prior = json.loads((args.seed_from / "manifest.json").read_text())
            demand(prior.get("large_seed", False) == large, "shared seed profile mismatch")
            expand(args.seed_from / "seed.img.gz", seed)
            demand(digest(seed) == prior["seed_sha256"], "shared seed hash mismatch")
            manifest["seed_from"] = str(args.seed_from.resolve())
        else:
            clone(fixture, seed)
            run([binary, "prepare", seed, *(["large"] if large else [])], work / "prepare.log")
        seed_check, state = observe(seed)
        save(work / "seed-check.json", seed_check)
        demand(seed_check["ok"] and state == expected_seed(large), "seed structure/content must independently pass")
        anchor_ino = seed_check["paths"][PREFIX + "anchor"]
        manifest["seed_sha256"] = digest(seed); save(work / "manifest.json", manifest)
        compress(seed, work / "seed.img.gz")
        save(work / "oracle-negative-controls.json", negative_controls(seed, work))
        counters, codes, saved_types = collections.defaultdict(collections.Counter), collections.Counter(), set()
        live = []
        with (work / "case-results.jsonl").open("w") as case_log:
            for sector in args.sectors:
                live.extend(live_faults(binary, seed, work, sector, large))
                save(work / "live-faults.json", live)
                for scenario in args.scenarios:
                    label = f"{scenario}-{sector}"
                    visible, log, payload = (work / (label + suffix) for suffix in (".img", ".jsonl", ".payload"))
                    clone(seed, visible)
                    try:
                        run([binary, "trace", visible, log, payload, scenario, sector, 0, 0], work / (label + ".log"))
                        events = read_trace(log, payload, seed.stat().st_size)
                        manifest["trace_sha256"].update({log.name: digest(log), payload.name: digest(payload)})
                        save(work / "manifest.json", manifest)
                        demand(next(e for e in events if e["kind"] == "operation")["ok"], "healthy operation failed")
                        demand(next(e for e in events if e["kind"] == "sync-result")["result"] == 0, "healthy sync failed")
                    finally:
                        visible.unlink(missing_ok=True)
                    old, expected = expected_seed(large), expected_after(scenario, large)
                    for model, boundary, writes, require_final in cases(events):
                        summary["states"] += 1
                        demand(summary["states"] <= MAX_STATES, "replay state limit")
                        path = work / "case.img"
                        materialize(seed, path, events, payload, writes)
                        try:
                            structure, state = observe(path, anchor_ino)
                            structural = not structure["ok"]
                            anchor = structure.get("anchor") == "damaged"
                            matches = state == expected
                            if matches and scenario == "link":
                                matches = structure["paths"].get(PREFIX + "alias") == structure["paths"].get(PREFIX + "source")
                            sync_fail = require_final and (structural or not matches)
                            negative = model == "cache-only-flush-negative-control"
                            if negative:
                                demand(sync_fail, "durability negative control was missed")
                                summary["negative_controls"] += 1
                            else:
                                summary["integrity_failures"] += structural
                                summary["sync_failures"] += sync_fail
                                summary["anchor_failures"] += anchor
                                summary["anchor_uncheckable"] += structure.get("anchor") != "intact" and not anchor
                            disposition = "after" if matches else "before" if state == old else "intermediate" if state is not None else "unreadable"
                            row = {"case": summary["states"], "trace": label, "model": model, "boundary": boundary,
                                   "writes": writes, "structural_failure": structural, "anchor_damage": anchor,
                                   "anchor_status": structure.get("anchor", "uncheckable"), "sync_failure": sync_fail,
                                   "negative_control": negative, "disposition": disposition, "errors": structure["errors"]}
                            case_log.write(json.dumps(row, sort_keys=True) + "\n"); case_log.flush()
                            counters[scenario]["cases"] += 1; counters[model]["cases"] += 1
                            if not negative and (structural or sync_fail or anchor):
                                counters[scenario]["failures"] += 1; counters[model]["failures"] += 1
                                types = tuple(sorted({e["code"] for e in structure["errors"]})) or ("sync_content" if sync_fail else "anchor",)
                                codes.update(types)
                                # One complete-write interruption per scenario;
                                # other cases remain exactly replayable from the
                                # archived seed and hashed trace/payload.
                                if model == "ordered-after" and scenario not in saved_types and len(summary["saved"]) < MAX_SAVED:
                                    saved_types.add(scenario)
                                    archive = work / f"failure-{summary['states']:04d}.img.gz"
                                    compress(path, archive)
                                    run([binary, "probe", path], work / f"failure-{summary['states']:04d}-probe.log")
                                    evidence = {"file": archive.name, "sha256": digest(path), **row}
                                    save(archive.with_suffix(".json"), evidence); summary["saved"].append(evidence)
                        finally:
                            path.unlink(missing_ok=True)
                    print(f"{label}: completed {summary['states']} cumulative states; {summary['integrity_failures']} structural failures", flush=True)
                    summary["by_scenario"] = {k: dict(counters[k]) for k in args.scenarios}
                    summary["by_model"] = {k: dict(v) for k, v in counters.items() if k not in SCENARIOS + LARGE_SCENARIOS}
                    summary["error_codes"] = dict(codes); save(work / "summary.json", summary)
        summary["live_faults"] = {"total": len(live), "failed": sum(not e["pass"] for e in live)}
        summary["status"] = "baseline_fail" if (summary["integrity_failures"] or summary["sync_failures"] or summary["anchor_failures"] or summary["live_faults"]["failed"]) else "pass_local_model"
    except BaseException as exc:
        summary["status"] = "harness_error"
        summary["harness_error"] = str(exc)
        raise
    finally:
        demand(digest(fixture) == manifest["fixture"]["sha256"], "original fixture changed")
        demand(all(digest(ROOT / p) == sha for p, sha in frozen.items()), "source/library/config changed during run")
        summary["fixture_and_sources_unchanged"] = True
        save(work / "summary.json", summary)
        seed.unlink(missing_ok=True)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("saved", "by_model", "by_scenario")}, sort_keys=True))
    return 0 if summary["status"] == "pass_local_model" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.SubprocessError, OSError, Invalid) as exc:
        print("HARNESS ERROR:", exc, file=sys.stderr)
        raise SystemExit(2)
