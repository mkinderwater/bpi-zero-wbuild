#!/usr/bin/env bash
# ============================================================
#  bpi-zero-wbuild - minimal BPI M2 Zero Trixie image builder
# ============================================================
#
# Builds a minimal application-ready image for the Banana Pi M2 Zero running Debian
# Trixie, with:
#   - partition 1: FAT32 "BPIWBUILD" - editable CONFIG.TXT
#                  (Wi-Fi + timezone + root password)
#   - partition 2: ext4 root filesystem, with Wi-Fi/Bluetooth firmware,
#                  first-boot resize/provisioning, GPIO, SPI0, I2C0 and
#                  playback-only I2S0/MAX98357A support
#
# The upstream boot image ships a small placeholder partition
# (its own file identifies it: PARTITION_INTENTIONALLY_EMPTY.TXT)
# that the SoC's boot process does not use. This build drops it
# entirely rather than carrying it forward -- see scripts/patch_mbr.py.
#
# Requirements: bash, python3, dpkg-deb, curl, gzip, dtc/fdt tools,
# kmod, e2fsprogs and ca-certificates (usable CA trust bundle).
# No mkfs.vfat/mtools/fdisk/parted required -- the FAT32
# partition and MBR partition table are built by hand in
# scripts/make_fat32.py and this script.
#
# Usage:
#   ./build.sh
#
# Optional build-location overrides: OUT_DIR and WORK_DIR.
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: build.sh must run as root (mount, apt, depmod)." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(tr -d '\r\n' < "$HERE/VERSION")"

# Fixed 3.13 platform inputs. This release deliberately does not adapt itself to
# arbitrary boot images, Debian roots or kernel ABIs.
DEBIAN_URL="https://dl.sd-card-images.johang.se/debians/2026-09-07/debian-trixie-armhf-pheiz3.bin.gz"
DEBIAN_SNAPSHOT_STAMP="20260907T235959Z"
EXPECTED_KERNEL_ABI="6.12.107+deb13-armmp"
EXPECTED_KERNEL_DEBIAN_VERSION="6.12.107-1"
BOOT_GZIP_SHA256="e106b4cb5efdb9d3a559cd8ca192a2102807c8b80ce451e0333f770eb3fb2979"

# Runtime package set for the fixed Trixie platform. Format: URL|staged filename.
FIRMWARE_SOURCE_URL="https://ftp.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/firmware-brcm80211_20250410-2_all.deb"
FIRMWARE_SOURCE_SHA256="266cc703e2299f5253fd1ff9a1fd625d85a2c8e5a88b1a65fcc190ac384ce3d7"
RUNTIME_PACKAGES=(
    # Offline first-boot Wi-Fi userspace. Keep this set intentionally small and
    # identical to the earlier BPI build that proved reliable on this board.
    "https://deb.debian.org/debian/pool/main/i/iwd/iwd_3.8-2_armhf.deb|pkgroot/iwd_3.8-2_armhf.deb"
    "https://deb.debian.org/debian/pool/main/e/ell/libell0_0.77-1_armhf.deb|pkgroot/libell0_0.77-1_armhf.deb"
    "https://deb.debian.org/debian/pool/main/r/readline/libreadline8t64_8.2-6_armhf.deb|pkgroot/libreadline8t64_8.2-6_armhf.deb"
    "https://deb.debian.org/debian/pool/main/r/readline/readline-common_8.2-6_all.deb|pkgroot/readline-common_8.2-6_all.deb"
    "https://deb.debian.org/debian/pool/main/w/wireless-regdb/wireless-regdb_2026.05.30-1~deb13u1_all.deb|pkgroot/wireless-regdb_2026.05.30-1~deb13u1_all.deb"
)

BPI_WIFI_COMMIT="6dee7aabad92112e548b551c5acb9611d15e5b33"
BT_HCD_URL="https://raw.githubusercontent.com/BPI-SINOVOIP/BPI_WiFi_Firmware/${BPI_WIFI_COMMIT}/ap6212/bcm43438a1.hcd"
WORK_DIR="${WORK_DIR:-$HERE/build}"
OUT_DIR="${OUT_DIR:-$HERE/out}"
CONFIG_PART_SECTORS=131072  # 64 MiB

mkdir -p "$WORK_DIR" "$OUT_DIR"
cd "$WORK_DIR"

log() { echo ">> $*"; }

# ------------------------------------------------------------
# 0. Host dependency check.
# ------------------------------------------------------------
MISSING_HOST_PKGS=()
# Keep this list aligned with the documented host requirements above.
command -v python3 >/dev/null 2>&1 || MISSING_HOST_PKGS+=(python3)
command -v dpkg-deb >/dev/null 2>&1 || MISSING_HOST_PKGS+=(dpkg)
command -v gzip >/dev/null 2>&1 || MISSING_HOST_PKGS+=(gzip)
command -v findmnt >/dev/null 2>&1 || MISSING_HOST_PKGS+=(util-linux)
command -v dtc >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v fdtget >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v fdtput >/dev/null 2>&1 || MISSING_HOST_PKGS+=(device-tree-compiler)
command -v depmod >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v modinfo >/dev/null 2>&1 || MISSING_HOST_PKGS+=(kmod)
command -v e2fsck >/dev/null 2>&1 || MISSING_HOST_PKGS+=(e2fsprogs)
command -v tune2fs >/dev/null 2>&1 || MISSING_HOST_PKGS+=(e2fsprogs)
command -v curl >/dev/null 2>&1 || MISSING_HOST_PKGS+=(curl)
# HTTPS downloads require a usable CA trust bundle. Do not weaken TLS with -k.
[ -s /etc/ssl/certs/ca-certificates.crt ] || MISSING_HOST_PKGS+=(ca-certificates)

