# Changelog

## 1.0.4-preview36 - Debian 6.12.101 / extlinux migration

- Changes the pinned Debian root image to `debian-trixie-armhf-eiy3bo.bin.gz` dated 2026-08-17 and verifies compressed SHA256 `8cca0fed789a76fef8fb7c8c18bf46ed4d362f9e84d91ffecfe6674e9713c94f`.
- Migrates the exact kernel ABI from `6.12.100+deb13-armmp` to `6.12.101+deb13-armmp`.
- Rebuilds only `snd-soc-max98357a` for 6.12.101 from the hardware-proven playback codec source; Debian stock I2S and simple-card modules remain untouched.
- Generates the clock DTB from the new kernel's stock Banana Pi M2 Zero DTB instead of carrying the previous DTB binary forward.
- Keeps playback-only I2S on PA18/PA19/PA20; PA21 / physical pin 38 remains free and touch remains PA17 / physical pin 37.
- Adopts the new root image's U-Boot extlinux boot path and pins root to final MBR partition 2 by PARTUUID.
- Removes the obsolete boot.cmd/boot.scr/mkimage mutation path.
- Preserves preview35's networking, firstboot, storage, watchdog, diagnostics and playback-only feature cull.
- Physical MAX98357A playback on kernel 6.12.101 is a target validation gate before production promotion.

# bpi-zero-clock changelog

## 1.0.4-preview35 - playback-only cull

- Removes ICS-43434 microphone/capture support.
- Restores exact hardware-validated playback-only DTB from 1.0.3.
- Removes `snd-soc-dmic` from preload policy.
- Deletes capture-only custom ASoC source-build scripts.
- Uses stock Debian `sun4i-i2s` and `snd-soc-simple-card`.
- Keeps exact validated MAX98357A codec module and PA1 5 ms SD/EN behavior.
- Removes ALSA capture/asym routing; default PCM is direct MAX98357A playback.
- Leaves PA21/pin 38 free; touch remains PA17/pin 37.
- Retains preview34 platform/network/firstboot/diagnostic policy.


## 1.0.4-preview34 - field diagnostics, CPU observation only

- Adds `/usr/local/sbin/bpi-zero-diag` for identity, firstboot, Wi-Fi/IP, CPU thermal/frequency, load and focused kernel diagnostics.
- Adds the current `wlan0` IPv4 address to the local agetty issue/login display with `\4{wlan0}`.
- Persists concise firstboot state in `/var/lib/bpi-zero-wbuild-status`.
- Keeps `quiet loglevel=4`; no additional kernel console chatter is enabled.
- Makes no CPU governor, OPP, frequency-limit or DTB changes; the Preview 33 validated DTB hash is retained exactly.

## 1.0.4-preview33 - image-owned Wi-Fi firmware

- Installs the validated BCM43430/Cypress firmware, board-qualified Banana Pi M2 Zero NVRAM, CLM payloads and regulatory database directly into `/usr/lib/firmware` while the root image is mounted during build.
- Removes Wi-Fi/regulatory payload staging from `/root`, the firstboot firmware checkpoint, the firstboot copy/cleanup stage, and its normal-path `brcmfmac` unload/reload.
- Retains the controlled `brcmfmac` reload only in the existing Wi-Fi recovery retry.
- Renumbers subsequent firstboot stages after removing the firmware stage.
- Retains preview32 persistent headless debconf, preview31 machine-ID persistence/loglevel 4, and validated audio/watchdog/storage/networking policy.

## 1.0.4-preview32 - persistent headless debconf

- After Wi-Fi/DHCP succeeds, firstboot Stage 15 persists `debconf/frontend=Noninteractive` with `debconf-set-selections`.
- Future manual and automated package operations, including after reboot, no longer probe missing Dialog or Perl Readline frontends.
- Retains the two command-scoped noninteractive Stage 08 `dpkg` calls because they bootstrap iwd/networking before the persistent post-Wi-Fi policy can be written.
- Does not persist `DEBIAN_FRONTEND` in environment or shell configuration and does not install Dialog/Perl modules solely to silence debconf.
- Retains preview31 machine-ID persistence, `quiet loglevel=4`, and all validated audio, watchdog, storage and networking behavior.

## 1.0.4-preview31 - persistent identity + diagnostic logging

- Firstboot Stage 05 now runs `systemd-machine-id-setup`, explicitly persisting a unique machine ID when the release image starts with an empty `/etc/machine-id`.
- Keeps `/var/lib/dbus/machine-id` linked to `/etc/machine-id`.
- Removes redundant fixed-component verification after known-good commands, while retaining input, storage-safety, resume, package-failure and Wi-Fi/DHCP checks.
- Raises the quiet kernel console from `loglevel=3` to `loglevel=4` so kernel warnings are available during diagnosis without normal informational chatter.
- Runtime audio, watchdog, storage and networking policy otherwise remain unchanged from preview30.

## 1.0.4-preview30 - clone-safe machine identity

- Clears the Debian base image's populated `/etc/machine-id` during final image construction.
- Replaces `/var/lib/dbus/machine-id` with a symlink to `/etc/machine-id` so the legacy D-Bus fallback cannot preserve a cloned identity.
- Leaves `/etc/machine-id` present and empty so systemd generates and persists a fresh ID on first boot.
- Adds build invariants and release metadata for the machine-ID policy.
- Keeps preview29's validated watchdog, SSH/root-user, networking, storage, kernel and native 24 kHz audio behavior unchanged.

