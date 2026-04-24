#!/usr/bin/env bash
# btrfs-migrate.sh — hardened Btrfs migration for Ubuntu 24.04+ and
# Arch Linux, with optional LUKS / LVM-on-LUKS, Snapper or Timeshift,
# and grub-btrfs. See README.md for full semantics.
#
# Exit codes:
#   0   success
#   10  preflight failed / invalid args / unsupported combo
#   20  user aborted at the plan-confirmation prompt
#   30  execution failed after plan was accepted (rollback ran)
#   40  post-migration verification failed

set -Eeuo pipefail

VERSION="v0.1.0"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
LIB="$HERE/lib"

# shellcheck source=lib/log.sh
. "$LIB/log.sh"
# shellcheck source=lib/checks.sh
. "$LIB/checks.sh"
# shellcheck source=lib/luks.sh
. "$LIB/luks.sh"
# shellcheck source=lib/btrfs.sh
. "$LIB/btrfs.sh"
# shellcheck source=lib/fstab.sh
. "$LIB/fstab.sh"
# shellcheck source=lib/bootloader.sh
. "$LIB/bootloader.sh"
# shellcheck source=lib/snapshots.sh
. "$LIB/snapshots.sh"

# -- Defaults ----------------------------------------------------------------
ROOT_DEV=""
BOOT_DEV=""
EFI_DEV=""
SEP_HOME_DEV=""
USERNAME=""
SUBVOLS_CSV=""              # if empty, use BTRFS_DEFAULT_SUBVOLS
ENCRYPT_MODE="none"         # none | luks | lvm-luks
ENCRYPT_BOOT=0              # 0 | 1
BOOTLOADER="grub"           # grub | systemd-boot
INSTALL_BOOTLOADER=0        # 0 | 1
WANT_SNAPPER=0
WANT_SNAPPER_HOME=0
WANT_TIMESHIFT=0
WANT_GRUB_BTRFS=0
WANT_BTRFS_ASSISTANT=0
CONVERT_HOME=0
MOUNT_OPTS_MODE="safe"      # safe | perf
DRY_RUN=0                   # exported to log.sh
FORCE_INSTALLED=0
I_HAVE_BACKUPS=0
ASSUME_YES=0
SRC_MP=""                   # explicit source root mountpoint (optional)
BIOS_DISK=""                # whole-disk for BIOS grub-install (e.g. /dev/sda)
LUKS_KEYFILE=""             # optional; enables fully-unattended LUKS format
PLAN_ONLY=0                 # 1 = collect plan to file, execute nothing
LUKS_REUSE=0                # 1 = open existing LUKS instead of luksFormat
ACCEPT_HOME_PLAINTEXT=0     # 1 = ack plaintext /home with encrypted root

show_help() {
    cat <<EOF
btrfs-migrate $VERSION — migrate a Linux root filesystem to Btrfs with
                        optional LUKS encryption and snapshot tooling.

USAGE:
  btrfs-migrate.sh --root DEV --boot DEV [--efi DEV] --user NAME [flags]

DEVICES:
  --root DEV            Target root partition (required).
  --boot DEV            Separate /boot partition (required).
  --efi DEV             EFI system partition (required in UEFI mode).
  --sep-home DEV        Existing separate /home partition (optional).
  --bios-disk DEV       Whole disk for BIOS grub-install (e.g. /dev/sda).
  --src-mp DIR          Source rootfs mountpoint. Default: / (installed) or
                        /target (Ubiquity) or auto-detect.

IDENTITY:
  --user NAME           Owner of /home/NAME. Default: auto-detect; confirm prompt.

SUBVOLUMES:
  --subvols a,b,c       Comma-separated set. Default is the upstream list:
                        @,@home,@log,@cache,@tmp,@libvirt,@flatpak,@docker,
                        @containers,@machines,@var_tmp,@opt

ENCRYPTION (target must be empty):
  --encrypt MODE        none | luks | lvm-luks  (default: none)
  --encrypt-boot        Encrypt /boot too. GRUB only.

BOOTLOADER:
  --bootloader B        grub (default) | systemd-boot
  --install-bootloader  Install (not just configure) the bootloader.

SNAPSHOTS:
  --snapper             Configure Snapper for /
  --snapper-home        Also configure Snapper for /home
  --timeshift           Configure Timeshift (mutually exclusive with --snapper)
  --grub-btrfs          Install grub-btrfs (package or source fallback)
  --btrfs-assistant     Install btrfs-assistant (package or source fallback)

/HOME BRANCH:
  --convert-home        If --sep-home given, convert it to its own Btrfs.

MOUNT OPTIONS:
  --mount-opts MODE     safe (defaults,noatime,compress=zstd) |
                        perf (defaults,noatime,compress=zstd:3 +ssd if SSD)

ENCRYPTION (unattended):
  --luks-key-file FILE  Read the LUKS passphrase from FILE instead of
                        prompting. Must be chmod 0600 and owned by the
                        invoking root user. Enables fully non-interactive
                        runs when combined with --yes --i-have-backups.

SAFETY:
  --dry-run             Log every command as DRY-RUN (still executes
                        read-only probes). For a non-executing review
                        artifact, prefer --plan-only.
  --plan-only           Collect every command this run would execute into
                        a plan file (path printed on stdout); do not
                        touch any disk. Distinct from --dry-run.
  --force-installed     Allow running on an installed system (not recommended).
  --i-have-backups      Required for destructive execution.
  --yes                 Non-interactive. Skip plan confirmation.
  --luks-reuse          Reuse an existing LUKS2 container on --root
                        instead of formatting it. Requires --encrypt
                        luks|lvm-luks; in --yes mode requires --luks-key-file.
  --accept-home-plaintext
                        Acknowledge that converting a plaintext separate
                        /home while root is encrypted is intentional.

  --help, -h            This help.
  --version, -V         Print version and exit.

EOF
}