if [ "${#MISSING_HOST_PKGS[@]}" -gt 0 ]; then
    log "installing missing host dependencies: ${MISSING_HOST_PKGS[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        apt-get install -y --no-install-recommends "${MISSING_HOST_PKGS[@]}"
fi

# A package may already be installed while its generated bundle is missing.
# Rebuild it once, then fail closed before any HTTPS fetch if trust is unusable.
if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    command -v update-ca-certificates >/dev/null 2>&1 || {
        echo "ERROR: ca-certificates is unavailable; HTTPS downloads cannot be verified." >&2
        exit 1
    }
    log "regenerating HTTPS CA certificate bundle"
    update-ca-certificates >/dev/null
fi
[ -s /etc/ssl/certs/ca-certificates.crt ] || {
    echo "ERROR: HTTPS CA certificate bundle unavailable: /etc/ssl/certs/ca-certificates.crt" >&2
    exit 1
}

snapshot_fallback_url() {
    local url="$1"
    case "$url" in
        https://deb.debian.org/debian/pool/*)
            printf 'https://snapshot.debian.org/archive/debian/%s/%s\n' \
                "$DEBIAN_SNAPSHOT_STAMP" "${url#https://deb.debian.org/debian/}"
            ;;
        *) return 1 ;;
    esac
}

download_once() {
    local url="$1" dest="$2"
    rm -f "$dest"
    curl -fL --retry 3 -o "$dest" "$url"
}

fetch() {
    local url="$1" dest="$2"
    local meta tmp meta_tmp cached_url="" fallback=""
    meta="${dest}.source-url"
    tmp="${dest}.tmp.$$"
    meta_tmp="${meta}.tmp.$$"

    if [ -s "$dest" ] && [ -s "$meta" ]; then
        cached_url="$(head -n1 "$meta" 2>/dev/null || true)"
        if [ "$cached_url" = "$url" ]; then
            log "present: $(basename "$dest")"
            return 0
        fi
    fi

    if [ -s "$dest" ]; then
        log "source changed or cache metadata missing; refreshing: $(basename "$dest")"
    else
        log "downloading: $(basename "$dest")"
    fi

    fallback="$(snapshot_fallback_url "$url" 2>/dev/null || true)"
    rm -f "$tmp" "$meta_tmp"

    if ! download_once "$url" "$tmp"; then
        rm -f "$tmp"
        if [ -n "$fallback" ]; then
            echo "WARNING: primary download failed for $(basename "$dest"); retrying pinned Debian snapshot." >&2
            echo "         Primary:  $url" >&2
            echo "         Fallback: $fallback" >&2
            if ! download_once "$fallback" "$tmp"; then
                rm -f "$tmp"
                echo "ERROR: failed to download $(basename "$dest")." >&2
                echo "       Primary:  $url" >&2
                echo "       Fallback: $fallback" >&2
                return 1
            fi
        else
            echo "ERROR: failed to download $(basename "$dest")." >&2
            echo "       Primary:  $url" >&2
            echo "       Fallback: none" >&2
            return 1
        fi
    fi

    mv -f "$tmp" "$dest"
    # Cache identity remains the primary release URL even when snapshot.debian.org
    # supplied the identical pinned pool object.
    printf '%s\n' "$url" > "$meta_tmp"
    mv -f "$meta_tmp" "$meta"
}

fetch_deb() {
    local url="$1" dest="$2"
    local filename stem expected_arch rest expected_pkg expected_version
    local actual_pkg actual_version actual_version_no_epoch actual_arch

    filename="${url##*/}"
    case "$filename" in
        *.deb) ;;
        *)
            echo "ERROR: Debian package URL does not end in .deb: $url" >&2
            return 1
            ;;
    esac

    stem="${filename%.deb}"
    expected_arch="${stem##*_}"
    rest="${stem%_*}"
    expected_pkg="${rest%%_*}"
    expected_version="${rest#*_}"
    if [ "$rest" = "$expected_pkg" ] || [ -z "$expected_pkg" ] || \
       [ -z "$expected_version" ] || [ -z "$expected_arch" ]; then
        echo "ERROR: could not parse pinned Debian package filename: $filename" >&2
        return 1
    fi

    fetch "$url" "$dest" || return 1

    actual_pkg="$(dpkg-deb -f "$dest" Package 2>/dev/null || true)"
    actual_version="$(dpkg-deb -f "$dest" Version 2>/dev/null || true)"
    actual_arch="$(dpkg-deb -f "$dest" Architecture 2>/dev/null || true)"
    actual_version_no_epoch="${actual_version#*:}"

    if [ "$actual_pkg" != "$expected_pkg" ] || \
       [ "$actual_version_no_epoch" != "$expected_version" ] || \
       [ "$actual_arch" != "$expected_arch" ]; then
        echo "ERROR: Debian package identity mismatch for $filename." >&2
        echo "       Expected: Package=$expected_pkg Version=$expected_version Architecture=$expected_arch" >&2
        echo "       Actual:   Package=${actual_pkg:-missing} Version=${actual_version:-missing} Architecture=${actual_arch:-missing}" >&2
        rm -f "$dest" "${dest}.source-url"
        return 1
    fi

    log "deb verified: $expected_pkg $actual_version $actual_arch"
}

