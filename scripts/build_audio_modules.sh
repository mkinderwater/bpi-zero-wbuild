#!/usr/bin/env bash
# Build the bpi-zero-clock 24 kHz capture ASoC modules from source.
# Target ABI: Debian 13 armhf 6.12.100+deb13-armmp (linux 6.12.100-1).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ABI="6.12.100+deb13-armmp"
DEBIAN_VERSION="6.12.100-1"
COMMON_NAME="linux-headers-6.12.100+deb13-common"
KBUILD_NAME="linux-kbuild-6.12.100+deb13"
SEC_BASE="https://security.debian.org/debian-security/pool/main/l/linux"
SEC_SNAPSHOT="https://snapshot.debian.org/archive/debian-security/20260802T000000Z/pool/main/l/linux"
SRC_BASE="https://sources.debian.org/data/main/l/linux/${DEBIAN_VERSION}"
WORK_DIR="${MK_AUDIO_BUILD_WORK:-$HERE/build/audio-source}"
OUT_DIR="${MK_AUDIO_BUILD_OUT:-$HERE/build/audio-modules}"

HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$HOST_ARCH" in
    amd64)
        KBUILD_ARCH=amd64
        CC_BIN=arm-linux-gnueabihf-gcc
        CROSS_COMPILE_PREFIX=arm-linux-gnueabihf-
        COMPILER_PACKAGE=gcc-arm-linux-gnueabihf
        ;;
    armhf)
        # Native build path for the BPI M2 Zero itself. Use Debian's armhf
        # kbuild helpers and the native GCC 14 compiler for the same target ABI.
        KBUILD_ARCH=armhf
        CC_BIN=gcc
        CROSS_COMPILE_PREFIX=
        COMPILER_PACKAGE=gcc
        ;;
    *)
        echo "ERROR: supported build hosts are Debian amd64 or armhf; found '$HOST_ARCH'." >&2
        exit 1
        ;;
esac

need=()
command -v curl >/dev/null 2>&1 || need+=(curl)
command -v dpkg-deb >/dev/null 2>&1 || need+=(dpkg)
command -v make >/dev/null 2>&1 || need+=(make)
command -v python3 >/dev/null 2>&1 || need+=(python3)
command -v xz >/dev/null 2>&1 || need+=(xz-utils)
command -v "$CC_BIN" >/dev/null 2>&1 || need+=("$COMPILER_PACKAGE")
command -v modinfo >/dev/null 2>&1 || need+=(kmod)
if [ "${#need[@]}" -gt 0 ]; then
    [ "$(id -u)" -eq 0 ] || {
        echo "ERROR: missing host packages: ${need[*]}; rerun as root so they can be installed." >&2
        exit 1
    }
    apt-get update
    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        apt-get install -y --no-install-recommends "${need[@]}"
fi

CC_MAJOR="$("$CC_BIN" -dumpversion | cut -d. -f1)"
[ "$CC_MAJOR" = "14" ] || {
    echo "ERROR: target kernel was built with GCC 14; $CC_BIN reports major $CC_MAJOR." >&2
    exit 1
}

echo ">> audio module build host: $HOST_ARCH ($CC_BIN, kbuild $KBUILD_ARCH)"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/sdk" \
         "$WORK_DIR/src/sound/soc/sunxi" \
         "$WORK_DIR/src/sound/soc/codecs" \
         "$WORK_DIR/src/sound/soc/generic" \
         "$OUT_DIR"

fetch() {
    local url="$1" out="$2" fallback="${3:-}"
    echo ">> downloading $(basename "$out")"
    if ! curl -fL --retry 3 --retry-delay 1 -o "$out.tmp" "$url"; then
        [ -n "$fallback" ] || return 1
        echo ">> primary archive unavailable; using pinned Debian snapshot"
        curl -fL --retry 3 --retry-delay 1 -o "$out.tmp" "$fallback"
    fi
    mv "$out.tmp" "$out"
}

HDR_ARM="$WORK_DIR/downloads/linux-headers-${ABI}_${DEBIAN_VERSION}_armhf.deb"
HDR_COMMON="$WORK_DIR/downloads/${COMMON_NAME}_${DEBIAN_VERSION}_all.deb"
KBUILD="$WORK_DIR/downloads/${KBUILD_NAME}_${DEBIAN_VERSION}_${KBUILD_ARCH}.deb"

