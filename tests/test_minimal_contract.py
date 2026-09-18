from pathlib import Path
import subprocess, struct, tempfile, sys, re

root=Path(__file__).resolve().parents[1]
build=(root/'build.sh').read_text()
first=(root/'overlay/root/bpi-zero-wbuild-firstboot.sh').read_text()
dtb=(root/'scripts/patch_base_hardware_dtb.sh').read_text()
assert 'GPU=/soc/gpu@1c40000' in dtb
assert 'fdtput -t s "$TMP" "$GPU" status disabled' in dtb
assert 'headless GPU policy was not applied' in dtb
mods=(root/'hardware/modules-load.conf').read_text().splitlines()
service=(root/'overlay/root/bpi-zero-wbuild-firstboot.service').read_text()
template=(root/'config/CONFIG.TXT.template').read_text()
fat_builder=(root/'scripts/make_fat32.py').read_text()

assert (root/'VERSION').read_text().strip() == '3.13-trixie-minimal-hw'
for token in ['spidev','i2c-dev','hci_uart','btbcm','sun4i-i2s','snd-soc-simple-card','snd-soc-max98357a']:
    assert token in mods, token
assert 'pwm-gpio' not in build.lower() and 'pwm-gpio' not in '\n'.join(mods).lower()
for token in ['SPI0=/soc/spi@1c68000','I2C0=/soc/i2c@1c2ac00','bpi-zero-userspace@0']:
    assert token in dtb, token
assert '/aliases spi0' in dtb and '/aliases i2c0' in dtb
for script in ['check_platform_aliases.py','check_platform_pins.py','check_bluetooth_topology.py','gpio_spec.py','fdt_read.py','set_fstab_policy.py','set_extlinux_policy.py','dpkg_status_field.py','hold_kernel_packages.py','prepare_login_accounts.py']:
    assert (root/'scripts'/script).is_file(), script
for script in ['check_platform_aliases.py','check_platform_pins.py','check_bluetooth_topology.py','set_extlinux_policy.py','hold_kernel_packages.py']:
    assert script in build

# Login safety is simple account state: root is locked and inherited human
# accounts are removed in the offline image. Firstboot validates ROOT_PASSWORD,
# replaces root's locked hash, creates SSH host keys and only then enables SSH.
assert "printf 'root:%s\\n' \"$ROOT_PASSWORD\" | chpasswd" in first
assert 'ROOT_PASSWORD_LEN=${#ROOT_PASSWORD}' in first
assert 'ssh-keygen -A' in first
assert 'userdel -r' not in first
assert 'prepare_login_accounts.py\" \"$MNT\"' in build
assert not (root/'overlay/root/bpi-zero-wbuild-preauth.sh').exists()
assert not (root/'overlay/root/bpi-zero-wbuild-preauth.service').exists()
assert not (root/'overlay/root/preauth-gate.conf').exists()
for gate_dir in ['getty@.service.d','serial-getty@.service.d','ssh.service.d','systemd-user-sessions.service.d']:
    assert gate_dir not in build, gate_dir
assert 'Requires=bpi-zero-wbuild-preauth.service' not in service
assert 'After=bpi-zero-wbuild-preauth.service' not in service
assert 'rm -f \"$MNT/etc/systemd/system/multi-user.target.wants/ssh.service\"' in build
assert first.count('systemctl enable ssh.service') == 1
assert 'root:bpi-zero-wbuild' not in first
assert 'ROOT_PASSWORD=' in template
assert 'ROOT_PASSWORD is required' in fat_builder
assert '8-64' in fat_builder
assert 'automatically' in template and 'blanked' in template
assert 'ROOT_PASSWORD must be 8-64 characters' in first
assert first.index('stage "02 ROOT FILESYSTEM CAPACITY"') < first.index('stage "03 CONFIG + ROOT LOGIN"')
assert first.index('attempt_root_resize || true') < first.index('ROOT_PASSWORD_LEN=${#ROOT_PASSWORD}')

# Secret scrub remains a committed, power-loss resumable finalization stage.
assert 'READY_MARKER=' in first
assert 'scrub_config_secrets()' in first
assert "grep -Eq '^PSK=.+|^ROOT_PASSWORD=.+'" in first
assert 'CONFIG.TXT absent during finalization' in first
assert 'CONFIG.TXT contains no credential keys' in first
assert first.index('touch "$READY_MARKER"') < first.rindex('finish_provisioning')
assert first.index('scrub_config_secrets', first.index('finish_provisioning()')) < first.index('touch "$MARKER"', first.index('finish_provisioning()'))
assert 'CONFIG_SECRET_POLICY=PSK-and-ROOT_PASSWORD-blanked-after-successful-firstboot' in build

