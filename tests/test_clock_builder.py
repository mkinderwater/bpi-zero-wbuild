#!/usr/bin/env python3
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1]
build = (root / 'build.sh').read_text()
readme = (root / 'README.md').read_text()
abi = '6.12.100+deb13-armmp'
validated = root / 'clock' / 'validated' / abi
ko = validated / 'snd-soc-max98357a.ko'
dtb = validated / 'sun8i-h2-plus-bananapi-m2-zero.dtb'

assert (root / 'VERSION').read_text().strip() == '1.0.3'
assert 'bpi-zero-clock-$VERSION-bpi-m2-zero.img' in build
assert f'VALIDATED_ABI="{abi}"' in build
assert 'hardware-validated-local-build' in build
assert 'snd-soc-max98357a.ko' in build
assert 'maxim,max98357a' in build
assert 'sdmode-delay' in build
assert 'MAX98357A_SD_DELAY_MS=5' in build
assert 'MAX98357A_MCLK_FS=256' in build
assert 'depmod -b "$MNT" "$KERNEL_ABI"' in build
assert 'LEGACY_AMP_GATE_PATHS=(' in build
assert '[ -L "$legacy_path" ]' in build
assert 'legacy amp-gate artifact survived image cleanup' in build
assert 'LEGACY_SPDIF_CODEC=removed' in build
assert 'LEGACY_AMP_GATE=removed' in build
assert 'LEGACY_AMP_GATE_FILES=absent-verified' in build

assert hashlib.sha256(ko.read_bytes()).hexdigest() == '906b7ef831e199a7ae0dc1aa724251ea1763876298cdcd8564a25e70badaa3c6'
assert hashlib.sha256(dtb.read_bytes()).hexdigest() == '7d54132d9b707ec62d5b72e08cd329b557a92940664e48164b5b8a8cfd5fcaff'
assert 'no startup pop' in readme.lower()
assert 'no trailing hiss' in readme.lower()
print('bpi-zero-clock 1.0.3 validated audio checks passed')