fetch "$SEC_BASE/linux-headers-${ABI}_${DEBIAN_VERSION}_armhf.deb" "$HDR_ARM" "$SEC_SNAPSHOT/linux-headers-${ABI}_${DEBIAN_VERSION}_armhf.deb"
fetch "$SEC_BASE/${COMMON_NAME}_${DEBIAN_VERSION}_all.deb" "$HDR_COMMON" "$SEC_SNAPSHOT/${COMMON_NAME}_${DEBIAN_VERSION}_all.deb"
fetch "$SEC_BASE/${KBUILD_NAME}_${DEBIAN_VERSION}_${KBUILD_ARCH}.deb" "$KBUILD" "$SEC_SNAPSHOT/${KBUILD_NAME}_${DEBIAN_VERSION}_${KBUILD_ARCH}.deb"

check_deb() {
    local deb="$1" pkg="$2" ver="$3" arch="$4"
    [ "$(dpkg-deb -f "$deb" Package)" = "$pkg" ]
    [ "$(dpkg-deb -f "$deb" Version)" = "$ver" ]
    [ "$(dpkg-deb -f "$deb" Architecture)" = "$arch" ]
}
check_deb "$HDR_ARM" "linux-headers-$ABI" "$DEBIAN_VERSION" armhf
check_deb "$HDR_COMMON" "$COMMON_NAME" "$DEBIAN_VERSION" all
check_deb "$KBUILD" "$KBUILD_NAME" "$DEBIAN_VERSION" "$KBUILD_ARCH"

dpkg-deb -x "$HDR_COMMON" "$WORK_DIR/sdk"
dpkg-deb -x "$HDR_ARM" "$WORK_DIR/sdk"
dpkg-deb -x "$KBUILD" "$WORK_DIR/sdk"

# Debian header packages are built for their installed /usr/src + /usr/lib
# layout. Relocate those references inside our private extracted SDK so Kbuild
# never escapes to the build host filesystem.
python3 "$HERE/scripts/relocate_debian_header_sdk.py" \
    --sdk-root "$WORK_DIR/sdk" \
    --abi "$ABI" \
    --common-name "$COMMON_NAME" \
    --kbuild-name "$KBUILD_NAME"

HDR_DIR="$WORK_DIR/sdk/usr/src/linux-headers-$ABI"
[ -s "$HDR_DIR/Module.symvers" ] || { echo "ERROR: Module.symvers missing from exact ARMMP headers." >&2; exit 1; }
[ -s "$HDR_DIR/include/config/auto.conf" ] || { echo "ERROR: ARMMP generated kernel configuration missing." >&2; exit 1; }

fetch "$SRC_BASE/sound/soc/sunxi/sun4i-i2s.c" "$WORK_DIR/src/sound/soc/sunxi/sun4i-i2s.c"
fetch "$SRC_BASE/sound/soc/codecs/dmic.c" "$WORK_DIR/src/sound/soc/codecs/dmic.c"
fetch "$SRC_BASE/sound/soc/generic/simple-card.c" "$WORK_DIR/src/sound/soc/generic/simple-card.c"

# Apply reviewed exact transforms. The transformer validates every source anchor,
# changes exactly the intended occurrence, and emits real unified diffs for audit.
AUDIT_DIR="$WORK_DIR/applied-patches"
echo ">> applying reviewed audio source transforms"
python3 "$HERE/scripts/apply_audio_source_transforms.py" \
    --src-root "$WORK_DIR/src" \
    --audit-dir "$AUDIT_DIR"

