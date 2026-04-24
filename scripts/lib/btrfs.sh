#!/usr/bin/env bash
# lib/btrfs.sh — subvolume creation and data migration with correct
# ownership handling. Fixes upstream issue #2 (the @home rsync left
# files root-owned, breaking login after reboot).

if [[ -n "${__BTRFS_MIGRATE_BTRFS_SH:-}" ]]; then return 0; fi
__BTRFS_MIGRATE_BTRFS_SH=1

# shellcheck source=log.sh
[[ -z "${__BTRFS_MIGRATE_LOG_SH:-}"    ]] && . "$(dirname "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=checks.sh
[[ -z "${__BTRFS_MIGRATE_CHECKS_SH:-}" ]] && . "$(dirname "${BASH_SOURCE[0]}")/checks.sh"

# Default subvolume list, preserved from upstream. Do NOT change ordering;
# @home must exist before we move /home data into it.
BTRFS_DEFAULT_SUBVOLS=(
    @ @home @log @cache @tmp @libvirt
    @flatpak @docker @containers @machines
    @var_tmp @opt
)

# Mapping of subvol -> on-target mountpoint (used by fstab.sh too).
# Exported as parallel arrays for portability across bash versions.
BTRFS_SUBVOL_MOUNT_KEYS=(@ @home @log @cache @libvirt @flatpak @docker @containers @machines @var_tmp @tmp @opt)
BTRFS_SUBVOL_MOUNT_VALS=(/ /home /var/log /var/cache /var/lib/libvirt /var/lib/flatpak /var/lib/docker /var/lib/containers /var/lib/machines /var/tmp /tmp /opt)

# btrfs_mountpoint_of SUBVOL — echo the default mountpoint for a subvol.
btrfs_mountpoint_of() {
    local want="$1" i
    for i in "${!BTRFS_SUBVOL_MOUNT_KEYS[@]}"; do
        if [[ "${BTRFS_SUBVOL_MOUNT_KEYS[$i]}" == "$want" ]]; then
            printf '%s' "${BTRFS_SUBVOL_MOUNT_VALS[$i]}"
            return 0
        fi
    done
    return 1
}

# btrfs_validate_subvols NAME1 NAME2... — ensure each begins with @, is
# distinct, and includes @ and @home.
btrfs_validate_subvols() {
    local -A seen=()
    local s has_root=0 has_home=0
    for s in "$@"; do
        [[ "$s" == @* ]] || die "Subvolume '$s' must start with '@'." 10
        [[ -n "${seen[$s]:-}" ]] && die "Duplicate subvolume '$s'." 10
        seen[$s]=1
        [[ "$s" == "@" ]]     && has_root=1
        [[ "$s" == "@home" ]] && has_home=1
    done
    (( has_root == 1 )) || die "Subvolume set must include '@' (root)." 10
    (( has_home == 1 )) || die "Subvolume set must include '@home'." 10
}

# btrfs_mkfs DEV [LABEL] — mkfs.btrfs on the selected root block device.
# Refuses to overwrite an existing filesystem unless BTRFS_MKFS_FORCE=1
# is set explicitly in the environment. This protects against rerunning
# the script after a partial success (where the partition is already a
# populated btrfs) silently wiping the prior migration.
#
# Existing-btrfs handling:
#   - If DEV is already btrfs AND BTRFS_MKFS_FORCE is unset -> die.
#   - If DEV is already btrfs AND BTRFS_MKFS_FORCE=1 -> wipefs + mkfs.
#   - If DEV has any other signature -> die (upstream policy: empty only).
btrfs_mkfs() {
    local dev="$1" label="${2:-}"
    ensure_bins mkfs.btrfs
    [[ -b "$dev" ]] || die "btrfs_mkfs: not a block device: $dev" 30

    local existing_fs=""
    existing_fs=$(lsblk -no FSTYPE -- "$dev" 2>/dev/null | head -n1 || true)
    if [[ -n "$existing_fs" ]]; then
        if [[ "$existing_fs" == "btrfs" ]] && [[ "${BTRFS_MKFS_FORCE:-0}" != "1" ]]; then
            die "Refusing mkfs.btrfs on $dev: already btrfs. Re-running would destroy the previous migration. Set BTRFS_MKFS_FORCE=1 to override." 30
        fi
        if [[ "$existing_fs" != "btrfs" ]]; then
            die "Refusing mkfs.btrfs on $dev: existing '$existing_fs' signature. Wipe it first." 10
        fi
        warn "BTRFS_MKFS_FORCE=1 — overwriting existing btrfs on $dev."
        run wipefs -a -- "$dev"
    fi

    local args=(-f)
    [[ -n "$label" ]] && args+=(-L "$label")
    log "mkfs.btrfs on $dev${label:+ (label=$label)}"
    run mkfs.btrfs "${args[@]}" -- "$dev"
}