# Wi-Fi stays simple and fixed to the known BPI-M2 Zero board contract:
# brcmfmac is loaded at boot and the onboard interface is wlan0.
assert 'install -m 0600 /dev/null "$PROFILE"' in first
assert 'AutoConnect=true' in first
assert 'mask_competing_wifi_managers' not in first
assert 'WIFI_IF=wlan0' not in first
assert 'cat >/etc/systemd/network/25-wlan0.network' in first
assert 'Name=wlan0' in first
assert 'Driver=brcmfmac' not in first
assert 'detect_wifi_if()' not in first and 'wait_wifi_if()' not in first
assert 'wlan0 is not present; check BCM43430 firmware and SDIO initialization.' in first
assert 'networkctl status wlan0 --no-pager' in first
assert '/^[[:space:]]*Address:([[:space:]]+|$)/ { inblock=1 }' in first
assert r'/^[[:space:]]*[[:alpha:]][[:alnum:] .()_\/-]*:([[:space:]]+|$)/ { inblock=0 }' in first
assert r'candidate !~ /^169\.254\./' in first
assert 'journalctl -b -u systemd-networkd --no-pager -n 80' in first
assert 'iwctl station wlan0 show' in first
assert 'modprobe -r brcmfmac' not in first and 'modprobe -r brcmutil' not in first
assert 'modprobe brcmfmac' not in first
assert 'brcmfmac' in (root/'hardware/modules-load.conf').read_text().splitlines()
assert 'validate_module_resolution brcmfmac' in build
assert 'WIFI_DRIVER=brcmfmac' in build and 'WIFI_INTERFACE=wlan0' in build
assert 'systemctl enable iwd.service systemd-networkd.service systemd-resolved.service' in first
assert 'systemctl restart systemd-resolved.service || fail' in first
assert 'systemctl restart iwd.service || fail' in first
assert 'systemctl restart systemd-networkd.service || fail' in first
assert 'ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf' in first
assert 'start_ssh_best_effort()' in first and 'require_ssh()' in first
assert 'install -d -m 0755 /run/sshd' in first
assert first.index('install -d -m 0755 /run/sshd') < first.index('ssh-keygen -A')
assert 'sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null' not in first
assert 'systemctl start ssh.service || fail "unable to start SSH."' in first
assert 'systemctl is-active --quiet ssh.service || fail "SSH did not become active."' in first
assert first.index('require_ssh\nnote "SSH reachable at: $IPV4_ADDR"') < first.index('stage "07 FINALIZE"')
finish_start=first.index('finish_provisioning()')
assert first.index('start_ssh_best_effort || true', finish_start) < first.index('scrub_config_secrets', finish_start)
assert 'stage "90 RECOVERY: RETRY ROOT RESIZE"' in first
assert 'stage "91 RECOVERY: FINALIZE INTERRUPTED FIRSTBOOT"' in first
assert 'stage "02 RETRY ROOT RESIZE"' not in first and 'stage "02 FINALIZE INTERRUPTED FIRSTBOOT"' not in first
assert 'command -v ip' not in first
assert 'DefaultInterface=brcmfmac' not in first
assert 'SaeDisable=brcmfmac' not in first
assert 'PowerSaveDisable=brcmfmac' not in first
assert 'bpi-zero-wifi.service' not in first
assert not (root/'overlay/root/bpi-zero-wifi.service').exists()
assert not (root/'overlay/root/bpi-zero-wifi-up.sh').exists()

