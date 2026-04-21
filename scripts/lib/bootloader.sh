#!/usr/bin/env bash
# lib/bootloader.sh — GRUB and systemd-boot dispatch across Ubuntu and
# Arch, with the encrypted-/boot edge case handled explicitly.

if [[ -n "${__BTRFS_MIGRATE_BOOT_SH:-}" ]]; then return 0; fi
__BTRFS_MIGRATE_BOOT_SH=1

# shellcheck source=log.sh
[[ -z "${__BTRFS_MIGRATE_LOG_SH:-}"    ]] && . "$(dirname "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=checks.sh
[[ -z "${__BTRFS_MIGRATE_CHECKS_SH:-}" ]] && . "$(dirname "${BASH_SOURCE[0]}")/checks.sh"
# shellcheck source=luks.sh
[[ -z "${__BTRFS_MIGRATE_LUKS_SH:-}"   ]] && . "$(dirname "${BASH_SOURCE[0]}")/luks.sh"

# bootloader_validate CHOICE ENCRYPT_BOOT — refuse impossible combos.
# systemd-boot cannot prompt for an encrypted /boot passphrase; that is a
# hard "fail fast" per the user spec.
bootloader_validate() {
    local choice="$1" encrypt_boot="${2:-0}"
    case "$choice" in
        grub|systemd-boot) : ;;
        *) die "bootloader: unknown choice '$choice' (want grub|systemd-boot)" 10 ;;
    esac
    if [[ "$choice" == "systemd-boot" ]] && (( encrypt_boot == 1 )); then
        die "systemd-boot does not support encrypted /boot. Use GRUB (--bootloader grub) or drop --encrypt-boot." 10
    fi
}

# bind_target_mounts ROOT_MP EFI_MP — bind /proc /sys /dev /dev/pts /run
# into the target and, when EFI_MP is non-empty, also efivarfs so
# grub-install / bootctl can write NVRAM entries. Registers rollbacks.
bind_target_mounts() {
    local root_mp="$1" efi_mp="${2:-}"
    local d
    for d in proc sys dev dev/pts run; do
        run mkdir -p "$root_mp/$d"
        run mount --bind "/$d" "$root_mp/$d"
        on_rollback "umount '$root_mp/$d' 2>/dev/null || true"
    done
    if [[ -n "$efi_mp" ]] && [[ -d /sys/firmware/efi/efivars ]]; then
        run mkdir -p "$root_mp/sys/firmware/efi/efivars"
        run mount --bind /sys/firmware/efi/efivars "$root_mp/sys/firmware/efi/efivars"
        on_rollback "umount '$root_mp/sys/firmware/efi/efivars' 2>/dev/null || true"
    fi
}

# -- GRUB --------------------------------------------------------------------

# grub_tune_defaults ROOT_MP CMDLINE_EXTRA [ENCRYPT_BOOT]
# Edits /etc/default/grub in the target:
#   - Appends CMDLINE_EXTRA to GRUB_CMDLINE_LINUX (dedup).
#   - GRUB_ENABLE_CRYPTODISK=y if ENCRYPT_BOOT==1.
#   - GRUB_PRELOAD_MODULES adds 'luks2 cryptodisk' when encrypted.
grub_tune_defaults() {
    local root_mp="$1" cmd_extra="${2:-}" enc_boot="${3:-0}"
    local file="$root_mp/etc/default/grub"
    [[ -f "$file" ]] || {
        log "Creating $file"
        run bash -c "printf '%s\n' 'GRUB_TIMEOUT=5' 'GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"' 'GRUB_CMDLINE_LINUX=\"\"' > \"$file\""
    }

    # Append cmd_extra to GRUB_CMDLINE_LINUX without duplication.
    if [[ -n "$cmd_extra" ]]; then
        local cur
        cur=$(awk -F'=' '/^GRUB_CMDLINE_LINUX=/{print; exit}' "$file" | sed -E 's/^GRUB_CMDLINE_LINUX="?//; s/"?$//')
        # Is every token of cmd_extra already present?
        local need=0 tok
        for tok in $cmd_extra; do
            [[ " $cur " == *" $tok "* ]] || need=1
        done
        if (( need == 1 )); then
            local new="$cur"
            for tok in $cmd_extra; do
                [[ " $new " == *" $tok "* ]] || new="${new:+$new }$tok"
            done
            log "Setting GRUB_CMDLINE_LINUX in $file"
            run sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new\"|" "$file"
        fi
    fi

    if (( enc_boot == 1 )); then
        _grub_kv_set "$file" GRUB_ENABLE_CRYPTODISK y
        # Preload luks2 + cryptodisk so GRUB can read the keyfile/prompt.
        local cur_preload
        cur_preload=$(awk -F'=' '/^GRUB_PRELOAD_MODULES=/{print; exit}' "$file" | sed -E 's/^GRUB_PRELOAD_MODULES="?//; s/"?$//')
        local want
        for want in luks2 cryptodisk; do
            [[ " $cur_preload " == *" $want "* ]] || cur_preload="${cur_preload:+$cur_preload }$want"
        done
        if grep -q '^GRUB_PRELOAD_MODULES=' "$file"; then
            run sed -i -E "s|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES=\"$cur_preload\"|" "$file"
        else
            run bash -c "printf 'GRUB_PRELOAD_MODULES=\"%s\"\n' \"$cur_preload\" >> \"$file\""
        fi
    fi
}

