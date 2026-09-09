# 3.10 fstab compatibility

The 2026-09-07 `pheiz3` build exposed a remaining upstream-layout assumption: the builder required `/etc/fstab` to already contain `/`. 3.10 accepts an absent root entry, verifies that the mounted Johang root image is ext4, and writes the final PARTUUID root entry itself. Multiple or incompatible root entries still fail closed.

# 3.10 Trixie-base update

The 3.8 GPIO and pre-login fixes are retained unchanged. 3.9 removes root-image/kernel-version coupling so a future explicitly selected Debian Trixie armhf Johang image can be used without changing ABI constants or hashes.

# 3.8 review fixes

| Finding | 3.8 disposition |
|---|---|
| Mixed-length `*-gpios` arrays skipped by 3.7 | Fixed with phandle-aware `#gpio-cells` walking. `<0>` consumes one cell; each real phandle consumes `1 + #gpio-cells`. Unknown/truncated GPIO specifiers fail closed. |
| `cs-gpios = <0>, <&pio 0 7 0>` hides PA7 | Regression test added; `check_gpio_ownership.py` now rejects it. |
| Platform direct-GPIO scan had same stride bug | Same parser shared by `check_platform_pins.py`; PA11 mixed-spec conflict test added. |
| Dead `if path in groups` guard | Replaced by an actual `group_paths` set. |
| GPIO hog checker inconsistency | Both validators use the same owning-controller `#gpio-cells` parser. |
| Groups under disabled controller collected | Group collection now requires effective enablement. |
| `Type=simple` allows userdel during console login | Account removal moved to synchronous `ExecStartPre`, ordered before `getty.target` and `ssh.service`. |
| Runtime timeout during FAT scrub can leave mount rw | Main provisioning keeps a global EXIT cleanup trap; rw scrub still mounts `sync`. |
| Inherited SSH host keys could become visible during background provisioning | Build deletes inherited keys; pre-login phase regenerates unique keys before SSH is released. |

Long resize/network/package provisioning remains intentionally asynchronous after the pre-login security barrier.