# Exercise the actual awk program embedded in ipv4_for_wlan0. It must scan
# continuation lines, accept IPv4 with or without CIDR, and reject link-local.
m=re.search(r"ipv4_for_wlan0\(\) \{.*?\| awk '(.+?)' \|\| true\n\}", first, re.S)
assert m, 'unable to extract ipv4_for_wlan0 awk parser'
awk_program=m.group(1)
def parse_networkctl(sample: str) -> str:
    r=subprocess.run(['awk', awk_program], input=sample, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()
assert parse_networkctl("       Address: fe80::1/64\n                192.168.24.135\n       Gateway: 192.168.24.1\n") == '192.168.24.135'
assert parse_networkctl("       Address: 192.168.24.135/24\n       Gateway: 192.168.24.1\n") == '192.168.24.135'
assert parse_networkctl("       Address: fe80::1/64\n       Carrier Bound To: wlan0\n                192.168.24.135/24\n") == ''
assert parse_networkctl("       Address: 169.254.12.7/16\n       Gateway: none\n") == ''

# Offline runtime package set is exact and intentionally small.
for pkg in ['iwd_3.8-2_armhf.deb','libell0_0.77-1_armhf.deb','libreadline8t64_8.2-6_armhf.deb','readline-common_8.2-6_all.deb','wireless-regdb_2026.05.30-1~deb13u1_all.deb']:
    assert pkg in build and f'/root/{pkg}' in first, pkg
for pkg in ['iproute2_','iw_6.9','libnl-3-200_','libnl-genl-3-200_','libelf1t64_','libbpf1_','libmnl0_','libdb5.3t64_','libtirpc-common_','libtirpc3t64_','libxtables12_','libcap2-bin_']:
    assert pkg not in build and pkg not in first, pkg
assert 'TARGET_SYSTEMD_VERSION=' not in build and 'TARGET_RESOLVED_VERSION=' not in build
assert '--package systemd-resolved --field Version' in build
assert 'target root is missing systemd-resolved; DNS policy cannot be guaranteed.' in build
assert 'systemd-resolved_257.13-1~deb13u1_armhf.deb' not in build and 'systemd-resolved_257.13-1~deb13u1_armhf.deb' not in first
assert 'for reg in /usr/lib/firmware/regulatory.db /usr/lib/firmware/regulatory.db.p7s' in first
assert 'extracting regulatory.db from wireless-regdb' in build
assert 'regulatory.db-upstream' in build and 'regulatory.db.p7s-upstream' in build
assert 'install -m 0644 "$REGDB" "$MNT/usr/lib/firmware/regulatory.db"' in build
assert 'install -m 0644 "$REGSIG" "$MNT/usr/lib/firmware/regulatory.db.p7s"' in build
assert '[ ! -e "$reg" ] || [ -L "$reg" ] || rm -f "$reg"' in first
assert 'FIRMWARE_SOURCE_URL=' in build
assert 'https://ftp.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/firmware-brcm80211_20250410-2_all.deb' in build
assert '266cc703e2299f5253fd1ff9a1fd625d85a2c8e5a88b1a65fcc190ac384ce3d7' in build
assert 'firmware-brcm80211.deb|pkgroot/' not in build
assert 'IDENTITY_MARKER=' not in first
assert 'PACKAGES_MARKER=' not in first
assert 'IWD_PROFILE_STATE=' not in first
assert 'STATE_DIR=' not in first
assert 'find_config_dev()' not in first
assert 'CFG_DEV=/dev/disk/by-label/BPIWBUILD' in first
assert "MACHINE_ID=\"$(tr -d '[:space:]' </etc/machine-id)\"" in first
assert 'CURRENT_HOST="bpi-zero-${MACHINE_ID:0:6}"' in first
assert first.count('READY_MARKER=') == 1

# Root resize is best effort so storage growth cannot strand a headless board.
assert '180s resize2fs' in first
assert first.count('300s env') >= 2
assert '30s partx --update' in first
assert 'WARNING: online resize2fs failed; Wi-Fi/SSH provisioning will continue and resize will retry next boot.' in first
assert 'fail "online root filesystem expansion failed."' not in first
assert 'if [ -e "$RESIZE_MARKER" ]; then' in first
assert 'Root resize remains deferred; firstboot will retry it on the next boot.' in first
assert 'Type=oneshot' in service
assert 'TimeoutStartSec=30min' in service
assert 'StandardOutput=journal+console' in service
assert 'tee -a "$LOG"' in first

# Root identity and bootloader policy are applied and verified against final PARTUUID.
for mod in ['i2c-dev','brcmfmac','hci_uart','btbcm']:
    assert f'validate_module_resolution {mod}' in build
assert 'modinfo -b "$MNT" -k "$KERNEL_ABI" -n "$mod"' in build
assert 'modprobe -d "$MNT" -S "$KERNEL_ABI" -n -v' not in build
assert 'resolved_rel="${resolved_rel#"$MNT"}"' in build
assert 'set_fstab_policy.py' in build
assert 'set_extlinux_policy.py" "$EXTLINUX_CONF" "$U_BOOT_DEFAULTS" --partuuid "$ROOT_PARTUUID"' in build
assert '$MNT/boot/extlinux/extlinux.conf' in build
assert 'append root=PARTUUID=${ROOT_PARTUUID} rw rootwait loglevel=7 systemd\\.show_status=yes' in build
assert 'U_BOOT_ROOT=' in build and 'U_BOOT_PARAMETERS=' in build
assert 'boot_patched.bin --partition 2' in build
assert 'mbr_partuuid.py" boot.bin --partition 2' not in build
assert 'BOOT_GZIP_SHA256=' in build
assert 'DEBIAN_GZIP_SHA256=' not in build
assert 'DEBIAN_SOURCE_TRUST=fixed-https-url-gzip-verified;sha256-pin-pending-upstream-hash' in build
assert 'DEBIAN_ROOT_SHA256' not in build
assert 'DEBIAN_GZIP_OBSERVED_SHA256=' in build
assert 'BT_HCD_OBSERVED_SHA256=' in build
assert 'BLUETOOTH_FIRMWARE_TRUST=commit-pinned-size-validated;sha256-pin-pending' in build
extlinux_policy=(root/'scripts/set_extlinux_policy.py').read_text()
assert 'rw rootwait loglevel=7 systemd.show_status=yes' in extlinux_policy
assert 'quiet loglevel=4' not in extlinux_policy

# Kernel/DTB contract uses one mechanism: hold the fixed kernel ABI.
assert 'dpkg-divert' not in build
assert '99-bpi-zero-kernel-pin' not in build
assert '/etc/apt/preferences.d' not in build
assert 'hold_kernel_packages.py\" \"$MNT/var/lib/dpkg/status\" --require \"$KERNEL_PACKAGE\"' in build
assert 'KERNEL_UPDATE_POLICY=dpkg-hold-fixed-kernel' in build
assert 'DTB_UPDATE_POLICY=kernel-held-active-dtb' in build
assert 'mapfile -t KERNEL_ABIS' not in build
assert 'KERNEL_ABI="$EXPECTED_KERNEL_ABI"' in build
assert 'target root is missing fixed kernel module tree $KERNEL_ABI.' in build

# Console issue line is written once from the known wlan0 contract after Wi-Fi succeeds.
getty_override=(root/'overlay/root/getty-tty1-override.conf').read_text()
assert not (root/'overlay/root/bpi-zero-console-info.sh').exists()
assert not (root/'overlay/root/bpi-zero-console-info.service').exists()
assert 'bpi-zero-console-info' not in build
assert '/etc/issue.d/90-bpi-zero-network.issue' in first
assert r'IPv4: \\4{wlan0}' in first
assert 'Wi-Fi: wlan0' in first and 'MAC: %s' in first
assert 'TTYVTDisallocate=no' in getty_override

# Release image output remains atomic and integrity-tested.
assert 'OUT_GZ=' in build and 'TMP_GZ=' in build
assert 'gzip -t "$TMP_GZ"' in build
assert 'mv -f "$TMP_GZ" "$OUT_GZ"' in build
assert 'OUT_IMG=' not in build
assert 'sha256sum "$(basename "$OUT_GZ")"' in build
assert 'findmnt -n -o FSTYPE --target "$MNT"' in build
assert 'command -v findmnt' in build and 'MISSING_HOST_PKGS+=(util-linux)' in build
assert '[ "$ROOT_FS_TYPE" = "ext4" ]' in build
assert 'Storage=volatile' in build and 'rm -rf "$MNT/var/log/journal"' in build
assert 'Before=mk-piclock-core.service' not in (root/'hardware/spidev.service').read_text()
assert 'command -v unzip' not in build and 'MISSING_HOST_PKGS+=(xz-utils)' not in build
assert 'BOOT_URL=' not in build
assert 'DEBIAN_URL:=' not in build and 'BT_HCD_URL:=' not in build
assert 'CONFIG_PART_MB' not in build
assert 'command -v wget' not in build and 'wget -O' not in build
assert 'cp -f "$HERE/boot-banana_pi_m2_zero.bin.gz" boot.bin.gz' in build
assert 'BOOT_SOURCE=bundled-source-archive' in build
assert 'bpi-zero-wbuild-btfirmware.service' not in build
assert 'bpi-zero-wbuild-resizefs.service' not in build

# Pinned Debian runtime package downloads are deterministic and fail visibly.
assert 'DEBIAN_SNAPSHOT_STAMP="20260907T235959Z"' in build
assert 'DEBIAN_SNAPSHOT_DEFAULT=' not in build
assert 'snapshot.debian.org/archive/debian/%s/%s' in build
assert 'fetch_deb() {' in build
assert 'actual_version_no_epoch="${actual_version#*:}"' in build
assert 'Package=$expected_pkg Version=$expected_version Architecture=$expected_arch' in build
assert 'fetch_deb "$url" "$dest"' in build
assert "printf '%s\\n' \"$url\" > \"$meta_tmp\"" in build
assert 'required Banana Pi AP6212 Bluetooth HCD download failed' in build

# The jump-point includes fixed MAX98357A playback as board capability.
max_builder=(root/'scripts/build_max98357a_6_12_107.sh').read_text()
assert (root/'hardware/max98357a/max98357a.c').is_file()
assert 'MK_MAX98357A_BUILD_OUT=' in build
assert 'EXPECTED_KERNEL_ABI="6.12.107+deb13-armmp"' in build
assert 'EXPECTED_KERNEL_DEBIAN_VERSION="6.12.107-1"' in build
assert 'AUDIO_ENDPOINT=MAX98357A' in build
assert 'MAX98357A_SD_GPIO=PA1' in build and 'MAX98357A_SD_DELAY_MS=5' in build
assert 'I2S_LRCLK_GPIO=PA18' in build and 'I2S_BCLK_GPIO=PA19' in build and 'I2S_TX_GPIO=PA20' in build
assert 'HARDWARE_SCOPE=wifi-bluetooth-spi-i2c-gpio-i2s-max98357a;resize-best-effort' in build
assert 'KBUILD_BUILD_HOST=bpi-m2-zero' in max_builder and 'bpi-zero-clock' not in max_builder
assert '${WORK_DIR:-$HERE/build}/max98357a-source' in max_builder

assert '--hidden-sectors "$CONFIG_START_SECTOR"' in build
assert '--volume-id "0x$CONFIG_VOLID_HEX"' in build
assert 'fdtput -t s "$TMP" /aliases spi0 "$SPI0"' in dtb
assert 'fdtput -t s "$TMP" /aliases i2c0 "$I2C0"' in dtb
assert 'fdtput -cp "$TMP" /aliases' in dtb
for shell in [root/'build.sh',root/'overlay/root/bpi-zero-wbuild-firstboot.sh',root/'scripts/patch_base_hardware_dtb.sh',root/'scripts/build_max98357a_6_12_107.sh',root/'hardware/bind-spidev']:
    r=subprocess.run(['bash','-n',str(shell)],capture_output=True,text=True)
    assert r.returncode == 0, f'{shell}: {r.stderr}'
for py in root.rglob('*.py'):
    r=subprocess.run(['python3','-m','py_compile',str(py)],capture_output=True,text=True)
    assert r.returncode == 0, f'{py}: {r.stderr}'

assert "prop == 'gpios' or prop.endswith('-gpios')" in (root/'scripts/check_platform_pins.py').read_text()
assert "prop.endswith('gpios')" not in (root/'scripts/check_platform_pins.py').read_text()

# Offline login helper locks root and removes inherited human accounts before boot.
with tempfile.TemporaryDirectory() as td:
    rootfs=Path(td)
    (rootfs/'etc').mkdir()
    (rootfs/'etc/passwd').write_text('root:x:0:0:root:/root:/bin/bash\ndebian:x:1000:1000:Debian:/home/debian:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n')
    (rootfs/'etc/shadow').write_text('root:$6$abc:1:0:99999:7:::\ndebian:$6$def:1:0:99999:7:::\ndaemon:*:1:0:99999:7:::\n')
    (rootfs/'etc/group').write_text('root:x:0:\ndebian:x:1000:\naudio:x:29:debian\ndaemon:x:1:\n')
    (rootfs/'etc/gshadow').write_text('root:*::\ndebian:*::\naudio:*::debian\ndaemon:*::\n')
    r=subprocess.run(['python3',str(root/'scripts/prepare_login_accounts.py'),str(rootfs)],capture_output=True,text=True)
    assert r.returncode == 0, r.stderr
    assert 'debian:' not in (rootfs/'etc/passwd').read_text()
    assert 'debian:' not in (rootfs/'etc/shadow').read_text()
    root_shadow=next(x for x in (rootfs/'etc/shadow').read_text().splitlines() if x.startswith('root:'))
    assert root_shadow.split(':',2)[1].startswith('!')
    assert 'audio:x:29:' in (rootfs/'etc/group').read_text() and 'debian' not in (rootfs/'etc/group').read_text()

# Kernel hold helper edits dpkg status deterministically and requires the target kernel.
with tempfile.TemporaryDirectory() as td:
    status=Path(td)/'status'
    status.write_text("Package: linux-image-6.12.107+deb13-armmp\nStatus: install ok installed\nVersion: 6.12.107-1\n\nPackage: bash\nStatus: install ok installed\nVersion: 5.2\n\n")
    r=subprocess.run(['python3',str(root/'scripts/hold_kernel_packages.py'),str(status),'--require','linux-image-6.12.107+deb13-armmp'],capture_output=True,text=True)
    assert r.returncode == 0, r.stderr
    text=status.read_text()
    assert 'Package: linux-image-6.12.107+deb13-armmp\nStatus: hold ok installed' in text
    assert 'Package: bash\nStatus: install ok installed' in text

# extlinux helper rewrites the actual boot command line and U-Boot defaults.
with tempfile.TemporaryDirectory() as td:
    ext=Path(td)/'extlinux.conf'
    defs=Path(td)/'u-boot'
    ext.write_text('default linux\nprompt 1\ntimeout 50\nlabel linux\n  linux /vmlinuz\n  append root=LABEL=rootfs quiet\n')
    defs.write_text('U_BOOT_ROOT=\"root=LABEL=rootfs\"\nU_BOOT_PARAMETERS=\"quiet\"\n')
    r=subprocess.run(['python3',str(root/'scripts/set_extlinux_policy.py'),str(ext),str(defs),'--partuuid','12345678-02'],capture_output=True,text=True)
    assert r.returncode == 0, r.stderr
    assert 'append root=PARTUUID=12345678-02 rw rootwait loglevel=7 systemd.show_status=yes' in ext.read_text()
    assert 'prompt 0' in ext.read_text() and 'timeout 10' in ext.read_text()
    assert 'U_BOOT_ROOT=\"root=PARTUUID=12345678-02\"' in defs.read_text()
    assert 'U_BOOT_PARAMETERS=\"rw rootwait loglevel=7 systemd.show_status=yes\"' in defs.read_text()

# fstab rewrites an existing root and also accepts Johang roots that omit it.
with tempfile.TemporaryDirectory() as td:
    f=Path(td)/'fstab'; f.write_text('LABEL=root / ext4\nproc /proc proc defaults 0 0\n')
    r=subprocess.run(['python3',str(root/'scripts/set_fstab_policy.py'),str(f),'--partuuid','12345678-02'],capture_output=True,text=True)
    assert r.returncode == 0, r.stderr
    assert f.read_text().splitlines()[0] == 'PARTUUID=12345678-02\t/\text4'

with tempfile.TemporaryDirectory() as td:
    f=Path(td)/'fstab'; f.write_text('# root intentionally omitted by upstream\nproc /proc proc defaults 0 0\n')
    r=subprocess.run(['python3',str(root/'scripts/set_fstab_policy.py'),str(f),'--partuuid','12345678-02'],capture_output=True,text=True)
    assert r.returncode == 0, r.stderr
    assert 'PARTUUID=12345678-02\t/\text4\tdefaults\t0\t1' in f.read_text().splitlines()

with tempfile.TemporaryDirectory() as td:
    f=Path(td)/'fstab'; f.write_text('LABEL=a / ext4 defaults 0 1\nLABEL=b / ext4 defaults 0 1\n')
    r=subprocess.run(['python3',str(root/'scripts/set_fstab_policy.py'),str(f),'--partuuid','12345678-02'],capture_output=True,text=True)
    assert r.returncode != 0 and 'multiple root mounts' in (r.stdout+r.stderr)

# FAT32 BPB reflects the final disk offset and supplied volume ID.
with tempfile.TemporaryDirectory() as td:
    img=Path(td)/'cfg.fat32'
    r=subprocess.run(['python3',str(root/'scripts/make_fat32.py'),str(img),'131072',str(root/'config/CONFIG.TXT.template'),'--hidden-sectors','8192','--volume-id','0xa1b2c3d4'],capture_output=True,text=True)
    assert r.returncode == 0, r.stderr
    bs=img.read_bytes()[:512]
    assert struct.unpack_from('<I',bs,28)[0] == 8192
    assert struct.unpack_from('<I',bs,67)[0] == 0xa1b2c3d4

# patch_mbr rejects a boot file shorter than the LBA gap it declares.
with tempfile.TemporaryDirectory() as td:
    bad=bytearray(512)
    bad[510:512]=b'\x55\xaa'
    struct.pack_into('<B3sB3sII',bad,446,0,b'\0\0\0',0x0c,b'\0\0\0',8192,100)
    boot=Path(td)/'boot.bin'; boot.write_bytes(bad)
    deb=Path(td)/'root.bin'; deb.write_bytes(b'\0'*512)
    out=Path(td)/'out.bin'
    r=subprocess.run(['python3',str(root/'scripts/patch_mbr.py'),'--boot-in',str(boot),'--boot-out',str(out),'--debian-in',str(deb),'--config-sectors','131072'],capture_output=True,text=True)
    assert r.returncode != 0 and 'shorter than its own pre-partition gap' in (r.stderr+r.stdout)

# Exercise the alias/pin/ownership validators without relying on dtc being installed.
def build_test_dtb(path: Path, conflict=False, protected_mixed=False, platform_mixed=False, pc0_gpio_conflict=False, bad_max_pa1=False):
    import struct
    def s(v): return v.encode() + b'\0'
    def sl(*vals): return b''.join(s(v) for v in vals)
    def u(*vals): return struct.pack('>' + 'I'*len(vals), *vals)
    rootnode = {'name':'', 'props':{}, 'children':[]}
    aliases={'name':'aliases','props':{'spi0':s('/soc/spi@1c68000'),'i2c0':s('/soc/i2c@1c2ac00'),'serial1':s('/soc/serial@1c28400')},'children':[]}
    soc={'name':'soc','props':{},'children':[]}
    pio={'name':'pinctrl@1c20800','props':{'phandle':u(1),'linux,phandle':u(1),'#gpio-cells':u(3),'gpio-controller':b'','ngpios':u(224)},'children':[]}
    rpio={'name':'pinctrl@1f02c00','props':{'phandle':u(10),'linux,phandle':u(10),'#gpio-cells':u(3),'gpio-controller':b''},'children':[
        {'name':'ir-pins','props':{'pins':sl('PL11'),'function':s('s_cir_rx'),'phandle':u(11)},'children':[]}
    ]}
    pio['children'] += [
        {'name':'i2c0-pins','props':{'pins':sl('PA11','PA12'),'function':s('i2c0'),'phandle':u(2)},'children':[]},
        {'name':'spi0-pins','props':{'pins':sl('PC0','PC1','PC2','PC3'),'function':s('spi0'),'phandle':u(3)},'children':[]},
        {'name':'i2s0-pins','props':{'pins':sl('PA18','PA19','PA20'),'function':s('i2s0'),'phandle':u(4)},'children':[]},
        {'name':'disabled-pa7','props':{'pins':sl('PA7'),'function':s('gpio_out'),'phandle':u(5)},'children':[]},
    ]
    spi_props={'status':s('okay'),'pinctrl-names':s('default'),'pinctrl-0':u(3)}
    if protected_mixed:
        spi_props['cs-gpios']=u(0,1,0,7,0)  # <0>, <&pio 0 7 0>
    if platform_mixed:
        spi_props['cs-gpios']=u(0,1,0,11,0) # <0>, <&pio 0 11 0> conflicts with I2C0
    spi={'name':'spi@1c68000','props':spi_props,'children':[]}
    i2c={'name':'i2c@1c2ac00','props':{'status':s('okay'),'pinctrl-names':s('default'),'pinctrl-0':u(2)},'children':[]}
    i2s={'name':'i2s@1c22000','props':{'status':s('okay'),'pinctrl-names':s('default'),'pinctrl-0':u(4)},'children':[]}
    ir={'name':'ir@1f02000','props':{'status':s('okay'),'pinctrl-names':s('default'),'pinctrl-0':u(11)},'children':[]}
    wifi_pwrseq={'name':'wifi-pwrseq','props':{'status':s('okay'),'reset-gpios':u(10,0,7,0)},'children':[]}
    max98357a={'name':'max98357a','props':{'status':s('okay'),'compatible':s('maxim,max98357a'),'sdmode-gpios':u(1,0,2 if bad_max_pa1 else 1,0)},'children':[]}
    unrelated_missing_default={'name':'unrelated-missing-default@2','props':{'status':s('okay'),'pinctrl-names':s('default')},'children':[]}
    unrelated_unknown_phandle={'name':'unrelated-unknown-phandle@3','props':{'status':s('okay'),'pinctrl-names':s('default'),'pinctrl-0':u(0xdeadbeef)},'children':[]}
    disabled_bus={'name':'disabled-test@0','props':{'status':s('disabled')},'children':[
        {'name':'child','props':{'status':s('okay'),'test-gpios':u(1,0,7,0),'pinctrl-names':s('default'),'pinctrl-0':u(5)},'children':[]}
    ]}
    uart={'name':'serial@1c28400','props':{'status':s('okay'),'uart-has-rtscts':b''},'children':[{'name':'bluetooth','props':{'status':s('okay'),'compatible':s('brcm,bcm43438-bt')},'children':[]}]}
    soc['children']=[pio,rpio,spi,i2c,i2s,uart,ir,wifi_pwrseq,unrelated_missing_default,unrelated_unknown_phandle,disabled_bus]
    if pc0_gpio_conflict:
        soc['children'].append({'name':'bad-pc0-gpio@4','props':{'status':s('okay'),'test-gpios':u(1,2,0,0)},'children':[]})
    if conflict:
        pio['children'].append({'name':'bad-pa11','props':{'pins':sl('PA11'),'function':s('gpio_out'),'phandle':u(6)},'children':[]})
        soc['children'].append({'name':'bad-consumer@1','props':{'status':s('okay'),'pinctrl-names':s('default'),'pinctrl-0':u(6)},'children':[]})
    rootnode['children']=[aliases,max98357a,soc]
    prop_names=[]
    def collect(n):
        for k in n['props']:
            if k not in prop_names: prop_names.append(k)
        for c in n['children']: collect(c)
    collect(rootnode)
    strings=b''; offsets={}
    for name in prop_names:
        offsets[name]=len(strings); strings += name.encode()+b'\0'
    st=bytearray()
    def pad4():
        while len(st)%4: st.append(0)
    def emit(n):
        st.extend(struct.pack('>I',1)); st.extend(n['name'].encode()+b'\0'); pad4()
        for k,v in n['props'].items():
            st.extend(struct.pack('>III',3,len(v),offsets[k])); st.extend(v); pad4()
        for c in n['children']: emit(c)
        st.extend(struct.pack('>I',2))
    emit(rootnode); st.extend(struct.pack('>I',9))
    reserve=b'\0'*16
    off_rsv=40; off_struct=off_rsv+len(reserve); off_strings=off_struct+len(st); total=off_strings+len(strings)
    hdr=struct.pack('>10I',0xD00DFEED,total,off_struct,off_strings,off_rsv,17,16,0,len(strings),len(st))
    path.write_bytes(hdr+reserve+st+strings)

with tempfile.TemporaryDirectory() as td:
    good=Path(td)/'good.dtb'; build_test_dtb(good)
    for script in ['check_platform_aliases.py','check_platform_pins.py','check_bluetooth_topology.py']:
        r=subprocess.run(['python3',str(root/'scripts'/script),str(good)],capture_output=True,text=True)
        assert r.returncode == 0, f'{script}: {r.stdout} {r.stderr}'
    bad=Path(td)/'conflict.dtb'; build_test_dtb(bad, conflict=True)
    r=subprocess.run(['python3',str(root/'scripts/check_platform_pins.py'),str(bad)],capture_output=True,text=True)
    assert r.returncode != 0 and 'multiple enabled owners' in (r.stdout+r.stderr)

    # Heterogeneous GPIO arrays remain conflict-checked entry-by-entry.
    platform=Path(td)/'platform-mixed.dtb'; build_test_dtb(platform, platform_mixed=True)
    r=subprocess.run(['python3',str(root/'scripts/check_platform_pins.py'),str(platform)],capture_output=True,text=True)
    assert r.returncode != 0 and 'PA11' in (r.stdout+r.stderr) and 'multiple enabled owners' in (r.stdout+r.stderr)

    # GPIO claims on non-A banks are also compared against platform pinctrl use.
    pc0=Path(td)/'pc0-conflict.dtb'; build_test_dtb(pc0, pc0_gpio_conflict=True)
    r=subprocess.run(['python3',str(root/'scripts/check_platform_pins.py'),str(pc0)],capture_output=True,text=True)
    assert r.returncode != 0 and 'PC0' in (r.stdout+r.stderr) and 'multiple enabled owners' in (r.stdout+r.stderr)

    # MAX98357A SD/EN is an explicit base contract on PA1.
    badmax=Path(td)/'bad-max-pa1.dtb'; build_test_dtb(badmax, bad_max_pa1=True)
    r=subprocess.run(['python3',str(root/'scripts/check_platform_pins.py'),str(badmax)],capture_output=True,text=True)
    assert r.returncode != 0 and 'PA1' in (r.stdout+r.stderr)

# Malformed DTBs now fail with a controlled parser error rather than IndexError.
sys.path.insert(0, str(root/'scripts'))
from fdt_read import parse
with tempfile.TemporaryDirectory() as td:
    bad=Path(td)/'bad.dtb'
    hdr=struct.pack('>10I',0xD00DFEED,40,40,40,40,17,16,0,0,4)
    bad.write_bytes(hdr)  # structure block claims bytes beyond totalsize
    try:
        parse(bad)
    except ValueError as exc:
        assert 'malformed DTB' in str(exc)
    else:
        raise AssertionError('malformed DTB unexpectedly parsed')

# SSH early-start regression: root password auth is explicit and sshd is active
# before any Wi-Fi package/network stage begins.
assert 'PermitRootLogin yes' in first
assert 'PasswordAuthentication yes' in first
assert 'PasswordAuthentication no' not in first
assert 'Match User root' not in first
ssh_stage3_start = first.index('if start_ssh_best_effort; then')
assert ssh_stage3_start < first.index('stage "04 DEVICE IDENTITY + TIME"')
assert ssh_stage3_start < first.index('stage "05 INSTALL WIFI USERSPACE"')
assert ssh_stage3_start < first.index('stage "06 WIFI + DHCP"')
assert 'note "SSH reachable at: $IPV4_ADDR"' in first

assert 'sshd -T -C user=root,host=localhost,addr=127.0.0.1' in first
assert 'effective SSH policy does not permit root login' in first
assert 'effective SSH policy does not permit password authentication for root' in first
assert 'SSH policy verified: root login=yes password authentication=yes.' in first

print('3.13 Trixie platform contract checks passed')
