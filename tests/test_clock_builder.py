#!/usr/bin/env python3
from pathlib import Path
import hashlib
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
build = (root / 'build.sh').read_text()
readme = (root / 'README.md').read_text()
install_doc = (root / 'INSTALL.md').read_text()
firstboot = (root / 'overlay/root/bpi-zero-wbuild-firstboot.sh').read_text()
modules = (root / 'clock/hardware/bpi-zero-clock.modules').read_text().splitlines()

VERSION='1.0.4-preview36'
ABI='6.12.101+deb13-armmp'
DEBIAN_VERSION='6.12.101-1'
ROOT_GZ_SHA='8cca0fed789a76fef8fb7c8c18bf46ed4d362f9e84d91ffecfe6674e9713c94f'
SOURCE_SHA='75b251c2eaa9aa03ae18bea9a1d134308ab8e882bde3f08523ca9f1d55797d54'

assert (root / 'VERSION').read_text().strip() == VERSION
assert f'BPI_ZERO_CLOCK_VERSION:-{VERSION}' in build
assert f'EXPECTED_ABI="{ABI}"' in build
assert 'BASE_VERSION=1.2.7' in build
assert 'VERSION=1.2.7' in build
assert 'BASE=debian-trixie-armhf-eiy3bo' in build
assert 'AUDIO_MODE=playback-only' in build
assert 'AUDIO_CAPTURE=removed' in build
assert 'APPLICATION_AUDIO_BASELINE=mk-clock-adult-2.3.50-preview34' in build
assert 'I2S_RX_GPIO=unassigned' in build
assert 'I2S_RX_HEADER_PIN=38-free' in build
assert 'TOUCH_GPIO=PA17' in build and 'TOUCH_HEADER_PIN=37' in build

# New upstream root image is exact and checksum-pinned.
assert 'https://dl.sd-card-images.johang.se/debians/2026-08-17/debian-trixie-armhf-eiy3bo.bin.gz' in build
assert f'DEBIAN_GZIP_SHA256="{ROOT_GZ_SHA}"' in build
assert 'Debian root image SHA256 mismatch' in build
assert 'ner4uz' not in build

# Playback-only source is the exact source used by the hardware-clean 1.0.3 path.
codec = root / 'clock/playback/max98357a.c'
assert codec.exists()
assert hashlib.sha256(codec.read_bytes()).hexdigest() == SOURCE_SHA
module_builder = (root / 'scripts/build_max98357a_module.sh').read_text()
assert f'ABI="{ABI}"' in module_builder
assert f'DEBIAN_VERSION="{DEBIAN_VERSION}"' in module_builder
assert f'SOURCE_SHA256="{SOURCE_SHA}"' in module_builder
assert 'linux-headers-6.12.101+deb13-common' in module_builder
assert 'linux-kbuild-6.12.101+deb13' in module_builder
assert 'pool/updates/main/l/linux' in module_builder
assert 'gcc-arm-linux-gnueabihf' in module_builder
assert 'SOURCE_POLICY=hardware-validated-max98357a-source-rebuilt-for-exact-kernel' in module_builder
for dead in ['snd-soc-dmic', 'sun4i-i2s.ko', 'snd-soc-simple-card.ko', 'capture-rate-hz']:
    assert dead not in module_builder, dead

# DTB is derived from the new kernel's stock BPI DTB, not carried from 6.12.100.
dtb_patch = (root / 'scripts/patch_playback_dtb.sh').read_text()
assert 'STOCK_DTB="$MNT/usr/lib/linux-image-$KERNEL_ABI/$CLOCK_DTB_NAME"' in build
assert 'patch_playback_dtb.sh' in build
for token in [
    '/soc/spi@1c68000 status okay',
    '/soc/i2c@1c2ac00 status okay',
    'pins PA18 PA19 PA20',
    '/max98357a compatible maxim,max98357a',
    '/max98357a sdmode-delay 5',
    'simple-audio-card,name MAX98357A',
    'simple-audio-card,mclk-fs 100',
]:
    assert token in dtb_patch, token
