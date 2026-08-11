#!/usr/bin/env python3
from pathlib import Path
root = Path(__file__).resolve().parents[1]
build = (root / 'build.sh').read_text()
dtb = (root / 'clock/patch-clock-dtb.sh').read_text()
readme = (root / 'README.md').read_text()
assert (root / 'VERSION').read_text().strip() == '1.0.0'
assert 'bpi-zero-clock.img' in build
assert 'PREBUILT_MAX98357A_KO' in build
assert 'modinfo -F vermagic' in build
assert 'snd-soc-max98357a.ko' in build
assert 'depmod -b "$MNT" "$KERNEL_ABI"' in build
assert 'bpi-zero-clock-release' in build
assert 'maxim,max98357a' in dtb
assert 'mk-clock,max98357a' not in dtb
assert 'bpi-zero-clock,hardware' in dtb
assert 'kernel-matched' in readme
print('clock builder checks passed')
