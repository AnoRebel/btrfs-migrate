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

SAFETY:
  --dry-run             Print the plan, don't touch anything.
  --force-installed     Allow running on an installed system (not recommended).
  --i-have-backups      Required for destructive execution.
  --yes                 Non-interactive. Skip plan confirmation.

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
            --force-installed)   FORCE_INSTALLED=1; shift ;;
            --i-have-backups)    I_HAVE_BACKUPS=1; shift ;;
            --yes|-y)            ASSUME_YES=1; shift ;;
            --help|-h)           show_help; exit 0 ;;
            --version|-V)        printf 'btrfs-migrate %s\n' "$VERSION"; exit 0 ;;
            *) die "Unknown argument: $1 (try --help)" 10 ;;
        esac
    done
    export DRY_RUN   # log.sh reads this
}

# -- Validation --------------------------------------------------------------
validate_args() {
    [[ -n "$ROOT_DEV" ]] || die "--root is required." 10
    [[ -n "$BOOT_DEV" ]] || die "--boot is required." 10

    require_partition "$ROOT_DEV"
    require_partition "$BOOT_DEV"
    [[ -n "$EFI_DEV" ]] && require_partition "$EFI_DEV"
    [[ -n "$SEP_HOME_DEV" ]] && require_partition "$SEP_HOME_DEV"

    case "$ENCRYPT_MODE" in none|luks|lvm-luks) : ;; *) die "--encrypt must be one of: none|luks|lvm-luks" 10 ;; esac
    case "$BOOTLOADER"   in grub|systemd-boot) : ;; *) die "--bootloader must be one of: grub|systemd-boot" 10 ;; esac
    case "$MOUNT_OPTS_MODE" in safe|perf) : ;; *) die "--mount-opts must be one of: safe|perf" 10 ;; esac

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
    require_user "$USERNAME"

    # Resolve subvolume list.
    if [[ -n "$SUBVOLS_CSV" ]]; then
        IFS=',' read -r -a SUBVOLS <<<"$SUBVOLS_CSV"
    else
        SUBVOLS=("${BTRFS_DEFAULT_SUBVOLS[@]}")
    fi
    btrfs_validate_subvols "${SUBVOLS[@]}"
    (( WANT_TIMESHIFT == 1 )) && snap_warn_layout_for_timeshift "${SUBVOLS[@]}"

    # Encryption + data-present is a hard refusal.
    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        luks_require_empty "$ROOT_DEV"
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
        [[ -d "$SRC_MP" ]] || die "--src-mp '$SRC_MP' does not exist." 10
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
}

phase_encrypt() {
    [[ "$ENCRYPT_MODE" == "none" ]] && return 0
    luks_tools_installed "$ENCRYPT_MODE"
    luks_format "$ROOT_DEV"
    if [[ "$ENCRYPT_MODE" == "lvm-luks" ]]; then
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

    # Mount /boot (and /boot/efi) inside the target root so grub sees them.
    run mkdir -p "$at_root/boot"
    run mount -- "$BOOT_DEV" "$at_root/boot"
    on_rollback "umount '$at_root/boot' 2>/dev/null || true"
    if [[ -n "$EFI_DEV" ]]; then
        run mkdir -p "$at_root/boot/efi"
        run mount -- "$EFI_DEV" "$at_root/boot/efi"
        on_rollback "umount '$at_root/boot/efi' 2>/dev/null || true"
    fi

    # LUKS wiring BEFORE initramfs rebuild.
    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        luks_write_crypttab "$at_root" "$ROOT_DEV" "$CRYPT_NAME"
        # luks_configure_initramfs needs proc/sys/dev already bound, and
        # bootloader_apply will bind them. Do initramfs AFTER bind.
    fi

    local cmdline=""
    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        cmdline=$(luks_kernel_cmdline "$ROOT_DEV" "$ENCRYPT_MODE")
    fi

    bootloader_apply "$at_root" "${EFI_DEV:+$at_root/boot/efi}" "$BIOS_DISK" \
        "$BOOTLOADER" "$INSTALL_BOOTLOADER" "$ENCRYPT_BOOT" "$cmdline"

    if [[ "$ENCRYPT_MODE" != "none" ]]; then
        luks_configure_initramfs "$at_root" "$ENCRYPT_MODE"
    else
        case "$DISTRO_LIKE" in
            debian) run chroot "$at_root" update-initramfs -u -k all ;;
            arch)   run chroot "$at_root" mkinitcpio -P ;;
        esac
    fi
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
    # Preflight happens as the invoking user (for live-ISO detection and
    # $SUDO_USER awareness). After plan confirmation we re-exec via sudo.
    phase_preflight
    print_plan
    confirm_plan
    require_root_or_reexec "$@"

    # From here on we're root.
    phase_encrypt
    phase_mkfs_and_subvols
    phase_migrate_data
    phase_fstab
    phase_bootloader_and_initramfs
    phase_snapshots
    phase_verify
    phase_cleanup
    ok "Done. Reboot to use your new Btrfs root."
}

main "$@"