## 1.0.4-preview29 - sunxi watchdog timeout fix

- Changes `RuntimeWatchdogSec` from 30 seconds to the Allwinner `sunxi-wdt` hardware-supported 16-second maximum.
- Changes `RebootWatchdogSec` from 2 minutes to 16 seconds so reboot/shutdown protection uses a timeout the same watchdog can actually accept.
- Updates release metadata and regression checks to enforce the 16-second runtime/reboot watchdog policy and reject the old invalid values.
- SSH/root-user policy and all preview28 networking, storage, kernel and native 24 kHz audio behavior are unchanged.

## 1.0.4-preview28 - validated Debian base mirror

- Changes the default `DEBIAN_URL` to `https://download.icubedev.com/debian-trixie-armhf-ner4uz.bin.gz`.
- Keeps the exact same `debian-trixie-armhf-ner4uz.bin.gz` base-image identity and existing `gzip -t` cache-integrity policy.
- The withdrawn Johang dated Debian URL is no longer the default and is regression-tested as absent.
- Boot-image source, runtime package set, firstboot, kernel/audio artifacts, networking and appliance policy are unchanged from preview27.

## 1.0.4-preview27 - explicit builder TLS/unzip prerequisites

- Adds `ca-certificates` as an explicit build-host dependency in both HTTPS-download builder paths.
- If the package exists but `/etc/ssl/certs/ca-certificates.crt` is missing, regenerates the bundle once with `update-ca-certificates`, then fails closed if it is still unusable.
- Adds `unzip` as an explicit main builder-host dependency.
- Keeps TLS certificate verification mandatory; no `curl -k`/`--insecure` fallback.
- Produced clock runtime/package set is unchanged from preview26.

## 1.0.4-preview26 - post-cull cleanup/correctness

- Keeps build-cache `*.source-url` metadata on the build host instead of staging it into `/root`. Installed preview25 vetting found 108 KiB of otherwise dead URL metadata after the `.deb` archives had been correctly removed.
- Stops staging the duplicate `/root/bpi-zero-wbuild-firstboot.service`; the live unit is installed directly under `/etc/systemd/system`.
- Removes the unit-level `ConditionPathExists=!/var/lib/bpi-zero-wbuild-firstboot.done`. The script already owns completion-marker handling, so this makes its interrupted-completion recovery branch reachable if power is lost after the `.done` marker is committed but before the service is disabled.
- Keeps `/root/bpi-zero-wbuild-firstboot.sh`, the live firstboot unit, final `.done` marker and logs for deterministic recovery/serviceability.
- Runtime packages and validated storage/network/audio behavior are unchanged from preview25.

## 1.0.4-preview25 - full cull

- Adds `--no-install-recommends` to both automated build-host `apt-get install` paths. Required tools remain explicitly requested; unrelated recommended packages are no longer pulled onto the builder.
- Removes dead `scripts/patch_audio_capture_dtb.py`; the production DTB is already fixed and hash-validated. Tests retain a read-only minimal FDT parser.
- Removes the stale `patches/` placeholder and old unconsumed validated-source/provenance files.
- Consolidates hardware provenance into `HARDWARE-VALIDATION.txt`; the release-critical validated payload remains the MAX98357A `.ko` and fixed DTB.
- Stops copying the redundant audio source-build manifest into the target rootfs. Release metadata already records module source policy and hashes.
- Removes firstboot `networkctl` and `iw unavailable` fallback branches that are unreachable because Stage 08 fails closed unless `ip` and `iw` are installed.
- Removes intermediate firstboot checkpoints after successful final provisioning while retaining the final completion marker and logs.
- Reduces `CONFIG.TXT` from the exhaustive timezone catalogue to required fields plus concise examples. Any valid IANA timezone can still be entered directly.
- Runtime package set and validated audio/network behavior are otherwise unchanged from preview24.

## 1.0.4-preview24

- Makes unattended build-host package installation use command-scoped noninteractive debconf, eliminating Readline/Term::ReadLine fallback warnings without adding Perl modules or persistent debconf policy.
- Target runtime package set and preview23 hardware/audio behavior unchanged.

## 1.0.4-preview23

- Adds hardware-proven capture `mclk-fs = <256>`; 24 kHz S32_LE stereo `hw_params`, live RUNNING state and exact DMA byte counts validated on Banana Pi M2 Zero.
- Makes CONFIG.TXT reading fail-safe and guarantees config-partition unmount on error.
- Tracks/removes only the firstboot-owned stale iwd profile after SSID correction.
- Makes required ALSA masks and iwd/networkd/SSH enablement fail-closed.
- Removes staged firmware and `.deb` payloads after checkpoint commit.
- Pins the exact validated kernel image/header ABI packages.

## 1.0.4-preview22

- Scopes noninteractive debconf to firstboot `dpkg --unpack` and `dpkg --configure -a`; no locale/Perl Readline packages added.

## 1.0.4-preview21

- Removes the bundled microphone validator; validation becomes post-image/external.
- Keeps Debian `alsa-utils` for standard field diagnostics.

## 1.0.4-preview20

- Adds offline Debian `alsa-utils 1.2.14-1` plus required runtime dependencies.
- Masks Debian ALSA state restore/save services so appliance audio state remains application-owned.

## 1.0.4-preview19

- Adds `gzip -t` integrity validation and automatic redownload for corrupt cached base-image payloads.

## 1.0.4-preview18

- Keeps locale footprint minimal and removes SSH forwarding of client `LANG`/`LC_*` values instead of installing locale-generation packages.
