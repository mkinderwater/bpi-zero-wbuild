#!/usr/bin/env python3
"""Normalize U-Boot kernel arguments to quiet loglevel=3."""
from __future__ import annotations

import re
import sys
from pathlib import Path

BOOTARGS_RE = re.compile(r"^(?P<prefix>\s*setenv\s+bootargs\s+)(?P<args>.*)$")
LOGLEVEL_RE = re.compile(r"^loglevel=\d+$")


def normalize_line(line: str) -> tuple[str, bool]:
    newline = "\n" if line.endswith("\n") else ""
    body = line[:-1] if newline else line
    match = BOOTARGS_RE.match(body)
    if not match:
        return line, False

    tokens = match.group("args").split()
    tokens = [t for t in tokens if t != "quiet" and not LOGLEVEL_RE.match(t)]
    normalized = f"{match.group('prefix')}quiet loglevel=3"
    if tokens:
        normalized += " " + " ".join(tokens)
    return normalized + newline, True


def patch_file(path: Path) -> int:
    text = path.read_text()
    out = []
    matches = 0
    for line in text.splitlines(keepends=True):
        patched, changed = normalize_line(line)
        out.append(patched)
        matches += int(changed)

    if matches == 0:
        raise RuntimeError(f"no 'setenv bootargs' line found in {path}")

    path.write_text("".join(out))
    return matches


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} FILE [FILE ...]", file=sys.stderr)
        return 2

    try:
        for name in argv[1:]:
            path = Path(name)
            count = patch_file(path)
            print(f"patched {path}: {count} bootargs line(s) -> quiet loglevel=3")
    except (OSError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
