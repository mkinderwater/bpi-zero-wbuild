#!/usr/bin/env python3
from pathlib import Path
import hashlib
import importlib.util
import re

root = Path(__file__).resolve().parents[1]
build = (root / 'build.sh').read_text()
readme = (root / 'README.md').read_text()
install_doc = (root / 'INSTALL.md').read_text()
modules = (root / 'clock/hardware/bpi-zero-clock.modules').read_text().splitlines()
source_builder = (root / 'scripts/build_audio_modules.sh').read_text()
transformer = (root / 'scripts/apply_audio_source_transforms.py').read_text()
relocator = (root / 'scripts/relocate_debian_header_sdk.py').read_text()
abi = '6.12.100+deb13-armmp'
validated = root / 'clock' / 'validated' / abi
ko = validated / 'snd-soc-max98357a.ko'
dtb = validated / 'sun8i-h2-plus-bananapi-m2-zero.dtb'

assert (root / 'VERSION').read_text().strip() == '1.0.4-preview25'
assert 'BPI_ZERO_CLOCK_VERSION:-1.0.4-preview25' in build
assert f'VALIDATED_ABI="{abi}"' in build
assert 'VALIDATED_DTB_SHA256="0ff283cc75acd93a43722769e3d9771dcb5d629825348593fdd4da605e4b1452"' in build
assert 'playback-validated-capture-source-built-clock-dma-hardware-confirmed' in build
assert 'APPLICATION_AUDIO_BASELINE=mk-clock-adult-2.3.50-preview25' in build
assert 'modinfo -b "$MNT" -k "$KERNEL_ABI" -n "$mod"' in build
assert 'modprobe -d "$MNT" -S "$KERNEL_ABI" -n "$mod"' in build
assert 'MODPROBE_CFG=' not in build
assert 'module resolution OK:' in build
assert 'env -u XZ_OPT xz -C crc32 -f -T1 -3 --memlimit-compress=64MiB' in source_builder
assert 'xz -C crc32 -f -9' not in source_builder
assert 'xz -T0' not in source_builder

# Physical-console kernel chatter is reduced without disabling audit.
boot_policy = (root / 'scripts/set_boot_loglevel.py').read_text()
assert 'quiet loglevel=3' in boot_policy
assert 'audit=0' not in boot_policy
assert 'KERNEL_BOOT_QUIET=yes' in build
assert 'KERNEL_CONSOLE_LOGLEVEL=3' in build

# 24/7 SD-endurance and watchdog policy is image-owned.
journal = (root / 'clock/hardware/journald-volatile.conf').read_text()
tmp_mount = (root / 'clock/hardware/tmp.mount').read_text()
watchdog = (root / 'clock/hardware/system-watchdog.conf').read_text()
assert 'Storage=volatile' in journal
assert 'RuntimeMaxUse=16M' in journal
assert 'RuntimeMaxFileSize=4M' in journal
assert 'What=tmpfs' in tmp_mount
assert 'Where=/tmp' in tmp_mount
assert 'size=64M' in tmp_mount
assert 'RuntimeWatchdogSec=30s' in watchdog
assert 'RebootWatchdogSec=2min' in watchdog
for token in [
    '/etc/systemd/journald.conf.d/20-mk-clock-volatile.conf',
    '/etc/systemd/system.conf.d/20-mk-clock-watchdog.conf',
    '/etc/systemd/system/tmp.mount',
    'local-fs.target.wants/tmp.mount',
    'rm -rf "$MNT/var/log/journal"',
    'JOURNAL_STORAGE=volatile',
    'JOURNAL_RUNTIME_MAX_USE=16M',
    'TMP_MOUNT=tmpfs-64M',
    'SYSTEMD_RUNTIME_WATCHDOG_SEC=30s',
]:
    assert token in build, token


# Resumable firstboot and CLI diagnostics are image-owned.
firstboot = (root / 'overlay/root/bpi-zero-wbuild-firstboot.sh').read_text()
for token in [
    'CLI_NETWORK_TOOL=iproute2-6.15.0-1',
    'FIRSTBOOT_RESUME=checkpointed',
    'WIFI_RECOVERY_RETRY=one-controlled-radio-userspace-restart',
    'FIRSTBOOT_CONSOLE_LOGGING=stage-summary',
    'iproute2_6.15.0-1_armhf.deb',
    'iw_6.9-1_armhf.deb',
    'CLI_WIFI_TOOL=iw-6.9-1',
    'WIFI_POWER_SAVE_POLICY=iwd-DriverQuirks-PowerSaveDisable-brcmfmac',
    'ALSA_UTILS=alsa-utils-1.2.14-1',
    'ALSA_STATE_RESTORE=disabled-image-policy',
]:
    assert token in build, token
