#!/usr/bin/env python3
"""Test validation scheduling/error reporting, without compiling or mounting NTFS.

The fake compiler tests runner dispatch only. It supplies no product, filesystem,
sanitizer or data-integrity acceptance evidence.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from validation_timing import run_timed

ROOT = Path(__file__).resolve().parent.parent


class TimingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="xntfs-validation-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.report = self.work / "timings.jsonl"

    def run_child(self, code, **kwargs):
        return run_timed([sys.executable, "-c", code], timing_path=self.report,
                         phase="test", label="child", **kwargs)

    def records(self):
        return [json.loads(line) for line in self.report.read_text().splitlines()]

    def test_output_and_nonzero_are_preserved(self):
        result = self.run_child("import sys; print('out'); print('err', file=sys.stderr); sys.exit(7)",
                                capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (7, "out\n", "err\n"))
        self.assertEqual(self.records()[0]["returncode"], 7)
        self.assertGreaterEqual(self.records()[0]["elapsed_seconds"], 0)

    def test_checked_failure_and_timeout_are_recorded_and_raised(self):
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.run_child("raise SystemExit(9)", check=True)
        self.assertEqual(error.exception.returncode, 9)
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_child("import time; time.sleep(30)", timeout=0.05)
        records = self.records()
        self.assertEqual([r["outcome"] for r in records], ["exit", "timeout"])
        self.assertEqual(records[0]["returncode"], 9)
        self.assertIsNone(records[1]["returncode"])

    def test_spawn_failure_is_not_success(self):
        with self.assertRaises(FileNotFoundError):
            run_timed([self.work / "absent"], timing_path=self.report, phase="build", label="missing")
        self.assertEqual(self.records()[0]["outcome"], "spawn_error")

    def test_bad_report_path_prevents_execution(self):
        target = self.work / "should-not-exist"
        with self.assertRaises(FileNotFoundError):
            run_timed([sys.executable, "-c", f"open({str(target)!r}, 'w').close()"],
                      timing_path=self.work / "absent/report", phase="test", label="bad-path")
        self.assertFalse(target.exists())

    def test_cli_preserves_arguments_and_status(self):
        argument = "literal $(not-a-command) `unchanged` with spaces"
        result = subprocess.run([sys.executable, ROOT / "tests/validation_timing.py",
                                 "--output", self.report, "--phase", "suite", "--label", "cli", "--",
                                 sys.executable, "-c", "import sys; print(sys.argv[1]); sys.exit(13)", argument],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 13)
        self.assertEqual(result.stdout.strip(), argument)
        self.assertEqual(self.records()[0]["command"][-1], argument)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        # A private tiny repo avoids real compiler/device calls and stale WIP.
        self.tmp = tempfile.TemporaryDirectory(prefix="xntfs-runner-", suffix=" with spaces")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        for name in ("tests", "bin", "ntfs3g/bridge", "build/libntfs-universal", "_tmp"):
            (self.root / name).mkdir(parents=True)
        for name in ("run_bridge_regressions.sh", "validation_timing.py"):
            shutil.copy2(ROOT / "tests" / name, self.root / "tests" / name)
        for name in ("libntfs-3g.a", "config.h"):
            (self.root / "build/libntfs-universal" / name).write_text("stub")
        self.fixture = self.root / "tests/work.ntfs"
        self.fixture.write_bytes(b"fixture" * 100)
        self.compiler_log = self.root / "compiler.jsonl"
        fake = self.root / "bin/xcrun"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1:] == ['--sdk', 'macosx', '--show-sdk-path']:
    print('/mock sdk'); sys.exit(0)
with open(os.environ['FAKE_COMPILER_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ.get('FAKE_BUILD_FAILURE'):
    sys.exit(19)
output = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
output.write_text("#!/usr/bin/env python3\\nimport os, pathlib, sys\\n"
                  "args = sys.argv[1:]\\n"
                  "if args and args[0] in ('all', 'xattr-retirement'): args = args[1:]\\n"
                  "for name in args:\\n"
                  " p = pathlib.Path(name)\\n"
                  " assert p.read_bytes() == b'fixture' * 100, 'image not fresh'\\n"
                  " p.write_bytes(b'changed')\\n"
                  "print('PASS: runner stub only')\\n"
                  "sys.exit(int(os.environ.get('FAKE_TEST_FAILURE', '0')))\\n")
output.chmod(0o755)
''')
        fake.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("NFSK_")}
        self.env.update(PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                        FAKE_COMPILER_LOG=str(self.compiler_log), PYTHONDONTWRITEBYTECODE="1")

    def run_bridge(self, suites=None, **extra):
        env = dict(self.env, **extra)
        if suites is not None:
            env["NFSK_BRIDGE_SUITES"] = suites
        return subprocess.run(["bash", self.root / "tests/run_bridge_regressions.sh", self.fixture],
                              env=env, text=True, capture_output=True)

    def artifacts(self):
        return next((self.root / "_tmp").iterdir())

    def records(self):
        return [json.loads(line) for line in (self.artifacts() / "timings.jsonl").read_text().splitlines()]

    def test_default_runs_five_groups_and_ten_builds(self):
        result = self.run_bridge()
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.records()
        self.assertEqual(len([r for r in records if r["phase"] == "build"]), 10)
        self.assertEqual([r["label"] for r in records if r["phase"] == "test"],
                         ["core", "basic", "directory", "xattr", "symlink-normal", "symlink-faults",
                          "symlink-backend-error", "symlink-backend-zero", "symlink-backend-resident",
                          "symlink-short-write", "symlink-cleanup", "symlink-windows"])
        self.assertFalse((self.artifacts() / "test.img").exists())
        self.assertEqual(self.fixture.read_bytes(), b"fixture" * 100)

    def test_single_group_only_builds_its_hooks_and_propagates_flags(self):
        result = self.run_bridge("core", NFSK_SANITIZE="address", NFSK_BRIDGE_PROFILE="o2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["label"] for r in self.records()], ["core-bridge", "core-reparse", "core-link", "core"])
        commands = [json.loads(line) for line in self.compiler_log.read_text().splitlines()]
        self.assertEqual(len(commands), 3)
        self.assertTrue(all("-fsanitize=address" in c and "-O2" in c for c in commands))
        self.assertIn("-Dntfs_inode_sync=nfsk_test_inode_sync", commands[0])
        self.assertFalse((self.artifacts() / "xattr-tests").exists())

    def test_multiple_groups_deduplicate_in_original_order(self):
        result = self.run_bridge("xattr directory xattr")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["label"] for r in self.records() if r["phase"] == "test"], ["directory", "xattr"])
        self.assertEqual(len(self.compiler_log.read_text().splitlines()), 4)

    def test_symlink_group_keeps_fault_images_separate(self):
        result = self.run_bridge("symlink symlink", NFSK_SANITIZE="address")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["label"] for r in self.records()],
                         ["symlink-bridge", "symlink-link", "symlink-normal", "symlink-faults",
                          "symlink-backend-error", "symlink-backend-zero", "symlink-backend-resident",
                          "symlink-short-write", "symlink-cleanup", "symlink-windows"])
        commands = [json.loads(line) for line in self.compiler_log.read_text().splitlines()]
        self.assertEqual(len(commands), 2)
        self.assertIn("-Dntfs_delete=nfsk_test_delete", commands[0])
        self.assertFalse((self.artifacts() / "test.img").exists())

    def test_invalid_selection_fails_before_build(self):
        for selection in ("", "   ", "core typo", "core\nxattr"):
            with self.subTest(selection=selection):
                result = self.run_bridge(selection)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.compiler_log.exists())
                self.assertEqual(list((self.root / "_tmp").iterdir()), [])

    def test_compiler_error_stops_without_running_tests(self):
        result = self.run_bridge(FAKE_BUILD_FAILURE="1")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(len(self.records()), 1)
        self.assertEqual(self.records()[0]["returncode"], 19)

    def test_test_error_survives_tee_and_stops_later_groups(self):
        result = self.run_bridge(FAKE_TEST_FAILURE="23")
        self.assertEqual(result.returncode, 23)
        self.assertEqual([r["label"] for r in self.records()],
                         ["core-bridge", "core-reparse", "core-link", "core"])
        self.assertEqual(self.records()[-1]["returncode"], 23)
        self.assertFalse((self.artifacts() / "test.img").exists())

    def copy_inputs(self, names):
        for name in names:
            target = self.root / name
            target.parent.mkdir(exist_ok=True, parents=True)
            shutil.copy2(ROOT / name, target)

    def test_compressed_build_only_records_three_commands(self):
        import run_compressed_regressions as compressed
        self.copy_inputs(["ntfs3g/bridge/" + n for n in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m")]
                         + ["tests/" + n for n in ("compressed_fixture.c", "ntfs_compressed_check.py",
                                                   "ntfs_image_check.py", "run_compressed_regressions.py")])
        output = self.root / "_tmp/compressed"
        args = ["runner", str(self.fixture), "--output", str(output), "--build-only"]
        with mock.patch.object(compressed, "ROOT", self.root), mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(sys, "argv", args):
            self.assertEqual(compressed.main(), 0)
        self.assertEqual([r["phase"] for r in self.records()], ["build"] * 3)
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertIn("validation_timing.py", manifest["sources"])

    def test_queue_records_build_and_runtime_with_fresh_copies(self):
        import run_volume_queue as queue
        self.copy_inputs(["ntfs3g/" + n for n in ("ntfs3gVolume.swift", "ntfs3gItem.swift", "ntfs3gFileSystem.swift")]
                         + ["ntfs3g/bridge/" + n for n in ("ntfs_fskit.c", "ntfs_fskit.h", "ntfs_device_fskit.m")]
                         + ["Shared/DiagnosticRecorder.swift"]
                         + ["tests/" + n for n in ("test_volume_queue.swift", "run_volume_queue.py", "volume_write_gate.c",
                                                   "volume_write_gate.h", "directory_packer.m", "directory_packer.h")])
        for scenario, image_count in (("all", 6), ("xattr-retirement", 1)):
            with self.subTest(scenario=scenario):
                output = self.root / "_tmp" / scenario
                args = ["runner", "--fixture", str(self.fixture), "--output", str(output)]
                if scenario != "all":
                    args += ["--scenario", scenario]
                with mock.patch.object(queue, "ROOT", self.root), mock.patch.dict(os.environ, self.env, clear=True), \
                        mock.patch.object(sys, "argv", args):
                    queue.main()
                records = [json.loads(line) for line in (output / "timings.jsonl").read_text().splitlines()]
                self.assertEqual([r["phase"] for r in records], ["build"] * 5 + ["test"])
                manifest = json.loads((output / "manifest.json").read_text())
                self.assertIn("validation_timing.py", manifest["compiled_sources"])
                self.assertEqual(manifest["scenario"], scenario)
                self.assertEqual(manifest["run_command"][1], scenario)
                self.assertEqual(len(manifest["run_command"][2:]), image_count)
                self.assertTrue(manifest["fixture_unchanged"])
                self.assertEqual(list(output.glob("case-*.ntfs")), [])


class BenchmarkTraceTests(unittest.TestCase):
    def test_lookup_reply_trace_is_complete_and_drift_is_rejected(self):
        from run_volume_benchmark import trace_source
        source = (ROOT / "ntfs3g/ntfs3gVolume.swift").read_text()
        traced = trace_source(source)
        start = traced.index("    private func replyWithItem(")
        end = traced.index("    private func item(", start)
        reply = traced[start:end]
        for marker in ("perfEnqueued =", "perfStarted =", "perfBody =", "VolumeTrace.record("):
            self.assertEqual(reply.count(marker), 1)
        self.assertLess(reply.index("VolumeTrace.record("), reply.index("case .success"))
        self.assertLess(reply.index("VolumeTrace.record("), reply.index("case .failure"))
        self.assertEqual(traced.count("VolumeTrace.record("), 3)
        changed = source.replace("\n            let result = Result { try body() }", "\n            let changed = Result { try body() }")
        with self.assertRaisesRegex(RuntimeError, "replyWithItem changed"):
            trace_source(changed)


if __name__ == "__main__":
    unittest.main()
