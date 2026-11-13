#!/usr/bin/env python3
"""Bounded autorelease pressure on real wrapper queues; ordinary-file fixture only."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

from run_crash_consistency import ROOT, clone, demand, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=ROOT / "ntfs3g")
    parser.add_argument("--fixture", type=Path, default=ROOT / "tests/work.ntfs")
    parser.add_argument("--sanitize", choices=["address", "thread"])
    parser.add_argument("--observe", action="store_true")
    args = parser.parse_args()
    work = args.output.absolute()
    demand(work.parent.resolve().is_relative_to((ROOT / "_tmp").resolve()) and not work.exists(), "new output under _tmp")
    work.mkdir(parents=True)
    source = work / "source"
    source.mkdir()
    for name in ("ntfs3gVolume.swift", "ntfs3gFileSystem.swift", "ntfs3gItem.swift"):
        shutil.copyfile(args.source / name, source / name)
    for name in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m"):
        shutil.copyfile(args.source / "bridge" / name, source / name)
    shutil.copyfile(ROOT / "Shared/DiagnosticRecorder.swift", source / "DiagnosticRecorder.swift")
    for name in ("volume_memory_probe.h", "volume_memory_probe.m", "test_volume_memory.swift", "run_volume_memory.py"):
        shutil.copyfile(ROOT / "tests" / name, source / name)
    env = {k: v for k, v in os.environ.items() if k != "SDKROOT"}
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
    arch = platform.machine()
    flags = ["-O2", "-g", "-Werror", "-arch", arch, "-mmacosx-version-min=15.4", "-isysroot", sdk,
             "-DHAVE_CONFIG_H=1", "-I" + str(source), "-I" + str(ROOT / "build/libntfs-universal"),
             "-I" + str(ROOT / "ntfs-3g/include")]
    swift = ["-O", "-g", "-swift-version", "5", "-whole-module-optimization", "-parse-as-library",
             "-target", arch + "-apple-macos15.4", "-sdk", sdk]
    if args.sanitize:
        flags += ["-fsanitize=" + args.sanitize, "-fno-omit-frame-pointer"]
        swift += ["-sanitize=" + args.sanitize]
    commands = []
    for filename, obj, extra in (("ntfs_fskit.c", "bridge.o", []), ("ntfs_device_fskit.m", "backend.o", ["-fobjc-arc"]),
                                 ("volume_memory_probe.m", "probe.o", ["-fno-objc-arc"])):
        commands.append(["xcrun", "clang", *flags, *extra, "-c", source / filename, "-o", work / obj])
    commands.append(["xcrun", "swiftc", *swift, "-import-objc-header", source / "volume_memory_probe.h", "-I" + str(source),
                     *[source / name for name in ("test_volume_memory.swift", "ntfs3gVolume.swift", "ntfs3gFileSystem.swift", "ntfs3gItem.swift", "DiagnosticRecorder.swift")],
                     *[work / name for name in ("bridge.o", "backend.o", "probe.o")], ROOT / "build/libntfs-universal/libntfs-3g.a",
                     "-framework", "Foundation", "-framework", "FSKit", "-framework", "DiskArbitration", "-o", work / "test-memory"])
    manifest = {"sources": {p.name: digest(p) for p in source.iterdir()}, "fixture": digest(args.fixture),
                "library": digest(ROOT / "build/libntfs-universal/libntfs-3g.a"), "config": digest(ROOT / "build/libntfs-universal/config.h"),
                "commands": [[str(x) for x in c] for c in commands], "observe": args.observe, "sanitizer": args.sanitize,
                "scope": "synthetic 32 KiB autoreleased objects inside real volume/resource reply callbacks; file image; no OS mount/device"}
    image = work / "test.img"
    try:
        for i, command in enumerate(commands):
            with (work / f"build-{i}.log").open("w") as log:
                subprocess.run([str(x) for x in command], env=env, check=True, timeout=120, stdout=log, stderr=subprocess.STDOUT)
        manifest["binary"] = digest(work / "test-memory")
        clone(args.fixture, image)
        command = [str(work / "test-memory"), str(image)] + (["observe"] if args.observe else [])
        with (work / "results.log").open("w") as log:
            result = subprocess.run(command, env=env, timeout=120, stdout=log, stderr=subprocess.STDOUT)
        manifest["exit_code"] = result.returncode
        lines = (work / "results.log").read_text().splitlines()
        print("\n".join(line for line in lines if line.startswith(("QUEUE_MEMORY", "PASS:", "FAIL:"))))
        if result.returncode:
            print("\n".join(lines[-40:]))
        demand(result.returncode == 0, "native memory checks failed")
    finally:
        image.unlink(missing_ok=True)
        manifest["fixture_unchanged"] = digest(args.fixture) == manifest["fixture"]
        (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    demand(manifest["fixture_unchanged"], "fixture changed")


if __name__ == "__main__":
    main()
