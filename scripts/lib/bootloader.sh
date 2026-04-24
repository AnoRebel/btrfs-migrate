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
# Idempotent: if a directory is already a mountpoint (detected via
# findmnt), we skip re-binding and do not register a rollback for it —
# the caller that established the mount owns its cleanup.
bind_target_mounts() {
    local root_mp="$1" efi_mp="${2:-}"
    local d
    for d in proc sys dev dev/pts run; do
        run mkdir -p "$root_mp/$d"
        if findmnt -nr --target "$root_mp/$d" -o TARGET 2>/dev/null | grep -qx "$root_mp/$d"; then
            debug "bind_target_mounts: $root_mp/$d already mounted — skipping"
            continue
        fi
        run mount --bind "/$d" "$root_mp/$d"
        on_rollback -- umount "$root_mp/$d"
    done
    if [[ -n "$efi_mp" ]] && [[ -d /sys/firmware/efi/efivars ]]; then
        run mkdir -p "$root_mp/sys/firmware/efi/efivars"
        if findmnt -nr --target "$root_mp/sys/firmware/efi/efivars" -o TARGET 2>/dev/null \
                | grep -qx "$root_mp/sys/firmware/efi/efivars"; then
            debug "bind_target_mounts: efivars already mounted — skipping"
        else
            run mount --bind /sys/firmware/efi/efivars "$root_mp/sys/firmware/efi/efivars"
            on_rollback -- umount "$root_mp/sys/firmware/efi/efivars"
        fi
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
        write_file "$file" 'GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
'
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
            append_file "$file" "GRUB_PRELOAD_MODULES=\"$cur_preload\"
"
        fi
    fi
}

# Internal: set a key=value pair in a shell-style config file.
_grub_kv_set() {
    local file="$1" key="$2" val="$3"
    if grep -Eq "^${key}=" "$file"; then
        run sed -i -E "s|^${key}=.*|${key}=${val}|" "$file"
    else
        append_file "$file" "$key=$val
"
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

# sdboot_enumerate_kernels ROOT_MP — print one line per discovered kernel
# under @/boot. Format: BASENAME<TAB>VMLINUZ_REL<TAB>INITRD_REL where the
# *_REL paths are relative to the boot directory the loader will see at
# runtime ("/" inside the ESP for systemd-boot, which canonically expects
# /vmlinuz-* and /initramfs-* style relative paths).
#
# We pair each vmlinuz-<basename> with its initramfs by trying the common
# naming conventions:
#   Arch:    /boot/initramfs-<basename>.img
#   Ubuntu:  /boot/initrd.img-<basename>
sdboot_enumerate_kernels() {
    local root_mp="$1"
    local boot="$root_mp/boot"
    [[ -d "$boot" ]] || return 0
    local k base initrd_rel
    for k in "$boot"/vmlinuz-*; do
        [[ -e "$k" ]] || continue
        base="${k##*/vmlinuz-}"
        # Skip fallback / rescue images as primary entries; they will get
        # their own line via the wildcard if they're real kernels too.
        case "$base" in
            *.img|*.efi) continue ;;
        esac
        initrd_rel=""
        if   [[ -e "$boot/initramfs-$base.img" ]]; then initrd_rel="/initramfs-$base.img"
        elif [[ -e "$boot/initrd.img-$base"   ]]; then initrd_rel="/initrd.img-$base"
        elif [[ -e "$boot/initramfs-$base"     ]]; then initrd_rel="/initramfs-$base"
        fi
        printf '%s\t/vmlinuz-%s\t%s\n' "$base" "$base" "$initrd_rel"
    done
}

# sdboot_write_entry EFI_MP BASENAME VMLINUZ_REL INITRD_REL CMDLINE — write
# a single loader entry. The entry filename is btrfs-migrate-<basename>.conf
# under EFI_MP/loader/entries/. INITRD_REL may be empty (no initrd line).
sdboot_write_entry() {
    local efi_mp="$1" base="$2" vmlinuz_rel="$3" initrd_rel="$4" cmdline="$5"
    # Constrain basename to a tame token — it becomes a filename + a key
    # in loader.conf and we don't want shell metachars or path separators.
    [[ "$base" =~ ^[A-Za-z0-9._+-]+$ ]] || die "sdboot_write_entry: refusing unsafe basename '$base'" 10
    local entries_dir="$efi_mp/loader/entries"
    run mkdir -p "$entries_dir"
    local entry="$entries_dir/btrfs-migrate-$base.conf"
    local arch; arch=$(uname -m)
    local body="title   btrfs-migrate $base ($arch)
linux   $vmlinuz_rel
"
    [[ -n "$initrd_rel" ]] && body+="initrd  $initrd_rel
"
    body+="options $cmdline rw
"
    write_file "$entry" "$body"
    log "Wrote systemd-boot entry: $(basename -- "$entry")"
}

# _sdboot_pick_default BASENAMES... — choose the highest version-sorted
# kernel basename as the loader.conf default. version-sort puts e.g.
# 6.9.0 ahead of 6.6.0, and 'linux' ahead of 'linux-lts' alphabetically
# only when versions are equal (good enough; operators can edit).
_sdboot_pick_default() {
    printf '%s\n' "$@" | sort -V | tail -n1
}

