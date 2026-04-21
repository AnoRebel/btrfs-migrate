#!/usr/bin/env bash
# lib/luks.sh — LUKS2 and LVM-on-LUKS provisioning, plus crypttab +
# initramfs wiring. Encryption targets must be EMPTY partitions; we
# refuse anything else.

if [[ -n "${__BTRFS_MIGRATE_LUKS_SH:-}" ]]; then return 0; fi
__BTRFS_MIGRATE_LUKS_SH=1

# shellcheck source=log.sh
[[ -z "${__BTRFS_MIGRATE_LOG_SH:-}"    ]] && . "$(dirname "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=checks.sh
[[ -z "${__BTRFS_MIGRATE_CHECKS_SH:-}" ]] && . "$(dirname "${BASH_SOURCE[0]}")/checks.sh"

# Name of the unlocked mapper node.
CRYPT_NAME="${CRYPT_NAME:-cryptroot}"
# Name of the LVM VG (used only in lvm-luks mode).
LVM_VG="${LVM_VG:-vgcrypt}"
# Name of the root LV (used only in lvm-luks mode).
LVM_LV_ROOT="${LVM_LV_ROOT:-root}"

# luks_tools_installed — verify/install cryptsetup (and lvm2 for lvm-luks).
luks_tools_installed() {
    local mode="$1"   # luks | lvm-luks
    local need=(cryptsetup)
    [[ "$mode" == "lvm-luks" ]] && need+=(lvm2)

    local missing=()
    local b
    for b in "${need[@]}"; do have "$b" || missing+=("$b"); done

    if (( ${#missing[@]} > 0 )); then
        log "Installing encryption tooling: ${missing[*]}"
        pkg_install "${missing[@]}" || die "Failed to install: ${missing[*]}" 30
    fi
    ensure_bins cryptsetup
    [[ "$mode" == "lvm-luks" ]] && ensure_bins pvcreate vgcreate lvcreate
}

# luks_require_empty DEV — refuse if the partition has any signature.
# Directly enforces the user's policy: "only encrypt new installs /
# empty partitions. Refuse if data exists."
luks_require_empty() {
    local dev="$1"
    require_partition "$dev"
    if ! partition_is_empty "$dev"; then
        local sigs
        sigs=$(wipefs --no-act -- "$dev" 2>/dev/null | tail -n +2 | awk '{print $5" ("$6")"}' | paste -sd', ')
        die "Refusing to encrypt $dev: existing signature(s) found: ${sigs:-unknown}. Wipe the partition first if you really want encryption here." 10
    fi
    debug "Partition $dev is empty — safe to encrypt."
}

# luks_format DEV [KEYFILE] — format as LUKS2, then open at $CRYPT_NAME.
# If KEYFILE is empty, prompts on the TTY (cryptsetup handles that).
# Arguments:
#   $1 DEV     — target partition (must be empty per policy above).
#   $2 KEYFILE — optional path to a pre-existing key file (for unattended).
luks_format() {
    local dev="$1" keyfile="${2:-}"
    luks_require_empty "$dev"

    local args=(
        --type luks2
        --cipher aes-xts-plain64
        --key-size 512
        --hash sha256
        --pbkdf argon2id
        --use-urandom
        --batch-mode
    )

    log "LUKS2-formatting $dev (cipher=aes-xts-plain64, pbkdf=argon2id)"
    if [[ -n "$keyfile" ]]; then
        [[ -r "$keyfile" ]] || die "Keyfile not readable: $keyfile" 10
        run cryptsetup luksFormat "${args[@]}" --key-file "$keyfile" -- "$dev"
        on_rollback -- cryptsetup close "$CRYPT_NAME"
        run cryptsetup open --type luks --key-file "$keyfile" -- "$dev" "$CRYPT_NAME"
    else
        # Interactive: cryptsetup will prompt on the TTY. The ERR trap
        # will fire if the user aborts; that's OK (the partition's still
        # empty because we refused non-empty above).
        run cryptsetup luksFormat "${args[@]}" -- "$dev"
        on_rollback -- cryptsetup close "$CRYPT_NAME"
        run cryptsetup open --type luks -- "$dev" "$CRYPT_NAME"
    fi
    [[ -b "/dev/mapper/$CRYPT_NAME" ]] || die "LUKS open did not produce /dev/mapper/$CRYPT_NAME" 30
    ok "LUKS container open at /dev/mapper/$CRYPT_NAME"
}

# luks_provision_lvm — create PV/VG/LV on /dev/mapper/$CRYPT_NAME.
# After this call, /dev/$LVM_VG/$LVM_LV_ROOT is the block device that
# Btrfs should be created on.
luks_provision_lvm() {
    local mapper="/dev/mapper/$CRYPT_NAME"
    [[ -b "$mapper" ]] || die "Expected $mapper to be open before LVM provisioning." 30
    log "Creating LVM on $mapper (VG=$LVM_VG LV=$LVM_LV_ROOT)"
    # Tame-identifier enforcement — these values reach rollback argv and
    # appear in paths and LVM names.
    [[ "$LVM_VG"      =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "Invalid LVM VG name: $LVM_VG"      10
    [[ "$LVM_LV_ROOT" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "Invalid LVM LV name: $LVM_LV_ROOT" 10
    run pvcreate -ff -y "$mapper"
    on_rollback -- pvremove -ff -y "$mapper"
    run vgcreate "$LVM_VG" "$mapper"
    on_rollback -- vgremove -ff -y "$LVM_VG"
    # Use all free extents for the root LV. Users who want /home on its own
    # LV can run lvcreate themselves after the migration.
    run lvcreate -l 100%FREE -n "$LVM_LV_ROOT" "$LVM_VG"
    on_rollback -- lvremove -ff -y "$LVM_VG/$LVM_LV_ROOT"
    [[ -b "/dev/$LVM_VG/$LVM_LV_ROOT" ]] || die "Expected /dev/$LVM_VG/$LVM_LV_ROOT after lvcreate." 30
}

# luks_root_block — echo the block device that Btrfs should go on,
# given the selected encryption mode.
#   luks        -> /dev/mapper/$CRYPT_NAME
#   lvm-luks    -> /dev/$LVM_VG/$LVM_LV_ROOT
luks_root_block() {
    case "$1" in
        luks)     printf '/dev/mapper/%s' "$CRYPT_NAME" ;;
        lvm-luks) printf '/dev/%s/%s' "$LVM_VG" "$LVM_LV_ROOT" ;;
        *)        die "luks_root_block: unknown mode '$1'" 10 ;;
    esac
}

# luks_write_crypttab ROOT_MOUNT DEV CRYPT_NAME — write /etc/crypttab
# on the target filesystem.
# Entry format (standard on both Ubuntu and Arch):
#   <name>  UUID=<uuid>  none  luks,discard
luks_write_crypttab() {
    local root_mp="$1" dev="$2" name="$3"
    local uuid_eq; uuid_eq=$(uuid_of "$dev")
    local tab="$root_mp/etc/crypttab"
    local line="$name $uuid_eq none luks,discard"
    # CRYPT_NAME and LVM_VG/LV names are used as regex literals below and
    # as column-1 keys; reject anything that isn't a tame identifier so a
    # hostile env override can't smuggle in shell or regex metachars.
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "Invalid crypt mapper name: $name" 10
    if [[ ! -f "$tab" ]]; then
        log "Creating $tab"
        write_file "$tab" "# <name> <device> <password> <options>
$line
"
    else
        # Idempotent replace-or-append keyed on first column (name).
        if grep -Eq "^[[:space:]]*${name}[[:space:]]" "$tab"; then
            log "Updating existing $tab entry for $name"
            run sed -i -E "s|^[[:space:]]*${name}[[:space:]].*|${line}|" "$tab"
        else
            log "Appending $tab entry for $name"
            append_file "$tab" "$line
"
        fi
    fi
    run chmod 0600 "$tab"
}

# luks_kernel_cmdline DEV — produce the bits that need to be added to
# GRUB_CMDLINE_LINUX so the initramfs can unlock the root.
# Ubuntu and Arch use different conventions:
#   Ubuntu (cryptsetup-initramfs): no kernel args needed when crypttab is
#     populated; but we emit a stable hint anyway for GRUB menu titles.
#   Arch (mkinitcpio 'encrypt' hook): needs cryptdevice=UUID=xxx:name
#     [root=/dev/mapper/<name> or root=/dev/<vg>/<lv>]
luks_kernel_cmdline() {
    local dev="$1" mode="$2"
    local uuid_eq; uuid_eq=$(uuid_of "$dev")
    local root_block; root_block=$(luks_root_block "$mode")
    case "$DISTRO_LIKE" in
        arch)
            printf 'cryptdevice=%s:%s root=%s' "$uuid_eq" "$CRYPT_NAME" "$root_block"
            ;;
        debian)
            printf 'root=%s' "$root_block"
            ;;
        *)
            printf 'root=%s' "$root_block"
            ;;
    esac
}

# luks_configure_initramfs ROOT_MOUNT — arrange for the unlock keys/hooks
# to be baked into the initramfs of the target system. Caller must have
# bind-mounted /proc /sys /dev into $root_mp already (bootloader.sh does).
luks_configure_initramfs() {
    local root_mp="$1" mode="$2"
    case "$DISTRO_LIKE" in
        debian)
            # Make sure cryptsetup-initramfs is present in the target.
            # It is what reads /etc/crypttab at boot.
            log "Ensuring cryptsetup-initramfs in target"
            run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cryptsetup-initramfs
            # Force CRYPTSETUP=y in conf-hook (Ubuntu 24.04+ default is y but be explicit).
            local hook="$root_mp/etc/cryptsetup-initramfs/conf-hook"
            if [[ -f "$hook" ]]; then
                if grep -q '^#\?CRYPTSETUP=' "$hook"; then
                    run sed -i -E 's|^#?CRYPTSETUP=.*|CRYPTSETUP=y|' "$hook"
                else
                    append_file "$hook" "CRYPTSETUP=y
"
                fi
            fi
            run chroot "$root_mp" update-initramfs -u -k all
            ;;
        arch)
            # mkinitcpio needs 'encrypt' before 'filesystems' in HOOKS.
            # For lvm-luks, also 'lvm2' before 'filesystems'.
            local conf="$root_mp/etc/mkinitcpio.conf"
            [[ -f "$conf" ]] || die "Missing $conf on target" 30
            local insert="encrypt"
            [[ "$mode" == "lvm-luks" ]] && insert="encrypt lvm2"
            # Only touch if the required hooks aren't already present.
            if ! grep -Eq "^HOOKS=\(.*\bencrypt\b.*\)" "$conf"; then
                log "Adding '$insert' to mkinitcpio HOOKS before 'filesystems'"
                run sed -i -E "s|^(HOOKS=\([^)]*) filesystems|\\1 $insert filesystems|" "$conf"
            elif [[ "$mode" == "lvm-luks" ]] && ! grep -Eq "^HOOKS=\(.*\blvm2\b.*\)" "$conf"; then
                run sed -i -E "s|^(HOOKS=\([^)]*\bencrypt\b)|\\1 lvm2|" "$conf"
            fi
            run chroot "$root_mp" mkinitcpio -P
            ;;
        *)
            warn "No initramfs wiring for DISTRO_LIKE='$DISTRO_LIKE' — caller must handle."
            ;;
    esac
}
