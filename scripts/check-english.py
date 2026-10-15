#!/usr/bin/env python3
"""Check project-owned text for non-Latin scripts without reading ignored data.

This source-language check does not inspect or restrict user task databases.
"""
from pathlib import Path
import subprocess
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[1]


def main():
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
    ).decode("utf-8").split("\0")
    failures = []
    checked = 0
    for name in sorted(set(filter(None, names))):
        path = ROOT / name
        if not path.is_file() or path.is_symlink():
            continue
        raw = path.read_bytes()
        if b"\0" in raw:
            continue
        try:
            content = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        checked += 1
        for number, line in enumerate((name + "\n" + content).splitlines()):
            if any(unicodedata.category(char).startswith("L")
                   and "LATIN" not in unicodedata.name(char, "")
                   for char in line):
                failures.append(f"{name}:{number}: non-Latin letters in project text")
    if failures:
        print("English-only source check failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"English-only source check passed: {checked} text files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
