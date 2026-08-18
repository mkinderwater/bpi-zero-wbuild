# Changelog

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