# Fetch a gzip payload and verify the entire compressed stream before it is
# accepted. A successful HTTP transfer can still return a truncated/corrupt
# payload, and the URL cache alone cannot detect that. A failed integrity check
# invalidates both the payload and its source-url marker so the next attempt is
# guaranteed to perform a fresh download rather than reusing poisoned cache.
fetch_gzip() {
    local url="$1" dest="$2" attempt
    for attempt in 1 2 3; do
        if ! fetch "$url" "$dest"; then
            echo "WARNING: download failed for $(basename "$dest") (attempt $attempt/3)." >&2
            rm -f "$dest" "${dest}.source-url"
            continue
        fi
        if gzip -t "$dest" >/dev/null 2>&1; then
            log "gzip verified: $(basename "$dest")"
            return 0
        fi

        echo "WARNING: gzip integrity check failed for $(basename "$dest") (attempt $attempt/3)." >&2
        rm -f "$dest" "${dest}.source-url"
    done

    echo "ERROR: $(basename "$dest") failed gzip integrity verification after 3 fresh downloads." >&2
    return 1
}

# ------------------------------------------------------------
# 1. Prepare the bundled boot image and pinned Debian root image.
# ------------------------------------------------------------
log "using bundled Banana Pi M2 Zero boot image"
cp -f "$HERE/boot-banana_pi_m2_zero.bin.gz" boot.bin.gz
gzip -t boot.bin.gz
BOOT_ACTUAL_SHA256="$(sha256sum boot.bin.gz | awk '{print $1}')"
[ "$BOOT_ACTUAL_SHA256" = "$BOOT_GZIP_SHA256" ] || {
    echo "ERROR: bundled boot image SHA256 mismatch." >&2
    echo "       Expected: $BOOT_GZIP_SHA256" >&2
    echo "       Actual:   $BOOT_ACTUAL_SHA256" >&2
    exit 1
}
fetch_gzip "$DEBIAN_URL" debian.bin.gz
DEBIAN_GZIP_OBSERVED_SHA256="$(sha256sum debian.bin.gz | awk '{print $1}')"

log "decompressing boot/root images"
gunzip -k -f boot.bin.gz
gunzip -k -f debian.bin.gz
log "building final MBR layout early for PARTUUID/fstab/extlinux policy"
python3 "$HERE/scripts/patch_mbr.py" \
    --boot-in boot.bin \
    --boot-out boot_patched.bin \
    --debian-in debian.bin \
    --config-sectors "$CONFIG_PART_SECTORS"
ROOT_PARTUUID="$(python3 "$HERE/scripts/mbr_partuuid.py" boot_patched.bin --partition 2)"
CONFIG_START_SECTOR="$(python3 "$HERE/scripts/mbr_partuuid.py" boot_patched.bin --partition 1 --field start)"
CONFIG_VOLID_HEX="$(python3 "$HERE/scripts/mbr_partuuid.py" boot_patched.bin --field disk-signature)"

# ------------------------------------------------------------
# 2. Download runtime packages (staged into /root, installed by
#    the firstboot service on first boot). Recreate pkgroot on each
#    build so removed features cannot survive as stale staged files.
# ------------------------------------------------------------
rm -rf pkgroot
mkdir -p pkgroot
fetch_deb "$FIRMWARE_SOURCE_URL" firmware-brcm80211.deb || {
    echo "ERROR: required pinned firmware source package failed: $FIRMWARE_SOURCE_URL" >&2
    exit 1
}
echo "$FIRMWARE_SOURCE_SHA256  firmware-brcm80211.deb" | sha256sum -c - >/dev/null || {
    echo "ERROR: firmware-brcm80211 SHA-256 mismatch." >&2
    rm -f firmware-brcm80211.deb firmware-brcm80211.deb.source-url
    exit 1
}
log "firmware source SHA-256 verified"
for spec in "${RUNTIME_PACKAGES[@]}"; do
    url="${spec%%|*}"
    dest="${spec#*|}"
    fetch_deb "$url" "$dest" || {
        echo "ERROR: required pinned Debian package failed validation: $url" >&2
        exit 1
    }
done

extract_deb_data() {
    local deb="$1" dest="$2"
    rm -rf "$dest" && mkdir -p "$dest"
    dpkg-deb -x "$deb" "$dest"
}

