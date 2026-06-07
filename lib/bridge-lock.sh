#!/usr/bin/env bash
# shellcheck shell=bash
# lib/bridge-lock.sh — a small, reusable scoped advisory-lock primitive.
#
# Issue #1661: `agent-bridge upgrade --apply` (and `rollback --apply`) had no
# singleton lock, so two concurrent runs against the same BRIDGE_HOME could race
# the daemon + agent mass-restart (5-process thrash observed on the v0.16.1
# cascade rollout). This generalizes the flock-first / mkdir-fallback primitive
# that `lib/bridge-daemon-control.sh` already proved, so the upgrade path does
# not have to source daemon-control internals nor carry a divergent copy.
#
# CRITICAL CALLING CONVENTION (flock correctness): the flock backend holds the
# lock through a long-lived fd opened with `exec {fd}>>file`. That fd survives
# only in the process that runs the function — so the acquire helper MUST be
# called DIRECTLY (`bridge_scoped_lock_acquire "$lock"`), NEVER inside a command
# substitution (`tok="$(bridge_scoped_lock_acquire ...)"`). A `$(...)` subshell
# closes its open-file-description on exit, releasing the flock immediately even
# though the parent's fd number looks open. The acquired release token is
# therefore returned via the global `BRIDGE_SCOPED_LOCK_TOKEN`, not stdout.
#
# Public API:
#   bridge_scoped_lock_acquire <lockfile> [--wait <secs>]
#       Acquire an exclusive advisory lock. On success sets
#       BRIDGE_SCOPED_LOCK_TOKEN to a release token and returns 0. On contention
#       prints a clear diagnostic to stderr naming the holder pid + start time,
#       clears BRIDGE_SCOPED_LOCK_TOKEN, and returns 1. Default is REFUSE-FAST
#       (no blocking). `--wait <secs>` blocks up to <secs> seconds (bounded);
#       bare `--wait` defaults to a 600s ceiling. Operator/cascade automation
#       relies on the refuse-fast default, so blocking is strictly opt-in.
#       MUST be called directly (see CALLING CONVENTION above).
#
#   bridge_scoped_lock_release <token>
#       Release a lock acquired above. Idempotent; safe with an empty token.
#
#   bridge_scoped_lock_run_without <token> <cmd> [args...]
#       Run <cmd> with the lock's flock fd CLOSED FOR THE CHILD ONLY, so a
#       long-lived process spawned mid-critical-section (e.g. the upgrade's
#       `bridge-daemon.sh ensure`, which daemonizes + spawns tmux) cannot
#       inherit the fd and keep the lock held past this process's exit. The
#       caller retains its own fd + the lock for the rest of the section. A
#       no-op pass-through for the mkdir backend (no fd to leak) or an empty
#       token. Mirrors lib/bridge-daemon-control.sh's #1388/#1390 fd-leak fix.
#
# Token format (matches daemon-control for forensic familiarity):
#   flock:<fd>:<lockfile>
#   mkdir:<lockdir>

# Guard: refuse double-source.
if [[ -n "${_BRIDGE_LOCK_SH_SOURCED:-}" ]]; then
  return 0
fi
_BRIDGE_LOCK_SH_SOURCED=1

# Out-parameter for bridge_scoped_lock_acquire (see CALLING CONVENTION).
BRIDGE_SCOPED_LOCK_TOKEN="${BRIDGE_SCOPED_LOCK_TOKEN:-}"

# Write the owner pid + an ISO-ish start timestamp into the lock so a contender
# can print a useful diagnostic. Best-effort — never fatal.
_bridge_lock_stamp() {
  local dest="$1"
  local kind="$2"  # "fd" or "file"
  local started
  started="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
  if [[ "$kind" == "fd" ]]; then
    ( printf 'pid=%s\nstarted=%s\n' "$$" "$started" >&"$dest" ) 2>/dev/null || true
  else
    printf 'pid=%s\nstarted=%s\n' "$$" "$started" >"$dest" 2>/dev/null || true
  fi
}

# Read holder pid/started from a lockfile (flock backend) or owner file (mkdir
# backend) for the contention diagnostic. Echoes "<pid> <started>".
_bridge_lock_read_owner() {
  local owner_file="$1"
  local pid="unknown" started="unknown" line key val
  if [[ -r "$owner_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      key="${line%%=*}"
      val="${line#*=}"
      case "$key" in
        pid) [[ -n "$val" ]] && pid="$val" ;;
        started) [[ -n "$val" ]] && started="$val" ;;
      esac
    done <"$owner_file"
  fi
  printf '%s %s' "$pid" "$started"
}