# -- Argument parsing --------------------------------------------------------
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --root)              ROOT_DEV="$2"; shift 2 ;;
            --boot)              BOOT_DEV="$2"; shift 2 ;;
            --efi)               EFI_DEV="$2"; shift 2 ;;
            --sep-home)          SEP_HOME_DEV="$2"; shift 2 ;;
            --bios-disk)         BIOS_DISK="$2"; shift 2 ;;
            --src-mp)            SRC_MP="$2"; shift 2 ;;
            --user)              USERNAME="$2"; shift 2 ;;
            --subvols)           SUBVOLS_CSV="$2"; shift 2 ;;
            --encrypt)           ENCRYPT_MODE="$2"; shift 2 ;;
            --encrypt-boot)      ENCRYPT_BOOT=1; shift ;;
            --luks-key-file)     LUKS_KEYFILE="$2"; shift 2 ;;
            --bootloader)        BOOTLOADER="$2"; shift 2 ;;
            --install-bootloader)INSTALL_BOOTLOADER=1; shift ;;
            --snapper)           WANT_SNAPPER=1; shift ;;
            --snapper-home)      WANT_SNAPPER_HOME=1; shift ;;
            --timeshift)         WANT_TIMESHIFT=1; shift ;;
            --grub-btrfs)        WANT_GRUB_BTRFS=1; shift ;;
            --btrfs-assistant)   WANT_BTRFS_ASSISTANT=1; shift ;;
            --convert-home)      CONVERT_HOME=1; shift ;;
            --mount-opts)        MOUNT_OPTS_MODE="$2"; shift 2 ;;
            --dry-run)           DRY_RUN=1; shift ;;
            --plan-only)         PLAN_ONLY=1; shift ;;
            --luks-reuse)        LUKS_REUSE=1; shift ;;
            --accept-home-plaintext) ACCEPT_HOME_PLAINTEXT=1; shift ;;
            --force-installed)   FORCE_INSTALLED=1; shift ;;
            --i-have-backups)    I_HAVE_BACKUPS=1; shift ;;
            --yes|-y)            ASSUME_YES=1; shift ;;
            --help|-h)           show_help; exit 0 ;;
            --version|-V)        printf 'btrfs-migrate %s\n' "$VERSION"; exit 0 ;;
            *) die "Unknown argument: $1 (try --help)" 10 ;;
        esac
    done

    # --plan-only is mutually exclusive with --dry-run (different intent)
    # and with --yes (plan-only never executes, so confirmation is moot).
    if (( PLAN_ONLY == 1 )); then
        (( DRY_RUN == 0 )) || die "--plan-only and --dry-run are mutually exclusive." 10
        (( ASSUME_YES == 0 )) || die "--plan-only does not execute; --yes is meaningless here." 10
    fi
    BTRFS_MIGRATE_PLAN_ONLY="$PLAN_ONLY"
    export DRY_RUN BTRFS_MIGRATE_PLAN_ONLY   # log.sh reads these
    plan_init   # no-op unless plan-only
}

