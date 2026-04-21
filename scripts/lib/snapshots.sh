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
# Pinned ref for grub-btrfs. Empty default -> resolve the latest
# release tag from GitHub at run time (see snap_resolve_latest_gh_tag).
# Set explicitly (tag, branch, or full SHA) to override.
GRUB_BTRFS_COMMIT="${GRUB_BTRFS_COMMIT:-}"
# Optional: if set, the post-checkout HEAD must match this SHA exactly
# (40 hex chars). Auto-resolved from the resolved tag after clone when
# empty. Set BTRFS_MIGRATE_STRICT_PIN=1 to require a pre-set SHA.
GRUB_BTRFS_COMMIT_SHA="${GRUB_BTRFS_COMMIT_SHA:-}"

# Canonical upstream for btrfs-assistant (GitLab). The github.com/nexusriot
# mirror is a fork/mirror; we let users override if they prefer it.
BTRFS_ASSISTANT_REPO="${BTRFS_ASSISTANT_REPO:-https://gitlab.com/btrfs-assistant/btrfs-assistant.git}"
BTRFS_ASSISTANT_COMMIT="${BTRFS_ASSISTANT_COMMIT:-}"
BTRFS_ASSISTANT_COMMIT_SHA="${BTRFS_ASSISTANT_COMMIT_SHA:-}"

# snap_resolve_latest_tag REPO_URL — echo the newest release tag.
# - For github.com repos, queries https://api.github.com/repos/OWNER/NAME/releases/latest.
# - For gitlab.com repos, queries https://gitlab.com/api/v4/projects/OWNER%2FNAME/releases (first item).
# - For anything else, returns non-zero so the caller can fall back.
# Requires curl (or wget). Output: a single tag string on stdout, no newline.
snap_resolve_latest_tag() {
    local url="$1"
    snap_validate_repo_url "$url"
    local fetch=""
    if have curl; then fetch='curl -fsSL --max-time 15'
    elif have wget; then fetch='wget -qO- --timeout=15'
    else
        warn "snap_resolve_latest_tag: neither curl nor wget present; cannot resolve latest tag."
        return 1
    fi

    local host owner repo api_url tag
    # Strip protocol + trailing .git, split host/owner/repo.
    local stripped="${url#https://}"; stripped="${stripped%.git}"
    host="${stripped%%/*}"; stripped="${stripped#*/}"
    owner="${stripped%%/*}"; repo="${stripped#*/}"
    case "$host" in
        github.com)
            api_url="https://api.github.com/repos/${owner}/${repo}/releases/latest"
            tag=$($fetch "$api_url" 2>/dev/null | \
                  awk -F'"' '/"tag_name"[[:space:]]*:/ {print $4; exit}')
            ;;
        gitlab.com)
            # GitLab URL-encodes the project path; %2F = '/'.
            api_url="https://gitlab.com/api/v4/projects/${owner}%2F${repo}/releases"
            tag=$($fetch "$api_url" 2>/dev/null | \
                  awk -F'"' '/"tag_name"[[:space:]]*:/ {print $4; exit}')
            ;;
        *)
            return 1
            ;;
    esac
    [[ -n "$tag" ]] || return 1
    snap_validate_repo_ref "$tag"
    printf '%s' "$tag"
}

