#!/usr/bin/env python3
import argparse, struct

ap = argparse.ArgumentParser()
ap.add_argument('image')
ap.add_argument('--partition', type=int, default=2)
args = ap.parse_args()
if not 1 <= args.partition <= 4:
    raise SystemExit('partition must be 1..4')
with open(args.image, 'rb') as f:
    mbr = f.read(512)
if len(mbr) != 512 or mbr[510:512] != b'\x55\xaa':
    raise SystemExit('invalid MBR')
sig = struct.unpack_from('<I', mbr, 440)[0]
if sig == 0:
    raise SystemExit('MBR disk signature is zero; cannot create stable PARTUUID')
print(f'{sig:08x}-{args.partition:02x}')