# -- Validation --------------------------------------------------------------
validate_args() {
    [[ -n "$ROOT_DEV" ]] || die "--root is required." 10
    [[ -n "$BOOT_DEV" ]] || die "--boot is required." 10

    require_partition "$ROOT_DEV"
    require_partition "$BOOT_DEV"
    [[ -n "$EFI_DEV" ]] && require_partition "$EFI_DEV"
    [[ -n "$SEP_HOME_DEV" ]] && require_partition "$SEP_HOME_DEV"
    [[ -n "$BIOS_DISK" ]] && require_whole_disk "$BIOS_DISK"

    # /boot should be ext4 (or ext2/ext3) — GRUB needs a non-btrfs /boot
    # unless --encrypt-boot with cryptodisk module is used. Reject oddball
    # filesystems before we wire a kernel at boot we can't read.
    if [[ -n "$BOOT_DEV" ]]; then
        local bootfs; bootfs=$(fs_of "$BOOT_DEV")
        case "$bootfs" in
            ext4|ext3|ext2|'') : ;;
            btrfs) warn "--boot $BOOT_DEV is btrfs; make sure your bootloader can read it." ;;
            *) die "--boot $BOOT_DEV has unsupported filesystem '$bootfs' (expected ext4)." 10 ;;
        esac
    fi
    if [[ -n "$EFI_DEV" ]]; then
        local efifs; efifs=$(fs_of "$EFI_DEV")
        case "$efifs" in
            vfat|'') : ;;
            *) die "--efi $EFI_DEV has filesystem '$efifs' — UEFI requires vfat/FAT32." 10 ;;
        esac
    fi

    # Refuse overlapping device args (same disk, typo, etc.).
    require_distinct_devices "$ROOT_DEV" "$BOOT_DEV" "$EFI_DEV" "$SEP_HOME_DEV"

    case "$ENCRYPT_MODE" in none|luks|lvm-luks) : ;; *) die "--encrypt must be one of: none|luks|lvm-luks" 10 ;; esac
    case "$BOOTLOADER"   in grub|systemd-boot) : ;; *) die "--bootloader must be one of: grub|systemd-boot" 10 ;; esac
    case "$MOUNT_OPTS_MODE" in safe|perf) : ;; *) die "--mount-opts must be one of: safe|perf" 10 ;; esac

    # BIOS + GRUB + no EFI requires a whole-disk target.
    if [[ "$BOOTLOADER" == "grub" ]] && [[ -z "$EFI_DEV" ]] && (( INSTALL_BOOTLOADER == 1 )); then
        [[ -n "$BIOS_DISK" ]] || die "BIOS GRUB install requires --bios-disk /dev/sdX." 10
    fi

    # systemd-boot + encrypted /boot is impossible; checked also in lib but
    # we want to reject at arg-parse time so the plan print is honest.
    bootloader_validate "$BOOTLOADER" "$ENCRYPT_BOOT"

    snap_validate_choice "$WANT_SNAPPER" "$WANT_TIMESHIFT"

    # Default user if not given.
    if [[ -z "$USERNAME" ]]; then
        USERNAME=$(detect_user)
        [[ -n "$USERNAME" ]] || die "Could not auto-detect a user. Pass --user explicitly." 10
        log "Using auto-detected --user=$USERNAME"
    fi
    require_username "$USERNAME"
    require_user "$USERNAME"

    # Resolve subvolume list.
    if [[ -n "$SUBVOLS_CSV" ]]; then
        IFS=',' read -r -a SUBVOLS <<<"$SUBVOLS_CSV"
    else
        SUBVOLS=("${BTRFS_DEFAULT_SUBVOLS[@]}")
    fi
    local s
    for s in "${SUBVOLS[@]}"; do require_subvol_name "$s"; done
    btrfs_validate_subvols "${SUBVOLS[@]}"
    (( WANT_TIMESHIFT == 1 )) && snap_warn_layout_for_timeshift "${SUBVOLS[@]}"

    # --luks-reuse requires --encrypt and (in unattended mode) a keyfile.
    if (( LUKS_REUSE == 1 )); then
        [[ "$ENCRYPT_MODE" != "none" ]] \
            || die "--luks-reuse requires --encrypt luks|lvm-luks." 10
        if (( ASSUME_YES == 1 )) && [[ -z "$LUKS_KEYFILE" ]]; then
            die "--luks-reuse with --yes requires --luks-key-file (cryptsetup open would otherwise prompt and hang)." 10
        fi
    fi

    # Encryption: with reuse we require an EXISTING container; without
    # reuse we require an EMPTY partition. Both paths refuse data-present.
    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        if (( LUKS_REUSE == 1 )); then
            luks_require_existing "$ROOT_DEV"
        else
            luks_require_empty "$ROOT_DEV"
        fi
    fi

    # Keyfile (if given): must exist, be owned by root, and be 0600/0400.
    if [[ -n "$LUKS_KEYFILE" ]]; then
        [[ "$ENCRYPT_MODE" != "none" ]] || die "--luks-key-file requires --encrypt luks|lvm-luks." 10
        require_keyfile_ownership "$LUKS_KEYFILE"
        [[ -r "$LUKS_KEYFILE" ]] || die "--luks-key-file '$LUKS_KEYFILE' is not readable." 10
    fi

    # Fully-unattended runs with encryption need a keyfile; otherwise cryptsetup
    # will prompt interactively and hang.
    if (( ASSUME_YES == 1 )) && [[ "$ENCRYPT_MODE" != "none" ]] && [[ -z "$LUKS_KEYFILE" ]]; then
        warn "--yes with encryption but no --luks-key-file: cryptsetup will still prompt for a passphrase on the TTY."
    fi

    # /home encryption-posture mismatch: root LUKS + plaintext separate /home
    # is almost always a misconfiguration. Warn if the operator is keeping
    # the partition as-is; refuse if they're converting it without ack.
    if [[ "$ENCRYPT_MODE" != "none" ]] && [[ -n "$SEP_HOME_DEV" ]]; then
        local home_fs; home_fs=$(fs_of "$SEP_HOME_DEV")
        if [[ "$home_fs" != "crypto_LUKS" ]]; then
            if (( CONVERT_HOME == 1 )) && (( ACCEPT_HOME_PLAINTEXT == 0 )); then
                die "Encryption mismatch: --encrypt $ENCRYPT_MODE on root but --sep-home $SEP_HOME_DEV is plaintext (fs='${home_fs:-none}'). Converting it would leave /home unencrypted at rest. Pass --accept-home-plaintext to confirm intent." 10
            fi
            warn "Encryption mismatch: root is encrypted ($ENCRYPT_MODE) but separate /home ($SEP_HOME_DEV, fs='${home_fs:-none}') is plaintext. /home contents will NOT be protected at rest."
        fi
    fi
}

