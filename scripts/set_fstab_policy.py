#!/usr/bin/env python3
import argparse
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('fstab')
ap.add_argument('--partuuid', required=True)
a = ap.parse_args()
p = Path(a.fstab)
if not p.is_file():
    raise SystemExit(f'fstab missing: {p}')

lines = p.read_text().splitlines()
out = []
root_count = 0
for lineno, line in enumerate(lines, 1):
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        out.append(line)
        continue
    fields = stripped.split()
    if len(fields) < 3:
        raise SystemExit(f'fstab line {lineno}: expected at least 3 fields')
    src, mnt, fstype = fields[:3]
    if mnt == '/':
        root_count += 1
        if root_count > 1:
            raise SystemExit('fstab contains multiple root mounts')
        if fstype != 'ext4':
            raise SystemExit(f'fstab root filesystem must be ext4, found {fstype}')
        fields[0] = f'PARTUUID={a.partuuid}'
        out.append('\t'.join(fields))
        continue
    if mnt in ('/boot', '/boot/firmware'):
        raise SystemExit(f'fstab contains unsupported separate boot mount: {mnt}')
    if src.startswith('/dev/mmcblk') or src.startswith('/dev/sd'):
        raise SystemExit(f'fstab contains unstable block-device path at line {lineno}: {src}')
    out.append(line)

if root_count == 0:
    # Recent Johang Trixie roots may intentionally omit a root entry. The final
    # image still needs a stable root mount contract, so create it from the
    # patched MBR PARTUUID rather than depending on transient device names.
    if out and out[-1].strip():
        out.append('')
    out.append(f'PARTUUID={a.partuuid}\t/\text4\tdefaults\t0\t1')

p.write_text('\n'.join(out) + '\n')

root = [ln.split() for ln in p.read_text().splitlines()
        if ln.strip() and not ln.lstrip().startswith('#') and len(ln.split()) >= 3 and ln.split()[1] == '/']
if len(root) != 1:
    raise SystemExit(f'fstab post-write root verification found {len(root)} root mounts')
if root[0][0] != f'PARTUUID={a.partuuid}':
    raise SystemExit('fstab post-write root PARTUUID verification failed')
if root[0][2] != 'ext4':
    raise SystemExit('fstab post-write root filesystem is not ext4')
print(f'fstab root policy OK: PARTUUID={a.partuuid}')
