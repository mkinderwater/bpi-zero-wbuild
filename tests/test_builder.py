#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
assert (root / "VERSION").read_text().strip() == "1.0.4-preview36"

build = (root / "build.sh").read_text()
for cmd, pkg in [
    ("python3", "python3"),
    ("ar", "binutils"),
    ("tar", "tar"),
    ("gzip", "gzip"),
    ("unzip", "unzip"),
]:
    assert f"command -v {cmd}" in build, f"missing startup dependency check for {cmd}"
    assert f"MISSING_HOST_PKGS+=({pkg})" in build, f"missing package mapping for {cmd}"
firstboot = (root / "overlay/root/bpi-zero-wbuild-firstboot.sh").read_text()
assert "command -v fdtget" in build

for p in [
    root / "build.sh",
    root / "overlay/root/bpi-zero-wbuild-firstboot.sh",
    root / "clock/hardware/mk-piclock-bind-spidev",
    root / "scripts/build_max98357a_module.sh",
    root / "scripts/patch_playback_dtb.sh",
]:
    result = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
    assert result.returncode == 0, f"shell syntax error in {p}: {result.stderr}"

for p in [
    root / "scripts/make_fat32.py",
    root / "scripts/patch_mbr.py",
    root / "tests/fdt_read.py",
    root / "scripts/mbr_partuuid.py",
    root / "scripts/set_extlinux_policy.py",
    root / "scripts/relocate_debian_header_sdk.py",
]:
    compile(p.read_text(), str(p), "exec")

# Minimal appliance locale policy: do not add locale packages just to satisfy
# client-forwarded LANG/LC_* values. Strip those AcceptEnv patterns at build time.
ssh_locale_transform = (root / "scripts/disable_ssh_locale_forwarding.py").read_text()
assert 'disable_ssh_locale_forwarding.py" --root "$MNT"' in build
assert 'SSH_CLIENT_LOCALE_FORWARDING=disabled' in build
assert 'LOCALE_PACKAGES=not-installed' in build
assert 'token == "LANG" or token.startswith("LC_")' in ssh_locale_transform
assert 'locale-gen' not in build
assert 'apt-get install -y locales' not in build

