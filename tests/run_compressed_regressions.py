#!/usr/bin/env python3
"""Real compressed DATA fixtures on disposable ordinary images; never OS mounts.

Exit 0 means the requested local checks pass, 1 a reproduced product gap, 2 a
harness/build/fixture error. --fixtures-only validates the generator/oracle only.
"""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
from validation_timing import run_timed

from ntfs_image_check import DATA, Image, Invalid, need
from ntfs_compressed_check import CompressedImage, self_test

ROOT = Path(__file__).resolve().parent.parent


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def noise(length):
    return b"".join(hashlib.sha256(i.to_bytes(4, "little")).digest()
                    for i in range((length + 31) // 32))[:length]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=ROOT / "ntfs3g/bridge")
    parser.add_argument("--sanitize", choices=("address", "undefined"))
    parser.add_argument("--fixtures-only", action="store_true")
    parser.add_argument("--truncate-only", action="store_true", help="check growth without accepting the still-open finalization feature")
    parser.add_argument("--new-tail", action="store_true", help="bounded new-tail finalization; retains the known old half-full tail gap")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--uninstrumented", action="store_true")
    parser.add_argument("--swift", action="store_true", help="experimental finalization acceptance through Swift callbacks")
    args = parser.parse_args()
    if args.new_tail and (args.fixtures_only or args.truncate_only or args.build_only):
        parser.error("new-tail is a separate acceptance scope")
    if args.uninstrumented and not args.build_only:
        parser.error("uninstrumented builds are only for independent timing runs")
    if args.swift and (args.fixtures_only or args.truncate_only or args.build_only or args.sanitize == "undefined"):
        parser.error("Swift lifecycle requires full normal or AddressSanitizer checks")
    fixture, output, source = (p.resolve() for p in (args.fixture, args.output, args.source))
    if args.fixture.is_symlink() or not fixture.is_file() or not 512 <= fixture.stat().st_size <= 128 << 20:
        parser.error("expected bounded ordinary NTFS file")
    if not output.is_relative_to(ROOT / "_tmp"):
        parser.error("output must be a new directory below project _tmp")
    output.mkdir(parents=True, exist_ok=False)
    frozen = output / "source"
    frozen.mkdir()
    paths = [source / name for name in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m")]
    paths += [ROOT / "tests" / name for name in ("compressed_fixture.c", "ntfs_compressed_check.py", "ntfs_image_check.py", "validation_timing.py", Path(__file__).name)]
    if args.swift:
        paths += [ROOT / "ntfs3g" / name for name in ("ntfs3gVolume.swift", "ntfs3gFileSystem.swift", "ntfs3gItem.swift")]
        paths += [ROOT / "Shared/DiagnosticRecorder.swift", ROOT / "tests/test_compressed_volume.swift"]
    for path in paths:
        shutil.copy2(path, frozen / path.name)
    library = ROOT / "build/libntfs-universal"
    env = dict(os.environ)
    env.pop("SDKROOT", None)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
    flags = ["-O2", "-g", "-Wall", "-Wextra", "-Werror", "-arch", platform.machine(),
             "-isysroot", sdk, "-mmacosx-version-min=15.4", "-DHAVE_CONFIG_H=1",
             "-I" + str(library), "-I" + str(ROOT / "ntfs-3g/include"), "-I" + str(frozen)]
    if args.sanitize:
        flags += ["-fsanitize=" + args.sanitize, "-fno-omit-frame-pointer", "-fno-sanitize-recover=undefined"]
    bridge_hooks = [] if args.uninstrumented else ["-Dntfs_attr_pclose=nfsk_fixture_attr_pclose",
         "-Dntfs_inode_sync=nfsk_fixture_inode_sync", "-Dntfs_attr_open=nfsk_fixture_attr_open", "-Dntfs_attr_close=nfsk_fixture_attr_close",
         "-Dntfs_attr_pwrite=nfsk_fixture_attr_pwrite",
         "-Dntfs_attr_add=nfsk_fixture_attr_add", "-Dntfs_attr_rm=nfsk_fixture_attr_rm",
         "-Dntfs_attr_pread=nfsk_fixture_attr_pread",
         "-Dntfs_attr_truncate=nfsk_fixture_attr_truncate",
         "-Dntfs_mapping_pairs_decompress=nfsk_fixture_mapping_pairs_decompress"]
    backend_hooks = [] if args.uninstrumented else ["-Dpread=nfsk_fixture_pread", "-Dpwrite=nfsk_fixture_pwrite", "-Dfsync=nfsk_fixture_fsync"]
    commands = [
        ["xcrun", "clang", *flags, *bridge_hooks, "-c", frozen / "ntfs_fskit.c", "-o", output / "bridge.o"],
        ["xcrun", "clang", *flags, "-fobjc-arc", *backend_hooks,
         "-c", frozen / "ntfs_device_fskit.m", "-o", output / "backend.o"],
        ["xcrun", "clang", *flags, frozen / "compressed_fixture.c", output / "bridge.o", output / "backend.o",
         library / "libntfs-3g.a", "-framework", "Foundation", "-framework", "CoreFoundation", "-framework", "FSKit", "-o", output / "fixture-tool"],
    ]
    manifest = {"commands": [[str(x) for x in c] for c in commands], "sdk": sdk,
                "fixture": sha(fixture), "library": sha(library / "libntfs-3g.a"), "config": sha(library / "config.h"),
                "sources": {p.name: sha(p) for p in frozen.iterdir()},
                "instrumented": not args.uninstrumented,
                "scope": "file-image local; prebuilt libntfs not sanitizer-instrumented; no Windows or physical device"}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def run(command, label):
        command = [str(x) for x in command]
        phase = ("build" if label.startswith(("build-", "swift-build-")) else
                 "fixture" if label.startswith("seed-") else "test")
        result = run_timed(command, timing_path=output / "timings.jsonl", phase=phase, label=label,
                           env=env, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=90)
        (output / (label + ".log")).write_text(result.stdout)
        if result.returncode:
            raise RuntimeError(label + ": " + result.stdout[-3000:])
        return result.stdout

    for i, command in enumerate(commands):
        run(command, "build-" + str(i))
    if args.build_only:
        print("Built:", output / "fixture-tool")
        return 0
    self_test()
    tool = output / "fixture-tool"
    seeded = output / "seeded.img"
    shutil.copyfile(fixture, seeded)
    with fixture.open("rb") as stream:
        boot = stream.read(512)
    unit = boot[13] * 512 * 16
    need(8192 <= unit <= 65536, "fixture_compression_geometry")
    inputs = {"Empty": b"", "Small": b"resident-compressed-" * 7,
              "High": b"Q" * (unit * 3 + 123),
              "Mixed": b"M" * unit + noise(unit) + bytes(unit) + b"tail" * 1251,
              "Random": noise(unit * 3 + 1199), "Zero": bytes(unit * 2 + 29),
              "Plain": b"P" * (unit * 2 + 3001)}
    if args.new_tail:
        inputs["Aligned"] = b"Q" * (unit * 3)
    for name, data in inputs.items():
        payload = output / (name + ".data")
        payload.write_bytes(data)
        run([tool, "seed", seeded, name, payload, int(name != "Plain"), 1], "seed-" + name)
    seed_hash = sha(seeded)
    report = {"decoder_controls": self_test(), "fixtures": {}, "observations": {}, "defects": [],
              "acceptance_scope": "new-tail finalization; old half-full tails remain open" if args.new_tail else
                                  "truncate only; finalization remains open" if args.truncate_only else "full requested checks"}

    def inspect(image, name, expected, label):
        parsed = CompressedImage(image)
        try:
            parsed.scan()
            need(not parsed.errors, "structure:" + json.dumps(parsed.errors[:3]))
            attr = parsed.attr(parsed.records[parsed.paths["/" + name]], DATA)
            decoded = parsed.stream(attr)
            info = {"size": attr["size"], "initialized": attr["initialized"], "allocated": attr.get("allocated"),
                    "physical": attr.get("compressed_size"), "compression": attr.get("compression"),
                    "layout": parsed.layout(attr), "sha256": hashlib.sha256(decoded).hexdigest()}
            need(decoded == expected, "independent_content:" + label)
        finally:
            parsed.close()
        readback = output / (label + ".readback")
        native = json.loads(run([tool, "read", image, name, readback], label + "-library"))
        need(readback.read_bytes() == expected, "library_content:" + label)
        readback.unlink()
        need(native["size"] == len(expected), "library_size:" + label)
        return info

    for name, data in inputs.items():
        report["fixtures"][name] = inspect(seeded, name, data, "fixture-" + name)
    need("lznt1" in report["fixtures"]["High"]["layout"], "genuine_compressed_clusters")
    need(set(report["fixtures"]["Mixed"]["layout"]) >= {"lznt1", "raw", "hole"}, "mixed_unit_layout")
    need(report["fixtures"]["Small"]["layout"] == ["resident"], "resident_fixture")
    need(report["fixtures"]["Plain"]["compression"] == 0, "ordinary_control")
    need(sha(seeded) == seed_hash, "read_only_inspection_mutated_fixture")
    # The existing oracle must still fail closed on compressed fixtures.
    probe = CompressedImage(seeded)
    try:
        probe.scan()
        compressed_record = probe.records[probe.paths["/High"]]["data"]
    finally:
        probe.close()
    old = Image(seeded)
    try:
        try:
            old.attrs(compressed_record)
        except Invalid as exc:
            need(str(exc) == "unsupported:compressed_or_encrypted", "old_oracle_error")
        else:
            raise Invalid("old_oracle_accepted_compression")
    finally:
        old.close()
    report["old_oracle_rejects_compression"] = True
    report["negative_controls"] = []
    probe = CompressedImage(seeded)
    try:
        probe.scan()
        attr = probe.attr(probe.records[probe.paths["/High"]], DATA)
        cluster = next(probe.units(attr))[0]
        for label, field, value in (("unit", 34, (3).to_bytes(2, "little")),
                                    ("physical-size", 64, (attr["compressed_size"] + 1).to_bytes(8, "little"))):
            damaged = bytearray(compressed_record)
            damaged[attr["pos"] + field:attr["pos"] + field + len(value)] = value
            try:
                probe.attrs(damaged)
            except Invalid as exc:
                report["negative_controls"].append({"case": label, "detected": str(exc)})
            else:
                raise Invalid("accepted_damaged_" + label)
        for label, delta in (("chunk-signature", 1), ("content", 3)):
            damaged = output / "negative.img"
            shutil.copyfile(seeded, damaged)
            with damaged.open("r+b") as stream:
                stream.seek(cluster * probe.cluster + delta)
                value = stream.read(1)[0] ^ 0x10
                stream.seek(-1, 1)
                stream.write(bytes([value]))
            try:
                inspect(damaged, "High", inputs["High"], "negative-" + label)
            except Invalid as exc:
                report["negative_controls"].append({"case": label, "detected": str(exc), "image_sha256": sha(damaged)})
            else:
                raise Invalid("accepted_damaged_" + label)
            damaged.unlink()
    finally:
        probe.close()
    if not args.fixtures_only:
        cases = [("High", unit * 3 + 124), ("High", unit * 5 + 777),
                 ("Small", unit * 2 + 9), ("Empty", unit + 17),
                 ("High", len(inputs["High"])), ("High", unit + 17), ("High", 0),
                 ("Zero", unit * 5 + 3), ("Random", unit + 129), ("Plain", unit * 4 + 7)]
        for name, amount in cases:
            image = output / "case.img"
            shutil.copyfile(seeded, image)
            label = "truncate-" + name + "-" + str(amount)
            event = json.loads(run([tool, "bridge", image, name, "truncate", amount], label))
            report["observations"][label] = event
            expected = inputs[name][:amount] + bytes(max(0, amount - len(inputs[name])))
            try:
                need(event["result"] == event["sync"] == event["release"] == 0, "truncate_status:" + label)
                event["oracle"] = inspect(image, name, expected, label)
            except Invalid as exc:
                report["defects"].append({"case": label, "error": str(exc), "reported": event})
                # Preserve a compact immutable failure copy, before other library operations.
                import gzip
                with image.open("rb") as inp, gzip.open(output / (label + ".img.gz"), "wb") as out:
                    shutil.copyfileobj(inp, out)
            image.unlink()
        if args.swift:
            # Recompile without C test hooks: these are the real Swift callbacks
            # and bridge, with file-backend allocation/content as the oracle.
            swift_commands = [
                ["xcrun", "clang", *flags, "-c", frozen / "ntfs_fskit.c", "-o", output / "swift-bridge.o"],
                ["xcrun", "clang", *flags, "-fobjc-arc", "-c", frozen / "ntfs_device_fskit.m", "-o", output / "swift-backend.o"],
                ["xcrun", "swiftc", "-g", "-sdk", sdk, "-target", platform.machine() + "-apple-macos15.4",
                 *(["-sanitize=address"] if args.sanitize == "address" else []), "-parse-as-library",
                 "-import-objc-header", frozen / "ntfs_fskit.h", "-I" + str(frozen),
                 *[frozen / name for name in ("test_compressed_volume.swift", "ntfs3gVolume.swift",
                                             "ntfs3gFileSystem.swift", "ntfs3gItem.swift", "DiagnosticRecorder.swift")],
                 output / "swift-bridge.o", output / "swift-backend.o", library / "libntfs-3g.a",
                 "-framework", "FSKit", "-framework", "Foundation", "-framework", "DiskArbitration",
                 "-o", output / "swift-volume"],
            ]
            manifest["swift_commands"] = [[str(x) for x in c] for c in swift_commands]
            (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            for i, command in enumerate(swift_commands):
                run(command, "swift-build-" + str(i))
            report["swift"] = {}
            profiles = [("High", [])]
            if args.new_tail:
                profiles = [("Empty", ["Empty", str(unit // 16)]),
                            ("Aligned", ["Aligned", str(report["fixtures"]["Aligned"]["physical"] + unit // 16)]),
                            ("High", ["High", "pending"])]
            for name, arguments in profiles:
                for mode in ("legacy-close", "modern-close", "reclaim", "sync", "unmount", "legacy-unlink"):
                    image = output / "swift.img"
                    shutil.copyfile(seeded, image)
                    label = "swift-" + name + "-" + mode
                    event = {"output": run([output / "swift-volume", image, mode, *arguments], label)}
                    if mode == "legacy-unlink":
                        check = CompressedImage(image)
                        try:
                            check.scan()
                            need(not check.errors and "/" + name not in check.paths, "swift_unlink_structure")
                        finally:
                            check.close()
                    else:
                        event["oracle"] = inspect(image, name, inputs[name] + b"R" * 700, label)
                    report["swift"][name + "-" + mode] = event
                    image.unlink()
        image = output / "case.img"
        shutil.copyfile(seeded, image)
        append = output / "append.data"
        append.write_bytes(b"R" * 701)
        event = json.loads(run([tool, "bridge", image, "High", "write", len(inputs["High"]), append], "append"))
        expected = inputs["High"] + append.read_bytes()
        before = inspect(image, "High", expected, "append-before-pclose")
        run([tool, "pclose", image, "High"], "append-explicit-pclose")
        after = inspect(image, "High", expected, "append-after-pclose")
        report["observations"]["append"] = {"bridge": event, "before": before, "after_explicit_pclose": after}
        if before["physical"] != after["physical"]:
            report.setdefault("known_unfixed" if args.truncate_only or args.new_tail else "defects", []).append({"case": "append-finalization", "error": "close/sync left a compressible tail unfinalized",
                                      "before": before["physical"], "after": after["physical"], "content_intact": True})
        image.unlink()
        writes = [("High", unit - 31, noise(unit + 137)), ("Random", unit - 1, bytes(unit + 113)),
                  ("Mixed", 2 * unit + 9, noise(4097)), ("Small", len(inputs["Small"]), b"S" * (2 * unit)),
                  ("Empty", 0, b"N" * (unit + 123)), ("High", len(inputs["High"]) + 2 * unit + 7, b"G" * 333)]
        for index, (name, offset, data) in enumerate(writes):
            image = output / "case.img"
            shutil.copyfile(seeded, image)
            payload = output / "write.data"
            payload.write_bytes(data)
            label = "write-" + str(index)
            event = json.loads(run([tool, "bridge", image, name, "write", offset, payload], label))
            need(event["result"] == len(data) and event["sync"] == event["release"] == 0, "write_status:" + label)
            expected = bytearray(inputs[name])
            expected.extend(bytes(max(0, offset + len(data) - len(expected))))
            expected[offset:offset + len(data)] = data
            event["oracle"] = inspect(image, name, bytes(expected), label)
            report["observations"][label] = event
            image.unlink()
        for mode in ("enospc", "zero", "close"):
            image = output / "case.img"
            shutil.copyfile(seeded, image)
            event = json.loads(run([tool, "truncate-fault", image, "High", mode], "truncate-fault-" + mode))
            expected = inputs["High"] + (bytes(event["target"] - len(inputs["High"])) if mode == "close" else b"")
            event["oracle"] = inspect(image, "High", expected, "truncate-fault-" + mode)
            report["observations"]["truncate-fault-" + mode] = event
            image.unlink()
        # A file produced by the old rounding bug has data_size > initialized_size.
        image = output / "case.img"
        shutil.copyfile(seeded, image)
        run([tool, "raw-truncate", image, "High", unit * 6], "uninitialized-tail-prepare")
        amount = len(inputs["High"]) + 3001
        event = json.loads(run([tool, "bridge", image, "High", "truncate", amount], "uninitialized-tail-shrink"))
        need(event["result"] == 0 and event["size"] == amount, "uninitialized_tail_shrink_size")
        event["oracle"] = inspect(image, "High", inputs["High"] + bytes(3001), "uninitialized-tail-shrink")
        report["observations"]["uninitialized-tail-shrink"] = event
        image.unlink()
        if args.new_tail:
            boundaries = [("Empty", "append-large"), ("High", "append-cross"),
                          ("High", "overwrite-old"), ("High", "grow-shrink-old"),
                          ("Empty", "grow-shrink-new"), ("High", "truncate-grow"),
                          ("Empty", "plain-error"), ("Empty", "plain-write")]
            boundaries += [(name, mode) for name in ("Empty", "Aligned")
                           for mode in ("data-read-error", "data-write-error")]
            report["boundaries"] = {}
            for name, mode in boundaries:
                image = output / "case.img"
                shutil.copyfile(seeded, image)
                label = "boundary-" + name + "-" + mode
                event = json.loads(run([tool, "finalization-boundary", image, name, mode], label))
                original = inputs[name]
                if mode == "append-large": expected = original + b"R" * ((2 << 20) + 123)
                elif mode == "append-cross": expected = original + b"R" * (unit + 701)
                elif mode == "overwrite-old": expected = original[:17] + b"R" * 700 + original[717:]
                elif mode == "grow-shrink-old": expected = original[:-50]
                elif mode == "grow-shrink-new": expected = b"R" * (unit + 400)
                elif mode == "truncate-grow": expected = original + bytes(unit * 2 + 701)
                elif mode == "data-read-error": expected = original + b"R" * (unit + 700)
                else: expected = original + b"R" * 700
                is_data_error = mode.startswith("data-")
                wanted_closes = int(not is_data_error and mode not in ("overwrite-old", "grow-shrink-old"))
                need(event["pclose_before_finish"] == 0 and event["pclose_calls"] == wanted_closes,
                     "boundary_finalization_count:" + label)
                need(all(event[key] == 0 for key in ("sync", "close", "retry", "clean", "release", "attrs_live")),
                     "boundary_status:" + label)
                need(event["data_read_injected"] + event["data_write_injected"] == int(is_data_error),
                     "boundary_actual_data_fault:" + label)
                if is_data_error:
                    need(event["write_result"] == -1 and event["write_error"] == errno.EIO, "boundary_EIO:" + label)
                need(event["synthetic_injected"] == int(mode == "plain-error"), "boundary_plain_fault:" + label)
                event["oracle"] = inspect(image, name, expected, label)
                plain = inputs["Plain"]
                if mode == "plain-write": plain = plain[:17] + b"R" * 50 + plain[67:]
                inspect(image, "Plain", plain, label + "-plain")
                report["boundaries"][label] = event
                image.unlink()
        report["lifecycle"] = {}
        life_name = "Aligned" if args.new_tail else "High"
        modes = [] if args.truncate_only else ["modern", "sync", "switch", "unlink", "pclose-fail", "unlink-fail",
                 "read-fail-1", "write-fail-1", "metadata-fail", "flush-fail",
                 "release-fail", "release-prior-fail"]
        if args.new_tail:
            modes.remove("unlink-fail")
            modes += ["switch-fail", "delete-fail"]
            report["not_applicable"] = ["unlink-fail: unlink already finalizes the new tail; a later partial-tail write is intentionally skipped"]
        for mode in modes:
            image = output / "case.img"
            shutil.copyfile(seeded, image)
            event = json.loads(run([tool, "lifecycle", image, life_name, mode], "lifecycle-" + mode))
            report["lifecycle"][mode] = event
            injections = sum(event[key] for key in ("pclose_fail_injected", "read_injected", "write_injected", "flush_injected", "metadata_injected"))
            need(injections == int("fail" in mode), "actual_lifecycle_injection:" + mode)
            if mode == "modern":
                need(max(event["pclose_reads"], event["pclose_writes"]) <= 16, "fault_point_limit")
                modes.extend("read-fail-" + str(i) for i in range(2, event["pclose_reads"] + 1))
                modes.extend("write-fail-" + str(i) for i in range(2, event["pclose_writes"] + 1))
            if event["fatal"]:
                def failed_state(path):
                    check = CompressedImage(path)
                    try:
                        check.scan()
                        for unaffected in ("Mixed", "Random", "Plain"):
                            need(check.stream(check.attr(check.records[check.paths["/" + unaffected]], DATA)) == inputs[unaffected],
                                 "fatal_pclose_unrelated_content")
                        attr = check.attr(check.records[check.paths["/" + life_name]], DATA)
                        actual = check.stream(attr)
                        return {"structure_findings": check.errors, "size": attr["size"],
                                "content_intact": actual == inputs[life_name] + b"R" * 700,
                                "sha256": hashlib.sha256(actual).hexdigest(), "layout": check.layout(attr)}
                    finally:
                        check.close()
                event["failure_state"] = failed_state(image)
                event["acceptance"] = "ERROR_CONTAINMENT_ONLY: partial pclose may already have damaged data; no retry or clean sync claimed"
                import gzip
                with image.open("rb") as inp, gzip.open(output / ("lifecycle-" + mode + ".img.gz"), "wb") as out:
                    shutil.copyfileobj(inp, out)
                # Same writes and injected boundary; stop immediately after the
                # exported upstream pclose returns, without our recovery policy.
                reference = output / "reference.img"
                shutil.copyfile(seeded, reference)
                event["upstream_reference"] = json.loads(run([tool, "lifecycle", reference, life_name, "reference-" + mode],
                                                              "reference-" + mode))
                upstream_state = failed_state(reference)
                need(upstream_state == event["failure_state"], "new_or_broader_pclose_damage:" + mode)
                event["same_as_upstream_failure_state"] = True
                with reference.open("rb") as inp, gzip.open(output / ("reference-" + mode + ".img.gz"), "wb") as out:
                    shutil.copyfileobj(inp, out)
                reference.unlink()
            elif mode.startswith("release"):
                event["content_acceptance"] = "NOT_RUN: irrevocable release after injected error"
            elif event["removed"]:
                check = CompressedImage(image)
                try:
                    check.scan()
                    need(not check.errors and "/" + life_name not in check.paths, "unlink_cleanup_structure")
                    need(check.stream(check.attr(check.records[check.paths["/Mixed"]], DATA)) == inputs["Mixed"], "unlink_unrelated_bytes")
                finally:
                    check.close()
            else:
                event["oracle"] = inspect(image, life_name, inputs[life_name] + b"R" * 700, "lifecycle-" + mode)
                if mode == "switch":
                    data = inputs["Mixed"][:19] + b"R" * 7 + inputs["Mixed"][26:]
                    inspect(image, "Mixed", data, "lifecycle-switch-mixed")
            image.unlink()
    manifest["seeded_image"] = sha(seeded)
    manifest["expected_inputs"] = {name: hashlib.sha256(data).hexdigest() for name, data in inputs.items()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    need(sha(fixture) == manifest["fixture"] and sha(library / "libntfs-3g.a") == manifest["library"], "formal_input_changed")
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    partial_failures = sum(not row.get("failure_state", {}).get("content_intact", True)
                           for row in report.get("lifecycle", {}).values())
    print(json.dumps({"fixtures": len(inputs), "defects": report["defects"],
                      "acceptance_scope": report["acceptance_scope"], "known_unfixed": report.get("known_unfixed", []),
                      "known_upstream_partial_io_content_failures": None if args.truncate_only or args.fixtures_only else partial_failures,
                      "scope": "normal behavior and error containment; not all-fault data recovery", "output": str(output)}, indent=2))
    return 1 if report["defects"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Invalid, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        print("HARNESS ERROR:", exc, file=sys.stderr)
        sys.exit(2)
