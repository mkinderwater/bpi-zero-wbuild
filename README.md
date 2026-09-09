# bpi-zero-wbuild 3.12-trixie-minimal-hw

Minimal Banana Pi M2 Zero platform image for the current kid and adult clock applications.

The base image owns only the board functions that must exist before either application starts.

## Platform contract

- Debian 13 Trixie armhf from the configured Johang root-image URL; kernel ABI and Debian kernel package version are discovered from that rootfs
- Wi-Fi firmware, iwd provisioning and IPv4 DHCP
- board-qualified AP6212 Bluetooth firmware and validated Bluetooth DT topology
- first-boot root partition and ext4 filesystem expansion
- one login account only: `root`
- operator-supplied root password from `CONFIG.TXT`; a synchronous pre-login barrier installs it, removes inherited human accounts, and generates unique SSH host keys before getty/SSH are released
- SPI0 alias pinned to `/soc/spi@1c68000`, exposed as `/dev/spidev0.0` for the SSD1322 OLED
- I2C0 alias pinned to `/soc/i2c@1c2ac00`, exposed as `/dev/i2c-0` for the adult-clock AHT10
- stock GPIO controller exposed as `/dev/gpiochip0`
- playback-only I2S0 on PA18/PA19/PA20
- MAX98357A codec support
- PA1 codec-driver SD/EN control with 5 ms delay
- `simple-audio-card,mclk-fs = 256`
- volatile systemd journal to avoid continuous SD-card journal writes

## Application-owned GPIO

The base image does not claim these lines:

- PA0: OLED RESET
- PA2: OLED D/C
- PA7: RGB red
- PA8: RGB green
- PA9: RGB blue
- PA17: touch

The build validates the final DTB and fails if an enabled GPIO consumer, GPIO hog or active pinctrl group claims any of them.

## Deliberately not image-owned

- RGB behavior or PWM
- touch behavior
- OLED D/C or RESET behavior
- application services
- application users/groups or udev policy
- BlueZ userspace
- application ALSA configuration
- application packages

## Build integrity

The builder fails closed on the platform assumptions that previously depended on luck:

- boot input remains SHA-256 pinned; the Debian root image is trusted from its configured HTTPS URL and gzip integrity-checked
- the boot image must contain its complete declared pre-partition area
- the final root PARTUUID is read from the patched MBR
- `/etc/fstab` may omit `/`; the builder creates or rewrites one canonical ext4 root entry using the final PARTUUID
- FAT32 `BPB_HiddSec` equals the actual config-partition LBA
- FAT32 volume ID derives from the image MBR disk signature
- target kernel ABI and Debian package version are read from the mounted root filesystem
- MAX98357A headers are tried from Debian main, security, then pinned snapshots
- final DTB validates SPI/I2C aliases, platform pin ownership/conflicts, I2S/MAX98357A, Bluetooth topology and free application GPIOs
- final extlinux/U-Boot root policy is re-read and verified
- required kernel modules are resolved against the target root filesystem
- the configured Debian source URL, derived base name, and image date are recorded in release metadata

A kernel ABI change is expected to work without editing the builder: the ABI/version are discovered from the rootfs and MAX98357A is rebuilt for that exact kernel. Hardware/DT/module validation still fails closed if a future Trixie image changes an incompatible board contract.

## Firstboot security and recovery

- `root` is configured before partition resize or inherited-account deletion.
- inherited UID 1000-59999 login accounts are snapshotted and removed in `ExecStartPre`, before getty/SSH can start; absence is verified.
- SSH is started after the root password and host keys are valid.
- `PSK=` and `ROOT_PASSWORD=` are blanked from the Windows/macOS-readable FAT32 `CONFIG.TXT` after successful provisioning.
- the final credential scrub is power-loss resumable through a committed ready-to-finalize marker.
- Wi-Fi interface use is quoted, competing managers are masked on initial setup and recovery, and iwd keeps brcmfmac power save disabled.
- firstboot uses `Type=simple` with a synchronous `ExecStartPre` security barrier. Root credentials, inherited-account removal and SSH host keys finish before getty/SSH; resize/network/package provisioning then continues in the background with command-level timeouts and a 30-minute runtime ceiling.

The installed iwd profile remains root-only (`0600`) because Wi-Fi still requires its passphrase. FAT credential blanking is not a forensic erase of flash media.

## GPIO validation

Device Tree `*-gpios` arrays are parsed entry-by-entry using each referenced controller's `#gpio-cells`. Mixed arrays such as `cs-gpios = <0>, <&pio 0 7 0>` are therefore handled correctly: the one-cell native-CS placeholder cannot hide a following GPIO claim. GPIO hog parsing uses the same controller cell count.

## Changing Wi-Fi later

After provisioning, use `iwctl` as root. `CONFIG.TXT` is not a persistent network-management interface and its credential fields are scrubbed during finalization.

## Updating the Debian Trixie base

The default root image is:

```text
https://dl.sd-card-images.johang.se/debians/2026-09-07/debian-trixie-armhf-pheiz3.bin.gz
```

There is no Debian root-image SHA pin. To use a later Trixie armhf image, change `DEBIAN_URL` or supply it as an environment override. The builder derives the base identity, kernel ABI, kernel Debian version, DTB path, and matching MAX98357A build inputs from the downloaded rootfs. It does not discover or follow a `latest` image.


## Compressed-only output

The final SD-card layout is streamed directly from `boot_patched.bin`, `bpiwbuild-config.fat32`, and the modified `debian.bin` through gzip into the release `.img.gz`. The builder does not create a full assembled `.img`, avoiding an unnecessary full-image write and reread. `debian.bin` remains necessary because the ext4 root filesystem must be seekable while mounted and modified during the build.