# Internal: set a key=value pair in a shell-style config file.
_grub_kv_set() {
    local file="$1" key="$2" val="$3"
    if grep -Eq "^${key}=" "$file"; then
        run sed -i -E "s|^${key}=.*|${key}=${val}|" "$file"
    else
        run bash -c "printf '%s=%s\n' \"$key\" \"$val\" >> \"$file\""
    fi
}

# grub_install ROOT_MP TARGET INSTALL — run grub-install inside the
# chroot, choosing EFI vs BIOS correctly. INSTALL=0 means configure-only
# (skip grub-install, only regenerate grub.cfg).
#
# Arguments:
#   $1 root_mp
#   $2 efi_mp (empty for BIOS)
#   $3 disk_for_bios (e.g. /dev/sda) — only for BIOS installs
#   $4 install (1=install+configure, 0=configure only)
grub_install() {
    local root_mp="$1" efi_mp="${2:-}" bios_disk="${3:-}" install="${4:-0}"
    local -a pkgs=()
    case "$DISTRO_LIKE" in
        debian)
            if [[ -n "$efi_mp" ]]; then pkgs=(grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr os-prober)
            else                         pkgs=(grub-pc os-prober); fi
            ;;
        arch)
            pkgs=(grub)
            [[ -n "$efi_mp" ]] && pkgs+=(efibootmgr)
            ;;
    esac

    if (( install == 1 )); then
        log "Installing GRUB packages: ${pkgs[*]}"
        case "$DISTRO_LIKE" in
            debian) run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" ;;
            arch)   run chroot "$root_mp" pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
        esac
        if [[ -n "$efi_mp" ]]; then
            log "grub-install --target=x86_64-efi"
            run chroot "$root_mp" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=btrfs-migrate --recheck
        else
            [[ -n "$bios_disk" ]] || die "BIOS GRUB install requires a disk (e.g. /dev/sda)" 10
            log "grub-install --target=i386-pc $bios_disk"
            run chroot "$root_mp" grub-install --target=i386-pc --recheck "$bios_disk"
        fi
    else
        log "Skipping grub-install (configure-only mode)"
    fi

    # Regenerate the config. Distro-specific command.
    case "$DISTRO_LIKE" in
        debian) run chroot "$root_mp" update-grub ;;
        arch)   run chroot "$root_mp" grub-mkconfig -o /boot/grub/grub.cfg ;;
    esac
}

# -- systemd-boot ------------------------------------------------------------

# sdboot_install ROOT_MP EFI_MP — bootctl install into the target ESP,
# generate a /boot/loader/entries/<id>.conf for the default kernel.
# Caller must have validated that encrypted /boot is NOT set.
sdboot_install() {
    local root_mp="$1" efi_mp="$2" install="${3:-0}" cmdline="${4:-}"
    [[ -n "$efi_mp" ]] || die "systemd-boot requires an EFI partition (--efi)." 10
    [[ -d /sys/firmware/efi ]] || die "systemd-boot requires booting in UEFI mode (no efivars found)." 10

    case "$DISTRO_LIKE" in
        debian) (( install == 1 )) && run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd-boot systemd-boot-efi efibootmgr ;;
        arch)   (( install == 1 )) && run chroot "$root_mp" pacman -Sy --noconfirm --needed efibootmgr ;;
    esac

    if (( install == 1 )); then
        log "bootctl install"
        run chroot "$root_mp" bootctl --esp-path=/boot/efi install
    else
        log "bootctl update (configure-only)"
        run chroot "$root_mp" bootctl --esp-path=/boot/efi update || \
            warn "bootctl update failed — ESP may not yet have systemd-boot installed."
    fi

    # Write a basic loader entry. Real kernel/initramfs paths differ per
    # distro, so we emit pointers to the canonical ones and let the user
    # refine.
    local loader_dir="$root_mp/boot/efi/loader"
    run mkdir -p "$loader_dir/entries"
    run bash -c "printf 'default  btrfs-migrate.conf\ntimeout  5\nconsole-mode max\n' > \"$loader_dir/loader.conf\""

    local entry="$loader_dir/entries/btrfs-migrate.conf"
    local linux initrd
    case "$DISTRO_LIKE" in
        debian) linux="/vmlinuz" ; initrd="/initrd.img" ;;   # Ubuntu maintains symlinks in /
        arch)   linux="/vmlinuz-linux" ; initrd="/initramfs-linux.img" ;;
    esac

    run bash -c "cat > \"$entry\" <<EOF
title   btrfs-migrate (\$(uname -m))
linux   $linux
initrd  $initrd
options $cmdline rw
EOF"
}

# -- Top-level dispatch ------------------------------------------------------

# bootloader_apply ROOT_MP EFI_MP BIOS_DISK CHOICE INSTALL ENCRYPT_BOOT CMDLINE
bootloader_apply() {
    local root_mp="$1" efi_mp="$2" bios_disk="$3" choice="$4" install="$5" enc_boot="$6" cmdline="$7"
    bootloader_validate "$choice" "$enc_boot"
    bind_target_mounts "$root_mp" "$efi_mp"

    case "$choice" in
        grub)
            grub_tune_defaults "$root_mp" "$cmdline" "$enc_boot"
            grub_install "$root_mp" "$efi_mp" "$bios_disk" "$install"
            ;;
        systemd-boot)
            sdboot_install "$root_mp" "$efi_mp" "$install" "$cmdline"
            ;;
    esac
}