for token in [
    'IDENTITY_MARKER=', 'SSH_MARKER=', 'FIRMWARE_MARKER=', 'PACKAGES_MARKER=',
    'stage "13 WIFI RECOVERY RETRY"', 'PKG_LOG=/var/log/bpi-zero-wbuild-packages.log',
    'command -v ip', 'command -v iw', 'PowerSaveDisable=brcmfmac',
    'iw dev wlan0 get power_save', 'wifi_diag_snapshot', 'SSID visible:', 'Associated:', 'console_line',
    'command -v arecord', 'command -v aplay', 'alsa-utils_1.2.14-1_armhf.deb',
    'systemctl mask alsa-restore.service alsa-state.service alsa-utils.service',
]:
    assert token in firstboot, token

# Preview23 firstboot hardening is fail-safe and cleanup remains checkpoint-safe.
for token in [
    'IWD_PROFILE_STATE=',
    'cleanup_config_mount()', 'trap cleanup_config_mount EXIT', 'trap - EXIT',
    'config_value()', 'SSID="$(config_value SSID)"',
    'cleanup_staged_firmware()', 'cleanup_staged_packages()',
    'touch "$FIRMWARE_MARKER"', 'touch "$PACKAGES_MARKER"',
    'rm -f "${FIRMWARE_STAGE[@]}"', 'rm -f "${PACKAGES[@]}"',
    'OLD_IWD_NAME=', 'Removed stale firstboot Wi-Fi profile',
    "''|.|..|*/*) ;;",
    'systemctl is-enabled "$unit"',
    'unable to enable $unit', 'unable to mask ALSA state restore/save services',
]:
    assert token in firstboot, token
assert firstboot.index('touch "$FIRMWARE_MARKER"') < firstboot.index('cleanup_staged_firmware', firstboot.index('touch "$FIRMWARE_MARKER"'))
assert firstboot.index('touch "$PACKAGES_MARKER"') < firstboot.index('cleanup_staged_packages', firstboot.index('touch "$PACKAGES_MARKER"'))
assert 'systemctl enable iwd.service >/dev/null 2>&1 || true' not in firstboot
assert 'systemctl enable systemd-networkd.service >/dev/null 2>&1 || true' not in firstboot
assert 'systemctl enable ssh.service >/dev/null 2>&1 || true' not in firstboot
assert 'systemctl mask alsa-restore.service alsa-state.service alsa-utils.service >>"$PKG_LOG" 2>&1 || true' not in firstboot

# Playback binary remains the physically validated one.
assert hashlib.sha256(ko.read_bytes()).hexdigest() == '906b7ef831e199a7ae0dc1aa724251ea1763876298cdcd8564a25e70badaa3c6'
assert hashlib.sha256(dtb.read_bytes()).hexdigest() == '0ff283cc75acd93a43722769e3d9771dcb5d629825348593fdd4da605e4b1452'

# No binary rate-mask transformer or transformed module artifacts survive.
assert not (root / 'scripts/patch_asoc_24k_module.py').exists()
assert not any(validated.glob('*24k*.ko*'))
assert 'snd-soc-spdif-rx' not in modules
assert 'snd-soc-dmic' in modules
assert 'sun4i-i2s' in modules
assert 'snd-soc-simple-card' in modules

