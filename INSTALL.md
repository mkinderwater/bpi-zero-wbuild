# Build and install

## Build

Run as root on Debian:

```bash
sudo ./build.sh
```

The builder creates:

- `out/bpi-zero-wbuild-3.12-trixie-minimal-hw-bpi-m2-zero.img.gz`
- SHA-256 for the compressed image

The builder streams the final card layout directly into gzip. It does not create a full raw `.img` first. If a raw image is ever needed, decompress the `.img.gz` after the build.

The build is intentionally strict. The Debian kernel ABI itself is not hardcoded; it is discovered from the configured Trixie rootfs. A malformed MBR, unsupported fstab, claimed application GPIO, unresolved kernel module or invalid hardware DT contract stops the build.

## Configure

After flashing, open the FAT32 `BPIWBUILD` partition and edit `CONFIG.TXT`:

```text
SSID=your network
PSK=your Wi-Fi passphrase
COUNTRY=CA
HIDDEN=false
TIMEZONE=America/Edmonton
ROOT_PASSWORD=choose-a-unique-password
```

`ROOT_PASSWORD` must be 12 to 64 characters. `root` is the only human login account created/retained by the platform provisioning step.

The Wi-Fi passphrase is consumed exactly as written after `PSK=`. Leading/trailing spaces are not stripped. After successful firstboot, `PSK=` and `ROOT_PASSWORD=` are blanked on the FAT32 partition. The root-only iwd profile remains mode `0600`.

## First boot

First boot:

1. pre-login barrier reads `ROOT_PASSWORD`, sets root, removes inherited UID 1000-59999 accounts, generates unique SSH host keys, validates sshd, and only then releases getty/SSH
2. reads Wi-Fi/timezone settings
3. expands the root partition and ext4 filesystem online
4. generates the unique machine ID/hostname
5. installs the pinned Wi-Fi runtime and confirms SSH availability
6. creates the iwd profile with mode `0600`
7. disables/masks competing Wi-Fi managers and keeps brcmfmac power save disabled
8. waits for the brcmfmac radio and detects its actual interface name
9. obtains IPv4 by DHCP, with one radio recovery attempt
10. blanks `PSK=` and `ROOT_PASSWORD=` from FAT32 `CONFIG.TXT` and commits completion

The synchronous pre-login phase has a 2-minute `TimeoutStartSec`. Once it succeeds, console/SSH may run while the remaining `Type=simple` provisioning continues, bounded by `RuntimeMaxSec=30min`.

## Expected platform endpoints

After provisioning:

- `/dev/spidev0.0`
- `/dev/i2c-0`
- `/dev/gpiochip0`
- ALSA card containing `MAX98357A`
- `/proc/device-tree/max98357a/compatible` = `maxim,max98357a`
- MAX98357A `sdmode-delay` = 5 ms
- `simple-audio-card,mclk-fs` = 256

PA0, PA2, PA7, PA8, PA9 and PA17 remain available to the application.

## Changing Wi-Fi after provisioning

`CONFIG.TXT` is only a firstboot input. After successful provisioning its `PSK=` and `ROOT_PASSWORD=` values are blanked and firstboot disables itself. Root/console login can be used while the later resize/network provisioning stages continue in the background; the destructive account sweep is already complete before login is released. To change Wi-Fi later, log in as root and use iwd directly:

```bash
iwctl device list
iwctl station <wifi-interface> scan
iwctl station <wifi-interface> get-networks
iwctl station <wifi-interface> connect "NEW SSID"
```

`iwctl` stores the new profile under `/var/lib/iwd`. Use `iwctl known-networks list` and `iwctl known-networks <name> forget` to remove an old network. Re-enabling firstboot is not the normal Wi-Fi-change path.

## Using a later Trixie root image

The default `DEBIAN_URL` points to the 2026-09-07 `pheiz3` armhf image. The Debian root payload is trusted from that configured HTTPS URL and is not SHA-pinned. To test a later Trixie image without editing source:

```bash
sudo env DEBIAN_URL=https://dl.sd-card-images.johang.se/debians/YYYY-MM-DD/debian-trixie-armhf-NAME.bin.gz ./build.sh
```

The builder does not select `latest`. It derives the kernel ABI and package version from the downloaded image, rebuilds MAX98357A for that ABI, patches the matching Banana Pi DTB, and runs the same hardware validators before emitting an image.
