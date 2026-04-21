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
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
        : >>"$LOG_FILE" 2>/dev/null || LOG_FILE="${TMPDIR:-/tmp}/btrfs-migrate.$(id -u).log"
    else
        LOG_FILE="${TMPDIR:-/tmp}/btrfs-migrate.$(id -u).log"
    fi
    : >>"$LOG_FILE"
}
_log_init

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
run() {
    if (( DRY_RUN == 1 )); then
        _log info "DRY-RUN: $*"
        return 0
    fi
    _log debug "RUN: $*"
    "$@"
}

# run_quiet CMD... — like run, but stdout goes only to the log file.
run_quiet() {
    if (( DRY_RUN == 1 )); then
        _log info "DRY-RUN: $*"
        return 0
    fi
    _log debug "RUN: $*"
    "$@" >>"$LOG_FILE" 2>&1
}

# -- Rollback registry -------------------------------------------------------
# Push shell snippets that should run (in LIFO order) if the script aborts
# partway. Handlers are best-effort: they must not abort on their own errors.
declare -a __rollback_stack=()

on_rollback() {
    # Register a rollback command. Example:
    #   on_rollback "umount /mnt/root || true"
    __rollback_stack+=("$*")
}

_run_rollback() {
    local rc=$?
    local i
    if (( ${#__rollback_stack[@]} == 0 )); then
        return "$rc"
    fi
    warn "Running ${#__rollback_stack[@]} rollback step(s)..."
    for (( i=${#__rollback_stack[@]}-1; i>=0; i-- )); do
        local cmd="${__rollback_stack[$i]}"
        _log debug "ROLLBACK: $cmd"
        bash -c "$cmd" >>"$LOG_FILE" 2>&1 || \
            warn "Rollback step failed (continuing): $cmd"
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
# The script entrypoint should call `require_root_or_reexec "$@"` after it has
# parsed flags and (in interactive mode) confirmed the plan. If not root, this
# re-execs the same script via sudo with a sentinel env var so we don't loop.
require_root_or_reexec() {
    if (( EUID == 0 )); then
        return 0
    fi
    if [[ -n "${BTRFS_MIGRATE_REEXECED:-}" ]]; then
        die "Privilege escalation failed: still non-root after re-exec." 2
    fi
    log "Elevating with sudo to execute the plan..."
    local self; self=$(readlink -f -- "$0")
    # shellcheck disable=SC2093
    BTRFS_MIGRATE_REEXECED=1 LOG_FILE="$LOG_FILE" DRY_RUN="$DRY_RUN" \
        exec sudo -E -- "$self" "$@"
}