# Source builder is pinned to the exact target ABI/source and compiles all
# three modules against Module.symvers.
for token in [
    'ABI="6.12.100+deb13-armmp"',
    'DEBIAN_VERSION="6.12.100-1"',
    'linux-headers-${ABI}_${DEBIAN_VERSION}_armhf.deb',
    '${COMMON_NAME}_${DEBIAN_VERSION}_all.deb',
    '${KBUILD_NAME}_${DEBIAN_VERSION}_${KBUILD_ARCH}.deb',
    'Module.symvers',
    'CROSS_COMPILE="$CROSS_COMPILE_PREFIX"',
    'apply_audio_source_transforms.py',
    'obj-m += sun4i-i2s.o',
    'obj-m += snd-soc-dmic.o',
    'obj-m += snd-soc-simple-card.o',
    'modinfo -F vermagic',
    'SOURCE-BUILD-MANIFEST.txt',
    'relocate_debian_header_sdk.py',
    '--sdk-root "$WORK_DIR/sdk"',
    'COMMON_NAME="linux-headers-6.12.100+deb13-common"',
    'KBUILD_NAME="linux-kbuild-6.12.100+deb13"',
]:
    assert token in source_builder, token
assert 'strip_signature' not in source_builder
assert 'bytes.fromhex' not in source_builder
assert 'amd64)' in source_builder
assert 'armhf)' in source_builder
assert 'CC_BIN=arm-linux-gnueabihf-gcc' in source_builder
assert 'CC_BIN=gcc' in source_builder
assert 'KBUILD_ARCH=armhf' in source_builder

# Post-transform assertions must validate semantic lines, not ambiguous token counts.
assert "require_count 1 'static const struct snd_pcm_hw_constraint_list mkclock_capture_rate_constraint = {'" in source_builder
assert "require_count 1 'ret = snd_pcm_hw_constraint_list(substream->runtime, 0,'" in source_builder
assert "require_count 1 '\"icubedev,capture-rate-hz\", &capture_rate))'" in source_builder
assert "require_count 1 'if (substream->stream != SNDRV_PCM_STREAM_CAPTURE)'" in source_builder
assert "require_count 1 'snd_pcm_hw_constraint_list'" not in source_builder
assert 'KBUILD_ARCH=amd64' in source_builder

# Debian header SDK must be self-contained after dpkg-deb extraction.
for token in [
    'include /usr/src/', 'include ../', '../../lib', 'expected Debian header symlink',
    'relocated Debian kernel-header SDK',
]:
    assert token in relocator, token
assert 'make -C "$HDR_DIR" M="$MOD_DIR" modules' in source_builder

# Source transformer adds 24 kHz to capture only and emits audit diffs.
for token in [
    'SNDRV_PCM_RATE_24000', '.capture = {', 'SNDRV_PCM_RATE_8000_192000',
    'simple_mkclock_startup', 'simple_util_startup(substream)',
    'SNDRV_PCM_STREAM_CAPTURE', 'icubedev,capture-rate-hz',
    'snd_pcm_hw_constraint_list', 'SNDRV_PCM_HW_PARAM_RATE',
    'simple_util_shutdown(substream)', 'difflib.unified_diff',
]:
    assert token in transformer, token
assert not (root / 'patches').exists()

# Image metadata records source provenance and policy separately.
for token in [
    'AUDIO_CAPTURE_CODEC=dmic-codec',
    'AUDIO_CAPTURE_DRIVER=snd-soc-dmic',
    'AUDIO_CAPTURE_DRIVER_SOURCE=debian-6.12.100-1-unmodified-dmic-source',
    'AUDIO_CAPTURE_RATE_HZ=24000',
    'AUDIO_CAPTURE_FORMAT=S32_LE',
    'AUDIO_CAPTURE_SLOT_WIDTH_BITS=32',
    'AUDIO_CAPTURE_MCLK_FS=256',
    'AUDIO_CAPTURE_SOFT_RESAMPLE=disabled',
    'I2S_DRIVER_SOURCE=debian-6.12.100-1-plus-capture-24khz-capability-patch',
    'MACHINE_AUDIO_DRIVER=snd-soc-simple-card',
    'MACHINE_CAPTURE_POLICY=snd_pcm_hw_constraint_list',
    'MACHINE_CAPTURE_RATE_HZ=24000',
    'MACHINE_CAPTURE_DT_PROPERTY=icubedev,capture-rate-hz',
    'AUDIO_CAPTURE_VALIDATION=clock-dma-hardware-confirmed-24khz-mic-signal-pending',
]:
    assert token in build, token

# ALSA userspace only selects hardware directions. No sample-rate plugin.
asound = (root / 'clock/hardware/asound.conf').read_text()
assert 'type asym' in asound
assert 'playback.pcm "mkclock_playback"' in asound
assert 'capture.pcm "mkclock_capture"' in asound
assert 'device 1' in asound
for forbidden in ['type plug', 'type rate', 'type dmix', 'type dsnoop']:
    assert forbidden not in asound

