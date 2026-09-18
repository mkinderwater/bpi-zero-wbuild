# bpi-zero-wbuild 3.13-trixie-minimal-hw

Minimal, reproducible Debian 13 Trixie jump-point image for the Banana Pi BPI-M2 Zero.

The base provides a fixed boot/root/kernel combination, Wi-Fi, AP6212 Bluetooth firmware, GPIO, SPI0, I2C0, playback-only MAX98357A/I2S audio, root expansion, root-only SSH provisioning and visible boot diagnostics. Displays, LEDs, touch inputs, sensors and other application hardware remain downstream-owned.

## Fixed platform

Default Debian root image:

```text
https://dl.sd-card-images.johang.se/debians/2026-09-07/debian-trixie-armhf-pheiz3.bin.gz
```

Release kernel contract:

```text
6.12.107+deb13-armmp
Debian kernel package 6.12.107-1
```

The builder verifies both values from the mounted root and never substitutes a newer kernel automatically. The installed kernel packages are held at `6.12.107-1`. The active BPI-M2 Zero DTB is patched directly for that fixed kernel. There is no DTB diversion layer.

## Base hardware

The base is intentionally headless. The inherited Mali-400 GPU node is disabled because the BPI-M2 Zero board DT does not define the `mali-supply` regulator expected by Lima. Downstream graphics projects may re-enable the GPU with an explicit board power/OPP policy.

- BCM43430 Wi-Fi using iwd + systemd-networkd
- `systemd-resolved` for DHCP-provided DNS
- AP6212 board-specific Bluetooth HCD and validated UART topology
- `/dev/gpiochip0`
- SPI0 as `/dev/spidev0.0`
- I2C0 as `/dev/i2c-0`
- playback-only MAX98357A ALSA endpoint on I2S0
- PA1 reserved for MAX98357A SD/EN with 5 ms sequencing
- PA18/PA19/PA20 reserved for I2S0 LRCLK/BCLK/TX
- root filesystem growth on first boot, retried later if online resize cannot complete
- root-only login and SSH provisioning
- unique SSH host keys and machine identity per flashed device, with hostname derived from machine ID
- verbose kernel/systemd/firstboot output
- tty1 Wi-Fi MAC and dynamic IPv4 banner without delaying the login prompt

## Deterministic inputs

The Banana Pi boot image is bundled in the source archive and SHA-256 verified. Runtime Debian packages are pinned to exact pool filenames and validated after download by package name, version and architecture. If a pinned Debian pool object is unavailable on the live mirror, the builder retries the identical path on the fixed `20260907T235959Z` Debian snapshot.

The Debian `pheiz3` root image is fixed by URL and gzip integrity, but this release does not yet claim a pre-download SHA-256 pin for that upstream gzip because an authoritative digest was not available when the release was assembled. The AP6212 HCD is fixed to Banana Pi firmware commit `6dee7aabad92112e548b551c5acb9611d15e5b33` and size-validated; its pre-download SHA-256 pin is likewise still pending. The builder records the observed SHA-256 of both downloaded objects in `/etc/bpi-zero-wbuild-release` so the exact bytes used by a completed build remain auditable.

Firstboot stages only five runtime packages that are not already in the pinned root:

```text
iwd
libell0
libreadline8t64
readline-common
wireless-regdb
```

The builder requires the pinned root to already contain `systemd-resolved`, consistent with Johang's Debian image. It fails explicitly if that expected DNS component is absent.

`firmware-brcm80211` is downloaded only as a container from which the required BCM43430 firmware files are extracted. It is not installed as a runtime package.

`wireless-regdb` remains one of the five firstboot packages, but its signed regulatory database is also extracted into the offline root image so cfg80211 has `regulatory.db` from the first kernel probe. Firstboot later installs the Debian package normally and hands ownership to the package.

## Wi-Fi

The onboard BPI-M2 Zero Wi-Fi contract is fixed: `brcmfmac` provides `wlan0`. The base loads `brcmfmac` during boot through modules-load, and firstboot writes an iwd profile with `AutoConnect=true` plus a `Name=wlan0` systemd-networkd DHCP rule. There is no custom persistent Wi-Fi manager and no runtime interface discovery. Subsequent association is normal iwd behavior.

Changing networks later means adding or changing iwd profiles under `/var/lib/iwd/`.

## First boot and security

Before powering the board, edit `CONFIG.TXT` on the `BPIWBUILD` partition. `ROOT_PASSWORD` is required and must be 8-64 characters. Wi-Fi SSID/PSK, country, hidden-network setting and timezone are configured there as well.

Login safety is based on account state rather than systemd ordering. At image-build time, inherited human login accounts are removed and root is locked. A local or serial getty may appear immediately, but there are no usable stock credentials. Firstboot attempts root filesystem growth before reading `CONFIG.TXT`, so a configuration mistake cannot leave the card at the seed-image size. It then validates `ROOT_PASSWORD`, replaces the locked root hash and creates unique SSH host keys. If credential validation fails, root remains locked; correct `CONFIG.TXT` and reboot. SSH is not enabled until credentials are valid.

After credential setup, firstboot generates host keys, validates the effective root/password SSH policy, enables SSH and makes a best-effort early start before Wi-Fi provisioning begins. It then installs the five Wi-Fi packages, verifies `wlan0` exists, configures Wi-Fi/DNS and obtains a non-link-local IPv4 address. SSH start and active-state verification become mandatory only after DHCP succeeds. Finalization performs only a non-fatal SSH recheck before credential scrub and completion. Root resize is best effort: if online partition/filesystem growth cannot complete, provisioning continues and firstboot remains enabled to retry the resize on later boots.

After successful provisioning, `PSK=` and `ROOT_PASSWORD=` are blanked from `CONFIG.TXT` with a power-loss-resumable FAT update path.

## Boot policy and tty1

The builder applies and validates the final root PARTUUID in `/boot/extlinux/extlinux.conf` and `/etc/default/u-boot` with:

```text
rw rootwait loglevel=7 systemd.show_status=yes
```

After Wi-Fi and DHCP succeed, firstboot writes the tty1 network banner under `/etc/issue.d/`. Its IPv4 field uses agetty's dynamic `\4{wlan0}` expansion. No pre-getty Wi-Fi status service runs, so early boot does not display a misleading pending/unavailable line.

## Fail-closed build validation

The image build stops on platform inconsistencies including:

- wrong kernel ABI, package version or architecture
- missing/malformed extlinux and U-Boot root policy
- incorrect final root PARTUUID policy
- malformed DTBs
- wrong SPI0 or I2C0 aliases
- pinmux/GPIO conflicts across enabled PIO and R_PIO consumers, including non-PA banks
- wrong MAX98357A PA1 SD/EN claim
- broken Bluetooth topology
- missing required kernel modules
- wrong MAX98357A vermagic, OF alias or audio DT contract
- failed kernel hold setup or unlocked inherited login state
- dirty final ext4 filesystem

## Build

```bash
unzip bpi-zero-wbuild-3.13-trixie-minimal-hw-jumppoint-source.zip
cd bpi-zero-wbuild-3.13-trixie-minimal-hw
sudo ./build.sh
```

## Output

```text
bpi-zero-wbuild-3.13-trixie-minimal-hw-bpi-m2-zero.img.gz
bpi-zero-wbuild-3.13-trixie-minimal-hw-bpi-m2-zero.img.gz.sha256
```

Only compressed output is produced. Final assembly is streamed directly into gzip and validated before publication.
