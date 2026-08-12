# bpi-zero-clock 1.0.3

Clock-ready Banana Pi M2 Zero image builder derived from `bpi-zero-wbuild 1.2.6`.

## Why This Project Exists

This builder turns cheap, widely available Banana Pi M2 Zero hardware into reliable, headless appliances (clocks, displays, sensors) without standard vendor friction.

* **Fixing Abandoned Vendor Software:** Stock vendor images ship with 2019-era kernels, dead links, and broken driver paths. `bpi-zero-wbuild` pulls current Debian Trixie and active firmware at build time.
* **Headless Out-of-Box Wi-Fi:** Eliminates the need for a serial console, monitor, or USB Ethernet. A FAT32 partition (`BPIWBUILD`) lets you configure Wi-Fi, country code, and timezone by editing `CONFIG.TXT` on any PC before booting.
* **Cost & Availability Alternative:** Bypasses Raspberry Pi Zero 2 W supply shortages and scalper pricing by putting affordable $15 clone boards sitting in drawers back to work.
* **Validated Hardware Audio:** Provides pop-free, zero-hiss I2S audio via MAX98357A out of the box without manual kernel hacks or DTB tinkering.

## Hardware-Validated Audio Release

Version 1.0.3 ships the MAX98357A module and Device Tree verified on physical hardware (2026-08-11). Playback tests confirmed no startup pop or trailing hiss.

**Validation Parameters:**
```text
Kernel ABI:              6.12.100+deb13-armmp
MAX98357A module SHA256: 906b7ef831e199a7ae0dc1aa724251ea1763876298cdcd8564a25e70badaa3c6
Clock DTB SHA256:        7d54132d9b707ec62d5b72e08cd329b557a92940664e48164b5b8a8cfd5fcaff
I2S0 Pinout:             PA18 / PA19 / PA20
MAX98357A SD/EN:         PA1 (owned by snd_soc_max98357a via sdmode-gpios)
sdmode-delay:            5 ms
mclk-fs:                 256
Codec compatible:        maxim,max98357a
```
*Note: Legacy `linux,spdif-dit` dummy codec and `mk-clock-amp-gate` userspace PA1 controls are retired.*

## Release Model

Validated artifacts are locked in `clock/validated/6.12.100+deb13-armmp/`.

During execution, `build.sh` validates the kernel ABI, module vermagic, OF alias, and SHA256 checksums, halting if any element differs. Inherits `bpi-zero-wbuild 1.2.6` Wi-Fi, AP6212 Bluetooth firmware, and auto root-fs expansion.

## Build

Run on a Linux host:

```bash
sudo ./build.sh
```

**Output Artifacts:**
* `out/bpi-zero-clock-1.0.3-bpi-m2-zero.img`
* `out/bpi-zero-clock-1.0.3-bpi-m2-zero.img.gz`

## Expected Runtime State

Verify hardware state after boot:

| Component | Expected State |
| --- | --- |
| **Driver Module** | `snd_soc_max98357a` loaded |
| **Legacy Driver** | `snd_soc_spdif_tx` absent |
| **ALSA Card** | `MAX98357A` |
| **PCM Device** | `1c22000.i2s-HiFi HiFi-0` |
| **Amp Gate** | `mk-clock-amp-gate` inactive/absent |