# Automated dpkg provisioning uses a command-scoped noninteractive debconf
# frontend. It must not persist DEBIAN_FRONTEND globally or add Perl Readline
# merely to silence unattended-install warnings.
firstboot = (root / 'overlay/root/bpi-zero-wbuild-firstboot.sh').read_text()
assert firstboot.count('DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true') == 2
assert 'dpkg --unpack "${PACKAGES[@]}"' in firstboot
assert 'dpkg --configure -a' in firstboot
assert 'export DEBIAN_FRONTEND' not in firstboot
assert 'Term::ReadLine' not in build

# Production image stays lean: no bundled microphone-validation script.
assert not (root / 'clock/hardware/mk-piclock-validate-ics43434-24k').exists()
assert 'mk-piclock-validate-ics43434-24k' not in build
assert 'MIC_VALIDATOR=' not in build
assert 'MIC_VALIDATOR_RUNTIME=' not in build
assert 'No microphone validator is installed in the production image' in install_doc
assert '-r 24000' in install_doc

# DT topology is dmic-codec + PA21 and carries the board policy property.
spec = importlib.util.spec_from_file_location('fdtpatch', root / 'tests/fdt_read.py')
fdt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fdt)
tree = fdt.parse(dtb)
pins = fdt.declist(fdt.get(tree, '/soc/pinctrl@1c20800/mk-piclock-i2s0-pins').props['pins'])
assert pins == ['PA18', 'PA19', 'PA20', 'PA21']
assert fdt.decstr(fdt.get(tree, '/dmic-codec').props['compatible']) == 'dmic-codec'
assert fdt.decu32(fdt.get(tree, '/dmic-codec').props['num-channels']) == (2,)
assert fdt.decu32(fdt.get(tree, '/sound-max98357a').props['icubedev,capture-rate-hz']) == (24000,)
assert fdt.decstr(fdt.get(tree, '/sound-max98357a').props['simple-audio-card,name']) == 'MAX98357A'
cap_cpu = fdt.get(tree, '/sound-max98357a/simple-audio-card,dai-link@1/cpu')
assert fdt.decu32(cap_cpu.props['dai-tdm-slot-num']) == (2,)
assert fdt.decu32(cap_cpu.props['dai-tdm-slot-width']) == (32,)
play_link = fdt.get(tree, '/sound-max98357a/simple-audio-card,dai-link@0')
cap_link = fdt.get(tree, '/sound-max98357a/simple-audio-card,dai-link@1')
assert fdt.decu32(play_link.props['mclk-fs']) == (256,)
assert fdt.decu32(cap_link.props['mclk-fs']) == (256,)
assert "'/sound-max98357a/simple-audio-card,dai-link@1' mclk-fs" in build

assert 'no binary `.ko` byte edits' in readme
assert 'capture capability only' in readme.lower()
assert 'snd_pcm_hw_constraint_list' in readme
assert 'full cull' in (root / 'CHANGELOG.md').read_text().lower()


# Current operator docs must not point at an older preview image or stale
# 48 kHz-failure expectation.
assert 'Preview21 keeps' not in readme
assert 'Preview6 keeps' not in install_doc
assert 'preview16-bpi-m2-zero.img' not in install_doc
assert 'RATE: 24000' in install_doc
assert 'negotiate' in install_doc.lower()
for doc in (readme, install_doc):
    for m in re.findall(r'bpi-zero-clock-(1\.0\.4-preview\d+)-bpi-m2-zero\.img', doc):
        assert m == '1.0.4-preview25', m

# Preview25 source/runtime cull keeps only release-critical validated artifacts.
assert not (root / 'scripts/patch_audio_capture_dtb.py').exists()
assert not (root / 'patches').exists()
assert (validated / 'HARDWARE-VALIDATION.txt').exists()
assert 'bpi-zero-clock-audio-source-build.txt' not in build
assert '--no-install-recommends' in build
assert '--no-install-recommends' in source_builder
assert 'cleanup_completed_state()' in firstboot
assert 'NETWORK_IPV4_VERIFIER=iproute2' in build

print('bpi-zero-clock 1.0.4-preview25 full-cull native-24k machine-policy checks passed')
