#!/usr/bin/env python3
"""Relocate Debian kernel-header package references inside a private extracted SDK.

Debian flavour header packages include the common-header Makefile by its installed
/usr/src path, and header trees may contain links to the installed linux-kbuild
path.  dpkg-deb -x preserves those package semantics, so a private SDK must
rewrite them to paths inside the extracted tree before Kbuild can be invoked.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sdk-root", required=True)
    ap.add_argument("--abi", required=True)
    ap.add_argument("--common-name", required=True)
    ap.add_argument("--kbuild-name", required=True)
    args = ap.parse_args()

    sdk = Path(args.sdk_root).resolve()
    hdr = sdk / "usr" / "src" / f"linux-headers-{args.abi}"
    common = sdk / "usr" / "src" / args.common_name
    kbuild = sdk / "usr" / "lib" / args.kbuild_name

    for path, label in [(hdr, "flavour headers"), (common, "common headers"), (kbuild, "kbuild")]:
        if not path.is_dir():
            die(f"private Debian SDK missing {label}: {path}")

    makefile = hdr / "Makefile"
    if not makefile.is_file():
        die(f"flavour header Makefile missing: {makefile}")

    installed_include = f"include /usr/src/{args.common_name}/Makefile"
    private_include = f"include ../{args.common_name}/Makefile"
    text = makefile.read_text()
    installed_count = text.count(installed_include)
    private_count = text.count(private_include)

    if installed_count == 1 and private_count == 0:
        makefile.write_text(text.replace(installed_include, private_include, 1))
    elif installed_count == 0 and private_count == 1:
        pass
    else:
        die(
            "unexpected flavour-header Makefile include layout: "
            f"installed={installed_count} private={private_count}"
        )

    # Both flavour and common packages may ship scripts/tools links.  Accept
    # Debian's installed absolute form or our already-relocated relative form.
    relative_prefix = Path("../../lib") / args.kbuild_name
    for tree in (hdr, common):
        for leaf in ("scripts", "tools"):
            link = tree / leaf
            if not link.is_symlink():
                die(f"expected Debian header symlink is missing: {link}")
            current = os.readlink(link)
            installed_target = f"/usr/lib/{args.kbuild_name}/{leaf}"
            private_target = str(relative_prefix / leaf)
            if current == installed_target:
                link.unlink()
                link.symlink_to(private_target)
            elif current == private_target:
                pass
            else:
                die(f"unexpected symlink target for {link}: {current}")

            resolved = (link.parent / os.readlink(link)).resolve()
            expected = (kbuild / leaf).resolve()
            if resolved != expected or not expected.exists():
                die(f"relocated {leaf} link does not resolve inside private SDK: {link} -> {resolved}")

    if makefile.read_text().count(private_include) != 1:
        die("private common-header Makefile include validation failed")

    print(f">> relocated Debian kernel-header SDK: {hdr.name}")
    print(f">> common headers: {common}")
    print(f">> kbuild tools: {kbuild}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