log "extracting BCM43430 firmware from firmware-brcm80211"
extract_deb_data firmware-brcm80211.deb _fw_extract
FW_DIR=_fw_extract/usr/lib/firmware
CYPRESS_BIN="$FW_DIR/cypress/cyfmac43430-sdio.bin"
CYPRESS_CLM="$FW_DIR/cypress/cyfmac43430-sdio.clm_blob"
BOARD_TXT="$FW_DIR/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt"
for f in "$CYPRESS_BIN" "$CYPRESS_CLM" "$BOARD_TXT"; do
    [ -s "$f" ] || { echo "ERROR: missing firmware payload $f"; exit 1; }
done

# cfg80211 can request regulatory.db as soon as the wireless stack probes, well
# before firstboot installs wireless-regdb. Seed the exact database from the
# pinned Debian package into the offline root, matching the proven 3.9 image.
log "extracting regulatory.db from wireless-regdb"
extract_deb_data pkgroot/wireless-regdb_2026.05.30-1~deb13u1_all.deb _regdb_extract
REGDB="_regdb_extract/usr/lib/firmware/regulatory.db-upstream"
REGSIG="_regdb_extract/usr/lib/firmware/regulatory.db.p7s-upstream"
for f in "$REGDB" "$REGSIG"; do
    [ -s "$f" ] || { echo "ERROR: missing regulatory payload $f"; exit 1; }
done
log "fetching hardware-validated Banana Pi AP6212 Bluetooth HCD"
fetch "$BT_HCD_URL" bpi-ap6212-bcm43438a1.hcd || {
    echo "ERROR: required Banana Pi AP6212 Bluetooth HCD download failed." >&2
    echo "       URL: $BT_HCD_URL" >&2
    exit 1
}
[ "$(stat -c %s bpi-ap6212-bcm43438a1.hcd)" -eq 33376 ] || {
    echo "ERROR: unexpected Banana Pi AP6212 Bluetooth HCD size" >&2
    exit 1
}
BT_HCD_OBSERVED_SHA256="$(sha256sum bpi-ap6212-bcm43438a1.hcd | awk '{print $1}')"