with tempfile.TemporaryDirectory() as td:
    troot = Path(td)
    (troot / "etc/ssh/sshd_config.d").mkdir(parents=True)
    (troot / "etc/ssh/sshd_config").write_text(
        "AcceptEnv LANG LC_*\nAcceptEnv FOO LANG BAR\nAcceptEnv KEEP_ME\n"
    )
    (troot / "etc/ssh/sshd_config.d/20-extra.conf").write_text(
        "AcceptEnv LC_CTYPE APP_TOKEN\n"
    )
    r = subprocess.run([
        "python3", str(root / "scripts/disable_ssh_locale_forwarding.py"),
        "--root", str(troot),
    ], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    main_cfg = (troot / "etc/ssh/sshd_config").read_text()
    extra_cfg = (troot / "etc/ssh/sshd_config.d/20-extra.conf").read_text()
    assert "# BPI-ZERO-WBUILD disabled client locale forwarding: AcceptEnv LANG LC_*" in main_cfg
    assert "AcceptEnv FOO BAR" in main_cfg
    assert "AcceptEnv KEEP_ME" in main_cfg
    assert "AcceptEnv APP_TOKEN" in extra_cfg
    assert "LC_CTYPE" not in extra_cfg

# Inherit the validated firstboot/storage/network behavior.
assert "command -v networkctl" not in firstboot
resize_stage = firstboot.index('stage "02 ROOT FILESYSTEM CAPACITY"')
network_restart = firstboot.index("systemctl restart systemd-networkd.service")
ipv4_check = firstboot.index('stage "11 VERIFYING WIFI + IPV4 (ATTEMPT 1/2)"')
assert resize_stage < network_restart < ipv4_check
assert "partx --update --nr" in firstboot
assert 'resize2fs "$ROOT_DEV"' in firstboot
assert "systemctl reboot" not in firstboot
assert "fsck.mode=force" not in firstboot
assert "fsck.repair=yes" not in firstboot
assert "tune2fs -E force_fsck" not in firstboot
assert "e2fsck" not in firstboot
assert "LABEL=rootfs" not in firstboot
assert "LABEL=rootfs" not in build
assert "ROOT_FS_BUILD_VALIDATION=e2fsck-read-only-clean-required" in build
assert "ROOT_FS_REPAIR=none" in build
assert "e2fsck -f -n debian.bin" in build
assert 'ROOT_DEV="$(readlink -f "$(findmnt -n -o SOURCE /)")"' in firstboot
assert "/dev/mmcblk0" not in firstboot
assert "/dev/mmcblk1" not in firstboot
assert "ROOT_RESIZE_MODE=firstboot-online-resize2fs-fail-closed" in build
assert "ROOT_RESIZE_ORDER=before-network" in build
assert "FIRSTBOOT_REBOOT=none" in build
assert "CLI_NETWORK_TOOL=iproute2-6.15.0-1" in build
assert "FIRSTBOOT_RESUME=checkpointed" in build
assert "WIFI_RECOVERY_RETRY=one-controlled-radio-userspace-restart" in build
assert 'iproute2_6.15.0-1_armhf.deb' in build
assert 'iproute2_6.15.0-1_armhf.deb' in firstboot
assert 'iw_6.9-1_armhf.deb' in build
assert 'iw_6.9-1_armhf.deb' in firstboot
assert 'alsa-utils_1.2.14-1_armhf.deb' in build
assert 'alsa-utils_1.2.14-1_armhf.deb' in firstboot
assert 'libasound2-data_1.2.14-1_all.deb' in build
assert 'libasound2t64_1.2.14-1_armhf.deb' in build
assert 'libatopology2t64_1.2.14-1_armhf.deb' in build
assert 'libfftw3-single3_3.3.10-2+b1_armhf.deb' in build
assert 'gcc-14-base_14.2.0-19_armhf.deb' in build
assert 'libgomp1_14.2.0-19_armhf.deb' in build
assert 'libsamplerate0_0.2.2-4+b2_armhf.deb' in build
assert 'ALSA_UTILS=alsa-utils-1.2.14-1' in build
assert 'ALSA_STATE_RESTORE=disabled-image-policy' in build
assert 'mk-piclock-validate-ics43434-24k' not in build
assert 'MIC_VALIDATOR=' not in build
assert 'MIC_VALIDATOR_RUNTIME=' not in build
assert not (root / 'clock/hardware/mk-piclock-validate-ics43434-24k').exists()
assert 'systemctl mask alsa-restore.service alsa-state.service alsa-utils.service' in firstboot
assert 'libnl-3-200_3.7.0-2_armhf.deb' in build
assert 'libnl-genl-3-200_3.7.0-2_armhf.deb' in build
assert 'PowerSaveDisable=brcmfmac' in firstboot
assert 'iw dev wlan0 get power_save' in firstboot
assert 'PACKAGES_MARKER=' in firstboot
assert 'IDENTITY_MARKER=' in firstboot
assert 'systemd-machine-id-setup' in firstboot
assert 'note "Machine ID: $MACHINE_ID"' in firstboot
assert 'FIRMWARE_MARKER=' not in firstboot
assert 'pkgroot/brcmfmac43430-sdio' not in build
assert 'pkgroot/regulatory.db' not in build
assert 'WIFI_FIRMWARE_INSTALL=image-build-direct' in build
for token in [
    'install -m 0644 "$REGDB" "$MNT/usr/lib/firmware/regulatory.db"',
    'install -m 0644 "$CYPRESS_BIN" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.bin"',
    'install -m 0644 "$BOARD_TXT" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt"',
]:
    assert token in build, token
assert 'stage "07 REGULATORY + BCM43430 WIFI FIRMWARE"' not in firstboot
assert 'SSH_MARKER=' in firstboot
assert 'CURRENT_HOST=' in firstboot
assert "grep -Eq '^bpi-zero-wbuild-[0-9a-z]{3}$'" in firstboot
assert 'stage "12 WIFI RECOVERY RETRY"' in firstboot
assert 'wait_ipv4 60' in firstboot
assert 'console_line' in firstboot
assert 'PKG_LOG=/var/log/bpi-zero-wbuild-packages.log' in firstboot
assert 'wifi_diag_snapshot "attempt 1 failed"' in firstboot
assert 'wifi_diag_snapshot "attempt 2 failed"' in firstboot
assert 'SSID visible:' in firstboot
assert 'Associated:' in firstboot
assert 'BSSID:' in firstboot
assert 'Signal:' in firstboot
assert 'Power save:' in firstboot
assert firstboot.count('stage "09 TIME ZONE"') == 1

# Preview23 correctness hardening.
assert 'IWD_PROFILE_STATE="$STATE_DIR/iwd-profile"' in firstboot
assert 'trap cleanup_config_mount EXIT' in firstboot
assert 'config_value()' in firstboot
assert 'cleanup_staged_firmware()' not in firstboot
assert 'cleanup_staged_packages()' in firstboot
assert 'Removed stale firstboot Wi-Fi profile' in firstboot
assert 'provisioning complete but unable to disable firstboot service' in firstboot
assert 'provisioning is complete but firstboot service could not be disabled' in firstboot
kernel_pin = (root / 'clock/kernel-pin.pref').read_text()
for pkg in [
    'linux-image-armmp', 'linux-headers-armmp',
    'linux-image-6.12.101+deb13-armmp',
    'linux-headers-6.12.101+deb13-armmp',
    'linux-headers-6.12.101+deb13-common',
]:
    assert pkg in kernel_pin, pkg
assert 'KERNEL_UPDATE_POLICY=image-release-owned-exact-abi-pinned' in build

# Release image identity must be clone-safe. The base image currently carries
# a populated machine-id, so finalization must clear it and eliminate the
# independent D-Bus fallback before the root filesystem is packaged.
for token in [
    'truncate -s 0 "$MNT/etc/machine-id"',
    'rm -f "$MNT/var/lib/dbus/machine-id"',
    'ln -s /etc/machine-id "$MNT/var/lib/dbus/machine-id"',
    'MACHINE_ID_POLICY=firstboot-systemd-machine-id-setup',
]:
    assert token in build, token
machine_reset = build.index('truncate -s 0 "$MNT/etc/machine-id"')
assert machine_reset < build.index('\nsync\n', machine_reset)

# First boot assigns a persistent random appliance hostname in the
# bpi-zero-wbuild-xxx format instead of cloning one shared hostname.
assert "HOST_ALPHABET='0123456789abcdefghijklmnopqrstuvwxyz'" in firstboot
assert 'HOST_RANDOM="$(od -An -N2 -tu2 /dev/urandom' in firstboot
assert 'HOST_RANDOM=$((HOST_RANDOM % 46656))' in firstboot
assert 'HOSTNAME_NEW="bpi-zero-wbuild-$HOST_SUFFIX"' in firstboot
assert "echo 'bpi-zero-wbuild' >/etc/hostname" not in firstboot
assert 'hostnamectl set-hostname bpi-zero-wbuild' not in firstboot

# Retain the board-qualified AP6212 firmware boundary and no BlueZ userspace.
assert "BCM43430A1.sinovoip,bpi-m2-zero.hcd" in build
assert 'rm -f "$MNT/usr/lib/firmware/brcm/BCM43430A1.hcd"' in build
commands = "\n".join(
    line for line in (build + "\n" + firstboot).splitlines()
    if not line.lstrip().startswith("#")
)
assert not re.search(r"\b(?:apt|apt-get|dpkg)\b[^\n]*\bbluez(?:\s|$)", commands)

# Derivative and base identities remain explicit.
assert "PRODUCT=bpi-zero-clock" in build
assert "BASE_VERSION=1.2.7" in build
assert "PRODUCT=bpi-zero-wbuild" in build
assert "VERSION=1.2.7" in build
assert "HARDWARE_CONFIGURATION=clock-image-owned" in build
assert 'OUT_IMG="$OUT_DIR/bpi-zero-clock-$VERSION-bpi-m2-zero.img"' in build

# Preview36 keeps playback-only audio while migrating to Debian 6.12.101.
assert 'EXPECTED_ABI="6.12.101+deb13-armmp"' in build
assert 'scripts/build_max98357a_module.sh' in build
assert 'scripts/patch_playback_dtb.sh' in build
assert (root / 'clock/playback/max98357a.c').exists()
assert (root / 'clock/playback/Makefile').exists()
assert (root / 'scripts/relocate_debian_header_sdk.py').exists()
assert not (root / 'scripts/build_audio_modules.sh').exists()
assert not (root / 'scripts/apply_audio_source_transforms.py').exists()
assert 'AUDIO_MODE=playback-only' in build
assert 'AUDIO_CAPTURE=removed' in build
assert 'I2S_RX_GPIO=unassigned' in build
assert 'I2S_RX_HEADER_PIN=38-free' in build
assert 'TOUCH_GPIO=PA17' in build and 'TOUCH_HEADER_PIN=37' in build
assert 'snd-soc-dmic' not in (root / 'clock/hardware/bpi-zero-clock.modules').read_text()
module_builder=(root / 'scripts/build_max98357a_module.sh').read_text()
assert 'ABI="6.12.101+deb13-armmp"' in module_builder
assert 'DEBIAN_VERSION="6.12.101-1"' in module_builder
assert 'gcc-arm-linux-gnueabihf' in module_builder
assert 'SOURCE_SHA256="75b251c2eaa9aa03ae18bea9a1d134308ab8e882bde3f08523ca9f1d55797d54"' in module_builder
assert 'snd-soc-dmic' not in module_builder
assert 'sun4i-i2s.ko' not in module_builder

# New rootfs uses extlinux. The builder owns a noninteractive, quiet, PARTUUID boot policy.
extlinux_policy=(root / 'scripts/set_extlinux_policy.py').read_text()
partuuid_script=(root / 'scripts/mbr_partuuid.py').read_text()
assert 'EXTLINUX_CONF="$MNT/boot/extlinux/extlinux.conf"' in build
assert 'ROOT_PARTUUID="$(python3 "$HERE/scripts/mbr_partuuid.py" boot.bin --partition 2)"' in build
assert 'set_extlinux_policy.py' in build
assert 'quiet loglevel=4' in extlinux_policy
assert "prompt 0" in extlinux_policy
assert "timeout 10" in extlinux_policy
assert 'PARTUUID' in extlinux_policy
assert "struct.unpack_from('<I', mbr, 440)" in partuuid_script
assert 'command -v mkimage' not in build
assert 'u-boot-tools' not in build
assert '/boot/boot.cmd' not in build
assert '/boot/boot.scr' not in build
assert 'KERNEL_BOOT_QUIET=yes' in build
assert 'KERNEL_CONSOLE_LOGLEVEL=4' in build

# Synthetic extlinux normalization test.
with tempfile.TemporaryDirectory() as td:
    ext = Path(td) / 'extlinux.conf'
    defaults = Path(td) / 'u-boot'
    ext.write_text('default l0\nprompt 1\ntimeout 50\nlabel l0\n\tappend root=LABEL=rootfs rw rootwait\n')
    defaults.write_text('U_BOOT_PARAMETERS="rw rootwait"\n')
    r = subprocess.run([
        'python3', str(root / 'scripts/set_extlinux_policy.py'),
        str(ext), str(defaults), '--partuuid', '12345678-02',
    ], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert 'prompt 0' in ext.read_text()
    assert 'timeout 10' in ext.read_text()
    assert 'append root=PARTUUID=12345678-02 rw rootwait quiet loglevel=4' in ext.read_text()
    assert 'U_BOOT_ROOT="root=PARTUUID=12345678-02"' in defaults.read_text()

# Cache/checksum behavior remains from the validated builder.
assert "rm -rf pkgroot" in build
assert 'meta="${dest}.source-url"' in build
assert '[ "$cached_url" = "$url" ]' in build
assert 'fetch_gzip() {' in build
assert 'gzip -t "$dest"' in build
assert 'rm -f "$dest" "${dest}.source-url"' in build
assert 'fetch_gzip "$BOOT_URL" boot.bin.gz' in build
assert 'fetch_gzip "$DEBIAN_URL" debian.bin.gz' in build
assert ': "${DEBIAN_URL:=https://dl.sd-card-images.johang.se/debians/2026-08-17/debian-trixie-armhf-eiy3bo.bin.gz}"' in build
assert 'DEBIAN_GZIP_SHA256="8cca0fed789a76fef8fb7c8c18bf46ed4d362f9e84d91ffecfe6674e9713c94f"' in build
assert 'download.icubedev.com/debian-trixie-armhf-ner4uz.bin.gz' not in build
assert 'failed gzip integrity verification after 3 fresh downloads' in build
assert 'sha256sum "$(basename "$OUT_IMG")"' in build
assert 'sha256sum "$(basename "$OUT_IMG").gz"' in build


# Automated build-host package installs must never invoke interactive debconf.
# Keep the policy command-scoped; do not persist DEBIAN_FRONTEND globally.
assert build.count('DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true') >= 1
assert 'DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \\\n        apt-get install -y --no-install-recommends "${MISSING_HOST_PKGS[@]}"' in build
assert 'export DEBIAN_FRONTEND' not in build
assert 'DEBCONF_FRONTEND_POLICY=persistent-Noninteractive-after-DHCP' in build

# Preview27 builder TLS/decompression prerequisites: explicit unzip and CA trust.
assert 'command -v unzip >/dev/null 2>&1 || MISSING_HOST_PKGS+=(unzip)' in build
assert '[ -s /etc/ssl/certs/ca-certificates.crt ] || MISSING_HOST_PKGS+=(ca-certificates)' in build
assert 'update-ca-certificates' in build
assert 'HTTPS CA certificate bundle unavailable' in build
assert 'curl -k' not in build and 'curl --insecure' not in build


# Preview25 cull invariants retained by preview26.
assert 'NETWORK_IPV4_VERIFIER=iproute2' in build
assert 'networkctl status wlan0 --no-pager 2>/dev/null |' not in firstboot
assert 'UNKNOWN (iw unavailable)' not in firstboot
assert 'cleanup_completed_state()' in firstboot
assert 'rm -rf "$STATE_DIR"' in firstboot
assert 'rm -f "$RESIZE_MARKER"' in firstboot
assert 'bpi-zero-clock-audio-source-build.txt' not in build
assert not (root / 'scripts/patch_audio_capture_dtb.py').exists()
assert not (root / 'patches').exists()
assert not (root / 'clock/validated').exists()
assert (root / 'clock/playback/max98357a.c').exists()
assert (root / 'config/CONFIG.TXT.template').stat().st_size < 2048

# Preview26 post-cull cleanup/completion invariants.
unit = (root / 'overlay/root/bpi-zero-wbuild-firstboot.service').read_text()
assert 'ConditionPathExists=' not in unit
assert 'ExecStart=/bin/bash /root/bpi-zero-wbuild-firstboot.sh' in unit
assert 'if [ -e "$MARKER" ]; then' in firstboot
marker_branch = firstboot.index('if [ -e "$MARKER" ]; then')
assert firstboot.index('systemctl disable bpi-zero-wbuild-firstboot.service', marker_branch) > marker_branch
assert 'for src in "$HERE"/overlay/root/*.sh; do' in build
assert 'for src in "$HERE"/overlay/root/*.sh "$HERE"/overlay/root/*.service; do' not in build
assert "find pkgroot -maxdepth 1 -type f -name '*.source-url' -delete" in build
assert build.index("find pkgroot -maxdepth 1 -type f -name '*.source-url' -delete") < build.index('cp -f pkgroot/* "$MNT/root/"')

print("bpi-zero-clock 1.0.4-preview36 new-root playback-only inherited-builder checks passed")