bridge_scoped_lock_acquire() {
  BRIDGE_SCOPED_LOCK_TOKEN=""
  local lock_path=""
  local wait_secs=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait)
        # Optional numeric argument; bare `--wait` => bounded default ceiling.
        if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
          wait_secs="$2"
          shift 2
        else
          wait_secs=600
          shift
        fi
        ;;
      --)
        shift
        ;;
      *)
        if [[ -z "$lock_path" ]]; then
          lock_path="$1"
          shift
        else
          printf '[bridge-lock] unexpected argument: %s\n' "$1" >&2
          return 2
        fi
        ;;
    esac
  done
  [[ -n "$lock_path" ]] || { printf '[bridge-lock] no lockfile given\n' >&2; return 2; }

  local lock_parent
  lock_parent="$(dirname -- "$lock_path")"
  mkdir -p -- "$lock_parent" 2>/dev/null || {
    printf '[bridge-lock] cannot create lock dir: %s\n' "$lock_parent" >&2
    return 1
  }

  # BRIDGE_SCOPED_LOCK_DISABLE_FLOCK=1 forces the mkdir backend even where
  # flock(1) exists — a testability seam (exercises the stale-reclaim path) and
  # an escape hatch for hosts with a broken/sandboxed flock.
  if [[ "${BRIDGE_SCOPED_LOCK_DISABLE_FLOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
    local lock_fd
    # exec assigns the fd in THE CALLER'S process so the lock persists past this
    # function's return (see CALLING CONVENTION — never call under `$(...)`).
    # Open with `>>` (no truncate) so a CONTENDER's open does not wipe the
    # current holder's stamped pid/started before it reads them; the winner
    # truncates + restamps explicitly below.
    # shellcheck disable=SC2093  # we explicitly want the fd to outlive this fn
    exec {lock_fd}>>"$lock_path" 2>/dev/null || {
      printf '[bridge-lock] cannot open lockfile: %s\n' "$lock_path" >&2
      return 1
    }
    # -w 0 == non-blocking refuse-fast; -w <secs> == bounded wait.
    if flock -w "$wait_secs" "$lock_fd" 2>/dev/null; then
      # Truncate-then-stamp so the diagnostic reflects THIS owner.
      : >"$lock_path" 2>/dev/null || true
      _bridge_lock_stamp "$lock_fd" fd
      BRIDGE_SCOPED_LOCK_TOKEN="flock:${lock_fd}:${lock_path}"
      return 0
    fi
    # Contention: read the current holder for a clear diagnostic, then close.
    local owner pid started
    owner="$(_bridge_lock_read_owner "$lock_path")"
    pid="${owner%% *}"
    started="${owner#* }"
    printf '[bridge-lock] an upgrade/rollback is already running for %s (pid %s, started %s)\n' \
      "${BRIDGE_HOME:-$lock_parent}" "$pid" "$started" >&2
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi

  # Fallback: mkdir-as-lock (no flock(1), e.g. stock macOS). Non-destructive —
  # reclaim a stale lockdir ONLY when its recorded owner pid is provably dead.
  local lock_dir="${lock_path}.d"
  local owner_file="$lock_dir/owner"
  local waited=0
  while : ; do
    if mkdir -- "$lock_dir" 2>/dev/null; then
      _bridge_lock_stamp "$owner_file" file
      BRIDGE_SCOPED_LOCK_TOKEN="mkdir:${lock_dir}"
      return 0
    fi
    # Lock taken — check liveness of recorded owner pid.
    local owner pid started
    owner="$(_bridge_lock_read_owner "$owner_file")"
    pid="${owner%% *}"
    started="${owner#* }"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      # Dead owner — reclaim. This is the only safe destructive path: we
      # proved the recorded pid is gone. Loop to retry mkdir.
      rm -f "$owner_file" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    if (( waited >= wait_secs )); then
      printf '[bridge-lock] an upgrade/rollback is already running for %s (pid %s, started %s)\n' \
        "${BRIDGE_HOME:-$lock_parent}" "$pid" "$started" >&2
      return 1
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
}

bridge_scoped_lock_release() {
  local token="${1:-}"
  [[ -n "$token" ]] || return 0
  case "$token" in
    flock:*:*)
      local fd="${token#flock:}"
      fd="${fd%%:*}"
      if [[ "$fd" =~ ^[0-9]+$ ]]; then
        # Close the fd; flock(2) releases on close. Leave the lockfile in
        # place (it carries no live state once the fd is gone).
        eval "exec ${fd}>&-" 2>/dev/null || true
      fi
      ;;
    mkdir:*)
      local lock_dir="${token#mkdir:}"
      if [[ -n "$lock_dir" && -d "$lock_dir" ]]; then
        rm -f "$lock_dir/owner" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
      fi
      ;;
  esac
  return 0
}

# Run a command with the lock's flock fd closed FOR THE CHILD ONLY. The parent
# keeps its fd + the lock. Use this around any spawn that can outlive this
# process (daemonizing process, tmux server) so it cannot inherit + pin the
# lock fd. mkdir backend / empty token => transparent pass-through.
bridge_scoped_lock_run_without() {
  local token="${1:-}"
  shift || true
  [[ $# -gt 0 ]] || return 0
  case "$token" in
    flock:*:*)
      local fd="${token#flock:}"
      fd="${fd%%:*}"
      if [[ "$fd" =~ ^[0-9]+$ ]]; then
        # `{fd}>&-` closes the fd for the spawned child only (eval-built but
        # argv-preserving). Run in a subshell so the parent's fd is untouched.
        ( eval "exec ${fd}>&-" 2>/dev/null || true; "$@" )
        return $?
      fi
      ;;
  esac
  "$@"
}
