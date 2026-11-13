#!/usr/bin/env python3
"""Record sequential validation steps without caching results or capturing output.

Callers keep their existing subprocess output, timeout and failure policy. The
JSONL is cost evidence, not a declaration that a test or known-failure gate passed.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def run_timed(command, *, timing_path, phase, label, **kwargs):
    command = [str(arg) for arg in command]
    record = {"phase": phase, "label": label, "command": command,
              "cwd": str(kwargs.get("cwd", Path.cwd())), "outcome": "interrupted",
              "returncode": None}
    # Open first: a bad report path must not launch a command whose cost is lost.
    # Each runner owns one report and calls this sequentially.
    with Path(timing_path).open("a", encoding="utf-8") as report:
        started = time.monotonic()
        try:
            result = subprocess.run(command, **kwargs)
            record.update(outcome="exit", returncode=result.returncode)
            return result
        except subprocess.CalledProcessError as error:
            record.update(outcome="exit", returncode=error.returncode)
            raise
        except subprocess.TimeoutExpired:
            record.update(outcome="timeout", timeout_seconds=kwargs.get("timeout"))
            raise
        except OSError as error:
            record.update(outcome="spawn_error", errno=error.errno)
            raise
        finally:
            record["elapsed_seconds"] = time.monotonic() - started
            report.write(json.dumps(record) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--phase", required=True, choices=("build", "test", "fixture", "suite"))
    parser.add_argument("--label", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    try:
        result = run_timed(command, timing_path=args.output, phase=args.phase, label=args.label)
    except OSError as error:
        parser.exit(126, str(error) + "\n")
    # subprocess uses negative signal numbers; preserve the shell exit convention.
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