# ------------------------------------------------------------
# 3. Stage the firstboot script and its offline package payload.
# ------------------------------------------------------------
install -m 0755 "$HERE/overlay/root/bpi-zero-wbuild-firstboot.sh" pkgroot/
find pkgroot -maxdepth 1 -type f -name '*.source-url' -delete
chmod 0644 pkgroot/*.deb

# ------------------------------------------------------------
# 4. Inject pkgroot into /root and install the firstboot unit.
#    Root credential setup runs first. Storage growth is best effort and never
#    blocks later Wi-Fi/SSH provisioning.
# ------------------------------------------------------------
log "injecting files into root filesystem (requires loop mount + root)"
MNT="$WORK_DIR/_mnt_root"
mkdir -p "$MNT"
if mountpoint -q "$MNT"; then umount "$MNT"; fi
mount -o loop,rw debian.bin "$MNT"
trap 'umount "$MNT" 2>/dev/null || true' EXIT
ROOT_FS_TYPE="$(findmnt -n -o FSTYPE --target "$MNT" 2>/dev/null || true)"
[ "$ROOT_FS_TYPE" = "ext4" ] || {
    echo "ERROR: configured Debian root image mounted as ${ROOT_FS_TYPE:-unknown}, expected ext4." >&2
    exit 1
}
[ -f "$MNT/etc/fstab" ] || { echo "ERROR: target /etc/fstab is missing." >&2; exit 1; }
python3 "$HERE/scripts/set_fstab_policy.py" "$MNT/etc/fstab" --partuuid "$ROOT_PARTUUID"

# The bundled U-Boot boots this root through extlinux. Apply the policy to the
# actual boot file and its u-boot-menu defaults, then validate both before the
# image can continue.
EXTLINUX_CONF="$MNT/boot/extlinux/extlinux.conf"
U_BOOT_DEFAULTS="$MNT/etc/default/u-boot"
[ -f "$EXTLINUX_CONF" ] || { echo "ERROR: target extlinux configuration is missing: /boot/extlinux/extlinux.conf" >&2; exit 1; }
python3 "$HERE/scripts/set_extlinux_policy.py" "$EXTLINUX_CONF" "$U_BOOT_DEFAULTS" --partuuid "$ROOT_PARTUUID"
grep -Eq "^[[:space:]]*append root=PARTUUID=${ROOT_PARTUUID} rw rootwait loglevel=7 systemd\.show_status=yes[[:space:]]*$" "$EXTLINUX_CONF" || {
    echo "ERROR: extlinux root/console policy validation failed." >&2; exit 1;
}
grep -qxF "U_BOOT_ROOT=\"root=PARTUUID=${ROOT_PARTUUID}\"" "$U_BOOT_DEFAULTS" || { echo "ERROR: U_BOOT_ROOT policy validation failed." >&2; exit 1; }
grep -qxF 'U_BOOT_PARAMETERS="rw rootwait loglevel=7 systemd.show_status=yes"' "$U_BOOT_DEFAULTS" || { echo "ERROR: U_BOOT_PARAMETERS policy validation failed." >&2; exit 1; }

cp -f pkgroot/* "$MNT/root/"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"

cp -f "$HERE/overlay/root/bpi-zero-wbuild-firstboot.service" \
    "$MNT/etc/systemd/system/bpi-zero-wbuild-firstboot.service"
# Banana Pi M2 Zero onboard Wi-Fi is a fixed board contract: brcmfmac -> wlan0.
# Firstboot writes one iwd profile and a wlan0 DHCP rule. No custom Wi-Fi
# service or runtime interface discovery is installed.
mkdir -p "$MNT/etc/systemd/system/getty@tty1.service.d"
cp -f "$HERE/overlay/root/getty-tty1-override.conf" \
    "$MNT/etc/systemd/system/getty@tty1.service.d/override.conf"

# Login safety is account-state based, not getty ordering. Remove inherited
# human accounts and lock root in the offline image. Firstboot replaces root's
# locked hash only after CONFIG.TXT validates.
python3 "$HERE/scripts/prepare_login_accounts.py" "$MNT"

# Keep SSH out of the boot transaction until firstboot explicitly enables it.
# This also avoids a harmless failed ssh.service while host keys are absent.
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/ssh.service"       "$MNT/etc/systemd/system/multi-user.target.wants/sshd.service"

# Never ship host keys inherited from the pinned Debian root image. Firstboot
# generates unique keys immediately after ROOT_PASSWORD validates.
rm -f "$MNT"/etc/ssh/ssh_host_*

# Wi-Fi firmware and the regulatory database required by cfg80211 are seeded
# into the rootfs before first boot. wireless-regdb remains in the firstboot
# package set so Debian owns/updates the database after provisioning.
mkdir -p "$MNT/usr/lib/firmware/brcm"
install -m 0644 "$REGDB" "$MNT/usr/lib/firmware/regulatory.db"
install -m 0644 "$REGSIG" "$MNT/usr/lib/firmware/regulatory.db.p7s"
install -m 0644 "$CYPRESS_BIN" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.bin"
install -m 0644 "$CYPRESS_BIN" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.bin"
install -m 0644 "$CYPRESS_CLM" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob"
install -m 0644 "$CYPRESS_CLM" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.clm_blob"
install -m 0644 "$BOARD_TXT" "$MNT/usr/lib/firmware/brcm/brcmfmac43430-sdio.sinovoip,bpi-m2-zero.txt"

# Install ONLY the board-qualified AP6212 HCD name validated on BPI-M2-Zero.
# Do not install a generic BCM43430A1.hcd fallback: the Debian generic payload
# produced UART baud/reset timeouts on this hardware.
rm -f "$MNT/usr/lib/firmware/brcm/BCM43430A1.hcd"
install -m 0644 bpi-ap6212-bcm43438a1.hcd \
    "$MNT/usr/lib/firmware/brcm/BCM43430A1.sinovoip,bpi-m2-zero.hcd"
rm -rf _fw_extract _regdb_extract

ln -sfn ../bpi-zero-wbuild-firstboot.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/bpi-zero-wbuild-firstboot.service"

KERNEL_ABI="$EXPECTED_KERNEL_ABI"
KERNEL_PACKAGE="linux-image-$KERNEL_ABI"
[ -d "$MNT/lib/modules/$KERNEL_ABI" ] || { echo "ERROR: target root is missing fixed kernel module tree $KERNEL_ABI." >&2; exit 1; }
KERNEL_DEBIAN_VERSION="$(python3 "$HERE/scripts/dpkg_status_field.py" "$MNT/var/lib/dpkg/status" --package "$KERNEL_PACKAGE" --field Version)"
KERNEL_PACKAGE_ARCH="$(python3 "$HERE/scripts/dpkg_status_field.py" "$MNT/var/lib/dpkg/status" --package "$KERNEL_PACKAGE" --field Architecture)"
[ "$KERNEL_PACKAGE_ARCH" = armhf ] || { echo "ERROR: $KERNEL_PACKAGE architecture is $KERNEL_PACKAGE_ARCH, expected armhf." >&2; exit 1; }
[ "$KERNEL_DEBIAN_VERSION" = "$EXPECTED_KERNEL_DEBIAN_VERSION" ] || { echo "ERROR: $KERNEL_PACKAGE version is $KERNEL_DEBIAN_VERSION, expected $EXPECTED_KERNEL_DEBIAN_VERSION." >&2; exit 1; }
python3 "$HERE/scripts/dpkg_status_field.py" "$MNT/var/lib/dpkg/status" --package systemd-resolved --field Version >/dev/null || {
    echo "ERROR: target root is missing systemd-resolved; DNS policy cannot be guaranteed." >&2; exit 1;
}
log "target kernel package: $KERNEL_PACKAGE $KERNEL_DEBIAN_VERSION ($KERNEL_PACKAGE_ARCH)"

# ------------------------------------------------------------
# Reusable board baseline: SPI0, I2C0 and playback-only I2S0/MAX98357A.
# The audio endpoint is part of the base hardware contract, not an application
# service. PA1 is SD/EN and PA18/PA19/PA20 are reserved for I2S0 playback.
# ------------------------------------------------------------
DTB_NAME="sun8i-h2-plus-bananapi-m2-zero.dtb"
STOCK_DTB="$MNT/usr/lib/linux-image-$KERNEL_ABI/$DTB_NAME"
HW_BUILD_DIR="$WORK_DIR/base-hardware"
HW_DTB_BUILD="$HW_BUILD_DIR/$DTB_NAME"

[ -s "$STOCK_DTB" ] || { echo "ERROR: stock Banana Pi DTB missing: ${STOCK_DTB#$MNT}" >&2; exit 1; }
rm -rf "$HW_BUILD_DIR"
mkdir -p "$HW_BUILD_DIR"

log "enabling SPI0 + I2C0 + I2S0/MAX98357A hardware baseline"
bash "$HERE/scripts/patch_base_hardware_dtb.sh" "$STOCK_DTB" "$HW_DTB_BUILD"
DTB_SHA256="$(sha256sum "$HW_DTB_BUILD" | awk '{print $1}')"

# MAX98357A is fixed to the known 6.12.107 kernel contract. There is no
# generalized ABI builder in this release.
MAX98357A_BUILD_DIR="$HW_BUILD_DIR/max98357a"
mkdir -p "$MAX98357A_BUILD_DIR"
log "building fixed MAX98357A module for $EXPECTED_KERNEL_ABI"
MK_MAX98357A_BUILD_OUT="$MAX98357A_BUILD_DIR" bash "$HERE/scripts/build_max98357a_6_12_107.sh"
MAX98357A_KO="$MAX98357A_BUILD_DIR/snd-soc-max98357a.ko"
[ -s "$MAX98357A_KO" ] || { echo "ERROR: fixed MAX98357A build output missing." >&2; exit 1; }
MODULE_SHA256="$(sha256sum "$MAX98357A_KO" | awk '{print $1}')"
MODULE_VERMAGIC="$(modinfo -F vermagic "$MAX98357A_KO" 2>/dev/null | awk '{print $1}')"
[ "$MODULE_VERMAGIC" = "$EXPECTED_KERNEL_ABI" ] || { echo "ERROR: MAX98357A vermagic '$MODULE_VERMAGIC' != '$EXPECTED_KERNEL_ABI'." >&2; exit 1; }
[ "$(modinfo -F name "$MAX98357A_KO" 2>/dev/null)" = snd_soc_max98357a ] || { echo "ERROR: unexpected MAX98357A module name." >&2; exit 1; }
modinfo -F alias "$MAX98357A_KO" 2>/dev/null | grep -q 'maxim,max98357a' || { echo "ERROR: MAX98357A OF alias missing." >&2; exit 1; }
python3 "$HERE/scripts/check_platform_aliases.py" "$HW_DTB_BUILD"
python3 "$HERE/scripts/check_platform_pins.py" "$HW_DTB_BUILD"
python3 "$HERE/scripts/check_bluetooth_topology.py" "$HW_DTB_BUILD"

DTB_BOOT="$MNT/usr/lib/linux-image-$KERNEL_ABI/$DTB_NAME"
DTB_FIRMWARE="$MNT/usr/lib/firmware/$KERNEL_ABI/device-tree/$DTB_NAME"
mkdir -p "$(dirname "$DTB_FIRMWARE")" "$MNT/lib/modules/$KERNEL_ABI/extra" "$MNT/etc/modules-load.d" "$MNT/usr/local/sbin" "$MNT/etc/systemd/system/multi-user.target.wants"

# The fixed kernel ABI is held below. Replace the active DTB directly;
# no dpkg diversion is needed for this fixed jump-point baseline.
install -m 0644 "$HW_DTB_BUILD" "$DTB_BOOT"

python3 "$HERE/scripts/hold_kernel_packages.py" "$MNT/var/lib/dpkg/status" --require "$KERNEL_PACKAGE"
install -m 0644 "$HW_DTB_BUILD" "$DTB_FIRMWARE"
install -m 0644 "$MAX98357A_KO" "$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko"
install -m 0644 "$HERE/hardware/modules-load.conf" "$MNT/etc/modules-load.d/bpi-zero-required-hardware.conf"
install -m 0755 "$HERE/hardware/bind-spidev" "$MNT/usr/local/sbin/bpi-zero-bind-spidev"
install -m 0644 "$HERE/hardware/spidev.service" "$MNT/etc/systemd/system/bpi-zero-spidev.service"
ln -sfn ../bpi-zero-spidev.service "$MNT/etc/systemd/system/multi-user.target.wants/bpi-zero-spidev.service"

depmod -b "$MNT" "$KERNEL_ABI"
validate_module_resolution() {
    local mod="$1" expected="${2:-}" resolved resolved_rel expected_rel
    resolved="$(modinfo -b "$MNT" -k "$KERNEL_ABI" -n "$mod" 2>/dev/null || true)"
    [ -n "$resolved" ] || { echo "ERROR: target module index cannot resolve: $mod" >&2; exit 1; }
    if [ -n "$expected" ]; then
        resolved_rel="$resolved"
        case "$resolved_rel" in
            "$MNT"/*) resolved_rel="${resolved_rel#"$MNT"}" ;;
        esac
        expected_rel="${expected#"$MNT"}"
        if [ "$resolved_rel" != "$expected_rel" ]; then
            echo "ERROR: $mod resolves to '$resolved' (${resolved_rel}), expected '$expected' (${expected_rel})." >&2
            exit 1
        fi
    fi
    modprobe -d "$MNT" -S "$KERNEL_ABI" -n "$mod" >/dev/null 2>&1 || { echo "ERROR: unresolved module/dependency: $mod" >&2; exit 1; }
}
MAX98357A_MODULE_FILE="$MNT/lib/modules/$KERNEL_ABI/extra/snd-soc-max98357a.ko"
validate_module_resolution snd-soc-max98357a "$MAX98357A_MODULE_FILE"
validate_module_resolution sun4i-i2s
validate_module_resolution snd-soc-simple-card
validate_module_resolution spidev
validate_module_resolution i2c-dev
validate_module_resolution brcmfmac
validate_module_resolution hci_uart
validate_module_resolution btbcm
[ "$(sha256sum "$DTB_BOOT" | awk '{print $1}')" = "$DTB_SHA256" ]
[ "$(sha256sum "$DTB_FIRMWARE" | awk '{print $1}')" = "$DTB_SHA256" ]
[ "$(sha256sum "$MAX98357A_MODULE_FILE" | awk '{print $1}')" = "$MODULE_SHA256" ]

# SD-card safety: do not ship the builder's persistent journal.
rm -rf "$MNT/var/log/journal"
mkdir -p "$MNT/etc/systemd/journald.conf.d"
cat >"$MNT/etc/systemd/journald.conf.d/20-bpi-zero-volatile.conf" <<'EOF_JOURNAL'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF_JOURNAL
chmod 0644 "$MNT/etc/systemd/journald.conf.d/20-bpi-zero-volatile.conf"

cat >"$MNT/etc/bpi-zero-wbuild-release" <<EOF_BASE_RELEASE
PRODUCT=bpi-zero-wbuild
VERSION=$VERSION
TARGET=bpi-m2-zero
BASE=debian-trixie-armhf-pheiz3
DEBIAN_SOURCE_URL=$DEBIAN_URL
DEBIAN_IMAGE_DATE=2026-09-07
KERNEL_ABI=$KERNEL_ABI
KERNEL_DEBIAN_VERSION=$KERNEL_DEBIAN_VERSION
BOOT_SOURCE=bundled-source-archive
BOOT_GZIP_SHA256=$BOOT_GZIP_SHA256
DEBIAN_SOURCE_TRUST=fixed-https-url-gzip-verified;sha256-pin-pending-upstream-hash
DEBIAN_GZIP_OBSERVED_SHA256=$DEBIAN_GZIP_OBSERVED_SHA256
WIFI_DRIVER=brcmfmac
WIFI_INTERFACE=wlan0
GPU_POLICY=headless-disabled-mali400
WIFI_FIRMWARE_SOURCE=Debian-firmware-brcm80211-20250410-2
WIFI_FIRMWARE_INSTALL=image-build-direct
BLUETOOTH_FIRMWARE_SOURCE=BananaPi-AP6212-${BPI_WIFI_COMMIT}-board-specific
BLUETOOTH_FIRMWARE_TRUST=commit-pinned-size-validated;sha256-pin-pending
BLUETOOTH_FIRMWARE_OBSERVED_SHA256=$BT_HCD_OBSERVED_SHA256
BLUETOOTH_FIRMWARE_PATH=brcm/BCM43430A1.sinovoip,bpi-m2-zero.hcd
BLUETOOTH_USERSPACE=not-installed-by-base
ROOT_RESIZE_MODE=firstboot-online-resize2fs-nonfatal-retry-until-success
SPI_ALIAS=spi0
SPI_DEVICE=/dev/spidev0.0
I2C_ALIAS=i2c0
I2C_DEVICE=/dev/i2c-0
GPIO_DEVICE=/dev/gpiochip0
BASE_DTB_SHA256=$DTB_SHA256
AUDIO_ENDPOINT=MAX98357A
AUDIO_CODEC_DRIVER=snd-soc-max98357a
MAX98357A_MODULE_SOURCE=fixed-release-build-6.12.107
MAX98357A_MODULE_SHA256=$MODULE_SHA256
MAX98357A_DTB_SHA256=$DTB_SHA256
KERNEL_UPDATE_POLICY=dpkg-hold-fixed-kernel
DTB_UPDATE_POLICY=kernel-held-active-dtb
MAX98357A_VERMAGIC=$MODULE_VERMAGIC
MAX98357A_SD_GPIO=PA1
MAX98357A_SD_DELAY_MS=5
MAX98357A_MCLK_FS=256
I2S_LRCLK_GPIO=PA18
I2S_BCLK_GPIO=PA19
I2S_TX_GPIO=PA20
GPIO_POLICY=board-default-plus-spi0-i2c0-i2s0-max98357a
CONFIG_SECRET_POLICY=PSK-and-ROOT_PASSWORD-blanked-after-successful-firstboot
LOGIN_SECURITY=offline-root-lock-and-human-account-prune;firstboot-root-password-and-ssh-host-key-setup
CONSOLE_LOGIN_POLICY=getty-may-start-while-root-locked;firstboot-unlocks-root
LOGIN_POLICY=root-only
LOGIN_ACCOUNT=root-only
BOOT_CONSOLE=verbose-kernel-and-systemd-status
TTY1_NETWORK_INFO=/etc/issue.d-dynamic-ip-no-boot-wait
HARDWARE_SCOPE=wifi-bluetooth-spi-i2c-gpio-i2s-max98357a;resize-best-effort
EOF_BASE_RELEASE
chmod 0644 "$MNT/etc/bpi-zero-wbuild-release"

# Clone-safe machine identity. Normalize the upstream rootfs regardless of
# whether it ships /etc/machine-id absent, empty, or populated. Every flashed
# device must generate its own persistent identity. Leave /etc/machine-id
# present but empty. Firstboot Stage 05 explicitly runs
# systemd-machine-id-setup, and the legacy D-Bus path references that same ID.
log "resetting image machine-id for first-boot generation"
mkdir -p "$MNT/var/lib/dbus"
truncate -s 0 "$MNT/etc/machine-id"
rm -f "$MNT/var/lib/dbus/machine-id"
ln -s /etc/machine-id "$MNT/var/lib/dbus/machine-id"

sync
umount "$MNT"
trap - EXIT

# The deployment image must leave the builder with a clean ext4 rootfs.
# Validate read-only and fail the release if consistency is not perfect.
# Do not repair it here: an unexpected dirty/corrupt image is a build failure.
log "validating clean root filesystem (read-only; no repair)"
set +e
e2fsck -f -n debian.bin
ROOTFS_CHECK_RC=$?
set -e
if [ "$ROOTFS_CHECK_RC" -ne 0 ]; then
    echo "ERROR: release root filesystem failed read-only e2fsck (rc=$ROOTFS_CHECK_RC)." >&2
    echo "       Refusing to package an image that would require target-side repair." >&2
    exit 1
fi
ROOTFS_STATE="$(tune2fs -l debian.bin 2>/dev/null | awk -F: '/Filesystem state:/ { gsub(/^[ \t]+/, "", $2); print $2; exit }')"
if [ "$ROOTFS_STATE" != "clean" ]; then
    echo "ERROR: release root filesystem state is '$ROOTFS_STATE', expected 'clean'." >&2
    exit 1
fi
log "root filesystem state: clean"


# ------------------------------------------------------------
# 5. Build the BPIWBUILD FAT32 config partition
# ------------------------------------------------------------
log "building BPIWBUILD FAT32 partition (64 MiB)"
python3 "$HERE/scripts/make_fat32.py" bpiwbuild-config.fat32 "$CONFIG_PART_SECTORS" \
    "$HERE/config/CONFIG.TXT.template" \
    --hidden-sectors "$CONFIG_START_SECTOR" \
    --volume-id "0x$CONFIG_VOLID_HEX"

# ------------------------------------------------------------
# 6. Revalidate the already-built final MBR layout before assembly.
# ------------------------------------------------------------
[ "$(python3 "$HERE/scripts/mbr_partuuid.py" boot_patched.bin --partition 2)" = "$ROOT_PARTUUID" ] || { echo "ERROR: patched MBR PARTUUID changed unexpectedly." >&2; exit 1; }
[ "$(stat -c %s boot_patched.bin)" -eq $((CONFIG_START_SECTOR * 512)) ] || { echo "ERROR: patched boot area length does not equal partition-1 start." >&2; exit 1; }

# ------------------------------------------------------------
# 7. Stream the final card layout directly to gzip.
#    The root filesystem must remain a seekable debian.bin while it is mounted
#    and modified above, but there is no reason to write an assembled raw .img
#    only to read it again for compression.
# ------------------------------------------------------------
OUT_GZ="$OUT_DIR/bpi-zero-wbuild-$VERSION-bpi-m2-zero.img.gz"
TMP_GZ="$OUT_GZ.tmp.$$"
# Remove same-version raw artifacts left by older builders so out/ reflects the compressed-only contract.
rm -f "$OUT_DIR/bpi-zero-wbuild-$VERSION-bpi-m2-zero.img" \
      "$OUT_DIR/bpi-zero-wbuild-$VERSION-bpi-m2-zero.img.sha256"
RAW_IMAGE_BYTES=$(( $(stat -c %s boot_patched.bin) + $(stat -c %s bpiwbuild-config.fat32) + $(stat -c %s debian.bin) ))
log "streaming final card image directly to $(basename "$OUT_GZ")"
log "logical uncompressed image size: $RAW_IMAGE_BYTES bytes"
rm -f "$TMP_GZ"
trap 'rm -f "$TMP_GZ"' EXIT
cat boot_patched.bin bpiwbuild-config.fat32 debian.bin | gzip -6 > "$TMP_GZ"
gzip -t "$TMP_GZ"
mv -f "$TMP_GZ" "$OUT_GZ"
trap - EXIT
(
    cd "$OUT_DIR"
    sha256sum "$(basename "$OUT_GZ")" > "$(basename "$OUT_GZ").sha256"
)

log "done"
ls -la "$OUT_DIR"
cat "$OUT_GZ.sha256"
