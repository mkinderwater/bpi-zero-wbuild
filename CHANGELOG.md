# 3.13 IPv4 detection + SSH availability fix

- Accept both plain IPv4 (`192.168.24.135`) and CIDR (`192.168.24.135/24`) forms from `networkctl status`; the prior parser required CIDR and could report DHCP failure even after systemd-networkd had assigned an address.
- Start and verify `ssh.service` immediately after DHCP/IPv4 is confirmed, before credential scrubbing and finalization.
- On interrupted-finalization resume, ensure SSH is active before cleanup/scrub work so a headless board remains recoverable.

# 3.13 Wi-Fi rollback to polished base

- Roll back the untested Wi-Fi troubleshooting changes made while firstboot was actually stopping at ROOT_PASSWORD validation.
- Restore the polished fixed-board path: brcmfmac from modules-load, fixed wlan0, iwd AutoConnect profile, systemd-networkd DHCP and systemd-resolved.
- Remove explicit driver load/reload, manager masking, power-save/SAE quirks, explicit iwctl connect logic and the iproute2/iw dependency chain.
- Retain the independent fixes: resize-before-password, 8-64 character root password policy, regulatory database preseed, firmware pinning and headless Lima cleanup.

# 3.13 firstboot dependency fix

- Root filesystem growth now runs before CONFIG.TXT/root-password validation, so a bad credential cannot prevent basic storage preparation.
- ROOT_PASSWORD policy is 8-64 characters; a 10-character configured password is valid.
- Credential validation still fails closed before SSH is enabled.

# Changelog

- Restore the proven 3.9 regulatory path: extract `regulatory.db-upstream` and its signature from the pinned wireless-regdb package into the offline root before first boot, while retaining the package for normal Debian ownership after provisioning.
- Restored the proven `ftp.debian.org` source for the pinned `firmware-brcm80211_20250410-2_all.deb` payload used by the older working BPI build, and now verify Debian's published SHA-256 before extracting board firmware.

## 3.13-trixie-minimal-hw

General Banana Pi BPI-M2 Zero Debian 13 Trixie jump-point release.

### Fixed board contract

- Fixed root image: `debian-trixie-armhf-pheiz3`.
- Fixed kernel: `6.12.107+deb13-armmp`, Debian package `6.12.107-1`.
- Onboard Wi-Fi is encoded as the known board fact `brcmfmac` -> `wlan0`; no runtime interface discovery or custom Wi-Fi service.
- AP6212 Bluetooth uses the board-qualified Banana Pi HCD and validated UART topology.
- SPI0, I2C0, GPIO and playback-only I2S0/MAX98357A are part of the base hardware contract.
- MAX98357A reserves PA1 for SD/EN and PA18/PA19/PA20 for I2S0.

### Builder

- Apply and validate final PARTUUID policy in extlinux, U-Boot defaults and fstab.
- Bundle and SHA-256 verify the boot image.
- Pin runtime `.deb` filenames and validate package/version/architecture after download, with a fixed Debian snapshot fallback.
- Stage only five Wi-Fi runtime packages: iwd, libell0, libreadline8t64, readline-common and wireless-regdb.
- Extract BCM43430 firmware from `firmware-brcm80211` without installing that package.
- Build the fixed MAX98357A module only for 6.12.107 and validate module resolution inside the target root.
- Hold the fixed kernel package and patch the active DTB directly.
- Fail on alias, GPIO/pinctrl, Bluetooth, module, root-policy or final ext4 inconsistencies.

### First boot

- Remove inherited human accounts and lock root in the offline image.
- Read `ROOT_PASSWORD` from `CONFIG.TXT`, set root credentials and generate unique SSH host keys.
- Derive the hostname from the generated machine ID.
- Grow the root filesystem best-effort; resize failure never blocks Wi-Fi or SSH and is retried on later boots.
- Use normal iwd + systemd-networkd + systemd-resolved on fixed interface `wlan0`.
- Blank `PSK` and `ROOT_PASSWORD` from `CONFIG.TXT` after successful provisioning.
- Write tty1 MAC/IP information only after networking succeeds.
- Use idempotent provisioning instead of identity/package checkpoint state. Only resize, ready-to-finalize and completion markers remain.

### Code cull

- Remove generalized kernel ABI discovery; verify the known fixed kernel tree directly.
- Remove runtime Wi-Fi interface discovery, manager masking and custom reconnect helpers.
- Remove separate preauth and pre-getty network-info services.
- Remove identity and package resume checkpoints; staged packages remain until finalization so reruns are safe.
- Remove duplicate DT field checks already enforced by the DT patcher and platform validators.
- Keep one kernel update guard: dpkg hold. No apt preference layer or DTB diversion.

## 3.12 development history

3.12 contained intermediate clock-oriented and Wi-Fi experiments while the reusable BPI baseline was being separated from downstream applications. Those experiments are not part of the 3.13 contract.

- Disable the inherited Mali-400 GPU node in the headless base DT to avoid Lima probing an undefined `mali-supply` regulator.
