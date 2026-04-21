#!/usr/bin/env bash
# lib/checks.sh — preflight, distro detection, live-ISO detection,
# partition/filesystem validation, SSD detection, package-resolver helpers.

if [[ -n "${__BTRFS_MIGRATE_CHECKS_SH:-}" ]]; then return 0; fi
__BTRFS_MIGRATE_CHECKS_SH=1

# Source log.sh if the caller didn't.
# shellcheck source=log.sh
[[ -z "${__BTRFS_MIGRATE_LOG_SH:-}" ]] && . "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# -- Distro detection --------------------------------------------------------
# Sets DISTRO_ID (ubuntu|arch|unknown) and DISTRO_LIKE (debian|arch|unknown)
# and DISTRO_VERSION_ID (eg "24.04", empty on rolling).
detect_distro() {
    DISTRO_ID=unknown
    DISTRO_LIKE=unknown
    DISTRO_VERSION_ID=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-$DISTRO_ID}"
        DISTRO_VERSION_ID="${VERSION_ID:-}"
    fi
    case "$DISTRO_ID" in
        ubuntu)
            DISTRO_LIKE=debian
            local major; major="${DISTRO_VERSION_ID%%.*}"
            if [[ -n "$major" ]] && (( major < 24 )); then
                die "Ubuntu $DISTRO_VERSION_ID is below the supported 24.04 floor." 10
            fi
            ;;
        arch)
            DISTRO_LIKE=arch
            ;;
        *)
            die "Unsupported distro '$DISTRO_ID'. Only ubuntu (>=24.04) and arch are supported." 10
            ;;
    esac
    log "Detected distro: $DISTRO_ID ${DISTRO_VERSION_ID:-(rolling)}"
}

# -- Live-ISO vs installed detection -----------------------------------------
# Sets EXEC_MODE to 'live' or 'installed'.
# Heuristics (any hit -> live):
#   - /cdrom is a mountpoint                     (Ubuntu casper)
#   - /run/live or /lib/live exists              (Debian live)
#   - /run/archiso or /run/miso exists           (Arch-based ISOs)
#   - kernel cmdline contains 'boot=casper' or 'boot=live' or 'archiso'
#   - / is a tmpfs or overlay                    (final fallback)
detect_exec_mode() {
    EXEC_MODE=installed
    if mountpoint -q /cdrom 2>/dev/null; then EXEC_MODE=live; fi
    [[ -d /run/live || -d /lib/live || -d /run/archiso || -d /run/miso ]] && EXEC_MODE=live
    if [[ -r /proc/cmdline ]]; then
        local cmd; cmd=$(cat /proc/cmdline)
        [[ "$cmd" == *boot=casper* || "$cmd" == *boot=live* || "$cmd" == *archiso* ]] && EXEC_MODE=live
    fi
    local rootfs; rootfs=$(findmnt -no FSTYPE /)
    [[ "$rootfs" == tmpfs || "$rootfs" == overlay ]] && EXEC_MODE=live
    log "Execution mode: $EXEC_MODE"
}

# Enforce per user answer: installed mode requires --force-installed.
enforce_exec_mode() {
    local force_installed="${1:-0}"
    if [[ "$EXEC_MODE" == "installed" && "$force_installed" != "1" ]]; then
        die "Refusing to run on an installed system. Pass --force-installed to proceed, or (preferred) boot a Live ISO." 10
    fi
    if [[ "$EXEC_MODE" == "installed" ]]; then
        warn "Running on an INSTALLED system (--force-installed given). This is not the recommended mode."
    fi
}

