#!/usr/bin/env bash
# lib/snapshots.sh — Snapper / Timeshift / grub-btrfs integration.
#
# Hard rule: --snapper and --timeshift are mutually exclusive; the
# caller is expected to have enforced that. We double-check here.
#
# grub-btrfs is not always in distro repos, so we discover first, then
# try the package manager, then fall back to source install from
# https://github.com/Antynea/grub-btrfs .

if [[ -n "${__BTRFS_MIGRATE_SNAPS_SH:-}" ]]; then return 0; fi
__BTRFS_MIGRATE_SNAPS_SH=1

# shellcheck source=log.sh
[[ -z "${__BTRFS_MIGRATE_LOG_SH:-}"    ]] && . "$(dirname "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=checks.sh
[[ -z "${__BTRFS_MIGRATE_CHECKS_SH:-}" ]] && . "$(dirname "${BASH_SOURCE[0]}")/checks.sh"

GRUB_BTRFS_REPO="${GRUB_BTRFS_REPO:-https://github.com/Antynea/grub-btrfs.git}"

# Canonical upstream for btrfs-assistant (GitLab). The github.com/nexusriot
# mirror is a fork/mirror; we let users override if they prefer it.
BTRFS_ASSISTANT_REPO="${BTRFS_ASSISTANT_REPO:-https://gitlab.com/btrfs-assistant/btrfs-assistant.git}"

# snap_validate_choice WANT_SNAPPER WANT_TIMESHIFT — refuse both.
snap_validate_choice() {
    local want_snapper="${1:-0}" want_timeshift="${2:-0}"
    if (( want_snapper == 1 )) && (( want_timeshift == 1 )); then
        die "--snapper and --timeshift are mutually exclusive. Their auto-snapshot layouts conflict. Pick one." 10
    fi
}

# snap_warn_layout SUBVOLS... — Timeshift expects @ and @home at a
# specific depth. Warn loudly if the user custom-renamed either.
snap_warn_layout_for_timeshift() {
    local -a subvols=("$@")
    local has_at=0 has_at_home=0 s
    for s in "${subvols[@]}"; do
        [[ "$s" == "@" ]]     && has_at=1
        [[ "$s" == "@home" ]] && has_at_home=1
    done
    (( has_at == 1 && has_at_home == 1 )) || \
        warn "Timeshift requires subvolumes named exactly '@' and '@home' at the top-level. Your layout is missing one — Timeshift will not auto-detect this install."
}

# snap_install_snapper ROOT_MP [CONFIGURE_HOME=0]
# Installs snapper in the target and runs `snapper create-config` for /
# (and optionally /home) inside the chroot.
snap_install_snapper() {
    local root_mp="$1" config_home="${2:-0}"
    log "Installing Snapper in target"
    case "$DISTRO_LIKE" in
        debian) run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends snapper ;;
        arch)   run chroot "$root_mp" pacman -Sy --noconfirm --needed snapper ;;
    esac

    # create-config will also create a .snapshots subvolume on /.
    # We catch 'already exists' errors and treat them as idempotent.
    log "snapper -c root create-config /"
    run chroot "$root_mp" bash -c "snapper -c root create-config / 2>/dev/null || true"
    # Enable timeline snapshots sensibly (10/10/3/1 per upstream guidance).
    run chroot "$root_mp" bash -c "snapper -c root set-config TIMELINE_MIN_AGE=1800 TIMELINE_LIMIT_HOURLY=10 TIMELINE_LIMIT_DAILY=10 TIMELINE_LIMIT_MONTHLY=3 TIMELINE_LIMIT_YEARLY=1 2>/dev/null || true"

    if (( config_home == 1 )); then
        log "snapper -c home create-config /home"
        run chroot "$root_mp" bash -c "snapper -c home create-config /home 2>/dev/null || true"
    fi

    # Enable the timer that actually takes the snapshots.
    case "$DISTRO_LIKE" in
        debian|arch)
            run chroot "$root_mp" systemctl enable snapper-timeline.timer snapper-cleanup.timer || \
                warn "Could not enable snapper timers — do it after reboot: systemctl enable --now snapper-timeline.timer snapper-cleanup.timer"
            ;;
    esac
}

# snap_install_timeshift ROOT_MP — install Timeshift in the target. We
# do NOT pre-seed config files; Timeshift's first-run UI is what users
# expect and our layout matches what it detects by default.
snap_install_timeshift() {
    local root_mp="$1"
    log "Installing Timeshift in target"
    case "$DISTRO_LIKE" in
        debian) run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends timeshift ;;
        arch)   run chroot "$root_mp" pacman -Sy --noconfirm --needed timeshift ;;
    esac
    log "Timeshift installed. Run 'sudo timeshift-gtk' (or 'sudo timeshift --btrfs' for CLI) after reboot to configure."
}

