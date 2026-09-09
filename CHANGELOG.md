# 3.12-trixie-minimal-hw

- Final card image is now streamed directly to `.img.gz`; no assembled raw `.img` is written.
- Retains the seekable `debian.bin` working image because the root filesystem must be mounted and modified.
- Writes the compressed release atomically through a temporary file and validates it with `gzip -t` before publication.
- Emits only the `.img.gz` SHA-256.

## 3.12-trixie-minimal-hw

- Accept Johang Trixie root images that intentionally omit `/` from `/etc/fstab`.
- Verify the mounted Debian root filesystem is ext4.
- If fstab has no root entry, create `PARTUUID=<final>-02 / ext4 defaults 0 1`.
- Rewrite one existing root entry as before; reject multiple root entries.

# Changelog

## 3.12-trixie-minimal-hw

- Default Debian root moved to `2026-09-07/debian-trixie-armhf-pheiz3.bin.gz`.
- Removed Debian root-image SHA pin and post-decompression root hashing by design; HTTPS source + gzip integrity are trusted.
- Removed exact `6.12.101+deb13-armmp` requirement.
- Kernel ABI, kernel package/version, DTB path and MAX98357A build target are derived from the mounted Debian rootfs.
- `BASE=` release identity is derived from the configured Debian image filename.
- Future Trixie root images can be selected by overriding only `DEBIAN_URL`; there is no automatic latest discovery.
- Debian Snapshot fallback date for kernel headers is derived from the configured Johang image date when available.
- Removed the hardcoded GCC 14 rejection; the selected compiler is recorded and module vermagic/module resolution remain validated.

# Changelog

## 3.8-k101-minimal-hw

- Replace fixed-width/modulus GPIO scanning with a phandle-aware walker that resolves each controller's `#gpio-cells`; a one-cell `<0>` placeholder no longer hides a following GPIO specifier.
- Use the same strict GPIO parser in both application-ownership and platform-conflict validators; harmonize GPIO-hog parsing against the owning controller's `#gpio-cells`.
- Fix the dead pin-group-path guard and only resolve pin groups from effectively enabled controller subtrees.
- Add regression tests for `cs-gpios = <0>, <&pio 0 7 0>` and a mixed PA11 claim conflicting with I2C0.
- Add a synchronous `ExecStartPre` pre-login security phase: validate/set root password, snapshot/remove inherited human accounts, generate unique SSH host keys, and validate sshd before getty/SSH are released.
- Remove inherited SSH host keys at image build time.
- Keep long resize/network/package provisioning `Type=simple` and non-blocking after the pre-login barrier.
- Keep an EXIT cleanup trap active for the configuration mount so SIGTERM/runtime timeout cannot leave BPIWBUILD mounted rw.

## 3.7-k101-minimal-hw

- Create and pin `/aliases:spi0` and `/aliases:i2c0` before validating documented bus endpoints.
- Resolve pinctrl groups across both main PIO and R_PIO controllers; strict phandle enforcement applies to image-owned SPI/I2C/I2S paths while unrelated unresolved upstream groups no longer abort the build.
- Check all-controller enabled default pinmux ownership for duplicate pin claims.
- Restrict direct main-PIO GPIO parsing to complete 16-byte sunxi GPIO specifiers.
- Make final FAT credential scrub tolerant of a missing CONFIG.TXT or missing credential keys after the ready-to-finalize marker, remove stale scrub temp files, scope umask, and mount FAT with `sync`.
- Scope SSH password authentication to root; later-created users do not inherit password authentication.
- Validate SSH configuration, require enablement, but do not abort provisioning solely because ssh.service cannot start transiently.
- Change firstboot to `Type=simple` with `RuntimeMaxSec=30min` so login startup is not blocked by the full provisioning run.
- Close DTB input cleanly and document post-provisioning Wi-Fi changes through `iwctl`.

## 3.6-k101-minimal-hw

- Establish and validate the root password before any partition resize or inherited-account deletion.
- Snapshot UID 1000-59999 account names before `userdel` and fail if any inherited human login remains.
- Blank `PSK=` and `ROOT_PASSWORD=` from FAT32 `CONFIG.TXT` after successful provisioning with power-loss-resumable finalization.
- Enable SSH as soon as root authentication and host keys are valid.
- Quote all Wi-Fi interface command/path uses; re-mask competing Wi-Fi managers during radio recovery; use `networkctl reload` for `.network` changes.
- Restore Debian epoch stripping for MAX98357A archive filenames while validating full dpkg versions.
- Add an explicit `*-armmp` ABI shape guard to the parameterized MAX98357A builder.
- Enforce `aliases:spi0` and `aliases:i2c0`, pinning `/dev/spidev0.0` and `/dev/i2c-0` numbering.
- Add platform pin-contract validation for PA1, PA11/PA12, PA18/PA19/PA20, SPI0 active mux and cross-owner pin conflicts.
- Make protected-GPIO checks ancestor-status aware.
- Accept valid three-field `/etc/fstab` entries.
- Harden the FDT parser against malformed header/structure bounds and unmatched nodes.
- Add explicit timeouts around `partx`, `resize2fs`, dpkg unpack/configure and a 30-minute firstboot service ceiling.

## 3.5-k101-minimal-hw

- Retained root as the only human login account; removed the `bpi-zero-wbuild` login user and published default passwords.
- Added operator-supplied `ROOT_PASSWORD` to `CONFIG.TXT`.
- Restored I2C0 and `i2c-dev` for the adult-clock AHT10; expected endpoint is `/dev/i2c-0`.
- Fixed `fetch_gzip` retries under `set -e`.
- Made `patch_mbr.py` reject a boot image shorter than its declared pre-partition area and assert bytes 0-445 remain unchanged.
- Derive root PARTUUID from the patched MBR, not the input boot image.
- Added fail-closed `/etc/fstab` validation/rewrite against the final root PARTUUID.
- Replaced hardcoded FAT32 volume ID and zero `BPB_HiddSec` with the image disk signature and actual config-partition start LBA.
- Preserve Wi-Fi passphrase whitespace; escape backslashes for iwd; create the profile as mode `0600` before writing it.
- Replaced hardcoded `wlan0` use with brcmfmac interface discovery and radio wait/recovery.
- Disable and mask NetworkManager, ConnMan and wpa_supplicant paths before iwd/networkd owns Wi-Fi.
- Added final-DTB enforcement for unclaimed PA0/PA2/PA7/PA8/PA9/PA17, including GPIO consumer, GPIO-hog and active pinctrl claims.
- Added Bluetooth DT topology validation and module-resolution checks for `hci_uart` and `btbcm`.
- MAX98357A module build now receives ABI and Debian kernel version from the mounted target rootfs; main/security archives are tried before pinned snapshots.
- Restored extlinux and U-Boot post-write verification.
- Restored volatile journald policy and removes any build-host persistent journal before image release.
- Removed application-unit coupling from `spidev.service`.
- Removed unused host `xz`/`unzip` requirements.
- Release metadata now records boot/root hashes, target Debian kernel package version and the uncompressed root image SHA-256.
- Version naming is now consistent: `3.5-k101-minimal-hw`.

## 3.4-k101-minimal-hw

- Reduced the base image to required board/platform functions.
- Retained Wi-Fi, Bluetooth firmware, resize, SPI0 and playback-only MAX98357A/I2S support.
- Removed image-owned RGB/PWM behavior and unrelated application policy.
