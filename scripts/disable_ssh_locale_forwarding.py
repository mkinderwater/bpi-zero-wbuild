#!/usr/bin/env python3
"""Remove SSH AcceptEnv patterns for client locale variables from a target rootfs.

This is a build-time transform. It keeps the appliance lean by preventing SSH
clients from injecting LANG/LC_* values that the minimal target has not generated,
without installing Debian locale-generation packages on the target.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

ACCEPT_RE = re.compile(r"^(?P<indent>\s*)AcceptEnv(?P<space>\s+)(?P<body>[^#\r\n]*?)(?P<trail>\s*)(?P<comment>#.*)?(?P<nl>\r?\n)?$")


def is_locale_pattern(token: str) -> bool:
    # Debian's stock policy is "LANG LC_*". Also remove explicit LC_* names.
    return token == "LANG" or token.startswith("LC_")


def transform_text(text: str) -> tuple[str, int]:
    out: list[str] = []
    changed = 0
    for line in text.splitlines(keepends=True):
        m = ACCEPT_RE.match(line)
        if not m or line.lstrip().startswith("#"):
            out.append(line)
            continue

        tokens = m.group("body").split()
        kept = [tok for tok in tokens if not is_locale_pattern(tok)]
        if len(kept) == len(tokens):
            out.append(line)
            continue

        changed += 1
        newline = m.group("nl") or ""
        indent = m.group("indent")
        comment = m.group("comment") or ""
        if kept:
            suffix = f" {comment}" if comment else ""
            out.append(f"{indent}AcceptEnv {' '.join(kept)}{suffix}{newline}")
        else:
            original = line[:-len(newline)] if newline else line
            out.append(f"{indent}# BPI-ZERO-WBUILD disabled client locale forwarding: {original.lstrip()}{newline}")
    return "".join(out), changed


def candidate_files(root: Path) -> list[Path]:
    files = [root / "etc/ssh/sshd_config"]
    dropin = root / "etc/ssh/sshd_config.d"
    if dropin.is_dir():
        files.extend(sorted(p for p in dropin.glob("*.conf") if p.is_file()))
    return files


def active_locale_acceptenv(path: Path) -> list[str]:
    bad: list[str] = []
    for n, line in enumerate(path.read_text(errors="strict").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = ACCEPT_RE.match(line)
        if not m:
            continue
        if any(is_locale_pattern(tok) for tok in m.group("body").split()):
            bad.append(f"{path}:{n}:{line}")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, type=Path)
    args = ap.parse_args()
    root = args.root.resolve()
    main_cfg = root / "etc/ssh/sshd_config"
    if not main_cfg.is_file():
        print(f"ERROR: target sshd_config missing: {main_cfg}", file=sys.stderr)
        return 1

    total = 0
    configs = candidate_files(root)
    for path in configs:
        text = path.read_text()
        new_text, changed = transform_text(text)
        if changed:
            path.write_text(new_text)
            total += changed

    bad: list[str] = []
    for path in configs:
        bad.extend(active_locale_acceptenv(path))
    if bad:
        print("ERROR: active SSH client locale forwarding survived transform:", file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        return 1

    print(f"SSH client locale forwarding disabled ({total} AcceptEnv directive(s) adjusted).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
