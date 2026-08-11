#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/max98357a-src"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 KERNEL_ABI KERNEL_HEADERS_DIR [OUTPUT_DIR]" >&2
    echo "Example: $0 6.12.100+deb13-armmp /usr/src/linux-headers-6.12.100+deb13-armmp" >&2
    exit 2
fi

ABI="$1"
HEADERS="$2"
OUT="${3:-$HERE/prebuilt/$ABI}"

[ -d "$HEADERS" ] || { echo "ERROR: kernel headers not found: $HEADERS" >&2; exit 1; }
[ -f "$HEADERS/Makefile" ] || { echo "ERROR: not a kernel header/build tree: $HEADERS" >&2; exit 1; }

ARCH_ARGS=()
if [ "$(uname -m)" != "armv7l" ] && [ "$(uname -m)" != "armhf" ]; then
    if command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
        ARCH_ARGS=(ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-)
    else
        echo "ERROR: non-ARM host requires arm-linux-gnueabihf-gcc." >&2
        exit 1
    fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -a "$SRC/." "$TMP/"
make -C "$HEADERS" M="$TMP" "${ARCH_ARGS[@]}" modules

KO="$TMP/snd-soc-max98357a.ko"
[ -s "$KO" ] || { echo "ERROR: module was not produced." >&2; exit 1; }

if command -v modinfo >/dev/null 2>&1; then
    VM="$(modinfo -F vermagic "$KO" | awk '{print $1}')"
    [ "$VM" = "$ABI" ] || {
        echo "ERROR: module vermagic '$VM' does not match '$ABI'." >&2
        exit 1
    }
fi

mkdir -p "$OUT"
install -m 0644 "$KO" "$OUT/snd-soc-max98357a.ko"
sha256sum "$OUT/snd-soc-max98357a.ko" > "$OUT/snd-soc-max98357a.ko.sha256"
echo "Built: $OUT/snd-soc-max98357a.ko"
