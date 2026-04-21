#!/usr/bin/env bash
# lib/log.sh — structured logging, ERR/EXIT traps, rollback registry,
# and the sudo re-exec helper used by btrfs-migrate.sh.
#
# Source this first. It assumes the sourcer has already set
# `set -Eeuo pipefail` (or it will set them itself if missing).

if [[ -n "${__BTRFS_MIGRATE_LOG_SH:-}" ]]; then return 0; fi
__BTRFS_MIGRATE_LOG_SH=1

set -Eeuo pipefail

LOG_FILE="${LOG_FILE:-/var/log/btrfs-migrate.log}"
LOG_LEVEL="${LOG_LEVEL:-info}"   # debug|info|warn|error
DRY_RUN="${DRY_RUN:-0}"

# Allowed prefixes for $LOG_FILE. We validate rather than trusting the env
# so a hostile caller cannot redirect root appends into /etc/cron.d or
# similar (H7 in the security audit).
_LOG_ALLOWED_DIRS=(/var/log /tmp "${TMPDIR:-/tmp}" "/run/user/${EUID:-0}")

_log_path_is_safe() {
    local p="$1" dir resolved prefix
    # Absolute, no '..', no newline/NUL — standardise via readlink -f of the
    # parent (file may not exist yet).
    [[ "$p" = /* ]] || return 1
    [[ "$p" != *$'\n'* && "$p" != *$'\0'* ]] || return 1
    dir=$(dirname -- "$p")
    resolved=$(readlink -f -- "$dir" 2>/dev/null) || return 1
    for prefix in "${_LOG_ALLOWED_DIRS[@]}"; do
        [[ "$resolved" = "$prefix" || "$resolved" = "$prefix"/* ]] && return 0
    done
    return 1
}

# Colors only when stderr is a TTY.
if [[ -t 2 ]]; then
    _C_RESET=$'\e[0m'; _C_DIM=$'\e[2m'; _C_RED=$'\e[31m'
    _C_YEL=$'\e[33m';  _C_GRN=$'\e[32m'; _C_BLU=$'\e[34m'
else
    _C_RESET=; _C_DIM=; _C_RED=; _C_YEL=; _C_GRN=; _C_BLU=
fi

_log_level_num() {
    case "$1" in debug) echo 10;; info) echo 20;; warn) echo 30;; error) echo 40;; *) echo 20;; esac
}
_log_threshold=$(_log_level_num "$LOG_LEVEL")

# Ensure the log file exists and is writable. If we don't have permission
# yet (script is running pre-sudo), fall back to a per-user temp log and
# let the re-exec move things later.
_log_init() {
    # Refuse a log path that escapes the allowed set. Fall back to a
    # per-user tempfile rather than trusting the env-supplied value.
    if ! _log_path_is_safe "$LOG_FILE"; then
        LOG_FILE="${TMPDIR:-/tmp}/btrfs-migrate.$(id -u).log"
    fi
    # Refuse symlinks at the final component. Post-privilege this prevents
    # a symlink-swap attack on /var/log/btrfs-migrate.log.
    if [[ -L "$LOG_FILE" ]]; then
        LOG_FILE="${TMPDIR:-/tmp}/btrfs-migrate.$(id -u).log"
    fi
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
        : >>"$LOG_FILE" 2>/dev/null || LOG_FILE="${TMPDIR:-/tmp}/btrfs-migrate.$(id -u).log"
    else
        LOG_FILE="${TMPDIR:-/tmp}/btrfs-migrate.$(id -u).log"
    fi
    : >>"$LOG_FILE"
}
_log_init

# Redaction list — space-separated strings that should be masked when they
# appear in logged command args. We populate this with paths like the
# LUKS keyfile so `run`/`_log debug RUN:` don't leak operational secrets
# via the persistent log file.
declare -a __btrfs_migrate_redact=()
redact_add() {
    local s
    for s in "$@"; do
        [[ -n "$s" ]] && __btrfs_migrate_redact+=("$s")
    done
}
_redacted() {
    local out="$*" needle
    for needle in "${__btrfs_migrate_redact[@]}"; do
        out="${out//$needle/<redacted>}"
    done
    printf '%s' "$out"
}

_log() {
    local lvl="$1"; shift
    local lvl_num; lvl_num=$(_log_level_num "$lvl")
    (( lvl_num < _log_threshold )) && return 0
    local ts; ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local line="[$ts] [$lvl] $*"
    printf '%s\n' "$line" >>"$LOG_FILE"
    case "$lvl" in
        debug) printf '%s%s%s\n' "$_C_DIM" "$line" "$_C_RESET" >&2 ;;
        info)  printf '%s[*]%s %s\n' "$_C_BLU" "$_C_RESET" "$*"  >&2 ;;
        warn)  printf '%s[!]%s %s\n' "$_C_YEL" "$_C_RESET" "$*"  >&2 ;;
        error) printf '%s[x]%s %s\n' "$_C_RED" "$_C_RESET" "$*"  >&2 ;;
        ok)    printf '%s[+]%s %s\n' "$_C_GRN" "$_C_RESET" "$*"  >&2 ;;
    esac
}

log()   { _log info  "$*"; }
ok()    { _log ok    "$*"; }
warn()  { _log warn  "$*"; }
debug() { _log debug "$*"; }
error() { _log error "$*"; }

# die MSG [EXIT_CODE]
die() {
    local msg="$1"; local code="${2:-1}"
    error "$msg"
    exit "$code"
}

# run CMD... — execute or, in dry-run, print only. Always logged.
# Sensitive paths registered via redact_add are masked in log output.
run() {
    local rendered; rendered=$(_redacted "$*")
    if (( DRY_RUN == 1 )); then
        _log info "DRY-RUN: $rendered"
        return 0
    fi
    _log debug "RUN: $rendered"
    "$@"
}

# write_file PATH CONTENT — atomically create/overwrite PATH with CONTENT
# (no shell interpolation of the content). Honours DRY_RUN. Uses tee
# internally so content arrives on stdin and cannot be re-parsed.
write_file() {
    local path="$1" content="$2"
    if (( DRY_RUN == 1 )); then
        _log info "DRY-RUN: write_file $path (${#content} bytes)"
        return 0
    fi
    _log debug "WRITE: $path (${#content} bytes)"
    printf '%s' "$content" | tee -- "$path" >/dev/null
}

# append_file PATH CONTENT — append CONTENT to PATH (no shell interpolation
# of the content). Honours DRY_RUN.
append_file() {
    local path="$1" content="$2"
    if (( DRY_RUN == 1 )); then
        _log info "DRY-RUN: append_file $path (${#content} bytes)"
        return 0
    fi
    _log debug "APPEND: $path (${#content} bytes)"
    printf '%s' "$content" | tee -a -- "$path" >/dev/null
}

# run_quiet CMD... — like run, but stdout goes only to the log file.
run_quiet() {
    local rendered; rendered=$(_redacted "$*")
    if (( DRY_RUN == 1 )); then
        _log info "DRY-RUN: $rendered"
        return 0
    fi
    _log debug "RUN: $rendered"
    "$@" >>"$LOG_FILE" 2>&1
}

# -- Rollback registry -------------------------------------------------------
# Handlers run LIFO when _on_err fires. To avoid re-parsing strings
# through `bash -c` (H1 in the audit) we store each handler as a single
# NUL-separated argv record and exec it directly — no second shell parse,
# no variable re-interpolation. Use `on_rollback -- argv...` for that
# form, or `on_rollback <legacy-string>` which we still accept but warn
# about.
declare -a __rollback_stack=()

# Pack an argv into a NUL-separated record so it round-trips safely
# through a single bash array slot.
_pack_argv() {
    local first=1 a
    for a in "$@"; do
        if (( first )); then first=0; else printf '\0'; fi
        printf '%s' "$a"
    done
}

on_rollback() {
    if [[ "${1:-}" == "--" ]]; then
        shift
        __rollback_stack+=("ARGV:$(_pack_argv "$@")")
    else
        # Legacy form — kept working so existing call sites don't regress,
        # but mark it so we execute it with `bash -c` deliberately.
        __rollback_stack+=("CMD:$*")
    fi
}

_run_rollback() {
    local rc=$?
    local i
    if (( ${#__rollback_stack[@]} == 0 )); then
        return "$rc"
    fi
    warn "Running ${#__rollback_stack[@]} rollback step(s)..."
    for (( i=${#__rollback_stack[@]}-1; i>=0; i-- )); do
        local entry="${__rollback_stack[$i]}"
        case "$entry" in
            ARGV:*)
                local packed="${entry#ARGV:}"
                local -a rb_argv=()
                # Split NUL-delimited into argv.
                local IFS=$'\0'
                read -r -d '' -a rb_argv < <(printf '%s\0' "$packed") || true
                unset IFS
                _log debug "ROLLBACK: ${rb_argv[*]}"
                "${rb_argv[@]}" >>"$LOG_FILE" 2>&1 || \
                    warn "Rollback step failed (continuing): ${rb_argv[*]}"
                ;;
            CMD:*)
                local cmd="${entry#CMD:}"
                _log debug "ROLLBACK: $cmd"
                bash -c "$cmd" >>"$LOG_FILE" 2>&1 || \
                    warn "Rollback step failed (continuing): $cmd"
                ;;
        esac
    done
    return "$rc"
}

# Cleared by the main script once it decides it wants to KEEP the
# partially-built state (e.g. after a successful phase boundary).
commit_phase() {
    __rollback_stack=()
    debug "rollback stack cleared"
}

# -- Trap handlers -----------------------------------------------------------
_on_err() {
    local rc=$?
    local line="${BASH_LINENO[0]:-?}"
    local cmd="${BASH_COMMAND:-?}"
    error "Command failed (rc=$rc) at line $line: $cmd"
    _run_rollback || true
    exit "$rc"
}

_on_exit() {
    local rc=$?
    if (( rc == 0 )); then
        ok   "btrfs-migrate finished OK."
    else
        error "btrfs-migrate exited with rc=$rc. See $LOG_FILE."
    fi
}

trap '_on_err' ERR
trap '_on_exit' EXIT

# -- Privilege re-exec -------------------------------------------------------
# After flag parsing and plan confirmation (interactive runs), the
# entrypoint calls require_root_or_reexec "$@". If we're already root
# we return. Otherwise we re-exec via sudo and the downstream run picks
# back up as the second process.
#
# We deliberately do NOT use `sudo -E`: that preserves every env var the
# invoking user set, including ones later consumed in `bash -c`
# contexts (e.g. GRUB_BTRFS_REPO). A hostile local caller could inject
# a shell payload that way. Instead we forward a fixed whitelist via
# `env -i` so the root-side shell starts with a known-minimal env.
require_root_or_reexec() {
    if (( EUID == 0 )); then
        return 0
    fi
    if [[ -n "${BTRFS_MIGRATE_REEXECED:-}" ]]; then
        die "Privilege escalation failed: still non-root after re-exec." 2
    fi
    log "Elevating with sudo to execute the plan..."
    local self; self=$(readlink -f -- "$0")
    # Re-validate LOG_FILE inside the forward — the child re-runs
    # _log_init, which rejects paths outside _LOG_ALLOWED_DIRS.
    local forwarded_log="$LOG_FILE"
    _log_path_is_safe "$forwarded_log" || forwarded_log=""
    # Optional repo overrides are forwarded only if they look like plain
    # https URLs ending in .git — no shell metachars, no file:// etc.
    local grub_btrfs_repo="" btrfs_assistant_repo=""
    if [[ "${GRUB_BTRFS_REPO:-}" =~ ^https://[A-Za-z0-9./_~@:-]+\.git$ ]]; then
        grub_btrfs_repo="$GRUB_BTRFS_REPO"
    fi
    if [[ "${BTRFS_ASSISTANT_REPO:-}" =~ ^https://[A-Za-z0-9./_~@:-]+\.git$ ]]; then
        btrfs_assistant_repo="$BTRFS_ASSISTANT_REPO"
    fi
    # shellcheck disable=SC2093
    exec sudo -- env -i \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        HOME="/root" \
        TERM="${TERM:-xterm}" \
        LANG="${LANG:-C.UTF-8}" \
        BTRFS_MIGRATE_REEXECED=1 \
        ${forwarded_log:+LOG_FILE="$forwarded_log"} \
        DRY_RUN="$DRY_RUN" \
        LOG_LEVEL="$LOG_LEVEL" \
        ${grub_btrfs_repo:+GRUB_BTRFS_REPO="$grub_btrfs_repo"} \
        ${btrfs_assistant_repo:+BTRFS_ASSISTANT_REPO="$btrfs_assistant_repo"} \
        -- "$self" "$@"
}
