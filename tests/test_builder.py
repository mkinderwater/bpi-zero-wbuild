#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
assert (root / "VERSION").read_text().strip() == "1.0.4-preview25"

build = (root / "build.sh").read_text()
for cmd, pkg in [
    ("python3", "python3"),
    ("ar", "binutils"),
    ("tar", "tar"),
    ("gzip", "gzip"),
]:
    assert f"command -v {cmd}" in build, f"missing startup dependency check for {cmd}"
    assert f"MISSING_HOST_PKGS+=({pkg})" in build, f"missing package mapping for {cmd}"
firstboot = (root / "overlay/root/bpi-zero-wbuild-firstboot.sh").read_text()
assert "command -v fdtget" in build

for p in [
    root / "build.sh",
    root / "overlay/root/bpi-zero-wbuild-firstboot.sh",
    root / "clock/hardware/mk-piclock-bind-spidev",
    root / "scripts/build_audio_modules.sh",
]:
    result = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
    assert result.returncode == 0, f"shell syntax error in {p}: {result.stderr}"

for p in [
    root / "scripts/make_fat32.py",
    root / "scripts/patch_mbr.py",
    root / "tests/fdt_read.py",
    root / "scripts/apply_audio_source_transforms.py",
    root / "scripts/relocate_debian_header_sdk.py",
    root / "scripts/set_boot_loglevel.py",
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

# Inherit the validated 1.2.6 firstboot/storage/network behavior.
assert "command -v ip" in firstboot
assert "command -v networkctl" not in firstboot
resize_stage = firstboot.index('stage "02 ROOT FILESYSTEM CAPACITY"')
network_restart = firstboot.index("systemctl restart systemd-networkd.service")
ipv4_check = firstboot.index('stage "12 VERIFYING WIFI + IPV4 (ATTEMPT 1/2)"')
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
assert 'command -v arecord' in firstboot
assert 'command -v aplay' in firstboot
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
assert 'command -v iw' in firstboot
assert 'iw dev wlan0 get power_save' in firstboot
assert 'PACKAGES_MARKER=' in firstboot
assert 'IDENTITY_MARKER=' in firstboot
assert 'FIRMWARE_MARKER=' in firstboot
assert 'SSH_MARKER=' in firstboot
assert 'CURRENT_HOST=' in firstboot
assert "grep -Eq '^bpi-zero-wbuild-[0-9a-z]{3}$'" in firstboot
assert 'stage "13 WIFI RECOVERY RETRY"' in firstboot
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
assert firstboot.count('stage "10 TIME ZONE"') == 1

# Preview23 correctness hardening.
assert 'IWD_PROFILE_STATE="$STATE_DIR/iwd-profile"' in firstboot
assert 'trap cleanup_config_mount EXIT' in firstboot
assert 'config_value()' in firstboot
assert 'cleanup_staged_firmware()' in firstboot
assert 'cleanup_staged_packages()' in firstboot
assert 'systemctl is-enabled "$unit"' in firstboot
assert 'Removed stale firstboot Wi-Fi profile' in firstboot
assert 'provisioning complete but unable to disable firstboot service' in firstboot
assert 'provisioning is complete but firstboot service could not be disabled' in firstboot
kernel_pin = (root / 'clock/kernel-pin.pref').read_text()
for pkg in [
    'linux-image-armmp', 'linux-headers-armmp',
    'linux-image-6.12.100+deb13-armmp',
    'linux-headers-6.12.100+deb13-armmp',
    'linux-headers-6.12.100+deb13-common',
]:
    assert pkg in kernel_pin, pkg
assert 'KERNEL_UPDATE_POLICY=image-release-owned-exact-abi-pinned' in build

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
assert "BASE_VERSION=1.2.6" in build
assert "PRODUCT=bpi-zero-wbuild" in build
assert "VERSION=1.2.6" in build
assert "HARDWARE_CONFIGURATION=clock-image-owned" in build
assert 'OUT_IMG="$OUT_DIR/bpi-zero-clock-$VERSION-bpi-m2-zero.img"' in build

# Exact source-built audio path is invoked by the image builder.
assert 'scripts/build_audio_modules.sh' in build
assert 'MK_AUDIO_BUILD_WORK=' in build
assert 'MK_AUDIO_BUILD_OUT=' in build
assert 'snd-soc-dmic.ko.xz' in build
assert 'snd-soc-simple-card.ko.xz' in build
assert 'sun4i-i2s.ko.xz' in build
assert 'patch_asoc_24k_module.py' not in build

# Appliance console policy is image-owned and survives future initramfs updates.
boot_policy = (root / "scripts/set_boot_loglevel.py").read_text()
assert "quiet loglevel=3" in boot_policy
assert "LOGLEVEL_RE" in boot_policy
assert "command -v mkimage" in build
assert "u-boot-tools" in build
assert 'BOOT_CMD="$MNT/boot/boot.cmd"' in build
assert 'BOOT_UPDATE_HOOK="$MNT/etc/initramfs/post-update.d/zz-update-uimg"' in build
assert 'python3 "$HERE/scripts/set_boot_loglevel.py" "$BOOT_CMD" "$BOOT_UPDATE_HOOK"' in build
assert 'mkimage -A arm -T script -C none -d "$BOOT_CMD" "$BOOT_SCR"' in build
assert "KERNEL_BOOT_QUIET=yes" in build
assert "KERNEL_CONSOLE_LOGLEVEL=3" in build

# Cache/checksum behavior remains from the validated builder.
assert "rm -rf pkgroot" in build
assert 'meta="${dest}.source-url"' in build
assert '[ "$cached_url" = "$url" ]' in build
assert 'fetch_gzip() {' in build
assert 'gzip -t "$dest"' in build
assert 'rm -f "$dest" "${dest}.source-url"' in build
assert 'fetch_gzip "$BOOT_URL" boot.bin.gz' in build
assert 'fetch_gzip "$DEBIAN_URL" debian.bin.gz' in build
assert 'failed gzip integrity verification after 3 fresh downloads' in build
assert 'sha256sum "$(basename "$OUT_IMG")"' in build
assert 'sha256sum "$(basename "$OUT_IMG").gz"' in build


# Synthetic U-Boot bootargs normalization test.
with tempfile.TemporaryDirectory() as td:
    bootcmd = Path(td) / "boot.cmd"
    hook = Path(td) / "zz-update-uimg"
    bootcmd.write_text("setenv bootargs root=PARTUUID=${partuuid} rw rootwait loglevel=7\n")
    hook.write_text("  setenv bootargs quiet root=PARTUUID=${partuuid} rw rootwait\n")
    r = subprocess.run([
        "python3", str(root / "scripts/set_boot_loglevel.py"),
        str(bootcmd), str(hook),
    ], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert bootcmd.read_text() == "setenv bootargs quiet loglevel=3 root=PARTUUID=${partuuid} rw rootwait\n"
    assert hook.read_text() == "  setenv bootargs quiet loglevel=3 root=PARTUUID=${partuuid} rw rootwait\n"

# Synthetic Debian private-SDK relocation test. This reproduces the package
# layout that failed on the real BPI without needing network/package downloads.
with tempfile.TemporaryDirectory() as td:
    sdk = Path(td) / "sdk"
    abi = "6.12.100+deb13-armmp"
    common_name = "linux-headers-6.12.100+deb13-common"
    kbuild_name = "linux-kbuild-6.12.100+deb13"
    hdr = sdk / "usr/src" / f"linux-headers-{abi}"
    common = sdk / "usr/src" / common_name
    kbuild = sdk / "usr/lib" / kbuild_name
    hdr.mkdir(parents=True)
    common.mkdir(parents=True)
    (kbuild / "scripts").mkdir(parents=True)
    (kbuild / "tools").mkdir(parents=True)
    (hdr / "Makefile").write_text(f"include /usr/src/{common_name}/Makefile\n")
    (common / "Makefile").write_text("# common\n")
    for tree in (hdr, common):
        (tree / "scripts").symlink_to(f"/usr/lib/{kbuild_name}/scripts")
        (tree / "tools").symlink_to(f"/usr/lib/{kbuild_name}/tools")
    r = subprocess.run([
        "python3", str(root / "scripts/relocate_debian_header_sdk.py"),
        "--sdk-root", str(sdk), "--abi", abi,
        "--common-name", common_name, "--kbuild-name", kbuild_name,
    ], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert (hdr / "Makefile").read_text() == f"include ../{common_name}/Makefile\n"
    for tree in (hdr, common):
        assert (tree / "scripts").readlink() == Path(f"../../lib/{kbuild_name}/scripts")
        assert (tree / "tools").readlink() == Path(f"../../lib/{kbuild_name}/tools")

# Automated build-host package installs must never invoke interactive debconf.
# Keep the policy command-scoped; do not persist DEBIAN_FRONTEND globally.
assert build.count('DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true') >= 1
assert 'DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \\\n        apt-get install -y --no-install-recommends "${MISSING_HOST_PKGS[@]}"' in build
assert 'export DEBIAN_FRONTEND' not in build

audio_builder = (root / 'scripts/build_audio_modules.sh').read_text()
assert 'DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \\\n        apt-get install -y --no-install-recommends "${need[@]}"' in audio_builder
assert 'export DEBIAN_FRONTEND' not in audio_builder


# Preview25 cull invariants.
assert 'NETWORK_IPV4_VERIFIER=iproute2' in build
assert 'networkctl status wlan0 --no-pager 2>/dev/null |' not in firstboot
assert 'UNKNOWN (iw unavailable)' not in firstboot
assert 'cleanup_completed_state()' in firstboot
assert 'rm -rf "$STATE_DIR"' in firstboot
assert 'rm -f "$RESIZE_MARKER"' in firstboot
assert 'bpi-zero-clock-audio-source-build.txt' not in build
assert not (root / 'scripts/patch_audio_capture_dtb.py').exists()
assert not (root / 'patches').exists()
for dead in ['CANDIDATE-SHA256SUMS','ORIGINAL-SHA256SUMS','SOURCE-BUILD-POLICY.txt','modinfo.txt','max98357a.c','Makefile','CAPTURE-PREVIEW.txt','VALIDATION.txt']:
    assert not (root / 'clock/validated/6.12.100+deb13-armmp' / dead).exists(), dead
assert (root / 'clock/validated/6.12.100+deb13-armmp/HARDWARE-VALIDATION.txt').exists()
assert (root / 'config/CONFIG.TXT.template').stat().st_size < 2048

print("bpi-zero-clock 1.0.4-preview25 full-cull inherited-builder checks passed")