# -- Plan print --------------------------------------------------------------
print_plan() {
    cat <<EOF

===== btrfs-migrate $VERSION — plan =====

Distro:              $DISTRO_ID ${DISTRO_VERSION_ID:-(rolling)} ($DISTRO_LIKE)
Execution mode:      $EXEC_MODE $( ((FORCE_INSTALLED==1)) && echo "(--force-installed)" )
Dry run:             $( ((DRY_RUN==1)) && echo YES || echo NO )

Target devices:
  / (root):          $ROOT_DEV$( [[ "$ENCRYPT_MODE" != "none" ]] && echo "  [ENCRYPTED: $ENCRYPT_MODE]" )
  /boot:             $BOOT_DEV$( ((ENCRYPT_BOOT==1)) && echo "  [encrypted /boot]" )
  /boot/efi:         ${EFI_DEV:-<none>}
  sep /home:         ${SEP_HOME_DEV:-<none>}$( [[ -n "$SEP_HOME_DEV" ]] && ((CONVERT_HOME==1)) && echo "  [will be reformatted to Btrfs]" )

Identity:
  user:              $USERNAME (will be used for chown of /home/$USERNAME)

Subvolumes:
  ${SUBVOLS[*]}

Bootloader:          $BOOTLOADER$( ((INSTALL_BOOTLOADER==1)) && echo " (install+configure)" || echo " (configure-only)" )
Mount options:       $MOUNT_OPTS_MODE
Snapper:             $( ((WANT_SNAPPER==1)) && echo "yes$( ((WANT_SNAPPER_HOME==1)) && echo ' (+ /home)')" || echo no )
Timeshift:           $( ((WANT_TIMESHIFT==1)) && echo yes || echo no )
grub-btrfs:          $( ((WANT_GRUB_BTRFS==1)) && echo yes || echo no )
btrfs-assistant:     $( ((WANT_BTRFS_ASSISTANT==1)) && echo yes || echo no )

Log file:            $LOG_FILE

EOF
}