# btrfs_mount_top DEV MP — mount the top of the btrfs (subvolid=5) at MP.
btrfs_mount_top() {
    local dev="$1" mp="$2"
    run mkdir -p "$mp"
    log "Mounting top-level subvol of $dev at $mp"
    run mount -o subvolid=5 -- "$dev" "$mp"
    on_rollback -- umount "$mp"
}

# btrfs_create_subvols MP SUBVOL1 SUBVOL2... — create subvolumes at the
# top-level of a mounted btrfs (MP is where subvolid=5 is mounted).
btrfs_create_subvols() {
    local mp="$1"; shift
    local s
    for s in "$@"; do
        if [[ -e "$mp/$s" ]]; then
            log "Subvolume $s already exists at $mp/$s (skipping)"
            continue
        fi
        log "Creating subvolume $s"
        run btrfs subvolume create -- "$mp/$s"
        on_rollback "btrfs subvolume delete '$mp/$s' 2>/dev/null || true"
    done
}

# btrfs_migrate_from_ext ROOTDEV TARGET_DEV SRC_MP — migrate an existing
# ext4 rootfs (mounted at SRC_MP) INTO the Btrfs at TARGET_DEV. The
# upstream script did this by snapshotting an ext4-converted-to-btrfs
# filesystem in place; that is unsafe. We copy instead.
#
# Because the user wants this v1 to support encryption (which forbids
# in-place over-existing-data) AND to support plain migration, we offer
# two paths from the caller: set MIGRATE_MODE=copy for encryption (the
# data comes from another mounted source), or MIGRATE_MODE=in-place
# when the upstream-style snapshot-from-existing-btrfs flow is used
# (caller guarantees DEV already contains data as btrfs).
#
# This function handles the 'copy' mode. SRC_MP is the source filesystem
# (read-only or read-write, doesn't matter), and @ and @home are populated
# under $TARGET_MP which must be the subvolid=5 mount of the new btrfs.
btrfs_populate_copy() {
    local src_mp="$1" target_mp="$2"
    ensure_bins rsync
    [[ -d "$src_mp" && -d "$target_mp" ]] || die "btrfs_populate_copy: src or target mp missing" 30

    # Root content -> @. Exclude pseudo filesystems and the target itself.
    log "Copying / into @ (this can take a while)"
    run rsync -aHAXS --numeric-ids --info=progress2 \
        --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
        --exclude='/run/*'  --exclude='/tmp/*'  --exclude='/mnt/*' \
        --exclude='/media/*' --exclude="$target_mp/*" \
        "$src_mp/" "$target_mp/@/"

    # Home content -> @home. Only do this if the source actually has /home
    # on the same root (the separate-/home branch is handled by
    # btrfs_home_strategy below).
    if [[ -d "$src_mp/home" ]]; then
        log "Copying /home into @home"
        run rsync -aHAXS --numeric-ids \
            "$src_mp/home/" "$target_mp/@home/"
    fi
}