assert 'PA21' in dtb_patch and 'PA21 is deliberately absent/free' in dtb_patch
assert 'dmic-codec' not in dtb_patch.lower()
assert 'capture-rate-hz' not in dtb_patch.lower()
assert 'CLOCK_DTB_BOOT="$MNT/usr/lib/linux-image-$KERNEL_ABI/$CLOCK_DTB_NAME"' in build
assert 'install -m 0644 "$CLOCK_DTB_BUILD" "$CLOCK_DTB_BOOT"' in build
assert 'install -m 0644 "$CLOCK_DTB_BUILD" "$CLOCK_DTB_OUT"' in build

# No microphone-era build path survives.
for dead in [
    'build_audio_modules.sh', 'apply_audio_source_transforms.py',
    'patch_audio_capture_dtb.py', 'patch_asoc_24k_module.py',
]:
    assert not (root / 'scripts' / dead).exists(), dead
assert not (root / 'patches').exists()
assert 'snd-soc-dmic' not in modules
assert 'sun4i-i2s' in modules
assert 'snd-soc-simple-card' in modules
assert 'snd-soc-max98357a' in modules
assert not (root / 'clock/hardware/mk-piclock-validate-ics43434-24k').exists()
assert 'mk-piclock-validate-ics43434-24k' not in build

# ALSA is direct hardware playback only.
asound=(root / 'clock/hardware/asound.conf').read_text().lower()
assert 'type hw' in asound and 'card max98357a' in asound and 'device 0' in asound
for forbidden in ['type asym','type plug','type rate','type dmix','type dsnoop','capture.pcm']:
    assert forbidden not in asound

# extlinux replaces the retired boot.cmd/boot.scr path. Root uses final MBR
# partition 2 PARTUUID so the rootfs label is not part of the appliance contract.
extlinux_policy=(root / 'scripts/set_extlinux_policy.py').read_text()
partuuid=(root / 'scripts/mbr_partuuid.py').read_text()
assert 'EXTLINUX_CONF="$MNT/boot/extlinux/extlinux.conf"' in build
assert 'ROOT_PARTUUID="$(python3 "$HERE/scripts/mbr_partuuid.py" boot.bin --partition 2)"' in build
assert 'set_extlinux_policy.py' in build
assert 'quiet loglevel=4' in extlinux_policy
assert "prompt 0" in extlinux_policy
assert "timeout 10" in extlinux_policy
assert "struct.unpack_from('<I', mbr, 440)" in partuuid
assert '/boot/boot.cmd' not in build
assert '/boot/boot.scr' not in build
assert 'mkimage' not in build
assert 'u-boot-tools' not in build
assert 'KERNEL_BOOT_QUIET=yes' in build
assert 'KERNEL_CONSOLE_LOGLEVEL=4' in build

with tempfile.TemporaryDirectory() as td:
    ext=Path(td)/'extlinux.conf'
    defs=Path(td)/'u-boot'
    ext.write_text('default l0\nprompt 1\ntimeout 50\nlabel l0\n\tappend root=LABEL=rootfs rw rootwait\n')
    defs.write_text('U_BOOT_PARAMETERS="rw rootwait"\n')
    r=subprocess.run([
        'python3', str(root/'scripts/set_extlinux_policy.py'), str(ext), str(defs),
        '--partuuid','12345678-02'
    ],capture_output=True,text=True)
    assert r.returncode == 0, r.stderr
    t=ext.read_text(); d=defs.read_text()
    assert 'prompt 0' in t and 'timeout 10' in t
    assert 'append root=PARTUUID=12345678-02 rw rootwait quiet loglevel=4' in t
    assert 'root=LABEL=rootfs' not in t
    assert 'U_BOOT_ROOT="root=PARTUUID=12345678-02"' in d
    assert 'U_BOOT_PARAMETERS="rw rootwait quiet loglevel=4"' in d

# Kernel ownership is exact-ABI pinned.
kernel_pin=(root/'clock/kernel-pin.pref').read_text()
for pkg in [
    'linux-image-armmp','linux-headers-armmp',
    'linux-image-6.12.101+deb13-armmp',
    'linux-headers-6.12.101+deb13-armmp',
    'linux-headers-6.12.101+deb13-common',
]:
    assert pkg in kernel_pin, pkg
assert 'KERNEL_UPDATE_POLICY=image-release-owned-exact-abi-pinned' in build

