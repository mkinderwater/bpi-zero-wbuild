# bpi-zero-clock 1.0.3

Clock-ready Banana Pi M2 Zero image builder derived from `bpi-zero-wbuild 1.2.6`.

## Why this thing exists

Nobody needed another SD card image builder for fun. This one got built because
the alternatives were either broken, stale, or a rip-off, and there's no good
reason to have a $15 board sitting in a drawer doing nothing.

**The official images are old and they show it.** Whatever Sinovoip or the
usual third-party Banana Pi image mirrors are shipping, it's not been touched
in a good while. Old kernels, old firmware blobs, old everything. You flash
it, boot it, and immediately start fighting driver mismatches and dead links
trying to chase down a firmware file from 2019. That's not a "weekend
project," that's a part-time job. `bpi-zero-wbuild` pulls a current Debian
Trixie base and current board firmware every time it builds, so you're not
starting from a hole.

**There was no easy way to get Wi-Fi onto the thing.** Stock images expect
you to either hook up a serial console, plug in a monitor and keyboard, or SSH
in over Ethernet you probably don't have wired up to a headless board sitting
on a shelf. That's a non-starter for a lot of builds. So this image carves
out a small FAT32 partition — `BPIWBUILD` — right on the SD card. Pull the
card, drop it in any computer (Windows, Mac, Linux, doesn't matter), open
`CONFIG.TXT` in a plain text editor, type in your SSID and password, save it,
put the card back in the board, apply power. No console cable, no monitor,
no keyboard, no fuss. That one file is also where you set your country code
and timezone. It's about as close to "it just works" as a $15 board gets.

**This is about giving old and cheap hardware a real job, not letting it rot
in a drawer.** A Banana Pi M2 Zero is a clone-class board — cheap, small,
and, if you're honest with yourself, kind of janky compared to the real
thing. But it's also sitting around unused in a lot of parts bins, and
there's no shame in putting a $15 board to work running a clock, a display,
a sensor node, whatever, instead of throwing it out or leaving it in a
drawer. Good tools get used. A board doing a real job beats a board doing
nothing every single time.

**And frankly, Raspberry Pi Zero 2 W boards are stupid expensive for what
they are right now.** Between scalpers, allocation limits, and general
supply nonsense, paying real money — sometimes real *stupid* money — for a
board the size of a stick of gum to blink an LED or run a clock is a hard
sell when a Banana Pi clone does the same job for a fraction of the price.
This project exists so the cheaper, more available hardware isn't a second-
class citizen. Get it a current OS, get it easy Wi-Fi setup, get it working
audio out for the clock build, and it'll do the job just as well as the
board that costs three or four times as much and is sold out everywhere
anyway.

None of that is glamorous. It's just fixing the actual, practical problems
that show up when you try to use this hardware for something real: old
software, no easy way to get online, and a price gap on the "official"
alternative that doesn't make sense for a hobby build. That's the whole
point of this repo.

## Hardware-validated audio release

Version 1.0.3 ships the exact MAX98357A module and Device Tree that passed the physical Banana Pi M2 Zero audio test on 2026-08-11.

Validated set:

```text
Kernel ABI:              6.12.100+deb13-armmp
MAX98357A module SHA256: 906b7ef831e199a7ae0dc1aa724251ea1763876298cdcd8564a25e70badaa3c6
Clock DTB SHA256:        7d54132d9b707ec62d5b72e08cd329b557a92940664e48164b5b8a8cfd5fcaff
I2S0:                    PA18 / PA19 / PA20
MAX98357A SD/EN:         PA1
sdmode-delay:            5 ms
mclk-fs:                 256
Codec compatible:        maxim,max98357a
```

The direct playback validation used one second of digital silence, a two-second 440 Hz tone, then one second of digital silence. Playback had no startup pop and no trailing hiss.

The earlier `linux,spdif-dit` dummy-codec path and `mk-clock-amp-gate` userspace PA1 control are retired. PA1 is owned by `snd_soc_max98357a` through `sdmode-gpios`.

## Release model

The validated module and DTB are immutable release artifacts under:

```text
clock/validated/6.12.100+deb13-armmp/
```

`build.sh` verifies the kernel ABI, module vermagic, OF alias, module SHA256 and DTB SHA256. The build stops if any part of the tested set differs.

The image continues to inherit the `bpi-zero-wbuild 1.2.6` Wi-Fi, board-qualified AP6212 Bluetooth firmware, and online root-filesystem resize behavior. Bluetooth userspace remains application-owned.

## Build

On a Linux build host:

```bash
sudo ./build.sh
```

Output:

```text
out/bpi-zero-clock-1.0.3-bpi-m2-zero.img
out/bpi-zero-clock-1.0.3-bpi-m2-zero.img.gz
```

## Expected runtime audio state

```text
snd_soc_max98357a loaded
snd_soc_spdif_tx absent
ALSA card: MAX98357A
PCM: 1c22000.i2s-HiFi HiFi-0
mk-clock-amp-gate inactive/absent
```

The clock application owns userspace application packages. The image owns the board/kernel hardware layer.