# -- Binary presence ---------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# ensure_bins BIN1 BIN2... — die if any are missing.
ensure_bins() {
    local missing=()
    local b
    for b in "$@"; do have "$b" || missing+=("$b"); done
    if (( ${#missing[@]} > 0 )); then
        die "Required binaries missing: ${missing[*]}. Run install_packages first or install them manually." 10
    fi
}

# -- Package resolver --------------------------------------------------------
# pkg_install NAME1 NAME2... — install via the distro's package manager.
# Best-effort: a failure to install is a warning, not a die, so the caller
# can fall back (e.g. grub-btrfs source install).
pkg_install() {
    (( $# == 0 )) && return 0
    case "$DISTRO_LIKE" in
        debian)
            run_quiet env DEBIAN_FRONTEND=noninteractive apt-get update || \
                warn "apt-get update failed (continuing)."
            run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || {
                warn "apt-get install failed for: $*"; return 1; }
            ;;
        arch)
            run_quiet pacman -Sy --noconfirm --needed "$@" || {
                warn "pacman install failed for: $*"; return 1; }
            ;;
        *)
            warn "Cannot install packages on unknown distro: $*"
            return 1
            ;;
    esac
    return 0
}

# pkg_available NAME — does the repo know about NAME? (true/false)
pkg_available() {
    local name="$1"
    case "$DISTRO_LIKE" in
        debian) apt-cache show --quiet=0 "$name" >/dev/null 2>&1 ;;
        arch)   pacman -Si "$name" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# -- Device helpers ----------------------------------------------------------
# require_partition DEV — must exist, be a block device, and be TYPE=part.
require_partition() {
    local dev="$1"
    [[ -n "$dev" ]] || die "Partition path is empty." 10
    # Reject device paths with shell/regex metachars — they'd be safe as
    # argv but surface in log messages and error text downstream.
    [[ "$dev" =~ ^/dev/[A-Za-z0-9/_-]+$ ]] || die "Invalid device path: $dev" 10
    [[ -b "$dev" ]] || die "Not a block device: $dev" 10
    local type; type=$(lsblk -ndo TYPE "$dev" 2>/dev/null || true)
    case "$type" in
        part|crypt|lvm) : ;;
        disk) die "Refusing to treat whole disk '$dev' as a partition. Create partitions first." 10 ;;
        *)    die "Unexpected block device type '$type' for $dev." 10 ;;
    esac
}

# require_whole_disk DEV — must be a block device of TYPE=disk (for BIOS
# grub-install targets). Refuses partitions.
require_whole_disk() {
    local dev="$1"
    [[ -n "$dev" ]] || die "Disk path is empty." 10
    [[ "$dev" =~ ^/dev/[A-Za-z0-9/_-]+$ ]] || die "Invalid disk path: $dev" 10
    [[ -b "$dev" ]] || die "Not a block device: $dev" 10
    local type; type=$(lsblk -ndo TYPE "$dev" 2>/dev/null || true)
    [[ "$type" == "disk" ]] || die "Expected whole disk for '$dev' but got type='$type'." 10
}

# require_distinct_devices DEV1 DEV2 ... — die if any pair refers to the
# same underlying block device (by resolving symlinks / same major:minor).
require_distinct_devices() {
    declare -A seen=()
    local d resolved key
    for d in "$@"; do
        [[ -z "$d" ]] && continue
        resolved=$(readlink -f -- "$d" 2>/dev/null || printf '%s' "$d")
        key=$(lsblk -ndo MAJ:MIN -- "$resolved" 2>/dev/null || printf '%s' "$resolved")
        if [[ -n "${seen[$key]:-}" ]]; then
            die "Device collision: '$d' and '${seen[$key]}' resolve to the same block device ($key)." 10
        fi
        seen[$key]="$d"
    done
}

# require_keyfile_ownership FILE — keyfile must be owned by uid 0 and
# have no group/world bits set. Prevents exfiltration via a weaker-ACL
# file passed in by accident.
require_keyfile_ownership() {
    local f="$1"
    [[ -f "$f" ]] || die "Keyfile not found: $f" 10
    local uid; uid=$(stat -c '%u' -- "$f" 2>/dev/null || echo '')
    [[ "$uid" == "0" ]] || die "Keyfile '$f' must be owned by root (uid=0), got uid=$uid." 10
    local mode; mode=$(stat -c '%a' -- "$f" 2>/dev/null || echo '')
    case "$mode" in
        600|400) : ;;
        *) die "Keyfile '$f' must be chmod 0600 or 0400 (got 0$mode)." 10 ;;
    esac
}