confirm_plan() {
    if (( BTRFS_MIGRATE_PLAN_ONLY == 1 )); then
        log "Plan-only — nothing will be changed; commands will be collected to $PLAN_FILE."
        return 0
    fi
    if (( DRY_RUN == 1 )); then
        log "Dry run — nothing will be changed."
        return 0
    fi
    if (( ASSUME_YES == 1 )); then
        (( I_HAVE_BACKUPS == 1 )) || die "--yes requires --i-have-backups (this script WILL modify disks)." 10
        warn "Non-interactive execution (--yes). Proceeding."
        return 0
    fi
    if (( I_HAVE_BACKUPS == 0 )); then
        die "Destructive execution requires --i-have-backups (you confirmed you have backups)." 10
    fi
    printf '\n'
    read -r -p "Type YES (uppercase) to execute this plan: " answer
    [[ "$answer" == "YES" ]] || { warn "User declined. Exiting."; exit 20; }
}

# -- Execution phases --------------------------------------------------------

# Mountpoints we own during the run.
TARGET_MP=""     # subvolid=5 mount of the new Btrfs
SRC_AUTO_MP=""   # where we auto-mount the source rootfs if the user didn't

auto_pick_src_mp() {
    if [[ -n "$SRC_MP" ]]; then
        require_srcmp_looks_like_root "$SRC_MP"
        return 0
    fi
    if [[ "$EXEC_MODE" == "installed" ]]; then
        SRC_MP="/"
        debug "Using running system (/) as source."
        return 0
    fi
    # Live ISO: Ubiquity stages the new install at /target during its final
    # phase, but if the user booted a Live and installed manually we have
    # nothing to copy — let the user specify.
    if mountpoint -q /target 2>/dev/null; then
        SRC_MP="/target"
        log "Using /target as source (Ubiquity layout)."
        require_srcmp_looks_like_root "$SRC_MP"
        return 0
    fi
    die "No source rootfs found. Mount the freshly-installed system somewhere and pass --src-mp /that/path." 10
}

phase_preflight() {
    detect_distro
    detect_exec_mode
    enforce_exec_mode "$FORCE_INSTALLED"
    validate_args
    auto_pick_src_mp
    ensure_bins lsblk blkid findmnt rsync btrfs awk sed install mount umount cp mv chmod chown

    # Environmental validators (feed the grouped pf_report collector).
    # Errors from individual checks are suppressed so every check runs
    # and every failure shows up in the final report.
    pf_report_reset
    local dev
    for dev in "$ROOT_DEV" "$BOOT_DEV" "$EFI_DEV" "$SEP_HOME_DEV"; do
        [[ -z "$dev" ]] && continue
        require_not_mounted "$dev"       || true
        require_device_not_in_use "$dev" || true
    done
    # Size check only against --root — the other devices are not receiving
    # the rsync payload.
    require_device_size_sufficient "$SRC_MP" "$ROOT_DEV" || true
    pf_report_emit
}

phase_encrypt() {
    [[ "$ENCRYPT_MODE" == "none" ]] && return 0
    luks_tools_installed "$ENCRYPT_MODE"
    if (( LUKS_REUSE == 1 )); then
        luks_open_existing "$ROOT_DEV" "$LUKS_KEYFILE"
    else
        luks_format "$ROOT_DEV" "$LUKS_KEYFILE"
    fi
    if [[ "$ENCRYPT_MODE" == "lvm-luks" ]]; then
        # In reuse mode the LVM stack is also expected to already exist.
        # We still run `pvcreate -ff` etc; that is destructive but matches
        # the operator's stated intent (reuse the LUKS, build LVM fresh
        # on top). A future enhancement could detect-and-skip; for now
        # this is documented in docs/ENCRYPTION.md.
        luks_provision_lvm
    fi
}

phase_mkfs_and_subvols() {
    local target_block; target_block="$ROOT_DEV"
    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        target_block=$(luks_root_block "$ENCRYPT_MODE")
    fi
    btrfs_mkfs "$target_block" "btrfs-root"

    TARGET_MP=$(mktemp -d -t btrfs-migrate-target.XXXXXX)
    on_rollback "umount '$TARGET_MP' 2>/dev/null || true; rmdir '$TARGET_MP' 2>/dev/null || true"
    btrfs_mount_top "$target_block" "$TARGET_MP"
    btrfs_create_subvols "$TARGET_MP" "${SUBVOLS[@]}"
}

