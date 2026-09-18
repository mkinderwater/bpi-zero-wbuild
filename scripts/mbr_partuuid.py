#!/usr/bin/env python3
import argparse, struct
ap = argparse.ArgumentParser()
ap.add_argument('image')
ap.add_argument('--partition', type=int, default=2)
ap.add_argument('--field', choices=('partuuid','start','sectors','disk-signature'), default='partuuid')
a = ap.parse_args()
if not 1 <= a.partition <= 4:
    raise SystemExit('partition must be 1..4')
with open(a.image, 'rb') as f:
    mbr = f.read(512)
if len(mbr) != 512 or mbr[510:512] != b'\x55\xaa':
    raise SystemExit('invalid MBR')
sig = struct.unpack_from('<I', mbr, 440)[0]
if sig == 0:
    raise SystemExit('MBR disk signature is zero; stable PARTUUID unavailable')
off = 446 + (a.partition - 1) * 16
start, sectors = struct.unpack_from('<II', mbr, off + 8)
if a.field == 'partuuid':
    print(f'{sig:08x}-{a.partition:02x}')
elif a.field == 'start':
    print(start)
elif a.field == 'sectors':
    print(sectors)
else:
    print(f'{sig:08x}')
