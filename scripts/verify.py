#!/usr/bin/env python3
"""Build before testing, with isolated fixtures and no inherited board connection."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=["core", "macos", "all"], default="all")
    args = parser.parse_args()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("WORKBOARD_") and key not in {"CODEX_THREAD_ID", "CLAUDE_ENV_FILE"}}
    cargo_home = Path(env.get("CARGO_HOME", Path.home() / ".cargo"))
    env["PATH"] = str(cargo_home / "bin") + os.pathsep + env.get("PATH", "")
    if not shutil.which("cargo", path=env["PATH"]):
        parser.error("Install Rust with Cargo before running verification.")
    commands = [["cargo", "build", "--workspace", "--locked"]]
    if args.scope in {"core", "all"}:
        commands += [
            ["cargo", "fmt", "--all", "--", "--check"],
            ["cargo", "test", "--workspace", "--locked"],
            ["cargo", "clippy", "--workspace", "--all-targets", "--locked", "--", "-D", "warnings"],
            [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v", "-f"],
            [sys.executable, "scripts/check-english.py"],
        ]
    if args.scope in {"macos", "all"}:
        if sys.platform != "darwin":
            parser.error("The macos scope requires a Mac. Use --scope core on other systems.")
        commands += [
            ["swift", "build", "--package-path", "macos", "--jobs", "2"],
            [sys.executable, "scripts/test-install.py"],
            ["bash", "macos/Tests/run.sh"],
            ["bash", "macos/Tests/run-workflows.sh"],
            ["bash", "macos/Tests/run-planner.sh"],
            ["bash", "scripts/verify-widget.sh"],
        ]
    for command in commands:
        print("\nRunning: " + " ".join(command), flush=True)
        step_env = dict(env)
        if command[0] == "bash" and command[1].startswith("macos/Tests/"):
            step_env["WORKBOARD_BIN"] = str(ROOT / "target/debug/workboard")
        started = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=step_env)
        print("Finished in {:.1f}s (exit {})".format(time.monotonic() - started, result.returncode), flush=True)
        if result.returncode:
            return result.returncode
    print("Selected checks passed. Desktop widget hosting and real account flows require separate evidence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
