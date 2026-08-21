#!/usr/bin/env bash
# Apply the clock's playback-only hardware contract to the stock BPI M2 Zero DTB.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 STOCK.dtb OUT.dtb" >&2; exit 2; }
IN="$1"
OUT="$2"
[ -s "$IN" ] || { echo "ERROR: stock DTB missing: $IN" >&2; exit 1; }
for tool in fdtget fdtput; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required." >&2; exit 1; }
done
cp -f "$IN" "$OUT"

GPIO_PHANDLE="$(fdtget -t x "$OUT" /soc/pinctrl@1c20800 phandle)"
[ -n "$GPIO_PHANDLE" ] || { echo "ERROR: pinctrl GPIO phandle unavailable." >&2; exit 1; }

# Stable private phandles chosen outside the stock DTB's normal low range.
I2S_PH=70000001
I2S_PINS_PH=70000002
CODEC_PH=70000003
CPU_PH=70000004

# Release identity markers used by the application hardware verifier.
fdtput -t s "$OUT" / bpi-zero-clock,hardware bpi-m2-zero-r1
fdtput -t s "$OUT" / mk-clock-adult,hardware bpi-m2-zero-r1
fdtput -t s "$OUT" / bpi-zero-clock,audio-codec maxim,max98357a

# SPI0 for the SSD1322 userspace driver.
fdtput -t s "$OUT" /soc/spi@1c68000 status okay
fdtput -c "$OUT" /soc/spi@1c68000/mk-piclock-oled@0
fdtput -t s "$OUT" /soc/spi@1c68000/mk-piclock-oled@0 compatible mk,piclock-oled
fdtput -t x "$OUT" /soc/spi@1c68000/mk-piclock-oled@0 reg 0
fdtput -t x "$OUT" /soc/spi@1c68000/mk-piclock-oled@0 spi-max-frequency 3d0900
fdtput -t s "$OUT" /soc/spi@1c68000/mk-piclock-oled@0 status okay

# I2C0 for AHT10.
fdtput -t s "$OUT" /soc/i2c@1c2ac00 status okay

# Playback-only I2S0. PA21 is deliberately absent/free.
fdtput -c "$OUT" /soc/pinctrl@1c20800/mk-piclock-i2s0-pins
fdtput -t s "$OUT" /soc/pinctrl@1c20800/mk-piclock-i2s0-pins pins PA18 PA19 PA20
fdtput -t s "$OUT" /soc/pinctrl@1c20800/mk-piclock-i2s0-pins function i2s0
fdtput -t x "$OUT" /soc/pinctrl@1c20800/mk-piclock-i2s0-pins phandle "$I2S_PINS_PH"
fdtput -t x "$OUT" /soc/pinctrl@1c20800/mk-piclock-i2s0-pins linux,phandle "$I2S_PINS_PH"

fdtput -t s "$OUT" /soc/i2s@1c22000 status okay
fdtput -t x "$OUT" /soc/i2s@1c22000 phandle "$I2S_PH"
fdtput -t x "$OUT" /soc/i2s@1c22000 linux,phandle "$I2S_PH"
fdtput -t s "$OUT" /soc/i2s@1c22000 pinctrl-names default
fdtput -t x "$OUT" /soc/i2s@1c22000 pinctrl-0 "$I2S_PINS_PH"

# MAX98357A codec. PA1 is SD/EN, initially low, with 5 ms delayed enable.
fdtput -c "$OUT" /max98357a
fdtput -t s "$OUT" /max98357a status okay
fdtput -t x "$OUT" /max98357a phandle "$CODEC_PH"
fdtput -t x "$OUT" /max98357a linux,phandle "$CODEC_PH"
fdtput -t x "$OUT" /max98357a sdmode-delay 5
fdtput -t x "$OUT" /max98357a sdmode-gpios "$GPIO_PHANDLE" 0 1 0
fdtput -t x "$OUT" /max98357a '#sound-dai-cells' 0
fdtput -t s "$OUT" /max98357a compatible maxim,max98357a

# Simple-card playback link. No capture/DMIC link exists.
fdtput -c "$OUT" /sound-max98357a
fdtput -t s "$OUT" /sound-max98357a compatible simple-audio-card
fdtput -t s "$OUT" /sound-max98357a simple-audio-card,name MAX98357A
fdtput -t s "$OUT" /sound-max98357a simple-audio-card,format i2s
fdtput -t x "$OUT" /sound-max98357a simple-audio-card,mclk-fs 100
fdtput -t s "$OUT" /sound-max98357a status okay
fdtput -c "$OUT" /sound-max98357a/simple-audio-card,cpu
fdtput -t x "$OUT" /sound-max98357a/simple-audio-card,cpu sound-dai "$I2S_PH"
fdtput -t x "$OUT" /sound-max98357a/simple-audio-card,cpu phandle "$CPU_PH"
fdtput -t x "$OUT" /sound-max98357a/simple-audio-card,cpu linux,phandle "$CPU_PH"
fdtput -c "$OUT" /sound-max98357a/simple-audio-card,codec
fdtput -t x "$OUT" /sound-max98357a/simple-audio-card,codec sound-dai "$CODEC_PH"
fdtput -t x "$OUT" /sound-max98357a simple-audio-card,bitclock-master "$CPU_PH"
fdtput -t x "$OUT" /sound-max98357a simple-audio-card,frame-master "$CPU_PH"

# Structural invariants.
[ "$(fdtget -t s "$OUT" /max98357a compatible)" = "maxim,max98357a" ]
[ "$(fdtget -t x "$OUT" /max98357a sdmode-delay)" = "5" ]
[ "$(fdtget -t s "$OUT" /sound-max98357a simple-audio-card,name)" = "MAX98357A" ]
[ "$(fdtget -t x "$OUT" /sound-max98357a simple-audio-card,mclk-fs)" = "100" ]
[ "$(fdtget -t s "$OUT" /soc/pinctrl@1c20800/mk-piclock-i2s0-pins pins)" = "PA18 PA19 PA20" ]
[ "$(fdtget -t s "$OUT" /soc/spi@1c68000 status)" = "okay" ]
[ "$(fdtget -t s "$OUT" /soc/i2c@1c2ac00 status)" = "okay" ]
[ "$(fdtget -t s "$OUT" /soc/i2s@1c22000 status)" = "okay" ]