# btrfs_verify_home_ownership TARGET_MP — walks @home/<dir> and checks
# each entry is owned by a uid matching a passwd entry. Corrects wrong
# ownership by looking up the user in the target's /etc/passwd.
# Directly addresses upstream issue #2.
#
# Before applying any chown, prints an announcement table so the operator
# sees exactly which paths will change and from which uid/gid to which.
# This makes post-migration UID drift auditable.
btrfs_verify_home_ownership() {
    local target_mp="$1"
    local home_sv="$target_mp/@home"
    [[ -d "$home_sv" ]] || { warn "No @home at $home_sv — skipping ownership check."; return 0; }

    # Prefer the target's /etc/passwd (more authoritative during Live-ISO migrations).
    local passwd="$target_mp/@/etc/passwd"
    [[ -f "$passwd" ]] || passwd=/etc/passwd
    [[ -f "$passwd" ]] || { warn "No passwd file found to cross-check ownership."; return 0; }

    # First pass: collect (path, cur, want, source) for every directory
    # whose ownership doesn't match. We print the table first, then chown,
    # so the operator sees the diff before the change.
    local -a changes=()  # tab-separated: path \t cur \t want \t source
    local d entry
    for d in "$home_sv"/*; do
        [[ -d "$d" ]] || continue
        local name; name=$(basename -- "$d")
        entry=$(awk -F: -v n="$name" '$1==n {print $3":"$4; exit}' "$passwd")
        if [[ -z "$entry" ]]; then
            warn "No passwd entry for home dir '$name' — leaving ownership untouched."
            continue
        fi
        local want_uid="${entry%%:*}" want_gid="${entry##*:}"
        local cur_uid; cur_uid=$(stat -c '%u' "$d")
        local cur_gid; cur_gid=$(stat -c '%g' "$d")
        if [[ "$cur_uid" != "$want_uid" || "$cur_gid" != "$want_gid" ]]; then
            changes+=("$d"$'\t'"$cur_uid:$cur_gid"$'\t'"$want_uid:$want_gid"$'\t'"target /etc/passwd")
        fi
    done

    if (( ${#changes[@]} == 0 )); then
        log "No /home ownership changes needed."
        return 0
    fi

    printf '\n===== /home ownership changes =====\n' >&2
    printf '  %-40s  %-10s  %-10s  %s\n' "PATH" "CURRENT" "DESIRED" "SOURCE" >&2
    local row path cur want src
    for row in "${changes[@]}"; do
        path="${row%%$'\t'*}";    row="${row#*$'\t'}"
        cur="${row%%$'\t'*}";     row="${row#*$'\t'}"
        want="${row%%$'\t'*}";    src="${row#*$'\t'}"
        printf '  %-40s  %-10s  %-10s  %s\n' "$path" "$cur" "$want" "$src" >&2
    done
    printf '\n' >&2

    # Second pass: apply. Skipped under plan-only (run() handles that).
    for row in "${changes[@]}"; do
        path="${row%%$'\t'*}";    row="${row#*$'\t'}"
        cur="${row%%$'\t'*}";     row="${row#*$'\t'}"
        want="${row%%$'\t'*}"
        log "Fixing ownership of $path ($cur -> $want) [issue #2]"
        run chown -R --no-dereference "$want" "$path"
    done
}

# btrfs_move_var_bits TARGET_MP — the upstream script tried to move
# /var/log and /var/cache content into their subvolumes after the fact
# and got it mostly wrong (moved content out from under @'s own copy).
# We do it right: after the @ subvolume is populated, we move
# @/var/log/* -> @log/, same for cache/tmp, then leave the dir empty
# so fstab-mounted subvol covers it at boot.
btrfs_move_var_bits() {
    local target_mp="$1"
    local -a pairs=(
        "@/var/log:@log"
        "@/var/cache:@cache"
        "@/var/tmp:@var_tmp"
        "@/tmp:@tmp"
        "@/opt:@opt"
        "@/var/lib/libvirt:@libvirt"
        "@/var/lib/flatpak:@flatpak"
        "@/var/lib/docker:@docker"
        "@/var/lib/containers:@containers"
        "@/var/lib/machines:@machines"
    )
    local pair src dst
    for pair in "${pairs[@]}"; do
        src="$target_mp/${pair%%:*}"
        dst="$target_mp/${pair##*:}"
        [[ -d "$src" && -d "$dst" ]] || continue
        # Only move if dst is empty (idempotency: re-runs don't double-move).
        if [[ -z "$(ls -A "$dst")" ]]; then
            log "Moving $src -> $dst"
            # rsync with --remove-source-files then cleanup empty dirs.
            run rsync -aHAXS --numeric-ids --remove-source-files "$src/" "$dst/"
            run find "$src" -mindepth 1 -type d -empty -delete
        else
            debug "$dst is not empty, skipping move"
        fi
    done
}

# btrfs_home_strategy ROOT_SRC_MP SEP_HOME_DEV TARGET_MP --convert
#
# Implements the user's policy:
#   - If /home is on same rootfs -> migrate into @home (already done by
#     btrfs_populate_copy).
#   - If /home is on a separate partition AND --convert-home NOT set ->
#     do nothing; caller must keep it mounted as-is via fstab.
#   - If /home is on a separate partition AND --convert-home set ->
#     convert that separate partition to its own Btrfs (not merged into
#     the root). Caller still mounts it at /home via fstab.
#
# Arguments:
#   $1 ROOT_SRC_MP  — where the source rootfs is mounted
#   $2 SEP_HOME_DEV — the separate /home partition, or "" if none
#   $3 TARGET_MP    — where subvolid=5 of the new root btrfs is mounted
#   $4 CONVERT      — 1 to convert the separate /home to its own Btrfs, 0 otherwise
btrfs_home_strategy() {
    local root_src_mp="$1" sep_home="$2" target_mp="$3" convert="${4:-0}"
    if [[ -z "$sep_home" ]]; then
        debug "No separate /home partition — already handled by @home copy."
        return 0
    fi
    warn "Separate /home partition detected: $sep_home"
    if (( convert == 0 )); then
        log "Leaving separate /home as-is. fstab will mount it at /home directly."
        return 0
    fi
    # Convert: stage the data to a tmp location, mkfs.btrfs the partition,
    # mount it, create a single @home subvolume, restore data, chown.
    local stage; stage=$(mktemp -d -t btrfs-migrate-home.XXXXXX)
    on_rollback "rm -rf '$stage' 2>/dev/null || true"
    log "Staging separate /home contents to $stage"
    # Mount the existing /home partition read-only to stage it.
    local tmp_mp; tmp_mp=$(mktemp -d)
    on_rollback "umount '$tmp_mp' 2>/dev/null || true; rmdir '$tmp_mp' 2>/dev/null || true"
    run mount -o ro -- "$sep_home" "$tmp_mp"
    run rsync -aHAXS --numeric-ids "$tmp_mp/" "$stage/"
    run umount "$tmp_mp"; rmdir "$tmp_mp" 2>/dev/null || true

    log "Re-formatting $sep_home as Btrfs"
    ensure_bins mkfs.btrfs
    run mkfs.btrfs -f -L home -- "$sep_home"

    local new_mp; new_mp=$(mktemp -d)
    on_rollback "umount '$new_mp' 2>/dev/null || true; rmdir '$new_mp' 2>/dev/null || true"
    run mount -o subvolid=5 -- "$sep_home" "$new_mp"
    run btrfs subvolume create -- "$new_mp/@home"
    on_rollback "btrfs subvolume delete '$new_mp/@home' 2>/dev/null || true"
    log "Restoring staged /home contents into @home"
    run rsync -aHAXS --numeric-ids "$stage/" "$new_mp/@home/"
    run umount "$new_mp"; rmdir "$new_mp" 2>/dev/null || true
    run rm -rf "$stage"
    ok "Separate /home converted to Btrfs with @home subvolume. Mount it via fstab."
}

# btrfs_postmigrate_check TARGET_MP [BOOT_DEV] — assert that the populated
# @ subvolume contains the minimum files needed for a bootable system.
# rsync exit code 0 is not sufficient proof of completeness — this catches
# mid-flight terminations or silently-dropped directories.
#
# A kernel image is allowed to live either inside @/boot (when /boot is on
# the same partition) or on the separate --boot partition; when BOOT_DEV is
# passed we additionally probe the device's mounted kernels via findmnt.
btrfs_postmigrate_check() {
    local target_mp="$1" boot_dev="${2:-}"
    local at="$target_mp/@"
    [[ -d "$at" ]] || die "Post-rsync: $at missing." 40

    local -a required=(
        "$at/etc/passwd"
        "$at/etc/shadow"
        "$at/etc/fstab"
    )
    # shell can live in either /bin/sh or /usr/bin/sh depending on distro.
    local shell_ok=0
    [[ -e "$at/bin/sh" || -e "$at/usr/bin/sh" ]] && shell_ok=1

    local -a missing=()
    local f
    for f in "${required[@]}"; do
        [[ -e "$f" ]] || missing+=("$f")
    done
    (( shell_ok == 1 )) || missing+=("$at/bin/sh or $at/usr/bin/sh")

    # Kernel image: check both @/boot/vmlinuz* and, if the separate boot
    # device is mounted, its vmlinuz*.
    local kernel_ok=0
    if compgen -G "$at/boot/vmlinuz-*" >/dev/null 2>&1 || [[ -e "$at/boot/vmlinuz" ]]; then
        kernel_ok=1
    fi
    if (( kernel_ok == 0 )) && [[ -n "$boot_dev" ]]; then
        local boot_mp; boot_mp=$(findmnt -nro TARGET --source "$boot_dev" 2>/dev/null | head -n1 || true)
        if [[ -n "$boot_mp" ]] && compgen -G "$boot_mp/vmlinuz-*" >/dev/null 2>&1; then
            kernel_ok=1
        fi
    fi
    (( kernel_ok == 1 )) || missing+=("kernel image under @/boot/vmlinuz-* or $boot_dev")

    if (( ${#missing[@]} > 0 )); then
        local m
        for m in "${missing[@]}"; do error "Post-rsync: missing $m"; done
        die "Post-rsync: target tree is incomplete — rsync reported success but critical files are absent. See missing paths above." 40
    fi
    ok "Post-rsync integrity check passed (${#required[@]} required + sh + kernel)."
}
