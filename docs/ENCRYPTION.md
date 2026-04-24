# Encryption scope

This document lists what LUKS topologies `btrfs-migrate` supports and
what it deliberately does not support, plus the rationale for each
exclusion. If your setup is in the out-of-scope list, the right move is
to prepare encryption manually and point the migration at the mapped
device via `--luks-reuse`.

## Supported

- **LUKS2 on a single root partition** (`--encrypt luks --root /dev/sdaN`).
  The partition must be EMPTY. A new LUKS2 header is written with
  `aes-xts-plain64`, `argon2id` PBKDF, and a random 512-bit key. The
  container is opened at `/dev/mapper/cryptroot` and Btrfs is created
  inside.
- **LVM-on-LUKS2 on a single root partition** (`--encrypt lvm-luks`).
  The partition must be EMPTY. A LUKS2 container is created as above,
  then a PV/VG/LV stack is provisioned on top; Btrfs lives inside the LV.
- **Reuse of an existing LUKS2 container** (`--encrypt luks|lvm-luks
  --luks-reuse --root /dev/sdaN`). The partition MUST already be a
  LUKS2 container. We call only `cryptsetup open` — never any
  header-modifying subcommand (no `luksFormat`, `luksAddKey`,
  `luksKillSlot`, `luksErase`). The existing header and keyslots are
  preserved.
- **Keyfile-based non-interactive unlock** (`--luks-key-file PATH`).
  The keyfile must be owned by uid 0 and mode `0600` or `0400`. Combines
  with `--yes` for fully unattended runs.
- **Encrypted `/boot` with GRUB** (`--encrypt-boot`). Requires
  `--bootloader grub`. GRUB's `cryptodisk`/`luks2` modules prompt for
  the passphrase before mounting `/boot`. Not compatible with
  systemd-boot; that combination is refused at arg-parse time.

## Out of scope (by design)

### Detached LUKS headers

`cryptsetup luksFormat --header FILE` and `cryptsetup open --header
FILE` are not wired through the tool. Detached headers are a legitimate
setup (plausible deniability, header-on-removable-media), but they
change the recovery story enough that a one-size-fits-all wizard is
unlikely to get it right without asking operators a dozen extra
questions. **Workaround:** prepare the container manually, then run
this tool with `--luks-reuse` on the already-opened mapped device.

### Multiple simultaneously-formatted LUKS devices per run

The tool formats at most one device (`--root`). If you want `/boot` or
`/home` also encrypted as new LUKS containers in the same run, the
current scope doesn't cover it. **Workaround:**

1. Encrypt each additional partition yourself, open the containers, and
   format their filesystems.
2. Add a `crypttab` entry for each so they unlock at boot.
3. Run `btrfs-migrate` with `--luks-reuse --root /dev/sdaN` for the
   root; pass the already-unlocked mapped devices (or filesystem UUIDs)
   for `--boot`, `--sep-home`, etc.

### Custom ciphers, PBKDF tuning, keyslot management

The `luksFormat` invocation is hard-coded with strong, modern defaults.
Operators who need `aes-cbc-essiv`, pbkdf memory/iteration overrides,
or multi-slot key management should do that before the migration and
use `--luks-reuse`.

### Keyfile vs passphrase choice

The tool uses whichever is provided. If `--luks-key-file` is set, the
keyfile is used for both `luksFormat` and the subsequent `open`. If
it's absent, cryptsetup prompts on the TTY. There is no "passphrase
AND keyfile" mode in this tool; cryptsetup supports multiple keyslots
natively — add more slots after migration with `cryptsetup luksAddKey`.

## Keyfile guidance

- Store the keyfile outside the root filesystem during migration — a
  removable USB or a tmpfs is ideal. It becomes part of the target
  system's unlock path if you copy it onto the target, so plan
  accordingly.
- Keyfile ownership is checked: uid must be 0, mode must be `0600` or
  `0400`. Anything else is rejected to prevent accidentally unlocking
  with a world-readable file.

## Debugging a failed `cryptsetup open`

If `--luks-reuse` opens the wrong container (for example, you pointed
at the wrong partition):

- `cryptsetup status cryptroot` shows what's currently open.
- `cryptsetup close cryptroot` detaches the mapping.
- `blkid /dev/sdaN` confirms the type is `crypto_LUKS`.
- `cryptsetup luksDump /dev/sdaN` lists keyslots and header details;
  match against the keyfile you intended.