phase_migrate_data() {
    btrfs_populate_copy "$SRC_MP" "$TARGET_MP"
    btrfs_move_var_bits "$TARGET_MP"
    btrfs_verify_home_ownership "$TARGET_MP"
    # Separate-/home branch:
    btrfs_home_strategy "$SRC_MP" "$SEP_HOME_DEV" "$TARGET_MP" "$CONVERT_HOME"
    # Fail fast if the copy is incomplete despite rsync's 0 exit.
    btrfs_postmigrate_check "$TARGET_MP" "$BOOT_DEV"
}

phase_fstab() {
    export MOUNT_OPTS_MODE
    local target_block; target_block="$ROOT_DEV"
    [[ "$ENCRYPT_MODE" != "none" ]] && target_block=$(luks_root_block "$ENCRYPT_MODE")
    # fstab UUID MUST be of the btrfs fs, not the underlying LUKS dev.
    # btrfs UUID == uuid_of "$target_block" (the mapper / LV).
    local -a lines=()
    mapfile -t lines < <(fstab_build_lines "$target_block" "$MOUNT_OPTS_MODE" "${SUBVOLS[@]}")
    lines+=("$(fstab_line_for_boot "$BOOT_DEV")")
    [[ -n "$EFI_DEV" ]]      && lines+=("$(fstab_line_for_efi "$EFI_DEV")")
    [[ -n "$SEP_HOME_DEV" ]] && lines+=("$(fstab_line_for_sep_home "$SEP_HOME_DEV")")

    # @ is the correct mountpoint root for fstab writes.
    local at_root="$TARGET_MP/@"
    fstab_write_managed_block "$at_root" "${lines[@]}"
}

phase_bootloader_and_initramfs() {
    local target_block; target_block="$ROOT_DEV"
    [[ "$ENCRYPT_MODE" != "none" ]] && target_block=$(luks_root_block "$ENCRYPT_MODE")
    local at_root="$TARGET_MP/@"

    # Mount /boot (and /boot/efi) inside the target root so grub/initramfs
    # tooling sees them.
    run mkdir -p "$at_root/boot"
    run mount -- "$BOOT_DEV" "$at_root/boot"
    on_rollback -- umount "$at_root/boot"
    if [[ -n "$EFI_DEV" ]]; then
        run mkdir -p "$at_root/boot/efi"
        run mount -- "$EFI_DEV" "$at_root/boot/efi"
        on_rollback -- umount "$at_root/boot/efi"
    fi

    # Bind /proc /sys /dev (and efivars if UEFI) into the target BEFORE
    # any chroot work. Both the initramfs rebuild and grub-install need
    # them. bootloader_apply also calls bind_target_mounts — that call is
    # idempotent via mount namespaces, but to keep the rollback stack
    # clean we bind once here and let bootloader_apply skip rebinding.
    bind_target_mounts "$at_root" "${EFI_DEV:+$at_root/boot/efi}"
    export BTRFS_MIGRATE_BIND_DONE=1

    local cmdline=""
    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        luks_write_crypttab "$at_root" "$ROOT_DEV" "$CRYPT_NAME"
        cmdline=$(luks_kernel_cmdline "$ROOT_DEV" "$ENCRYPT_MODE")
    fi

    # initramfs MUST be built before grub-mkconfig / bootctl write kernel
    # entries. Otherwise GRUB references an initrd that lacks the LUKS
    # unlock hooks and the machine is unbootable on first reboot.
    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        luks_configure_initramfs "$at_root" "$ENCRYPT_MODE"
    else
        case "$DISTRO_LIKE" in
            debian) run chroot "$at_root" update-initramfs -u -k all ;;
            arch)   run chroot "$at_root" mkinitcpio -P ;;
        esac
    fi

    bootloader_apply "$at_root" "${EFI_DEV:+$at_root/boot/efi}" "$BIOS_DISK" \
        "$BOOTLOADER" "$INSTALL_BOOTLOADER" "$ENCRYPT_BOOT" "$cmdline"
}

phase_snapshots() {
    local at_root="$TARGET_MP/@"
    (( WANT_SNAPPER == 1 ))         && snap_install_snapper        "$at_root" "$WANT_SNAPPER_HOME"
    (( WANT_TIMESHIFT == 1 ))       && snap_install_timeshift      "$at_root"
    (( WANT_GRUB_BTRFS == 1 ))      && snap_install_grub_btrfs     "$at_root"
    (( WANT_BTRFS_ASSISTANT == 1 )) && snap_install_btrfs_assistant "$at_root"
}

