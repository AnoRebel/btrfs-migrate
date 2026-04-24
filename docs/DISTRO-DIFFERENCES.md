# Distro differences

This tool targets two distros only: Ubuntu 24.04+ (`DISTRO_LIKE=debian`)
and Arch Linux (`DISTRO_LIKE=arch`). Where the two diverge, the tool
dispatches on `DISTRO_LIKE` internally; this document surfaces the
differences so you know what to expect.

## Capability matrix

| Capability              | Ubuntu 24.04+                                         | Arch Linux                                            |
|-------------------------|-------------------------------------------------------|-------------------------------------------------------|
| Package manager         | `apt-get` (non-interactive via `DEBIAN_FRONTEND=noninteractive`) | `pacman -Sy --noconfirm --needed`                    |
| Initramfs tool          | `update-initramfs -u -k all`                          | `mkinitcpio -P`                                       |
| Initramfs crypt hook    | `cryptsetup-initramfs` package; `CRYPTSETUP=y` in `/etc/cryptsetup-initramfs/conf-hook` | `encrypt` hook before `filesystems` in `HOOKS=(...)` in `/etc/mkinitcpio.conf` |
| Initramfs LVM hook      | Automatic once `cryptsetup-initramfs` + `lvm2` are installed | `lvm2` hook after `encrypt` in `HOOKS=(...)`         |
| Default bootloader      | GRUB                                                  | None enforced; GRUB and systemd-boot equally supported |
| GRUB config command     | `update-grub`                                         | `grub-mkconfig -o /boot/grub/grub.cfg`                |
| GRUB EFI target         | `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=btrfs-migrate --recheck` | same                                                  |
| GRUB BIOS target        | `grub-install --target=i386-pc --recheck $BIOS_DISK`  | same                                                  |
| systemd-boot install    | `apt-get install systemd-boot systemd-boot-efi efibootmgr` + `bootctl install` | `pacman -S efibootmgr` (systemd-boot ships in `systemd`) + `bootctl install` |
| Kernel naming           | `vmlinuz-<uname-r>` (e.g., `vmlinuz-6.8.0-generic`)   | `vmlinuz-linux`, `vmlinuz-linux-lts`, etc.            |
| Initramfs naming        | `initrd.img-<uname-r>`                                | `initramfs-linux.img`, `initramfs-linux-fallback.img` |
| Multi-kernel default    | One kernel at a time (`linux-image-generic`)          | `linux` + `linux-lts` common                          |
| Snapper (repo)          | Available in `universe` repo                          | Available in AUR (built from source fallback)         |
| Timeshift (repo)        | Available in `universe` repo                          | Available in AUR (built from source fallback)         |
| grub-btrfs (repo)       | Not packaged; source build from GitHub latest         | Available in AUR; tool also does source fallback      |
| btrfs-assistant (repo)  | Not packaged; source build from GitLab latest         | Available in AUR; tool also does source fallback      |

## Initramfs subtleties

### Ubuntu

`update-initramfs -u -k all` rebuilds every kernel's initrd. The tool
runs this unconditionally during `phase_bootloader_and_initramfs` so
LUKS/LVM hooks are baked in. If you post-install a new kernel, apt
re-triggers this automatically.

### Arch

`mkinitcpio -P` rebuilds every preset in `/etc/mkinitcpio.d/`. The
tool inserts `encrypt` (and `lvm2` in lvm-luks mode) into the HOOKS
array before `filesystems` and reruns `mkinitcpio -P`. Post-install
new kernels automatically trigger `mkinitcpio` via `pacman` hooks in
the `mkinitcpio` package.

## Bootloader defaults and why they matter

Arch does not install a bootloader by default — the installation
medium leaves bootloader choice to the user. This tool writes GRUB
config unconditionally unless `--bootloader systemd-boot` is chosen,
but it does **not** install GRUB packages unless
`--install-bootloader` is also passed.

Ubuntu ships GRUB pre-installed. `--install-bootloader` on Ubuntu
reinstalls over the existing install, which is safe and occasionally
necessary when the existing install is broken.

## systemd-boot entry authoring

systemd-boot is aggressively declarative: it only boots what's in
`/boot/efi/loader/entries/`. The tool's v0.2.0 writer:

1. Enumerates `@/boot/vmlinuz-*` after the initramfs is built.
2. Pairs each with its initramfs (`initramfs-<name>.img` on Arch,
   `initrd.img-<name>` on Ubuntu).
3. Writes `btrfs-migrate-<name>.conf` for each.
4. Picks the newest kernel (by `sort -V`) as `default` in `loader.conf`.
5. Runs `bootctl list` to confirm recognition; dies with exit 41 if
   the recognized count is less than the written count.

Arch's `linux` + `linux-lts` case works without manual intervention.

Ubuntu's per-version case works correctly as long as the tool runs
*after* the target's initramfs is built — otherwise the `initrd.img-*`
files don't exist yet. `phase_bootloader_and_initramfs` orders these
correctly (initramfs first, then bootloader).

## Package availability for snapshot tooling

### Snapper

- Ubuntu 24.04+: `apt install snapper`. Uses `snapper-configs` to
  bootstrap a sensible default for `/`.
- Arch: `pacman -S snapper`. Same config commands.

The tool writes a Snapper config for `/` (and optionally `/home`)
regardless of distro; the config format is identical.

### Timeshift

Timeshift is mutually exclusive with Snapper; the tool enforces this.
If you pass both `--snapper` and `--timeshift`, parsing refuses the
combination.

### grub-btrfs

Neither distro ships grub-btrfs in the official repos in a form this
tool pins. The tool resolves the latest GitHub release tag at runtime
and does a source build. `BTRFS_MIGRATE_STRICT_PIN=1` forces a full
40-char SHA pin to be supplied via `GRUB_BTRFS_REF` (for air-gapped
reproducible builds).

### btrfs-assistant

Same story as grub-btrfs; resolved from GitLab at runtime.

## SSD detection

Both distros expose `/sys/block/<disk>/queue/rotational` (0=SSD,
1=spinning). The tool uses this to decide whether to add `ssd` to
the mount options in `--mount-opts perf` mode. No distro-specific
handling needed.

## When distro autodetection fails

`/etc/os-release` is the authoritative source. If it's missing or
corrupt, `detect_distro` fails with exit 10. The tool does not
support generic "linux" fallback — the bootloader, initramfs, and
package-manager commands diverge enough that a silent fallback would
produce broken systems.
