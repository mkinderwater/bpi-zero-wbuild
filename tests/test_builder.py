#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
assert (root / "VERSION").read_text().strip() == "1.0.0"

build = (root / "build.sh").read_text()
firstboot = (root / "overlay/root/bpi-zero-wbuild-firstboot.sh").read_text()

for p in [
    root / "build.sh",
    root / "overlay/root/bpi-zero-wbuild-firstboot.sh",
    root / "clock/build-max98357a.sh",
    root / "clock/patch-clock-dtb.sh",
    root / "clock/hardware/mk-piclock-bind-spidev",
]:
    result = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
    assert result.returncode == 0, f"shell syntax error in {p}: {result.stderr}"

for p in [root / "scripts/make_fat32.py", root / "scripts/patch_mbr.py"]:
    compile(p.read_text(), str(p), "exec")

# Inherit the validated 1.2.6 firstboot/storage/network behavior.
assert "command -v ip" in firstboot
assert "command -v networkctl" in firstboot
resize_stage = firstboot.index('stage "02 GROWING ROOT PARTITION AND FILESYSTEM"')
network_restart = firstboot.index("systemctl restart systemd-networkd.service")
ipv4_check = firstboot.index('stage "12 VERIFYING IPV4"')
assert resize_stage < network_restart < ipv4_check
assert "partx --update --nr" in firstboot
assert 'resize2fs "$ROOT_DEV"' in firstboot
assert "systemctl reboot" not in firstboot
assert "ROOT_RESIZE_MODE=online-partx-resize2fs" in build
assert "ROOT_RESIZE_ORDER=before-network" in build
assert "FIRSTBOOT_REBOOT=none" in build

# Retain validated AP6212 firmware boundary and no BlueZ userspace in the image.
assert "BCM43430A1.sinovoip,bpi-m2-zero.hcd" in build
assert 'rm -f "$MNT/usr/lib/firmware/brcm/BCM43430A1.hcd"' in build
commands = "\n".join(
    line for line in (build + "\n" + firstboot).splitlines()
    if not line.lstrip().startswith("#")
)
assert not re.search(r"\b(?:apt|apt-get|dpkg)\b[^\n]*\bbluez(?:\s|$)", commands)

# Derivative identity and base identity are both explicit.
assert 'PRODUCT=bpi-zero-clock' in build
assert 'BASE_VERSION=1.2.6' in build
assert 'PRODUCT=bpi-zero-wbuild' in build
assert 'VERSION=1.2.6' in build
assert 'HARDWARE_CONFIGURATION=clock-image-owned' in build
assert 'OUT_IMG="$OUT_DIR/bpi-zero-clock.img"' in build

# Cache/checksum behavior remains from validated builder.
assert "rm -rf pkgroot" in build
assert 'meta="${dest}.source-url"' in build
assert '[ "$cached_url" = "$url" ]' in build
assert 'sha256sum "$(basename "$OUT_IMG")"' in build
assert 'sha256sum "$(basename "$OUT_IMG").gz"' in build

print("bpi-zero-clock 1.0.0 inherited-builder checks passed")