phase_verify() {
    # Minimal post-check: @ has an /etc/fstab with our managed block,
    # @home/<USERNAME> exists and is owned by the right uid/gid.
    local at_root="$TARGET_MP/@"
    [[ -f "$at_root/etc/fstab" ]] || die "Post-check: $at_root/etc/fstab missing." 40
    grep -qF "$FSTAB_TAG_BEGIN" "$at_root/etc/fstab" || die "Post-check: managed fstab block not written." 40
    if [[ -d "$TARGET_MP/@home/$USERNAME" ]]; then
        local uid_have; uid_have=$(stat -c '%u' "$TARGET_MP/@home/$USERNAME")
        local uid_want; uid_want=$(awk -F: -v n="$USERNAME" '$1==n{print $3; exit}' "$at_root/etc/passwd")
        [[ -n "$uid_want" && "$uid_have" == "$uid_want" ]] || \
            die "Post-check: /home/$USERNAME owner uid=$uid_have, passwd says $uid_want." 40
    fi

    # Bootloader entries must be recognized by the loader before we declare
    # success; a silently-malformed systemd-boot entry leaves the system
    # unbootable even though every prior phase succeeded.
    bootloader_verify_entries "$at_root" "$BOOTLOADER"

    ok "Post-migration verification passed."
}

phase_cleanup() {
    # Unmount in reverse order. Errors are tolerated; rollback stack
    # would also handle this on failures.
    local at_root="$TARGET_MP/@"
    [[ -n "$EFI_DEV" ]] && umount "$at_root/boot/efi" 2>/dev/null || true
    umount "$at_root/boot" 2>/dev/null || true
    for d in sys/firmware/efi/efivars run dev/pts dev sys proc; do
        umount "$at_root/$d" 2>/dev/null || true
    done
    umount "$TARGET_MP" 2>/dev/null || true
    rmdir "$TARGET_MP" 2>/dev/null || true
    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        cryptsetup close "$CRYPT_NAME" 2>/dev/null || true
    fi
    commit_phase   # success: don't let EXIT trap run rollbacks now
}

# -- Entry point -------------------------------------------------------------
main() {
    parse_args "$@"

    if [[ "${BTRFS_MIGRATE_REEXECED:-0}" != "1" ]]; then
        # First invocation (as the invoking user). Run preflight so we can
        # print an honest plan, confirm with the user, then sudo-re-exec.
        plan_phase_header preflight
        phase_preflight
        print_plan
        confirm_plan
        # Plan-only: collect commands across remaining phases without
        # executing them. We still need root to faithfully render commands
        # that probe state (lsblk/findmnt are read-only but would mismatch
        # under sudo permissions). Re-exec normally; child will re-enter
        # this branch with BTRFS_MIGRATE_REEXECED=1 and continue.
        require_root_or_reexec "$@"   # exec sudo env -i -- "$self" "$@"
    else
        # Post-re-exec as root. Skip plan/confirm (already done) but we
        # must re-populate DISTRO_*, EXEC_MODE and resolve SRC_MP/SUBVOLS
        # because those live in process-local shell state, not env.
        log "Resuming after sudo re-exec (root)."
        plan_phase_header preflight
        phase_preflight
    fi

    # From here on we're root.
    plan_phase_header encrypt;                phase_encrypt
    plan_phase_header mkfs_and_subvols;       phase_mkfs_and_subvols
    plan_phase_header migrate_data;           phase_migrate_data
    plan_phase_header fstab;                  phase_fstab
    plan_phase_header bootloader_and_initramfs; phase_bootloader_and_initramfs
    plan_phase_header snapshots;              phase_snapshots

    if (( BTRFS_MIGRATE_PLAN_ONLY == 1 )); then
        # phase_verify probes the populated tree — meaningless without
        # actual execution. Same for phase_cleanup's unmounts.
        printf '\nPlan written to %s\n' "$PLAN_FILE"
        ok "Plan-only complete. Review the file above, then re-run without --plan-only to execute."
        return 0
    fi

    plan_phase_header verify;  phase_verify
    plan_phase_header cleanup; phase_cleanup
    ok "Done. Reboot to use your new Btrfs root."
}

main "$@"