# snap_install_grub_btrfs ROOT_MP — try package manager first, then
# fall back to `git clone && make install` from the Antynea repo. All
# work happens inside the chroot so the install lands on the target
# system, not the live ISO.
snap_install_grub_btrfs() {
    local root_mp="$1"

    # 1) Already there?
    if chroot "$root_mp" bash -c 'command -v grub-btrfsd >/dev/null 2>&1'; then
        log "grub-btrfs already present in target"
        _grub_btrfs_enable "$root_mp"
        return 0
    fi

    # 2) Distro package (only Arch currently has it in extra).
    case "$DISTRO_LIKE" in
        arch)
            if chroot "$root_mp" pacman -Si grub-btrfs >/dev/null 2>&1; then
                log "Installing grub-btrfs via pacman"
                if run chroot "$root_mp" pacman -Sy --noconfirm --needed grub-btrfs; then
                    _grub_btrfs_enable "$root_mp"
                    return 0
                fi
            else
                warn "grub-btrfs not available in pacman repos; will build from source."
            fi
            ;;
        debian)
            # Not in Ubuntu repos as of 24.04. Fall through to source install.
            warn "grub-btrfs is not packaged for Ubuntu; will build from source."
            ;;
    esac

    # 3) Source fallback.
    log "Building grub-btrfs from source ($GRUB_BTRFS_REPO)"
    # Make sure build deps are present inside the chroot.
    case "$DISTRO_LIKE" in
        debian) run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git make inotify-tools ;;
        arch)   run chroot "$root_mp" pacman -Sy --noconfirm --needed git make inotify-tools ;;
    esac
    run chroot "$root_mp" bash -c "
        set -e
        rm -rf /usr/local/src/grub-btrfs
        git clone --depth=1 '$GRUB_BTRFS_REPO' /usr/local/src/grub-btrfs
        cd /usr/local/src/grub-btrfs
        make install
    "
    _grub_btrfs_enable "$root_mp"
}

# Enable the grub-btrfsd timer/service (named grub-btrfsd.service upstream)
# so that snapshots appear in the GRUB menu automatically.
_grub_btrfs_enable() {
    local root_mp="$1"
    # Name varies: package may provide grub-btrfs.path or grub-btrfsd.service.
    local unit
    for unit in grub-btrfsd.service grub-btrfs.path; do
        if chroot "$root_mp" systemctl list-unit-files 2>/dev/null | grep -q "^$unit"; then
            log "Enabling $unit in target"
            run chroot "$root_mp" systemctl enable "$unit" || \
                warn "Failed to enable $unit — enable it manually after reboot."
            return 0
        fi
    done
    warn "grub-btrfs installed, but no systemd unit detected. After reboot, run 'grub-mkconfig -o /boot/grub/grub.cfg' manually when you want the snapshot menu to refresh."
}

# snap_install_btrfs_assistant ROOT_MP — discover-then-install with
# source fallback to https://gitlab.com/btrfs-assistant/btrfs-assistant
# (canonical upstream; github.com/nexusriot is a mirror). Build deps:
# Qt6, C++17 compiler, CMake >= 3.5, plus pkexec/polkit at runtime.
snap_install_btrfs_assistant() {
    local root_mp="$1"

    # 1) Already present?
    if chroot "$root_mp" bash -c 'command -v btrfs-assistant >/dev/null 2>&1'; then
        log "btrfs-assistant already present in target"
        return 0
    fi

    # 2) Try the distro repo (packaged on Ubuntu 24.04+ universe and Arch extra).
    local pkg_ok=0
    case "$DISTRO_LIKE" in
        debian)
            if chroot "$root_mp" bash -c 'apt-cache show btrfs-assistant >/dev/null 2>&1'; then
                log "Installing btrfs-assistant via apt"
                if run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends btrfs-assistant; then
                    pkg_ok=1
                fi
            else
                warn "btrfs-assistant not visible to apt (universe may be disabled). Will build from source."
            fi
            ;;
        arch)
            if chroot "$root_mp" pacman -Si btrfs-assistant >/dev/null 2>&1; then
                log "Installing btrfs-assistant via pacman"
                if run chroot "$root_mp" pacman -Sy --noconfirm --needed btrfs-assistant; then
                    pkg_ok=1
                fi
            else
                warn "btrfs-assistant not in pacman repos. Will build from source."
            fi
            ;;
    esac
    (( pkg_ok == 1 )) && return 0

    # 3) Source fallback.
    log "Building btrfs-assistant from source ($BTRFS_ASSISTANT_REPO)"
    case "$DISTRO_LIKE" in
        debian)
            run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                git cmake g++ pkg-config \
                qt6-base-dev qt6-tools-dev qt6-tools-dev-tools \
                libbtrfs-dev policykit-1
            ;;
        arch)
            run chroot "$root_mp" pacman -Sy --noconfirm --needed \
                git cmake gcc pkgconf qt6-base qt6-tools polkit btrfs-progs
            ;;
    esac
    run chroot "$root_mp" bash -c "
        set -e
        rm -rf /usr/local/src/btrfs-assistant
        git clone --depth=1 '$BTRFS_ASSISTANT_REPO' /usr/local/src/btrfs-assistant
        cd /usr/local/src/btrfs-assistant
        cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
        cmake --build build -j\"\$(nproc)\"
        cmake --install build
    " || {
        warn "btrfs-assistant source build failed. Install manually later."
        return 1
    }
    ok "btrfs-assistant built and installed from source"
}