# require_username NAME — Linux username rules (IEEE Std 1003.1 + Debian):
# 1-32 chars, [a-z_][a-z0-9_-]*. Rejects trailing '$' (Samba machine acct).
require_username() {
    local name="$1"
    [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
        || die "Invalid username '$name' (must match [a-z_][a-z0-9_-]{0,31})." 10
}

# require_subvol_name NAME — @ or @[A-Za-z0-9_.-]{1,62}. No spaces, no
# slashes, no shell metas — these become path components.
require_subvol_name() {
    local name="$1"
    [[ "$name" =~ ^@[A-Za-z0-9_.-]{0,62}$ ]] \
        || die "Invalid subvolume name '$name' (must match @[A-Za-z0-9_.-]{0,62})." 10
}

# require_srcmp_looks_like_root DIR — sanity: the path the user passed as
# --src-mp should actually look like a rootfs (/etc/fstab + /bin or /usr).
# Catches typos like --src-mp /home/user that would otherwise rsync half
# a home directory into the new @.
require_srcmp_looks_like_root() {
    local mp="$1"
    [[ -d "$mp" ]] || die "--src-mp '$mp' is not a directory." 10
    [[ -f "$mp/etc/fstab" ]] \
        || die "--src-mp '$mp' doesn't look like a rootfs (no etc/fstab)." 10
    [[ -d "$mp/usr" || -d "$mp/bin" ]] \
        || die "--src-mp '$mp' doesn't look like a rootfs (no usr/ or bin/)." 10
}

# fs_of DEV — echo the filesystem type, or empty string.
fs_of() {
    blkid -o value -s TYPE -- "$1" 2>/dev/null || true
}

# require_fs DEV EXPECTED — die if mismatch.
require_fs() {
    local dev="$1" want="$2" got
    got=$(fs_of "$dev")
    if [[ "$got" != "$want" ]]; then
        die "Filesystem mismatch on $dev: expected '$want', got '${got:-none}'." 10
    fi
}

# partition_is_empty DEV — true if the partition has NO known signature.
# Uses wipefs --no-act which reports whatever signatures it would remove.
partition_is_empty() {
    local dev="$1" out
    out=$(wipefs --no-act -- "$dev" 2>/dev/null || true)
    # wipefs prints nothing when there are no signatures.
    [[ -z "$out" ]]
}

# is_ssd DEV — true if the backing disk is non-rotational.
is_ssd() {
    local dev="$1" disk rotfile
    disk=$(lsblk -ndo PKNAME -- "$dev" 2>/dev/null || true)
    [[ -z "$disk" ]] && return 1
    rotfile="/sys/block/$disk/queue/rotational"
    [[ -r "$rotfile" ]] || return 1
    [[ "$(cat "$rotfile")" == "0" ]]
}

# uuid_of DEV — echo UUID= string for fstab/crypttab.
uuid_of() {
    local u; u=$(blkid -o value -s UUID -- "$1" 2>/dev/null || true)
    [[ -n "$u" ]] || die "Could not read UUID of $1" 10
    printf 'UUID=%s' "$u"
}

# detect_user — best-effort guess at the non-root invoking user.
detect_user() {
    local u="${SUDO_USER:-}"
    if [[ -z "$u" || "$u" == "root" ]]; then
        u=$(logname 2>/dev/null || true)
    fi
    if [[ -z "$u" || "$u" == "root" ]]; then
        # On Live ISOs there may be a single UID>=1000 user.
        u=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
    fi
    printf '%s' "${u:-}"
}

# require_user NAME — must exist in /etc/passwd, uid>=1000, not root.
require_user() {
    local name="$1"
    [[ -n "$name" ]] || die "User name is empty; pass --user." 10
    local entry; entry=$(getent passwd "$name" || true)
    [[ -n "$entry" ]] || die "User '$name' does not exist." 10
    local uid; uid=$(cut -d: -f3 <<<"$entry")
    (( uid >= 1000 )) || die "User '$name' has uid=$uid; must be a regular user (uid>=1000)." 10
}
