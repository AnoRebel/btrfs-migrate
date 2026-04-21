#!/usr/bin/env bash
# lib/fstab.sh — compute btrfs mount options (safe vs perf, SSD-aware)
# and edit /etc/fstab idempotently by mountpoint. Replaces upstream's
# blanket `sed -i "/ btrfs /d"` which also nukes any user-managed lines.

if [[ -n "${__BTRFS_MIGRATE_FSTAB_SH:-}" ]]; then return 0; fi
__BTRFS_MIGRATE_FSTAB_SH=1

# shellcheck source=log.sh
[[ -z "${__BTRFS_MIGRATE_LOG_SH:-}"    ]] && . "$(dirname "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=checks.sh
[[ -z "${__BTRFS_MIGRATE_CHECKS_SH:-}" ]] && . "$(dirname "${BASH_SOURCE[0]}")/checks.sh"
# shellcheck source=btrfs.sh
[[ -z "${__BTRFS_MIGRATE_BTRFS_SH:-}"  ]] && . "$(dirname "${BASH_SOURCE[0]}")/btrfs.sh"

# Marker comments so we can re-find and replace OUR lines without
# touching the user's hand-edited rows.
FSTAB_TAG_BEGIN='# BEGIN btrfs-migrate managed'
FSTAB_TAG_END='# END   btrfs-migrate managed'

# fstab_btrfs_options DEV MODE — compute mount options string.
#
#   MODE=safe  ->  defaults,noatime,compress=zstd
#   MODE=perf  ->  defaults,noatime,compress=zstd:3
#                   +ssd              if the backing disk is non-rotational
#
# We intentionally do NOT hardcode space_cache=v2; the kernel has that as
# default since 5.15 and adding it again is stale-advice cargo.
# We intentionally do NOT hardcode discard=async; the drive-level
# behavior is better controlled by fstrim.timer on both Ubuntu and Arch.
fstab_btrfs_options() {
    local dev="$1" mode="${2:-safe}" subvol="$3"
    local opts
    case "$mode" in
        safe) opts='defaults,noatime,compress=zstd' ;;
        perf)
            opts='defaults,noatime,compress=zstd:3'
            if is_ssd "$dev"; then
                opts+=',ssd'
            fi
            ;;
        *) die "fstab_btrfs_options: unknown mode '$mode' (want safe|perf)" 10 ;;
    esac
    printf '%s,subvol=%s' "$opts" "$subvol"
}

# fstab_write_managed_block ROOT_MP — rewrite our managed block between
# the BEGIN/END marker lines. Preserves everything outside the block.
# All other arguments are the raw fstab lines to write inside the block.
fstab_write_managed_block() {
    local root_mp="$1"; shift
    local fstab="$root_mp/etc/fstab"
    [[ -f "$fstab" ]] || die "No fstab at $fstab" 30

    local tmp; tmp=$(mktemp)
    on_rollback "rm -f '$tmp' 2>/dev/null || true"

    # Copy everything OUTSIDE our markers to tmp (if markers exist at all).
    if grep -qF "$FSTAB_TAG_BEGIN" "$fstab"; then
        awk -v b="$FSTAB_TAG_BEGIN" -v e="$FSTAB_TAG_END" '
            index($0,b)==1 { inblock=1; next }
            index($0,e)==1 { inblock=0; next }
            !inblock { print }
        ' "$fstab" > "$tmp"
    else
        cp -a "$fstab" "$tmp"
    fi

    # Ensure a trailing newline before appending, then append our block.
    [[ -s "$tmp" ]] && tail -c1 "$tmp" | read -r _ || printf '\n' >> "$tmp"
    {
        printf '\n%s\n' "$FSTAB_TAG_BEGIN"
        printf '%s\n' "$@"
        printf '%s\n' "$FSTAB_TAG_END"
    } >> "$tmp"

    # Backup the original and install atomically.
    local bak="$fstab.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    log "Backing up $fstab to $bak"
    run cp -a -- "$fstab" "$bak"
    on_rollback "cp -a '$bak' '$fstab' 2>/dev/null || true"
    log "Writing updated $fstab"
    run install -m 0644 -T -- "$tmp" "$fstab"
    rm -f -- "$tmp"
}

# fstab_build_lines ROOTDEV MODE SUBVOL1 SUBVOL2... — echo the fstab
# lines (one per subvol) that should live inside the managed block.
fstab_build_lines() {
    local rootdev="$1" mode="$2"; shift 2
    local uuid_eq; uuid_eq=$(uuid_of "$rootdev")
    local s mp opts
    for s in "$@"; do
        mp=$(btrfs_mountpoint_of "$s") || {
            warn "No canonical mountpoint for subvol '$s' — skipping fstab entry."
            continue
        }
        opts=$(fstab_btrfs_options "$rootdev" "$mode" "$s")
        printf '%-40s  %-16s  %-6s  %-60s  0 0\n' "$uuid_eq" "$mp" "btrfs" "$opts"
    done
}

# fstab_line_for_boot BOOTDEV — /boot fstab line (ext4).
fstab_line_for_boot() {
    local dev="$1" uuid_eq; uuid_eq=$(uuid_of "$dev")
    printf '%-40s  %-16s  %-6s  %-60s  0 2\n' "$uuid_eq" "/boot" "ext4" "defaults,noatime"
}

# fstab_line_for_efi EFIDEV — /boot/efi fstab line (vfat).
fstab_line_for_efi() {
    local dev="$1" uuid_eq; uuid_eq=$(uuid_of "$dev")
    printf '%-40s  %-16s  %-6s  %-60s  0 1\n' "$uuid_eq" "/boot/efi" "vfat" "umask=0077,shortname=winnt,noatime"
}

# fstab_line_for_sep_home SEP_HOME_DEV — /home fstab line when the user
# keeps a separate /home partition (with or without --convert-home).
fstab_line_for_sep_home() {
    local dev="$1" uuid_eq; uuid_eq=$(uuid_of "$dev")
    local fs; fs=$(fs_of "$dev")
    local opts
    case "$fs" in
        btrfs) opts=$(fstab_btrfs_options "$dev" "${MOUNT_OPTS_MODE:-safe}" "@home") ;;
        ext4)  opts='defaults,noatime' ;;
        xfs)   opts='defaults,noatime' ;;
        *)     opts='defaults,noatime' ;;
    esac
    printf '%-40s  %-16s  %-6s  %-60s  0 2\n' "$uuid_eq" "/home" "$fs" "$opts"
}