# sdboot_install ROOT_MP EFI_MP — bootctl install into the target ESP,
# enumerate every kernel under @/boot, write one loader entry per kernel
# (Arch: linux + linux-lts case; Ubuntu: per-version case), choose the
# newest as default in loader.conf. Caller must have validated that
# encrypted /boot is NOT set.
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

    local loader_dir="$root_mp/boot/efi/loader"
    run mkdir -p "$loader_dir/entries"

    # Enumerate kernels. If none are found (e.g. plan-only with empty
    # tempdir, or a target that hasn't installed any kernel package yet),
    # fall back to the legacy single-entry behaviour with distro defaults.
    local -a basenames=()
    local line base vmlinuz_rel initrd_rel
    while IFS=$'\t' read -r base vmlinuz_rel initrd_rel; do
        [[ -n "$base" ]] || continue
        sdboot_write_entry "$loader_dir" "$base" "$vmlinuz_rel" "$initrd_rel" "$cmdline"
        basenames+=("$base")
    done < <(sdboot_enumerate_kernels "$root_mp")

    if (( ${#basenames[@]} == 0 )); then
        warn "No kernels found under $root_mp/boot — writing fallback single-entry."
        local fb_linux fb_initrd
        case "$DISTRO_LIKE" in
            debian) fb_linux="/vmlinuz" ;     fb_initrd="/initrd.img" ;;
            arch)   fb_linux="/vmlinuz-linux" ; fb_initrd="/initramfs-linux.img" ;;
            *)      die "sdboot_install: unknown DISTRO_LIKE '$DISTRO_LIKE'" 10 ;;
        esac
        sdboot_write_entry "$loader_dir" "fallback" "$fb_linux" "$fb_initrd" "$cmdline"
        basenames=("fallback")
    fi

    local default_base; default_base=$(_sdboot_pick_default "${basenames[@]}")
    write_file "$loader_dir/loader.conf" "default  btrfs-migrate-$default_base.conf
timeout  5
console-mode max
"
    log "systemd-boot default: btrfs-migrate-$default_base.conf (${#basenames[@]} entry(s) written)"

    # Verify entries are recognized by bootctl. Skip in plan-only because
    # the chroot tree isn't real.
    if (( BTRFS_MIGRATE_PLAN_ONLY == 0 )); then
        sdboot_verify_entries "$root_mp" "${#basenames[@]}"
    fi
}

# sdboot_verify_entries ROOT_MP EXPECTED — run `bootctl list` inside the
# chroot and require at least EXPECTED type-1 entries. Dies with code 41
# if bootctl recognizes fewer than expected (entry parse failure, wrong
# ESP path, etc).
sdboot_verify_entries() {
    local root_mp="$1" expected="$2"
    local out
    out=$(chroot "$root_mp" bootctl --esp-path=/boot/efi list 2>&1 || true)
    local got
    got=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*type:[[:space:]]' || true)
    if (( got < expected )); then
        error "bootctl list output:"
        printf '%s\n' "$out" >&2
        die "systemd-boot verify: bootctl recognized $got entry(s); expected $expected. Inspect $root_mp/boot/efi/loader/entries/." 41
    fi
    ok "systemd-boot verify: bootctl sees $got entry(s) (expected >=$expected)"
}

# -- Entry verification ------------------------------------------------------

# bootloader_verify_entries ROOT_MP CHOICE — assert that the chosen loader
# has at least one recognized entry. For GRUB we grep grub.cfg; for
# systemd-boot we run `bootctl list` inside the chroot. Dies with code 41
# on mismatch so the operator can inspect the loader state before reboot.
bootloader_verify_entries() {
    local root_mp="$1" choice="$2"
    case "$choice" in
        grub)
            local cfg=""
            if   [[ -f "$root_mp/boot/grub/grub.cfg"  ]]; then cfg="$root_mp/boot/grub/grub.cfg"
            elif [[ -f "$root_mp/boot/grub2/grub.cfg" ]]; then cfg="$root_mp/boot/grub2/grub.cfg"
            fi
            [[ -n "$cfg" ]] || die "bootloader verify: no grub.cfg found under $root_mp/boot" 41
            local count
            count=$(grep -cE '^[[:space:]]*menuentry[[:space:]]' "$cfg" || true)
            (( count > 0 )) || die "bootloader verify: grub.cfg has no menuentry lines ($cfg)" 41
            ok "GRUB verify: $count menuentry line(s) in $(basename -- "$cfg")"
            ;;
        systemd-boot)
            local out
            out=$(chroot "$root_mp" bootctl --esp-path=/boot/efi list 2>&1 || true)
            # `bootctl list` prints one block per entry; counting 'type:' lines
            # gives the recognized entry count and works across bootctl versions.
            local count
            count=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*type:[[:space:]]' || true)
            if (( count < 1 )); then
                error "bootctl list output:"
                printf '%s\n' "$out" >&2
                die "bootloader verify: systemd-boot reports no entries — inspect $root_mp/boot/efi/loader/entries/" 41
            fi
            ok "systemd-boot verify: $count loader entry(s) recognized by bootctl"
            ;;
        *)
            die "bootloader_verify_entries: unknown choice '$choice'" 41
            ;;
    esac
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
