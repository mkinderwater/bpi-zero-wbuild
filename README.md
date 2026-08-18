# bpi-zero-clock 1.0.4-preview25

Full-cull release derived from `bpi-zero-wbuild 1.2.6` for Banana Pi M2 Zero.

Preview25 removes dead source/build artifacts and dead firstboot fallback branches without changing the validated clock hardware behavior. Target runtime packages remain Debian-owned and complete: `iwd`, `iproute2`, `iw`, and `alsa-utils` are retained with their required dependencies.

## Hardware baseline

```text
Kernel ABI:        6.12.100+deb13-armmp
Clock target:      bpi-m2-zero-r1
MAX98357A DOUT:    PA20 / pin 40
MAX98357A SD/EN:   PA1  / pin 11
I2S LRCLK:         PA18 / pin 28
I2S BCLK:          PA19 / pin 27
ICS-43434 DOUT:    PA21 / pin 38
Touch:             PA17 / pin 37
Capture:           S32_LE, 2 channels, 24000 Hz
Capture mclk-fs:   256
```

The validated DTB SHA256 is:

```text
0ff283cc75acd93a43722769e3d9771dcb5d629825348593fdd4da605e4b1452
```

The validated MAX98357A codec module SHA256 is:

```text
906b7ef831e199a7ae0dc1aa724251ea1763876298cdcd8564a25e70badaa3c6
```

Capture clocking, ALSA 24 kHz policy and DMA have been hardware-confirmed on the Banana Pi. Physical ICS-43434 signal/noise/channel validation remains pending microphone installation. See `clock/validated/6.12.100+deb13-armmp/HARDWARE-VALIDATION.txt`.

## Audio policy

The builder source-builds three ASoC modules against exact Debian `6.12.100-1` headers/source:

- `sun4i-i2s`: adds `SNDRV_PCM_RATE_24000` to capture capability only;
- `snd-soc-dmic`: stock Debian source;
- `snd-soc-simple-card`: applies the DT-controlled 24000 Hz capture constraint with `snd_pcm_hw_constraint_list()`.

There are no binary `.ko` byte edits. `/etc/asound.conf` routes directly to hardware and contains no `plug`, `rate`, `dmix`, or `dsnoop` conversion layer.

## Appliance policy

- online root expansion on first boot, no reboot;
- fail-closed filesystem growth, no target-side fsck repair;
- stable random `bpi-zero-wbuild-xxx` hostname;
- iwd + systemd-networkd DHCP;
- persistent brcmfmac power save OFF;
- `ip`, `iw`, `arecord`, `aplay`, `amixer`, `alsactl`, `speaker-test` retained;
- ALSA state restore/save services masked;
- SSH client `LANG`/`LC_*` forwarding removed rather than installing locale packages;
- kernel console `quiet loglevel=3`;
- volatile bounded journald;
- `/tmp` 64 MiB tmpfs;
- systemd hardware watchdog policy;
- exact kernel ABI packages pinned.

Firstboot removes staged firmware/package payloads as soon as their checkpoints are committed. After final provisioning it also removes intermediate resume checkpoints, retaining only the final completion marker and the explicit firstboot/package logs.

## Preview25 cull

- build-host apt installs use `--no-install-recommends`;
- removed obsolete DTB patch generator from the release source;
- removed stale `patches/` placeholder;
- reduced validated artifacts to the two release-critical binaries plus one concise hardware-validation record;
- removed the redundant audio source-build manifest from the target rootfs;
- removed dead `networkctl` and `iw unavailable` fallback branches after Stage 08, because `ip` and `iw` are mandatory and fail-closed;
- reduced `CONFIG.TXT` to required fields plus concise timezone examples.

Bluetooth board HCD firmware remains intentionally present; BlueZ userspace is not installed.

## Build

On Debian 13 armhf or amd64 with Internet access:

```bash
sudo ./build.sh
```

Expected outputs:

```text
out/bpi-zero-clock-1.0.4-preview25-bpi-m2-zero.img
out/bpi-zero-clock-1.0.4-preview25-bpi-m2-zero.img.gz
```
