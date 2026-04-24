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
| `btrfs-assistant` | yes (universe)      | yes (extra)   | Clone <https://gitlab.com/btrfs-assistant/btrfs-assistant>, CMake build. |
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

A Bubble Tea v2 wizard (`btrfs-migrate`, the Go binary — same name as
the bash script, which keeps its `.sh` suffix) collects inputs
interactively and invokes the bash executor with the chosen flags. The
wizard is a convenience layer — the bash script is the canonical
implementation.

Build:

```bash
go build .          # produces ./btrfs-migrate
```

Standalone distribution: the bash script and every library under
`scripts/lib/` are embedded into the Go binary via `//go:embed`. A
single binary copied to another machine will self-extract to a
tempdir and run. Inspect what's embedded with:

```bash
./btrfs-migrate --extract /tmp/scripts   # writes scripts/ tree there
./btrfs-migrate --print-script-path      # resolves the path it would use
```

Unattended mode: pass all flags through via `--non-interactive` (alias
for the wizard's straight-through mode), and combine with the bash
script's `--yes --i-have-backups`. For encryption, provide
`--luks-key-file FILE` (chmod 0600) so cryptsetup doesn't prompt.

```bash
sudo ./btrfs-migrate --non-interactive \
  --root /dev/sda3 --boot /dev/sda2 --efi /dev/sda1 --user alice \
  --encrypt luks --luks-key-file /root/luks.key \
  --bootloader grub --install-bootloader --snapper --grub-btrfs \
  --yes --i-have-backups
```

## Further reading

Operator-facing documentation lives under `docs/`:

- [`docs/ENCRYPTION.md`](docs/ENCRYPTION.md) — what LUKS topologies are
  supported, what's intentionally out of scope, and how to handle
  edge cases via `--luks-reuse`.
- [`docs/RECOVERY.md`](docs/RECOVERY.md) — what to do when a phase
  fails mid-run: reading the rollback log, manual undo commands,
  chrooting into the new system.
- [`docs/PITFALLS.md`](docs/PITFALLS.md) — common footguns (mounted
  targets, UID shifts, systemd-boot multi-kernel gotchas, rsync
  exit-code trust).
- [`docs/DISTRO-DIFFERENCES.md`](docs/DISTRO-DIFFERENCES.md) —
  Ubuntu 24.04+ vs Arch: package managers, initramfs tools,
  bootloader defaults, snapshot-tool availability.

## License

MIT. See `LICENSE`. Upstream script by Diogo Pessoa; rewrite by Ano Rebel.