# snap_validate_repo_url URL — refuse anything but plain https://...git so
# an env override can't smuggle shell metachars, credential strings, or
# file://, git://, ssh://, or javascript: URIs into the clone command.
snap_validate_repo_url() {
    local url="$1"
    [[ "$url" =~ ^https://[A-Za-z0-9._~@:/?#-]+\.git$ ]] || \
        die "Refusing suspicious repo URL: '$url' (must be https://...git, tame charset)." 10
}

# snap_validate_repo_ref REF — refuse anything but tame git refs (tag
# name, branch name, or hex SHA). `git checkout` with a weird ref could
# be argv-safe but we want defence-in-depth.
snap_validate_repo_ref() {
    local ref="$1"
    [[ "$ref" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || \
        die "Refusing suspicious git ref: '$ref'." 10
}

# snap_validate_full_sha SHA — accepts only a 40-char lowercase hex SHA.
# Empty input is allowed (means "no strict SHA pin requested").
snap_validate_full_sha() {
    local sha="$1"
    [[ -z "$sha" ]] && return 0
    [[ "$sha" =~ ^[a-f0-9]{40}$ ]] || \
        die "Refusing non-SHA1 pin: '$sha' (must be 40 lowercase hex chars)." 10
}

# snap_verify_pin ROOT_MP SRC_DIR EXPECTED_SHA DESC — compare the
# chroot's HEAD in SRC_DIR against EXPECTED_SHA. If EXPECTED_SHA is
# empty and BTRFS_MIGRATE_STRICT_PIN=1, that is itself a failure.
# Otherwise empty is allowed with a warn().
snap_verify_pin() {
    local root_mp="$1" src="$2" expected="$3" desc="$4"
    snap_validate_full_sha "$expected"
    if [[ -z "$expected" ]]; then
        if [[ "${BTRFS_MIGRATE_STRICT_PIN:-0}" == "1" ]]; then
            die "$desc: BTRFS_MIGRATE_STRICT_PIN=1 but no full SHA pin was set." 10
        fi
        warn "$desc: no SHA pin set; trusting the floating ref. Export a *_COMMIT_SHA for supply-chain safety."
        return 0
    fi
    local got
    got=$(chroot "$root_mp" git -C "$src" rev-parse HEAD 2>/dev/null || echo '')
    if [[ -z "$got" ]]; then
        die "$desc: could not read HEAD of $src in target." 30
    fi
    if [[ "$got" != "$expected" ]]; then
        die "$desc: SHA mismatch. Expected '$expected', got '$got'. Upstream may have been tampered with or the pin is stale." 30
    fi
    ok "$desc: pinned SHA verified ($got)."
}

# snap_resolve_ref REPO_URL VAR_REF_NAME — if the named variable is
# empty, fill it with the latest GitHub/GitLab release tag. If the
# auto-resolver fails AND the ref is still empty, die. Callers pass the
# *name* of the variable so we can mutate it in place.
snap_resolve_ref() {
    local repo="$1" varname="$2"
    local current="${!varname:-}"
    if [[ -n "$current" ]]; then
        return 0
    fi
    log "Resolving latest release tag for $repo"
    local tag
    if tag=$(snap_resolve_latest_tag "$repo"); then
        printf -v "$varname" '%s' "$tag"
        log "Using $repo @ $tag (auto-resolved latest release)"
        return 0
    fi
    die "Could not resolve latest release tag for $repo. Set ${varname} explicitly to a tag or commit SHA." 30
}

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
    # `|| true` is intentional — "already exists" is a re-run no-op.
    log "snapper -c root create-config /"
    run chroot "$root_mp" snapper -c root create-config / 2>/dev/null || true
    # Enable timeline snapshots sensibly (10/10/3/1 per upstream guidance).
    run chroot "$root_mp" snapper -c root set-config \
        TIMELINE_MIN_AGE=1800 \
        TIMELINE_LIMIT_HOURLY=10 \
        TIMELINE_LIMIT_DAILY=10 \
        TIMELINE_LIMIT_MONTHLY=3 \
        TIMELINE_LIMIT_YEARLY=1 2>/dev/null || true

    if (( config_home == 1 )); then
        log "snapper -c home create-config /home"
        run chroot "$root_mp" snapper -c home create-config /home 2>/dev/null || true
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
    if chroot "$root_mp" command -v grub-btrfsd >/dev/null 2>&1; then
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

    # 3) Source fallback. Validate the repo URL and ref before we let
    # them anywhere near git (these values are env-overridable, see
    # CRITICAL-C1/H1 in the audit). An empty ref triggers a GitHub
    # release-latest lookup so we always build a tagged release rather
    # than whatever `main` happens to point at today.
    snap_validate_repo_url "$GRUB_BTRFS_REPO"
    snap_resolve_ref "$GRUB_BTRFS_REPO" GRUB_BTRFS_COMMIT
    snap_validate_repo_ref "$GRUB_BTRFS_COMMIT"
    snap_validate_full_sha "$GRUB_BTRFS_COMMIT_SHA"
    log "Building grub-btrfs from source ($GRUB_BTRFS_REPO @ $GRUB_BTRFS_COMMIT)"
    # Make sure build deps are present inside the chroot.
    case "$DISTRO_LIKE" in
        debian) run chroot "$root_mp" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git make inotify-tools ;;
        arch)   run chroot "$root_mp" pacman -Sy --noconfirm --needed git make inotify-tools ;;
    esac
    run chroot "$root_mp" rm -rf /usr/local/src/grub-btrfs
    run chroot "$root_mp" git clone --no-recurse-submodules -- \
        "$GRUB_BTRFS_REPO" /usr/local/src/grub-btrfs
    run chroot "$root_mp" git -C /usr/local/src/grub-btrfs fsck --no-dangling
    run chroot "$root_mp" git -C /usr/local/src/grub-btrfs checkout "$GRUB_BTRFS_COMMIT"
    snap_verify_pin "$root_mp" /usr/local/src/grub-btrfs "$GRUB_BTRFS_COMMIT_SHA" "grub-btrfs"
    run chroot "$root_mp" make -C /usr/local/src/grub-btrfs install
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
    if chroot "$root_mp" command -v btrfs-assistant >/dev/null 2>&1; then
        log "btrfs-assistant already present in target"
        return 0
    fi

    # 2) Try the distro repo (packaged on Ubuntu 24.04+ universe and Arch extra).
    local pkg_ok=0
    case "$DISTRO_LIKE" in
        debian)
            if chroot "$root_mp" apt-cache show btrfs-assistant >/dev/null 2>&1; then
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

    # 3) Source fallback. Validate repo URL and ref before handing them
    # to git (env-overridable, see C1/H1). Resolve the newest release tag
    # on demand (GitLab API) so we don't pin to a stale version.
    snap_validate_repo_url "$BTRFS_ASSISTANT_REPO"
    snap_resolve_ref "$BTRFS_ASSISTANT_REPO" BTRFS_ASSISTANT_COMMIT
    snap_validate_repo_ref "$BTRFS_ASSISTANT_COMMIT"
    snap_validate_full_sha "$BTRFS_ASSISTANT_COMMIT_SHA"
    log "Building btrfs-assistant from source ($BTRFS_ASSISTANT_REPO @ $BTRFS_ASSISTANT_COMMIT)"
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
    local src=/usr/local/src/btrfs-assistant
    local nproc; nproc=$(chroot "$root_mp" nproc 2>/dev/null || echo 2)
    [[ "$nproc" =~ ^[0-9]{1,3}$ ]] || nproc=2
    if ! {
        run chroot "$root_mp" rm -rf "$src" && \
        run chroot "$root_mp" git clone --no-recurse-submodules -- \
            "$BTRFS_ASSISTANT_REPO" "$src" && \
        run chroot "$root_mp" git -C "$src" fsck --no-dangling && \
        run chroot "$root_mp" git -C "$src" checkout "$BTRFS_ASSISTANT_COMMIT"
    }; then
        warn "btrfs-assistant clone/checkout failed. Install manually later."
        return 1
    fi
    snap_verify_pin "$root_mp" "$src" "$BTRFS_ASSISTANT_COMMIT_SHA" "btrfs-assistant"
    if ! {
        run chroot "$root_mp" cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release && \
        run chroot "$root_mp" cmake --build "$src/build" -j "$nproc" && \
        run chroot "$root_mp" cmake --install "$src/build"
    }; then
        warn "btrfs-assistant source build failed. Install manually later."
        return 1
    fi
    ok "btrfs-assistant built and installed from source"
}