require_count() {
    local expected="$1" pattern="$2" file="$3" label="$4"
    local count
    count="$(grep -cF "$pattern" "$file" || true)"
    [ "$count" = "$expected" ] || {
        echo "ERROR: $label: found $count occurrences, expected $expected." >&2
        exit 1
    }
}
require_count 1 'rates = SNDRV_PCM_RATE_8000_192000 | SNDRV_PCM_RATE_24000' "$WORK_DIR/src/sound/soc/sunxi/sun4i-i2s.c" '24 kHz capture mask'
require_count 1 'rates = SNDRV_PCM_RATE_8000_192000,' "$WORK_DIR/src/sound/soc/sunxi/sun4i-i2s.c" 'unchanged playback mask'
require_count 1 'static const struct snd_pcm_hw_constraint_list mkclock_capture_rate_constraint = {' "$WORK_DIR/src/sound/soc/generic/simple-card.c" 'simple-card constraint object'
require_count 1 'ret = snd_pcm_hw_constraint_list(substream->runtime, 0,' "$WORK_DIR/src/sound/soc/generic/simple-card.c" 'simple-card capture constraint call'
require_count 1 '"icubedev,capture-rate-hz", &capture_rate))' "$WORK_DIR/src/sound/soc/generic/simple-card.c" 'simple-card DT property read'
require_count 1 'if (substream->stream != SNDRV_PCM_STREAM_CAPTURE)' "$WORK_DIR/src/sound/soc/generic/simple-card.c" 'capture-only policy branch'

MOD_DIR="$WORK_DIR/module"
mkdir -p "$MOD_DIR"
cp "$WORK_DIR/src/sound/soc/sunxi/sun4i-i2s.c" "$MOD_DIR/"
cp "$WORK_DIR/src/sound/soc/codecs/dmic.c" "$MOD_DIR/"
cp "$WORK_DIR/src/sound/soc/generic/simple-card.c" "$MOD_DIR/"
cat > "$MOD_DIR/Makefile" <<'KBUILD_EOF'
obj-m += sun4i-i2s.o
obj-m += snd-soc-dmic.o
snd-soc-dmic-y := dmic.o
obj-m += snd-soc-simple-card.o
snd-soc-simple-card-y := simple-card.o
KBUILD_EOF

export ARCH=arm
export CROSS_COMPILE="$CROSS_COMPILE_PREFIX"
export KBUILD_BUILD_USER=icubedev
export KBUILD_BUILD_HOST=bpi-zero-clock
export KBUILD_BUILD_TIMESTAMP='2026-08-17 00:00:00 +0000'
export SOURCE_DATE_EPOCH=1786924800

make -C "$HDR_DIR" M="$MOD_DIR" modules

for ko in sun4i-i2s.ko snd-soc-dmic.ko snd-soc-simple-card.ko; do
    [ -s "$MOD_DIR/$ko" ] || { echo "ERROR: expected module not built: $ko" >&2; exit 1; }
    VM="$(modinfo -F vermagic "$MOD_DIR/$ko" | awk '{print $1}')"
    [ "$VM" = "$ABI" ] || { echo "ERROR: $ko vermagic '$VM' != '$ABI'." >&2; exit 1; }
    SIGNER="$(modinfo -F signer "$MOD_DIR/$ko" 2>/dev/null || true)"
    [ -z "$SIGNER" ] || { echo "ERROR: unexpected module signer on $ko: $SIGNER" >&2; exit 1; }
    install -m 0644 "$MOD_DIR/$ko" "$OUT_DIR/$ko"
    echo ">> compressing $ko (xz -3, 1 thread, <=64 MiB)"
    env -u XZ_OPT xz -C crc32 -f -T1 -3 --memlimit-compress=64MiB "$OUT_DIR/$ko"
done

{
    echo "KERNEL_ABI=$ABI"
    echo "DEBIAN_LINUX_VERSION=$DEBIAN_VERSION"
    echo "SOURCE_POLICY=debian-source-plus-reviewed-exact-transforms"
    echo "SOURCE_TRANSFORMER=apply_audio_source_transforms.py"
    sha256sum "$AUDIT_DIR/0001-sun4i-i2s-capture-24khz.patch" "$AUDIT_DIR/0002-simple-card-fixed-capture-rate.patch"
    echo "DMIC_SOURCE=unmodified-debian-${DEBIAN_VERSION}"
    echo "CAPTURE_RATE_HZ=24000"
    sha256sum "$OUT_DIR/sun4i-i2s.ko.xz" "$OUT_DIR/snd-soc-dmic.ko.xz" "$OUT_DIR/snd-soc-simple-card.ko.xz"
} > "$OUT_DIR/SOURCE-BUILD-MANIFEST.txt"

cat "$OUT_DIR/SOURCE-BUILD-MANIFEST.txt"
