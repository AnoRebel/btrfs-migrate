# Common pitfalls

Things that are technically legal but almost always a mistake. Read
this before your first live run.

## Running the tool with target devices mounted

This is the single most common footgun. If `/dev/sda3` is mounted
somewhere (even read-only) when you pass it as `--root`, the tool
writes a LUKS header or calls `mkfs.btrfs` and the currently-mounted
filesystem immediately diverges from disk.

**Mitigation in the tool:** preflight runs `require_not_mounted` on
every device flag and refuses to proceed. If you see `[FAIL]
not-mounted:/dev/sdaN — currently mounted at /foo` in the preflight
report, unmount first. If the target is the currently-running rootfs,
you must boot a Live ISO instead.

## UID/GID shifts between source and target

You migrate from a machine where `alice` is uid 1001 into a
freshly-installed target where `alice` is uid 1000. Without
correction, every file under `/home/alice` stays owned by 1001 — which
may now be a different user (`bob`) on the target system, or no user
at all.

**Mitigation in the tool:** `phase_migrate_data` runs
`btrfs_verify_home_ownership` which looks up the target's
`/etc/passwd` for each `/home/<name>` directory and fixes ownership to
match. v0.2.0 prints an announcement table (path / current / desired
/ source) before applying chowns so the changes are auditable.

**If you see the announcement list unexpected entries,** stop and
investigate: the target's `/etc/passwd` might not be what you think
(e.g., you installed the target earlier and passwd is stale).

## systemd-boot's lack of auto-discovery

systemd-boot will boot exactly what is listed under
`/boot/efi/loader/entries/`. It does not discover kernels. If you
install a new kernel via the package manager post-migration and the
package doesn't include a `kernel-install` hook that writes a loader
entry, **the new kernel will not appear in the boot menu**.

- Ubuntu: `kernel-install` is present by default; new kernels auto-append.
- Arch: `kernel-install` is available but NOT enabled by default for
  the `mkinitcpio` flow used by this tool. After migration, consider
  switching to `dracut` + `kernel-install`, or manage loader entries
  manually.

The tool's v0.2.0 release writes one entry per kernel found at
migration time. If you install `linux-lts` *after* the migration,
either re-run `btrfs-migrate.sh` with `--bootloader systemd-boot
--install-bootloader=0` to regenerate entries, or add the entry
manually.

## rsync exit code is not proof of completeness

A killed rsync (SIGKILL, out-of-space, power loss) can return a
non-zero exit code — but a filesystem that fills mid-copy and triggers
rsync's retry behaviour has, in at least one observed case, reported
exit 0 with a partial tree.

**Mitigation in the tool:** v0.2.0 runs `btrfs_postmigrate_check`
after rsync, asserting the presence of `/etc/passwd`, `/etc/shadow`,
`/etc/fstab`, a shell binary, and at least one kernel image. If any
of those are missing, the phase dies with exit code 40 and the
rollback stack undoes what it can.

This check is lightweight, not exhaustive. If you have application
trees that *must* survive the migration (e.g., `/var/lib/postgresql`),
check their presence manually after the run.

## Existing GRUB entry name collision

The tool's systemd-boot writer uses filenames like
`btrfs-migrate-linux.conf`. If a previous run left those files in
place and you re-run against a different target ESP, the old entries
are silently overwritten. No data loss, but the old fallback entry is
gone.

**Workaround:** mount the target ESP and inspect
`loader/entries/btrfs-migrate-*.conf` before re-running. Anything you
want to preserve, rename.

## `--yes` with encryption but no keyfile

Passing `--yes --encrypt luks` without `--luks-key-file` doesn't make
the run unattended — `cryptsetup` will prompt on the TTY for the
passphrase and hang the script until you type it in. Either supply a
keyfile (`--luks-key-file PATH`) or drop `--yes` and let the normal
prompts happen.

The tool emits a warning at parse time for this combination, but
doesn't refuse — there are legitimate cases where you want unattended
execution with an interactive password prompt (terminal multiplexer
with a human at one pane).

## Separate `/home` plaintext while root is encrypted

A common oversight: root LUKS + a separate `/home` partition without
its own LUKS container. The root is protected at rest; the home
directory is not. This is almost never what you want on a laptop.

**Mitigation in the tool:** v0.2.0 warns during preflight
(`Encryption mismatch: root is encrypted but separate /home is
plaintext`). If you also pass `--convert-home` in this posture, the
tool refuses the run unless you pass `--accept-home-plaintext` to
explicitly acknowledge intent.

## Re-running after success

`mkfs.btrfs` refuses to overwrite an existing btrfs unless
`BTRFS_MKFS_FORCE=1`. This is intentional and protects you from
destroying a completed migration. If you really want to redo
everything, pass the override explicitly — but remember that doing so
wipes the current `/` of your new system.

## Running on the live system without `--force-installed`

The tool refuses to run on an installed, booted system by default.
The rationale is simple: modifying the running root is unsafe for
almost any phase (mkfs on `/`, fstab rewrite while live, bootloader
reinstall while services are running). Even with
`--force-installed`, prefer a Live ISO unless you have a specific
reason not to.
