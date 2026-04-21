# btrfs-migrate

> ⚠️ **TESTED: NO.** This project is unreleased (`v0.1.0`). It performs
> destructive, hard-to-reverse operations on block devices and your
> bootloader. Test inside a VM against a throwaway disk image before
> running against real hardware. The script refuses to run on installed
> systems without `--force-installed`, and refuses destructive paths
> without `--i-have-backups`.

A hardened, fork-rewrite of
[diogopessoa/ubuntu-btrfs-install](https://github.com/diogopessoa/ubuntu-btrfs-install)
that converts a freshly-installed Linux system's root filesystem to Btrfs
with subvolumes, optional LUKS / LVM-on-LUKS encryption, and optional
snapshot integration with Snapper or Timeshift.

## Supported

- **Distros:** Ubuntu 24.04+ (server and desktop), Arch Linux (rolling).
- **Execution modes:** Live ISO (preferred) and installed system
  (requires `--force-installed`).
- **Encryption:** LUKS2, LVM-on-LUKS. New/empty targets only.
- **Bootloaders:** GRUB, systemd-boot. Install-and-configure or
  configure-only.
- **Snapshots:** Snapper, Timeshift (mutually exclusive),
  `grub-btrfs` for snapshot boot entries.

## Unsupported (by design)

The script will refuse, not silently degrade, in these cases:

- In-place encryption of a root partition that already contains data.
  Encryption is offered only on empty targets.
- Encrypted `/boot` with systemd-boot. The bootloader cannot prompt for
  a passphrase. Use GRUB + `--encrypt-boot` instead.
- Mixing `--snapper` and `--timeshift` in the same run.
- In-place migration of an already-encrypted root.
- Secure Boot signing of a self-installed shim/GRUB.

## Unpackaged dependencies

Some tools are not always present in distro repos. The script
discovers before using, and falls back to source installs where
possible:

| Tool              | Ubuntu 24.04+ repo? | Arch repo?    | Fallback                                                               |
| ----------------- | ------------------- | ------------- | ---------------------------------------------------------------------- |
| `btrfs-progs`     | yes                 | yes           | —                                                                      |
| `cryptsetup`      | yes                 | yes           | —                                                                      |
| `lvm2`            | yes                 | yes           | —                                                                      |
| `snapper`         | yes (universe)      | yes           | —                                                                      |
| `btrfs-assistant` | no                  | AUR           | Skipped with a warning; install manually.                              |
| `timeshift`       | yes                 | yes           | —                                                                      |
| `grub-btrfs`      | no                  | yes (extra)   | Clone <https://github.com/Antynea/grub-btrfs>, `make install` as root. |

## Usage

```bash
# Plan only — prints what it would do, no changes:
sudo ./scripts/btrfs-migrate.sh --dry-run \
  --root /dev/sda3 --boot /dev/sda2 --efi /dev/sda1 --user alice

# Live-ISO run, LUKS2, GRUB, Snapper, grub-btrfs:
sudo ./scripts/btrfs-migrate.sh \
  --root /dev/sda3 --boot /dev/sda2 --efi /dev/sda1 \
  --user alice \
  --encrypt luks --bootloader grub --install-bootloader \
  --snapper --grub-btrfs \
  --i-have-backups
```

## Flags (summary)

| Flag                     | Purpose                                                         |
| ------------------------ | --------------------------------------------------------------- |
| `--root <part>`          | Root partition (required).                                      |
| `--boot <part>`          | Separate `/boot` partition.                                     |
| `--efi <part>`           | EFI system partition.                                            |
| `--user <name>`          | Owner of `/home/<user>` (auto-detected; confirm at prompt).     |
| `--subvols a,b,c`        | Comma-separated subvolume list (defaults to the upstream set).  |
| `--encrypt MODE`         | `none` (default), `luks`, `lvm-luks`.                           |
| `--encrypt-boot`         | Encrypted `/boot`; GRUB only.                                   |
| `--bootloader B`         | `grub` (default) or `systemd-boot`.                             |
| `--install-bootloader`   | Install + configure (default is configure-only).                |
| `--snapper`              | Configure Snapper for `/` (and `/home` if `--snapper-home`).    |
| `--timeshift`            | Configure Timeshift.                                            |
| `--grub-btrfs`           | Install `grub-btrfs` (package or source fallback).              |
| `--convert-home`         | If `/home` is a separate partition, convert it to its own Btrfs.|
| `--mount-opts safe\|perf`| `safe` = defaults,noatime,compress=zstd. `perf` adds ssd,etc.   |
| `--dry-run`              | Print plan, change nothing.                                     |
| `--force-installed`      | Allow running on an installed system.                           |
| `--i-have-backups`       | Required for destructive actions.                               |
| `--yes`                  | Non-interactive; assume yes. Combine with backups flag.         |

## Logs

`/var/log/btrfs-migrate.log` — structured, timestamped, appended on
every run.

## Fixes relative to upstream

- **Issue #2:** `/home/<user>` ownership preserved through the migration
  (upstream left it root-owned after rsync into `@home`, breaking login).
- **Issue #3:** `grub-btrfs` integration with package + source fallback.
- Argument validation, `set -Eeuo pipefail`, ERR traps with rollback.
- Distro detection (Ubuntu + Arch dispatch).
- LUKS / LVM-on-LUKS first-class, with refusal on non-empty targets.
- SSD detection instead of hard-coded `ssd,space_cache=v2` (the latter
  is kernel-default since 5.15).
- Idempotent fstab editing keyed on mountpoint rather than a blanket
  `/ btrfs /d` delete.

## CLI wrapper

A Bubble Tea wizard (`cmd/btrfs-migrate`) is in progress. It collects
inputs interactively and invokes the bash executor with the chosen
flags. The wizard is a convenience layer — the bash script is the
canonical implementation.

## License

MIT. See `LICENSE`. Upstream script by Diogo Pessoa; rewrite by Ano Rebel.
