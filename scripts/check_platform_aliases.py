#!/usr/bin/env python3
import sys
from pathlib import Path
from fdt_read import parse, get, decstr, walk, effective_enabled

EXPECTED = {
    'spi0': '/soc/spi@1c68000',
    'i2c0': '/soc/i2c@1c2ac00',
}
if len(sys.argv) != 2:
    raise SystemExit(f'usage: {Path(sys.argv[0]).name} DTB')
try:
    root = parse(sys.argv[1])
except (OSError, ValueError) as exc:
    raise SystemExit(f'ERROR: {exc}')
paths = list(walk(root))
by_path = dict(paths)
try:
    aliases = get(root, '/aliases')
except KeyError:
    raise SystemExit('ERROR: DTB has no /aliases node')
for alias, expected_path in EXPECTED.items():
    raw = aliases.props.get(alias)
    if not raw:
        raise SystemExit(f'ERROR: DTB has no aliases:{alias}; documented /dev endpoint is not pinned')
    actual = decstr(raw)
    if actual != expected_path:
        raise SystemExit(f'ERROR: aliases:{alias}={actual!r}, expected {expected_path!r}')
    if actual not in by_path:
        raise SystemExit(f'ERROR: aliases:{alias} points to missing node {actual}')
    if not effective_enabled(actual, by_path):
        raise SystemExit(f'ERROR: aliases:{alias} target {actual} is disabled by its node or an ancestor')
print('Platform aliases OK: spi0=/soc/spi@1c68000, i2c0=/soc/i2c@1c2ac00')