# 24/7 appliance policies remain intact.
journal=(root/'clock/hardware/journald-volatile.conf').read_text()
tmp=(root/'clock/hardware/tmp.mount').read_text()
watchdog=(root/'clock/hardware/system-watchdog.conf').read_text()
assert 'Storage=volatile' in journal and 'RuntimeMaxUse=16M' in journal
assert 'What=tmpfs' in tmp and 'size=64M' in tmp
assert 'RuntimeWatchdogSec=16s' in watchdog and 'RebootWatchdogSec=16s' in watchdog
assert 'rm -rf "$MNT/var/log/journal"' in build

# Firstboot/network/storage behavior remains the proven appliance flow.
for token in [
    'partx --update --nr', 'resize2fs "$ROOT_DEV"',
    'ROOT_DEV="$(readlink -f "$(findmnt -n -o SOURCE /)")"',
    'PowerSaveDisable=brcmfmac', 'iw dev wlan0 get power_save',
    'stage "12 WIFI RECOVERY RETRY"', 'wait_ipv4 60',
    'PKG_LOG=/var/log/bpi-zero-wbuild-packages.log',
    'systemd-machine-id-setup', 'cleanup_staged_packages()',
]:
    assert token in firstboot, token
assert 'systemctl reboot' not in firstboot
assert 'e2fsck' not in firstboot
assert '/dev/mmcblk0' not in firstboot and '/dev/mmcblk1' not in firstboot
assert 'ROOT_RESIZE_MODE=firstboot-online-resize2fs-fail-closed' in build
assert 'ROOT_RESIZE_ORDER=before-network' in build
assert 'FIRSTBOOT_REBOOT=none' in build
assert 'WIFI_FIRMWARE_INSTALL=image-build-direct' in build
assert 'FIRSTBOOT_RESUME=checkpointed' in build
assert 'WIFI_RECOVERY_RETRY=one-controlled-radio-userspace-restart' in build
assert 'CLI_NETWORK_TOOL=iproute2-6.15.0-1' in build
assert 'CLI_WIFI_TOOL=iw-6.9-1' in build
assert 'ALSA_UTILS=alsa-utils-1.2.14-1' in build
assert 'systemctl mask alsa-restore.service alsa-state.service alsa-utils.service' in firstboot

# Clone-safe image finalization remains explicit even though the new upstream
# root image currently ships no populated machine-id.
for token in [
    'truncate -s 0 "$MNT/etc/machine-id"',
    'rm -f "$MNT/var/lib/dbus/machine-id"',
    'ln -s /etc/machine-id "$MNT/var/lib/dbus/machine-id"',
    'MACHINE_ID_POLICY=firstboot-systemd-machine-id-setup',
]:
    assert token in build, token

# Host/download hardening remains fail-closed.
for token in [
    'command -v unzip', 'ca-certificates', 'update-ca-certificates',
    'gzip -t "$dest"', 'e2fsck -f -n debian.bin',
    '--no-install-recommends',
]:
    assert token in build, token
assert 'curl -k' not in build and 'curl --insecure' not in build

# Scripts parse and shell-check.
for p in [
    root/'build.sh', root/'overlay/root/bpi-zero-wbuild-firstboot.sh',
    root/'clock/hardware/mk-piclock-bind-spidev',
    root/'scripts/build_max98357a_module.sh', root/'scripts/patch_playback_dtb.sh',
]:
    r=subprocess.run(['bash','-n',str(p)],capture_output=True,text=True)
    assert r.returncode == 0, f'{p}: {r.stderr}'
for p in [
    root/'scripts/make_fat32.py', root/'scripts/patch_mbr.py',
    root/'scripts/mbr_partuuid.py', root/'scripts/set_extlinux_policy.py',
    root/'scripts/relocate_debian_header_sdk.py', root/'scripts/disable_ssh_locale_forwarding.py',
    root/'tests/fdt_read.py',
]:
    compile(p.read_text(),str(p),'exec')

# Current docs should only describe preview36/new ABI and playback-only hardware.
for doc in (readme,install_doc):
    assert 'preview36' in doc.lower()
    assert 'playback-only' in doc.lower()
    assert '6.12.101' in doc
    assert 'ics-43434' not in doc.lower()
assert 'preview36' in (root/'CHANGELOG.md').read_text().lower()

print('bpi-zero-clock 1.0.4-preview36 new Debian 6.12.101 playback-only checks passed')
