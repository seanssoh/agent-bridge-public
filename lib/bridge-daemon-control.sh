#!/usr/bin/env bash
# lib/bridge-daemon-control.sh — high-level daemon orchestration helpers
# that the runtime calls AFTER a controller-side supplementary-groups
# mutation (agent create / delete / isolate / isolate --reapply).
#
# Beta20 L2 Variant 3A (codex r3 implement-ok at task #6270):
# fixes the "daemon-controller supp-groups stale" class that landed
# patch's three symptoms on the beta19 install:
#   1. bridge-send.sh --urgent falls back to queue-only because the
#      daemon (forked from a controller shell whose process-group set
#      was captured PRE-`usermod -aG`) cannot write the pending-attention
#      lock under the isolated agent's group-owned dir.
#   2. agent restart channel-readiness needs an `sg <group>` wrapper.
#   3. Stop hook idle-since rc=5 (separate; not addressed here per spec
#      §"Known non-goals").
#
# Fix shape: after the controller user is added to (or already in) the
# target group, restart the running daemon under `sudo -u <controller> -H`
# so PAM/initgroups rebuilds the supplementary group set for the new
# daemon process. The sudoers entry is narrow (named user, absolute
# bash + exact daemon command + exact args, SETENV restricted to the
# preserved env list); install / regenerate via:
#
#   agent-bridge init sudoers daemon-refresh --apply
#
# All non-Linux hosts no-op; daemon-not-running hosts no-op; agents whose
# controller membership was a no-op AND the daemon /proc/<pid>/status
# Groups line already contains the target GID also no-op.
#
# Status strings returned by bridge_daemon_refresh_after_group_membership_change:
#   ok                                    bridge-managed sudo restart (r3 direct path)
#   ok-systemd-sudo-self                  systemd-user managed; sudo-wrapped ExecStart
#                                         refreshed the daemon on `systemctl --user
#                                         restart agent-bridge-daemon.service` (r4)
#   skipped-non-linux
#   skipped-daemon-not-running
#   skipped-daemon-already-has-group
#   manual-required-sudoers               (sudo -n returned a sudoers-class rc)
#   manual-required-sudo-refresh-no-gid   (sudo invoke succeeded but new daemon's
#                                          Groups still lacks the target GID)
#   manual-required-systemd-unit-stale    (r4: unit is active but its ExecStart is
#                                          the legacy direct-bash shape — needs
#                                          regenerate + sudoers + restart)
#   manual-required-systemd-sudoers       (r4: unit is sudo-wrapped but sudoers
#                                          drop-in is missing or rejecting the
#                                          authorized command)
#   failed-restart                        (restart cmd returned non-zero)
#   failed-systemctl-restart              (r4: systemctl --user restart returned !=0)
#   failed-systemd-refresh-no-gid         (r4: systemctl restart succeeded but new
#                                          daemon's Groups STILL lacks the GID —
#                                          PAM/sudo refresh didn't take, host-config
#                                          drift)
#   failed-timeout                        (new daemon pid never appeared)
#
# All status strings are stable contract — consumed by JSON envelopes
# in agent create / delete and by the `agent-bridge init sudoers
# daemon-refresh --check` CLI; don't reword without updating both.

# Guard: refuse double-source.
if [[ -n "${_BRIDGE_DAEMON_CONTROL_SOURCED:-}" ]]; then
  return 0
fi
_BRIDGE_DAEMON_CONTROL_SOURCED=1

# Issue #1388: the singleton-lock fd number, recorded by
# bridge_daemon_ensure_singleton on a successful flock acquire so the
# daemon's agent-launch path can close it for the spawned tmux server
# (close-for-child) without ever releasing the daemon's own hold. Empty
# until acquired, and on the mkdir-fallback backend (no fd to leak).
BRIDGE_DAEMON_SINGLETON_LOCK_FD="${BRIDGE_DAEMON_SINGLETON_LOCK_FD:-}"

# Issue #1667: out-parameter for _bridge_daemon_control_lock_acquire (see the
# CALLING CONVENTION on that function). The flock backend holds the daemon-
# refresh lock through a long-lived fd opened with `exec {fd}>"$lock"`; that fd
# survives only in the process that runs the acquire helper. Capturing the
# token via command substitution — `tok="$(_bridge_daemon_control_lock_acquire
# ...)"` — runs the acquire in a `$(...)` subshell whose open-file-description
# closes on exit, RELEASING the flock immediately even though the parent saw a
# token string. The token is therefore returned via this global, NOT stdout,
# and the helper MUST be called directly. Mirrors lib/bridge-lock.sh's
# BRIDGE_SCOPED_LOCK_TOKEN (#1661).
BRIDGE_DAEMON_CONTROL_LOCK_TOKEN="${BRIDGE_DAEMON_CONTROL_LOCK_TOKEN:-}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_bridge_daemon_control_is_linux() {
  [[ "$(uname -s 2>/dev/null)" == "Linux" ]]
}

# Read /proc/<pid>/status and emit the numeric GIDs from the `Groups:`
# line, one per line. Returns rc=0 if the file was readable and rc=1
# otherwise. Empty output is valid (process has no supp groups).
_bridge_daemon_control_proc_groups() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  local status_path="/proc/$pid/status"
  [[ -r "$status_path" ]] || return 1
  # The `Groups:` line is space-separated GIDs followed by a trailing
  # space. Parse with awk to tolerate the field count varying across
  # kernels. Emits one GID per line; an empty supplementary set yields
  # zero lines.
  awk '/^Groups:/ { for (i=2; i<=NF; i++) print $i; exit }' "$status_path"
}

# Translate a group name into its numeric GID via getent. Empty output
# + rc=1 on lookup failure.
_bridge_daemon_control_resolve_gid() {
  local group="$1"
  [[ -n "$group" ]] || return 1
  # getent group <name> → "<name>:<pw>:<gid>:<member-list>"
  local line
  line="$(getent group "$group" 2>/dev/null)" || return 1
  printf '%s' "$line" | awk -F: '{ print $3 }'
}

# Return 0 if the running daemon (resolved via bridge_daemon_pid) has
# the target GID in its /proc/<pid>/status Groups line; rc=1 otherwise.
# rc=2 if the daemon is not running or its /proc/<pid>/status cannot be
# read (so callers can distinguish "no daemon" from "wrong groups").
#
# #1246: When BRIDGE_DAEMON_CONTROL_DECISION_LOG is set, this helper
# ALSO emits a single structured decision-evidence line to that file
# path so the operator can see *which* PID was probed, *what* groups
# were observed, and *which* outcome was returned. Without that the
# pre-check at lines 348/383 below could silently false-positive
# (return 0 with stale on-disk cache) and the systemd-user auto-restart
# branch at lines 404+ never fires.
#
# r2 codex r1 CONTRACT MISMATCH #1246: also emits `on_disk=<GIDs>` —
# the supplementary group set resolved via `id -G <user>` for the
# daemon's owner. Brief required both fields so the operator can
# diagnose "on_disk has the GID but in_proc doesn't → daemon needs a
# fresh exec; PAM/initgroups will pick up the new group" vs "on_disk
# itself is missing the GID → the controller user was never added,
# fix sudoers/usermod first". in_proc remains authoritative for the
# refresh decision; on_disk is purely diagnostic.
#
# Format (single line, no trailing newline beyond the literal \n):
#   [daemon-control] supp-group check: pid=<P> on_disk=<G1,G2,...> in_proc=<G1,G2,...> target_gid=<G> action=<refresh|skip> reason=<rationale>
_bridge_daemon_control_daemon_has_gid() {
  local target_gid="$1"
  [[ -n "$target_gid" ]] || return 2
  local pid
  pid="$(bridge_daemon_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] || {
    _bridge_daemon_control_emit_decision_log \
      "" "" "" "$target_gid" "skip" "daemon-not-running"
    return 2
  }
  local groups_output
  groups_output="$(_bridge_daemon_control_proc_groups "$pid" 2>/dev/null)" || {
    _bridge_daemon_control_emit_decision_log \
      "$pid" "$(_bridge_daemon_control_proc_owner_on_disk_groups "$pid")" "" "$target_gid" "skip" "proc-status-unreadable"
    return 2
  }
  # Normalize for the decision log: space-or-newline separated → comma.
  # Use `tr -s` to squeeze runs of whitespace, then tr space→comma; this
  # is portable across BSD/GNU sed (sed `\+` is a GNU-only extension).
  local _flat_groups
  _flat_groups="$(printf '%s' "$groups_output" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//' | tr ' ' ',')"
  local _on_disk
  _on_disk="$(_bridge_daemon_control_proc_owner_on_disk_groups "$pid")"
  if printf '%s\n' "$groups_output" | grep -Fxq -- "$target_gid"; then
    _bridge_daemon_control_emit_decision_log \
      "$pid" "$_on_disk" "$_flat_groups" "$target_gid" "skip" "already-has-group"
    return 0
  fi
  _bridge_daemon_control_emit_decision_log \
    "$pid" "$_on_disk" "$_flat_groups" "$target_gid" "refresh" "missing-from-supp-set"
  return 1
}

# r2 codex r1 CONTRACT MISMATCH #1246: resolve the daemon process
# owner via /proc/<pid>/status `Uid:` and emit `id -G <user>` as a
# comma-separated GID list. Empty string on any failure — the
# decision-evidence line still has a stable shape so log scrapers do
# not break.
_bridge_daemon_control_proc_owner_on_disk_groups() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  local status_path="/proc/$pid/status"
  [[ -r "$status_path" ]] || return 0
  # Uid: line is `Uid:\tREAL\tEFFECTIVE\tSAVED\tFS`; take the effective
  # uid (field 3) so a setuid process is resolved to the EUID under
  # which it actually runs.
  local uid
  uid="$(awk '/^Uid:/ { print $3; exit }' "$status_path" 2>/dev/null)"
  [[ -n "$uid" ]] || return 0
  local user
  user="$(getent passwd "$uid" 2>/dev/null | awk -F: '{ print $1; exit }')"
  [[ -n "$user" ]] || return 0
  # `id -G` emits space-separated GIDs; convert to comma-separated for
  # log-scraper consistency with in_proc.
  id -G "$user" 2>/dev/null | tr ' ' ',' | tr -d '\n'
}

# #1246: emit the structured decision-evidence line. Writes to
# BRIDGE_DAEMON_CONTROL_DECISION_LOG when set; otherwise emits to the
# daemon log via daemon_info when that helper is loaded; otherwise
# silently no-ops. Single-line, fixed-shape so log scrapers can grep
# the fixed prefix and parse the fields without parsing variable text.
#
# r2 codex r1: on_disk arg added (between pid and in_proc) so the
# operator sees both sources in one line — see contract comment on
# _bridge_daemon_control_daemon_has_gid above.
_bridge_daemon_control_emit_decision_log() {
  local pid="$1"
  local on_disk="$2"
  local in_proc="$3"
  local target_gid="$4"
  local action="$5"
  local reason="$6"
  local line
  line="$(printf '[daemon-control] supp-group check: pid=%s on_disk=%s in_proc=%s target_gid=%s action=%s reason=%s' \
    "${pid:-}" "${on_disk:-}" "${in_proc:-}" "${target_gid:-}" "${action:-}" "${reason:-}")"
  if [[ -n "${BRIDGE_DAEMON_CONTROL_DECISION_LOG:-}" ]]; then
    # Best-effort append; never fail the caller on log-write errors.
    printf '%s\n' "$line" >>"$BRIDGE_DAEMON_CONTROL_DECISION_LOG" 2>/dev/null || true
    return 0
  fi
  if command -v daemon_info >/dev/null 2>&1; then
    daemon_info "$line" 2>/dev/null || true
    return 0
  fi
  if command -v bridge_warn >/dev/null 2>&1; then
    # bridge_warn is the only logger guaranteed to exist when this lib
    # is sourced standalone (test fixtures). Route through it so the
    # evidence still lands somewhere the operator can find.
    bridge_warn "$line" 2>/dev/null || true
  fi
  return 0
}

# Sanitize a free-form reason string to the codex r3 §3 character class.
# Anything outside [A-Za-z0-9_.:=,+-] is replaced with '-'. Bounded to
# 256 chars so it cannot blow out the env line passed via sudo
# --preserve-env. Emits the sanitized value on stdout.
_bridge_daemon_control_sanitize_reason() {
  local raw="$1"
  [[ -n "$raw" ]] || { printf 'unspecified'; return 0; }
  local clean
  clean="$(printf '%s' "$raw" | LC_ALL=C tr -c 'A-Za-z0-9_.:=,+\-' '-')"
  if (( ${#clean} > 256 )); then
    clean="${clean:0:256}"
  fi
  printf '%s' "$clean"
}

# Lock acquisition. Tries flock(1) first (preferred — atomic kernel-level
# advisory lock with timeout); falls back to mkdir-with-PID-staleness
# guard when flock is missing. Returns rc=0 on success and rc=1 on
# contention or unrecoverable error.
#
# CALLING CONVENTION (#1667 — flock correctness): on success the release
# token is returned via the global BRIDGE_DAEMON_CONTROL_LOCK_TOKEN, NEVER
# stdout. The flock backend holds the lock through a long-lived fd opened
# with `exec {fd}>"$lock"`; that fd survives ONLY in the process that runs
# this function. Capturing the token under command substitution
# (`tok="$(_bridge_daemon_control_lock_acquire ...)"`) runs the body in a
# `$(...)` subshell whose open-file-description closes on exit, releasing
# the flock immediately — the caller would hold a token string for a lock
# that is already free, defeating the mutual exclusion the daemon-refresh
# critical section depends on. Call this helper DIRECTLY and read the token
# from the global; pass that token to _bridge_daemon_control_lock_release.
#
# Token format:
#   flock:<fd>:<lockfile>
#   mkdir:<lockdir>
_bridge_daemon_control_lock_acquire() {
  BRIDGE_DAEMON_CONTROL_LOCK_TOKEN=""
  local lock_path="$1"
  local timeout_secs="${2:-30}"
  [[ -n "$lock_path" ]] || return 1
  local lock_parent
  lock_parent="$(dirname -- "$lock_path")"
  mkdir -p -- "$lock_parent" 2>/dev/null || return 1

  if command -v flock >/dev/null 2>&1; then
    # flock with a non-stdio fd. exec assigns the fd in THE CALLER'S
    # process so the lock persists past the function return (see CALLING
    # CONVENTION — never call under `$(...)`); caller closes it via the
    # release helper. The lockfile is created if missing.
    local lock_fd
    # shellcheck disable=SC2093  # we explicitly want the fd to outlive this fn
    exec {lock_fd}>"$lock_path" 2>/dev/null || return 1
    if flock -w "$timeout_secs" "$lock_fd" 2>/dev/null; then
      # Stamp owner PID into the lockfile for forensic value (NOT
      # consulted on release — flock is the source of truth). Write
      # through the held fd via a subshell so multiple redirections
      # don't compete for stderr (shellcheck SC2261).
      ( printf '%s\n' "$$" >&"$lock_fd" ) 2>/dev/null || true
      BRIDGE_DAEMON_CONTROL_LOCK_TOKEN="flock:${lock_fd}:${lock_path}"
      return 0
    fi
    # Contention: close the fd we opened.
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi

  # Fallback: mkdir-as-lock. Non-destructive — if a stale lockdir
  # exists, we read its owner PID and reclaim ONLY when the recorded
  # PID is dead. Never unconditionally rm -rf an active lock.
  local lock_dir="${lock_path}.d"
  local waited=0
  while (( waited < timeout_secs )); do
    if mkdir -- "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock_dir/owner.pid" 2>/dev/null || true
      BRIDGE_DAEMON_CONTROL_LOCK_TOKEN="mkdir:${lock_dir}"
      return 0
    fi
    # Lock taken — check liveness of recorded owner PID.
    local owner_pid=""
    if [[ -r "$lock_dir/owner.pid" ]]; then
      owner_pid="$(head -n1 "$lock_dir/owner.pid" 2>/dev/null | tr -dc '0-9')"
    fi
    if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      # Dead owner — reclaim by removing the owner.pid and the dir,
      # then loop to retry mkdir. This is the only safe destructive
      # path: we proved the recorded PID is gone.
      rm -f "$lock_dir/owner.pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 1
}

_bridge_daemon_control_lock_release() {
  local token="$1"
  [[ -n "$token" ]] || return 0
  case "$token" in
    flock:*:*)
      local fd="${token#flock:}"
      fd="${fd%%:*}"
      if [[ "$fd" =~ ^[0-9]+$ ]]; then
        # Close the fd; flock(2) releases the lock on close.
        eval "exec ${fd}>&-" 2>/dev/null || true
      fi
      ;;
    mkdir:*)
      local lock_dir="${token#mkdir:}"
      if [[ -n "$lock_dir" && -d "$lock_dir" ]]; then
        rm -f "$lock_dir/owner.pid" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
      fi
      ;;
  esac
  return 0
}

# r4: detect whether the bridge daemon is currently managed by
# systemd-user. Returns 0 (true) when the unit is active per
# `systemctl --user is-active --quiet`, 1 otherwise (including
# systemctl missing, non-Linux, or unit stopped). Output is silent —
# callers branch on rc.
_bridge_daemon_control_systemd_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user is-active --quiet agent-bridge-daemon.service 2>/dev/null
}

# r4: check whether the installed systemd-user unit is refresh-capable
# — i.e. its ExecStart crosses the sudo-to-self PAM boundary. Returns
# 0 when the unit file contains either the explicit refresh-mode
# environment marker (`BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE=sudo-self`)
# OR an ExecStart line that starts with sudo. rc=1 otherwise (legacy
# direct-bash unit, missing unit, or unreadable).
_bridge_daemon_control_systemd_unit_is_refresh_capable() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local unit_file
  # `systemctl --user cat` resolves the active unit file (drop-ins
  # included). Quiet stderr to avoid noise on hosts that don't have
  # the unit installed yet.
  unit_file="$(systemctl --user cat agent-bridge-daemon.service 2>/dev/null || true)"
  [[ -n "$unit_file" ]] || return 1
  # Either marker satisfies the check:
  if printf '%s' "$unit_file" | grep -qF -- 'BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE=sudo-self'; then
    return 0
  fi
  if printf '%s' "$unit_file" | grep -qE '^[[:space:]]*ExecStart=[[:space:]]*[^ ]*sudo[[:space:]]'; then
    return 0
  fi
  return 1
}

# Resolve the controller user. Prefers BRIDGE_CONTROLLER_USER (set by
# bridge-lib.sh when the operator is the controller); falls back to the
# current effective user. Refuses to return root (sudoers MUST authorize
# a named non-root user — codex r3 §1).
_bridge_daemon_control_controller_user() {
  local user="${BRIDGE_CONTROLLER_USER:-}"
  if [[ -z "$user" ]]; then
    user="$(bridge_current_user 2>/dev/null || id -un 2>/dev/null || true)"
  fi
  if [[ -z "$user" || "$user" == "root" ]]; then
    return 1
  fi
  printf '%s' "$user"
}

# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------

# bridge_daemon_refresh_after_group_membership_change — top-level entry.
#
# Usage:
#   bridge_daemon_refresh_after_group_membership_change \
#     --group <name> \
#     --reason <text> \
#     [--dry-run]
#
# Emits one of the status strings documented at the top of this file on
# stdout (single line, no trailing punctuation). Exit code mirrors:
#   0 — ok / skipped-* (caller can ignore)
#   1 — failed-* / manual-required-* (caller surfaces but does not abort)
#
# Non-fatal contract: callers (agent create/delete, isolate, reapply)
# treat any non-zero rc as a UX surface, not a rollback trigger. The
# agent mutation that motivated the refresh has already landed; refusing
# the daemon refresh does NOT unwind it.
bridge_daemon_refresh_after_group_membership_change() {
  local group=""
  local reason=""
  local dry_run=0

  while (( $# > 0 )); do
    case "$1" in
      --group)
        group="${2:-}"
        shift 2
        ;;
      --reason)
        reason="${2:-}"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *)
        bridge_warn "bridge_daemon_refresh_after_group_membership_change: unknown arg: $1"
        return 1
        ;;
    esac
  done

  if [[ -z "$group" ]]; then
    bridge_warn "bridge_daemon_refresh_after_group_membership_change: --group required"
    return 1
  fi

  # Step 1: Linux gate.
  if ! _bridge_daemon_control_is_linux; then
    printf 'skipped-non-linux'
    return 0
  fi

  # Step 2: daemon-running check. Resolve via bridge_daemon_pid (the
  # cmdline-verified resolver — guards against PID recycling per #683).
  local daemon_pid=""
  daemon_pid="$(bridge_daemon_pid 2>/dev/null || true)"
  if [[ -z "$daemon_pid" ]] || ! kill -0 "$daemon_pid" 2>/dev/null; then
    printf 'skipped-daemon-not-running'
    return 0
  fi

  # Step 3: resolve target GID + check current daemon's supp set.
  local target_gid=""
  target_gid="$(_bridge_daemon_control_resolve_gid "$group" 2>/dev/null || true)"
  if [[ -z "$target_gid" ]]; then
    bridge_warn "daemon-refresh: group '$group' has no GID via getent — refusing to refresh"
    printf 'failed-restart'
    return 1
  fi

  if _bridge_daemon_control_daemon_has_gid "$target_gid"; then
    printf 'skipped-daemon-already-has-group'
    return 0
  fi

  # dry-run short-circuit: report the action without taking the lock or
  # invoking sudo. Useful for the install-time preflight and for tests.
  if (( dry_run == 1 )); then
    printf 'ok'
    return 0
  fi

  # Step 4: lock under state/daemon.refresh.lock. Serializes concurrent
  # `agent create` flows so we don't double-restart the daemon and race
  # the new-PID poll.
  local lock_path
  lock_path="${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}/daemon.refresh.lock"
  # Issue #1667: call the acquire helper DIRECTLY (NOT under `$(...)`) so the
  # flock fd lives in THIS shell for the lock's full intended lifetime — the
  # re-check + restart critical section below. The token is returned via the
  # BRIDGE_DAEMON_CONTROL_LOCK_TOKEN global, not stdout. `2>/dev/null` here
  # would muffle nothing useful (the helper is silent on contention; the
  # caller emits the diagnostic), but a redirection on the bare call is safe
  # since this is a function call, not a `exec`-style whole-shell redirect.
  local lock_token=""
  if _bridge_daemon_control_lock_acquire "$lock_path" 30; then
    lock_token="${BRIDGE_DAEMON_CONTROL_LOCK_TOKEN:-}"
  fi
  if [[ -z "$lock_token" ]]; then
    bridge_warn "daemon-refresh: could not acquire $lock_path within 30s (another refresh in progress?)"
    printf 'failed-restart'
    return 1
  fi
  # Always release the lock on return, regardless of success path.
  # shellcheck disable=SC2064  # we want the token expanded at trap-set time
  trap "_bridge_daemon_control_lock_release '$lock_token'" RETURN

  # Step 5: re-check under lock. Another concurrent refresh may have
  # already moved the daemon's Groups into the desired state.
  daemon_pid="$(bridge_daemon_pid 2>/dev/null || true)"
  if [[ -z "$daemon_pid" ]] || ! kill -0 "$daemon_pid" 2>/dev/null; then
    printf 'skipped-daemon-not-running'
    return 0
  fi
  if _bridge_daemon_control_daemon_has_gid "$target_gid"; then
    printf 'skipped-daemon-already-has-group'
    return 0
  fi

  # ----- Beta20 L2 Variant 3A r4: systemd-user managed daemon branch -----
  #
  # When systemd-user is managing the daemon, a direct `sudo
  # bridge-daemon.sh restart` races `Restart=always`: systemd notices
  # the TERM-exit and immediately re-spawns the daemon from its OWN
  # stale credential set (the user manager's supp groups were captured
  # at login, before the `usermod -aG` for this agent). The r3 path
  # would "succeed" briefly then get steamrolled.
  #
  # The fix (codex r4): make the systemd unit's ExecStart itself cross
  # the sudo-to-self PAM boundary so every systemd-driven start gets
  # fresh credentials. When that unit is in place (detected by
  # BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE=sudo-self env marker or a sudo-
  # prefixed ExecStart line), `systemctl --user restart` IS the refresh
  # mechanism — we don't need a bridge-managed direct sudo restart at
  # all on systemd-managed hosts.
  if _bridge_daemon_control_systemd_active; then
    if _bridge_daemon_control_systemd_unit_is_refresh_capable; then
      # Sudo-self ExecStart is in place. systemctl restart triggers
      # PAM/initgroups via the sudo wrapper → fresh daemon credentials.
      local _systemctl_rc=0
      systemctl --user restart agent-bridge-daemon.service 2>/dev/null \
        || _systemctl_rc=$?
      if (( _systemctl_rc != 0 )); then
        bridge_warn "daemon-refresh: systemctl --user restart agent-bridge-daemon.service failed (rc=$_systemctl_rc)"
        printf 'failed-systemctl-restart'
        return 1
      fi

      # Poll for cmdline-verified daemon up with target GID. Don't
      # key on pid-changed — Linux recycles PIDs and the unit's main
      # process may be `sudo` (KillMode=process keeps that as the
      # tracked PID), with the actual `bridge-daemon.sh run` as the
      # sudo child. bridge_daemon_pid resolves by cmdline so it
      # returns the bash daemon child, not the sudo wrapper.
      local _waited=0
      local _new_pid=""
      local _has_gid=0
      while (( _waited < 15 )); do
        _new_pid="$(bridge_daemon_pid 2>/dev/null || true)"
        if [[ -n "$_new_pid" ]] && kill -0 "$_new_pid" 2>/dev/null; then
          if _bridge_daemon_control_daemon_has_gid "$target_gid"; then
            _has_gid=1
            break
          fi
        fi
        sleep 1
        _waited=$(( _waited + 1 ))
      done

      if [[ -z "$_new_pid" ]] || ! kill -0 "$_new_pid" 2>/dev/null; then
        bridge_warn "daemon-refresh: systemctl restart succeeded but no daemon pid observable within 15s"
        printf 'failed-systemctl-restart'
        return 1
      fi
      if (( _has_gid == 0 )); then
        bridge_warn "daemon-refresh: systemd-restarted daemon pid=$_new_pid does NOT have GID $target_gid in supp groups — sudo/PAM did not refresh"
        printf 'failed-systemd-refresh-no-gid'
        return 1
      fi

      # r4: confirm exactly one ACTUAL `bash bridge-daemon.sh run`
      # process is live (codex r4 risk note — KillMode=process +
      # sudo-wrapped ExecStart could in principle leave orphan
      # children if a previous restart was racy). We don't fail the
      # refresh on >1 daemon — log it as a warning so the operator
      # can investigate, but the GID check above already proves the
      # resolved daemon is correct.
      #
      # Implementation: enumerate /proc/<pid>/comm and /proc/<pid>/cmdline
      # directly so we can exclude pgrep's own self-match. Looking for
      # bash processes (comm == bash) whose cmdline ends with the
      # bridge-daemon.sh run shape (no trailing arg). The sudo wrapper
      # is excluded by the comm filter.
      local _daemon_count=0
      local _proc_entry _proc_pid _proc_comm _proc_cmdline
      for _proc_entry in /proc/[0-9]*; do
        [[ -d "$_proc_entry" ]] || continue
        _proc_pid="${_proc_entry##*/}"
        _proc_comm="$(cat "$_proc_entry/comm" 2>/dev/null || true)"
        [[ "$_proc_comm" == "bash" ]] || continue
        _proc_cmdline="$(tr '\0' ' ' <"$_proc_entry/cmdline" 2>/dev/null || true)"
        case "$_proc_cmdline" in
          *"bridge-daemon.sh run "|*"bridge-daemon.sh run") _daemon_count=$(( _daemon_count + 1 )) ;;
        esac
      done
      if (( _daemon_count > 1 )); then
        bridge_warn "daemon-refresh: systemd-restart left $_daemon_count live bash bridge-daemon.sh run processes (expected 1) — pid=$_new_pid is the cmdline-verified primary"
      fi

      bridge_audit_log daemon daemon_refresh_systemd_sudo_self daemon \
        --detail group="$group" \
        --detail gid="$target_gid" \
        --detail new_pid="$_new_pid" \
        --detail daemon_count="$_daemon_count" \
        --detail reason="$(_bridge_daemon_control_sanitize_reason "$reason")" >/dev/null 2>&1 || true

      printf 'ok-systemd-sudo-self'
      return 0
    fi

    # Systemd is active but the unit's ExecStart is the legacy direct
    # `bash bridge-daemon.sh run` shape — `systemctl --user restart`
    # would just re-fork from the stale user manager. Don't try the
    # bridge-managed sudo restart either: Restart=always races us.
    # Tell the operator how to regenerate the unit.
    bridge_warn "daemon-refresh: systemd-user unit is active but ExecStart is NOT sudo-wrapped — refusing to race Restart=always"
    printf 'manual-required-systemd-unit-stale'
    return 1
  fi
  # ----- End systemd branch — fall through to r3 direct sudo path. -----

  # Step 6: invoke sudo. Exact shape from codex r3 §3.
  local controller_user=""
  controller_user="$(_bridge_daemon_control_controller_user 2>/dev/null || true)"
  if [[ -z "$controller_user" ]]; then
    bridge_warn "daemon-refresh: could not resolve controller user (refusing to restart as root)"
    printf 'manual-required-sudoers'
    return 1
  fi

  local bash_abs="${BRIDGE_BASH_BIN:-}"
  if [[ -z "$bash_abs" ]]; then
    bash_abs="$(command -v bash 2>/dev/null || printf '/bin/bash')"
  fi
  local bridge_home_abs="${BRIDGE_HOME:-}"
  if [[ -z "$bridge_home_abs" ]]; then
    bridge_warn "daemon-refresh: BRIDGE_HOME is unset"
    printf 'failed-restart'
    return 1
  fi

  local sanitized_reason
  sanitized_reason="$(_bridge_daemon_control_sanitize_reason "$reason")"
  # Export so --preserve-env can forward it.
  BRIDGE_DAEMON_REFRESH_REASON="$sanitized_reason"
  export BRIDGE_DAEMON_REFRESH_REASON

  # Capture sudo rc separately so we can classify sudoers-class failures
  # (rc=1 with no-sudoers-entry stderr) vs daemon-side rc.
  local sudo_rc=0
  local sudo_stderr=""
  sudo_stderr="$(
    sudo -n -u "$controller_user" -H \
      --preserve-env=BRIDGE_HOME,BRIDGE_STATE_DIR,BRIDGE_LAYOUT_MARKER_DIR,BRIDGE_ROSTER_FILE,BRIDGE_ROSTER_LOCAL_FILE,BRIDGE_TASK_DB,BRIDGE_BASH_BIN,BRIDGE_DAEMON_REFRESH_REASON \
      -- "$bash_abs" "$bridge_home_abs/bridge-daemon.sh" restart --force --internal-reason=group-refresh \
      2>&1 >/dev/null
  )" || sudo_rc=$?

  if (( sudo_rc != 0 )); then
    # Classify: sudo's own "no entry" / "password required" rejection
    # produces stderr containing "sudo:" / "a password is required" /
    # "may not run". Anything else → daemon-side failure.
    if printf '%s' "$sudo_stderr" | grep -qiE 'a password is required|not allowed|may not run|no tty|sudo:.* command not allowed'; then
      bridge_warn "daemon-refresh: sudoers entry missing or rejected — run 'agent-bridge init sudoers daemon-refresh --apply'"
      printf 'manual-required-sudoers'
      return 1
    fi
    bridge_warn "daemon-refresh: sudo restart failed (rc=$sudo_rc): $sudo_stderr"
    printf 'failed-restart'
    return 1
  fi

  # Step 7: poll for a live, cmdline-verified daemon with the target
  # GID in its /proc/<pid>/status Groups line.
  #
  # NOTE: we deliberately do NOT key on `new_pid != daemon_pid`. The
  # Linux kernel commonly recycles a freshly-freed PID for the very
  # next process, so the new daemon often inherits the OLD daemon's
  # PID number — observed live on agb-clean-test. The right
  # discriminator is "daemon's supp set now contains the target GID",
  # which is the load-bearing check anyway (the whole reason we
  # restart). bridge_daemon_pid is cmdline-verified per #683, so a
  # recycled-pid-pointing-to-some-other-process is still rejected.
  local waited=0
  local new_pid=""
  local daemon_has_gid=0
  while (( waited < 10 )); do
    new_pid="$(bridge_daemon_pid 2>/dev/null || true)"
    if [[ -n "$new_pid" ]] && kill -0 "$new_pid" 2>/dev/null; then
      if _bridge_daemon_control_daemon_has_gid "$target_gid"; then
        daemon_has_gid=1
        break
      fi
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done

  if [[ -z "$new_pid" ]] || ! kill -0 "$new_pid" 2>/dev/null; then
    bridge_warn "daemon-refresh: new daemon pid did not appear within 10s"
    printf 'failed-timeout'
    return 1
  fi

  # Step 8: if the daemon is up but doesn't have the target GID after
  # the poll window, sudo/PAM did NOT refresh supp groups. Surface the
  # diagnostic so the operator knows to investigate /etc/pam.d/sudo or
  # the host's nsswitch.conf rather than chase non-existent bugs.
  if (( daemon_has_gid == 0 )); then
    bridge_warn "daemon-refresh: new daemon pid=$new_pid does NOT have GID $target_gid in supp groups — sudo/PAM did not refresh"
    printf 'manual-required-sudo-refresh-no-gid'
    return 1
  fi

  # Best-effort audit row so the operator has a forensic trail when the
  # symptom returns. Non-fatal — audit failure does not change status.
  bridge_audit_log daemon daemon_refresh_after_group_membership daemon \
    --detail group="$group" \
    --detail gid="$target_gid" \
    --detail old_pid="$daemon_pid" \
    --detail new_pid="$new_pid" \
    --detail reason="$sanitized_reason" >/dev/null 2>&1 || true

  printf 'ok'
  return 0
}

# ---------------------------------------------------------------------------
# Sudoers installer
# ---------------------------------------------------------------------------

# Resolve the user-/install-scoped sudoers filename per codex r3 §1:
#   /etc/sudoers.d/agent-bridge-daemon-refresh-<controller_user>-<runtime_id>
#
# runtime_id is derived from BRIDGE_HOME (absolute path) via a short
# hash so multiple installs on the same host (different operator users
# or BRIDGE_HOME paths) get distinct sudoers entries instead of
# overwriting each other. Dots are forbidden in the basename because
# sudoers `#includedir` ignores files containing `.`.
bridge_daemon_control_sudoers_path() {
  local controller_user="$1"
  local bridge_home_abs="$2"
  [[ -n "$controller_user" && -n "$bridge_home_abs" ]] || return 1
  local runtime_id=""
  # 8-char hex digest of the absolute BRIDGE_HOME path. Stable across
  # installs at the same path; differs when the operator relocates.
  if command -v sha256sum >/dev/null 2>&1; then
    runtime_id="$(printf '%s' "$bridge_home_abs" | sha256sum | head -c8)"
  elif command -v shasum >/dev/null 2>&1; then
    runtime_id="$(printf '%s' "$bridge_home_abs" | shasum -a 256 | head -c8)"
  else
    runtime_id="$(printf '%s' "$bridge_home_abs" | cksum | awk '{ printf "%08x", $1 }')"
  fi
  printf '/etc/sudoers.d/agent-bridge-daemon-refresh-%s-%s' "$controller_user" "$runtime_id"
}

# Render the sudoers template with controller_user, bash_abs, and
# bridge_home_abs substituted. Refuses non-absolute paths (codex r3 §2
# warning — sudoers Command matching is literal-string, relative paths
# would NEVER match a sudo invoke and would silently fail at runtime).
bridge_daemon_control_sudoers_render() {
  local controller_user="$1"
  local bash_abs="$2"
  local bridge_home_abs="$3"
  [[ -n "$controller_user" && -n "$bash_abs" && -n "$bridge_home_abs" ]] || {
    bridge_warn "sudoers_render: controller_user, bash_abs, bridge_home_abs all required"
    return 1
  }
  if [[ "$bash_abs" != /* ]]; then
    bridge_warn "sudoers_render: bash_abs must be absolute, got: $bash_abs"
    return 1
  fi
  if [[ "$bridge_home_abs" != /* ]]; then
    bridge_warn "sudoers_render: bridge_home_abs must be absolute, got: $bridge_home_abs"
    return 1
  fi

  local template_path="$BRIDGE_HOME/scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template"
  # The script tree under BRIDGE_HOME is the live install; sourced
  # source tree may differ during upgrade. Prefer the live path; fall
  # back to BRIDGE_SCRIPT_DIR (the active source checkout).
  if [[ ! -r "$template_path" && -n "${BRIDGE_SCRIPT_DIR:-}" ]]; then
    template_path="$BRIDGE_SCRIPT_DIR/scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template"
  fi
  if [[ ! -r "$template_path" ]]; then
    bridge_warn "sudoers_render: template missing at $template_path"
    return 1
  fi

  local rendered
  rendered="$(cat "$template_path")" || return 1
  rendered="${rendered//\{\{controller_user\}\}/$controller_user}"
  rendered="${rendered//\{\{bash_abs\}\}/$bash_abs}"
  rendered="${rendered//\{\{bridge_home_abs\}\}/$bridge_home_abs}"
  printf '%s\n' "$rendered"
}

# Probe whether `sudo -n -u <controller> -H -- bash -c 'id -G'`
# actually refreshes supplementary groups via PAM/initgroups (codex r3
# §4). Emits one of:
#   ok                — refresh works (sudo's child sees the same static
#                       group set as `id -G <controller>` from a fresh shell)
#   sudo-refresh-no-gid — sudoers entry exists and sudo succeeded but the
#                       child's groups DON'T match the static set
#   sudoers-rejected  — sudo refused (no entry, password required, etc.)
#
# Used both at install time (preflight diagnostic) and at runtime via
# the helper above.
bridge_daemon_control_sudo_refresh_probe() {
  local controller_user="$1"
  [[ -n "$controller_user" ]] || return 1

  local bash_abs="${BRIDGE_BASH_BIN:-}"
  if [[ -z "$bash_abs" ]]; then
    bash_abs="$(command -v bash 2>/dev/null || printf '/bin/bash')"
  fi

  # Static expected group set (sorted, space-separated GIDs).
  local expected
  expected="$(id -G "$controller_user" 2>/dev/null | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//')"
  if [[ -z "$expected" ]]; then
    printf 'sudo-refresh-no-gid'
    return 1
  fi

  local sudo_rc=0
  local actual_raw=""
  actual_raw="$(
    sudo -n -u "$controller_user" -H -- "$bash_abs" -c 'id -G' 2>/dev/null
  )" || sudo_rc=$?

  if (( sudo_rc != 0 )); then
    printf 'sudoers-rejected'
    return 1
  fi

  local actual
  actual="$(printf '%s' "$actual_raw" | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok'
    return 0
  fi
  printf 'sudo-refresh-no-gid'
  return 1
}

# Generate the sudoers content, validate with visudo -cf, install with
# `install -m 0440 -o root -g root`. Idempotent — if the target file
# already exists with byte-identical content, skip the install.
#
# Returns rc=0 on success, rc=1 on render/validation/install failure.
# Emits the target path on stdout when success.
bridge_daemon_control_install_sudoers() {
  if ! _bridge_daemon_control_is_linux; then
    bridge_warn "install_sudoers: non-Linux host — skipping"
    return 0
  fi

  local controller_user=""
  controller_user="$(_bridge_daemon_control_controller_user 2>/dev/null || true)"
  if [[ -z "$controller_user" ]]; then
    bridge_warn "install_sudoers: could not resolve controller user (refusing to install for root)"
    return 1
  fi

  local bash_abs="${BRIDGE_BASH_BIN:-}"
  if [[ -z "$bash_abs" ]]; then
    bash_abs="$(command -v bash 2>/dev/null || printf '/bin/bash')"
  fi
  local bridge_home_abs="${BRIDGE_HOME:-}"
  if [[ -z "$bridge_home_abs" ]]; then
    bridge_warn "install_sudoers: BRIDGE_HOME is unset"
    return 1
  fi

  local target_path
  target_path="$(bridge_daemon_control_sudoers_path "$controller_user" "$bridge_home_abs")" || return 1

  # Reject basename containing dots (sudoers #includedir gotcha).
  local basename_part="${target_path##*/}"
  case "$basename_part" in
    *.*)
      bridge_warn "install_sudoers: refusing to install — basename '$basename_part' contains a dot (sudoers #includedir ignores those)"
      return 1
      ;;
  esac

  local rendered
  rendered="$(bridge_daemon_control_sudoers_render "$controller_user" "$bash_abs" "$bridge_home_abs")" || return 1

  # Idempotency: if the existing file matches, skip. Read via sudo
  # because /etc/sudoers.d/* is typically 0440 root:root.
  if [[ -e "$target_path" ]]; then
    local existing=""
    existing="$(bridge_linux_sudo_root cat "$target_path" 2>/dev/null || true)"
    if [[ "$existing" == "$rendered" ]]; then
      printf '%s' "$target_path"
      return 0
    fi
  fi

  # Write to a temp file under the controller's HOME (NOT /tmp — codex
  # r3 §1 caveat: world-writable tmp dirs can be raced; controller HOME
  # is 0700 in the standard linux-user-isolation layout). The temp
  # file is removed via trap on every return path.
  local tmp_root="${HOME:-/tmp}"
  local tmpfile=""
  tmpfile="$(mktemp "${tmp_root}/agent-bridge-daemon-refresh.XXXXXX")" || {
    bridge_warn "install_sudoers: mktemp failed under $tmp_root"
    return 1
  }
  # shellcheck disable=SC2064  # we want the tmpfile path expanded at trap-set time
  trap "rm -f '$tmpfile' 2>/dev/null || true" RETURN

  # Write WITH trailing newline — visudo requires it on the final line.
  printf '%s\n' "$rendered" >"$tmpfile" || {
    bridge_warn "install_sudoers: write to $tmpfile failed"
    return 1
  }

  if ! command -v visudo >/dev/null 2>&1; then
    bridge_warn "install_sudoers: visudo not found — refusing to install unvalidated sudoers fragment"
    return 1
  fi
  if ! visudo -cf "$tmpfile" >/dev/null 2>&1; then
    bridge_warn "install_sudoers: visudo -cf rejected the rendered template (controller=$controller_user)"
    return 1
  fi

  if ! bridge_linux_sudo_root install -m 0440 -o root -g root "$tmpfile" "$target_path"; then
    bridge_warn "install_sudoers: sudo install to $target_path failed"
    return 1
  fi
  printf '%s' "$target_path"
  return 0
}

# Verify the sudoers file is present at the expected path, mode 0440
# root:root, and content-equal to a fresh render. Emits one of:
#   ok | missing | invalid | sudo-refresh-no-gid
bridge_daemon_control_check_sudoers() {
  if ! _bridge_daemon_control_is_linux; then
    printf 'skipped-non-linux'
    return 0
  fi

  local controller_user=""
  controller_user="$(_bridge_daemon_control_controller_user 2>/dev/null || true)"
  if [[ -z "$controller_user" ]]; then
    printf 'missing'
    return 1
  fi

  local bash_abs="${BRIDGE_BASH_BIN:-}"
  if [[ -z "$bash_abs" ]]; then
    bash_abs="$(command -v bash 2>/dev/null || printf '/bin/bash')"
  fi
  local bridge_home_abs="${BRIDGE_HOME:-}"
  if [[ -z "$bridge_home_abs" ]]; then
    printf 'missing'
    return 1
  fi

  local target_path
  target_path="$(bridge_daemon_control_sudoers_path "$controller_user" "$bridge_home_abs")" || {
    printf 'missing'
    return 1
  }

  if [[ ! -e "$target_path" ]]; then
    printf 'missing'
    return 1
  fi

  local rendered existing
  rendered="$(bridge_daemon_control_sudoers_render "$controller_user" "$bash_abs" "$bridge_home_abs" 2>/dev/null)" || {
    printf 'invalid'
    return 1
  }
  existing="$(bridge_linux_sudo_root cat "$target_path" 2>/dev/null || true)"
  if [[ "$existing" != "$rendered" ]]; then
    printf 'invalid'
    return 1
  fi

  # Probe — even if the file content matches, sudo/PAM might not
  # actually refresh groups in this host's configuration.
  local probe_status
  probe_status="$(bridge_daemon_control_sudo_refresh_probe "$controller_user" 2>/dev/null || true)"
  case "$probe_status" in
    ok)
      printf 'ok'
      return 0
      ;;
    sudo-refresh-no-gid)
      printf 'sudo-refresh-no-gid'
      return 1
      ;;
    *)
      printf 'invalid'
      return 1
      ;;
  esac
}

# Emit a single-line preflight diagnostic for operator-visible status.
# Used by bridge-init.sh / bridge-upgrade.sh / oss-preflight.
bridge_daemon_control_preflight_row() {
  if ! _bridge_daemon_control_is_linux; then
    printf 'daemon_group_refresh_sudoers=skipped-non-linux\n'
    return 0
  fi
  local status
  status="$(bridge_daemon_control_check_sudoers 2>/dev/null || true)"
  if [[ -z "$status" ]]; then
    status="missing"
  fi
  printf 'daemon_group_refresh_sudoers=%s\n' "$status"
  return 0
}

# ---------------------------------------------------------------------------
# v0.15.0-beta4 Lane D — singleton spawn guard (issue #1276)
# ---------------------------------------------------------------------------
#
# Two daemon processes were observed running simultaneously on patch's
# beta3 fresh install: PID 140897 (installer-spawned, audit row present)
# + PID 1186715/1186719 (sudo-wrapped, audit row ABSENT). Both polled
# state/tasks.db → duplicate session_nudge_dropped rows + 5-10min
# operator-perceived nudge latency.
#
# Root: spawn entry points (cmd_start fork, direct `bridge-daemon.sh run`,
# sudo-wrapped invocation, systemd ExecStart) did not share a single
# pid-file lock; the existing `cmd_start` pre-check was advisory only
# (no flock, no kill of an existing daemon, no audit emit when invoked
# via `bridge-daemon.sh run` directly).
#
# Fix shape:
#   - bridge_daemon_ensure_singleton: called at the TOP of cmd_run (the
#     one bottleneck every spawn path crosses). Acquires an exclusive
#     flock on ${BRIDGE_DAEMON_PID_FILE}.lock, evicts a stale-but-living
#     bridge-daemon process (TERM + 10s grace + KILL fallback), atomic
#     PID-file write (tmp + rename), then emits a `daemon_started` audit
#     row carrying pid / parent_pid / wrapper / sudo_self for forensic
#     attribution.
#   - bridge_daemon_self_check: called periodically from cmd_run's main
#     loop. Compares $$ against the latest `daemon_started` audit row;
#     mismatch → audit `daemon_pid_mismatch` + best-effort alert task.
#
# Both helpers fail-safe: if flock/python/audit emit fails the daemon
# continues (we never `bridge_die` from these helpers — a wedge inside
# the singleton guard must not stop the daemon from running).

# Internal: resolve the lock-file path next to the daemon PID file.
_bridge_daemon_singleton_lock_path() {
  printf '%s' "${BRIDGE_DAEMON_PID_FILE:-${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}/daemon.pid}.lock"
}

# Internal: best-effort process-cmdline lookup. Returns a string that
# either looks like `bridge-daemon.sh run` (match) or anything else
# (mismatch — likely PID recycling, do not kill).
_bridge_daemon_singleton_cmdline() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  ps -p "$pid" -o args= 2>/dev/null | head -n1
}

# Internal: portable process START-TIME proof (#1563). `ps -o lstart=`
# prints the absolute wall-clock start time of a pid and is portable
# across macOS (BSD ps) and Linux (procps ps) — unlike `/proc/<pid>/stat`
# field 22 (Linux-only) or `etime` (elapsed, not absolute). Two processes
# that reuse the same pid number across a recycle have DIFFERENT lstart
# values, so a recorded (pid, start_time) pair uniquely identifies one
# process GENERATION: a recycled pid with a non-matching lstart is NOT the
# process we recorded. Whitespace is collapsed to single spaces so the
# value is a stable single-line token safe to store in the owner record
# and compare with `==`. Prints the normalized lstart on stdout; empty
# (and returns 1) when the pid is gone or ps is unavailable.
_bridge_daemon_proc_start_time() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  local raw
  raw="$(ps -p "$pid" -o lstart= 2>/dev/null | head -n1)"
  # Collapse runs of whitespace to a single space + trim ends so the same
  # process always yields a byte-identical token regardless of ps padding.
  raw="$(printf '%s' "$raw" | tr -s '[:space:]' ' ')"
  raw="${raw# }"
  raw="${raw% }"
  [[ -n "$raw" ]] || return 1
  printf '%s' "$raw"
}

# Internal: resolve the active-generation OWNER RECORD path (#1563). Lives
# next to the pid-file; holds the current lock owner's
# (pid, cmdline, start_time, generation) so a competitor can prove whether
# a pid-file pid is the SAME live process that took the lock (vs a recycled
# pid that merely reused the number).
_bridge_daemon_singleton_owner_path() {
  printf '%s.owner' "${BRIDGE_DAEMON_PID_FILE:-${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}/daemon.pid}"
}

# Internal: atomically publish the active-generation owner record under the
# held lock (#1563 point 1). Called ONLY after the lock is won, so exactly
# one writer reaches here per generation. tmp + rename so a competitor can
# never read a half-written record. Fields are newline-delimited `k=v`:
#   pid=<$$>  cmdline=<our args>  start_time=<lstart>  generation=<token>
# generation is a monotonic-ish token (epoch ns when available, else
# epoch-seconds.pid) that disambiguates two records that happen to share a
# recycled pid + identical-second start time. Best-effort: a write failure
# is non-fatal (the pid + start_time pair already observable via `ps` is the
# primary proof; the record is a convenience cache, not the source of truth).
_bridge_daemon_singleton_write_owner() {
  local owner_path
  owner_path="$(_bridge_daemon_singleton_owner_path)"
  local self_cmdline self_start generation
  self_cmdline="$(_bridge_daemon_singleton_cmdline "$$" 2>/dev/null || true)"
  self_start="$(_bridge_daemon_proc_start_time "$$" 2>/dev/null || true)"
  # generation token: prefer nanosecond resolution; fall back to
  # seconds.pid on platforms whose `date` lacks %N (macOS /bin/date emits
  # the literal string "N", which the case below rejects).
  generation="$(date +%s%N 2>/dev/null || true)"
  case "$generation" in
    ''|*[!0-9]*) generation="$(date +%s 2>/dev/null || printf '0').$$" ;;
  esac
  local owner_tmp="${owner_path}.new.$$"
  {
    printf 'pid=%s\n' "$$"
    printf 'cmdline=%s\n' "$self_cmdline"
    printf 'start_time=%s\n' "$self_start"
    printf 'generation=%s\n' "$generation"
  } >"$owner_tmp" 2>/dev/null || { rm -f "$owner_tmp" 2>/dev/null || true; return 1; }
  mv -f -- "$owner_tmp" "$owner_path" 2>/dev/null || { rm -f "$owner_tmp" 2>/dev/null || true; return 1; }
  return 0
}

# Internal: read one field from the active-generation owner record. Prints
# the field value on stdout (empty when the record or field is absent).
# `$1` = field name (pid|cmdline|start_time|generation).
_bridge_daemon_singleton_owner_field() {
  local field="$1"
  local owner_path
  owner_path="$(_bridge_daemon_singleton_owner_path)"
  [[ -r "$owner_path" ]] || return 1
  local line val=""
  while IFS= read -r line; do
    case "$line" in
      "${field}="*) val="${line#*=}" ;;
    esac
  done <"$owner_path"
  printf '%s' "$val"
}

# bridge_daemon_ensure_singleton — acquire the PID-file flock, publish the
# active-generation owner record, evict a PROVEN-stale bridge-daemon
# predecessor, atomically claim the PID file, and emit the `daemon_started`
# audit row.
#
# #1563 singleton invariant (the foundation this function enforces):
#   1. Exactly ONE daemon owns the lock AND publishes the active-generation
#      owner record — (pid, cmdline, start_time, generation) written under
#      the held lock via `_bridge_daemon_singleton_write_owner`.
#   2. A LOSER (a second `run` that cannot acquire the lock) exits cleanly
#      via `daemon_singleton_loser_exit` + `return 1` and NEVER evicts the
#      live holder.
#   3. A pid-file predecessor is reclaimed/evicted ONLY after POSITIVE
#      proof it is stale: PID-not-alive OR cmdline-mismatch OR
#      start-time-mismatch (its live `ps -o lstart=` differs from the
#      owner record). A recycled pid (same number, different start-time)
#      is never signalled — the slot is reclaimed without a kill.
#   4. The flock fd is held for the daemon's PROCESS LIFETIME (kernel
#      auto-release on exit); the mkdir fallback covers flock-less hosts.
#
# Returns 0 on success (PID file claimed, owner record published, audit
# row written).
# Returns 1 when the lock cannot be acquired (a concurrent holder is live —
# this process MUST NOT proceed; the canonical pattern is `bridge_die` at
# the caller's site to abort the daemon's main loop before it starts
# polling).
#
# Side effects on success:
#   - $BRIDGE_DAEMON_PID_FILE contains $$ atomically (tmp + rename).
#   - $BRIDGE_DAEMON_PID_FILE.owner holds the active-generation record.
#   - audit log row `daemon daemon_started daemon pid=$$ parent_pid=$PPID
#     wrapper=<value> sudo_self=<0|1>` is written.
#   - If an existing bridge-daemon process was found alive, an
#     intermediate `daemon_spawn_replacing` audit row is also written.
#
# Locking model: non-blocking `flock -n`, PROCESS-LIFETIME hold. The
# lock fd is opened on entry and INTENTIONALLY NOT closed on return —
# it stays held by the daemon process for its entire lifetime. The
# kernel auto-releases the flock when the last process holding the fd
# exits. This gives us a "first writer wins, late writers abort"
# semantic: a second `bridge_daemon_ensure_singleton` invocation while
# the original daemon is still running sees `flock -n` fail
# immediately, emits `daemon_spawn_lock_busy`, and returns 1 so the
# caller can `bridge_die` without evicting the original.
#
# Why not critical-section-only flock + explicit release? Because the
# r1 attempt (release-before-return + blocking `flock -w`) admits a
# "last-spawn-wins" race: after the first daemon finishes ensure_
# singleton, a competitor can acquire the (now-released) lock and TERM
# + KILL the just-started daemon. The r2 fix is the correct shape — a
# competitor must abort, not evict, while a healthy daemon holds the
# slot.
#
# Process-lifetime hold + nohup'd children: the lock fd is opened with
# `exec {lock_fd}>...` so it is inherited by `nohup &` children
# (silence-watchdog, queue-gateway-socket-listener). Those children's
# lifetime is intentionally bounded by the daemon process (they exit
# when the daemon exits), so the lock is released no later than the
# daemon process exits.
#
# Issue #1388 — the dangerous exception is the agent-launch path. When
# the daemon spawns an agent via `bridge-start.sh`, the chain ends in
# `tmux new-session`, and the tmux SERVER process daemonizes (reparents
# to PPID 1) and lives FOREVER, independent of this daemon. Bash does
# not set close-on-exec on `exec {lock_fd}>` descriptors (verified on
# Linux bash 5.2), so without intervention the immortal tmux server
# inherits the singleton lock fd. After this daemon dies (e.g. a
# systemd RestartSec cycle), the orphaned tmux keeps the flock held, so
# every respawned daemon hits `flock -n` busy → `daemon_spawn_lock_busy`
# → exit 1 → restart-loop. The fix: the fd number is recorded in the
# global $BRIDGE_DAEMON_SINGLETON_LOCK_FD on a successful acquire, and
# the daemon's agent-launch sites run through
# `bridge_daemon_run_without_singleton_lock`, which closes that fd FOR
# THE CHILD ONLY (`{var}>&-`) so the spawned tmux server never inherits
# it. This daemon keeps the fd + flock for its full lifetime; only the
# exec'd agent children are denied the descriptor. (Bash has no
# FD_CLOEXEC builtin and a subprocess cannot mutate a parent's fd flags,
# so per-launch close-for-child is the portable, argv-safe mechanism;
# the `eval`-based form was rejected because it mangles arguments with
# spaces — `{var}>&-` is eval-free and preserves argv exactly.)
#
# Any child that outlives the daemon (other than via the now-fixed
# agent-launch path) is a separate bug class (orphan reaper) and would
# block the next daemon start until the orphan is reaped — that is the
# correct safety behavior for the daemon-singleton contract.
#
# wrapper detection precedence:
#   1. BRIDGE_DAEMON_WRAPPER env (caller-injected: "sudo-self" /
#      "systemd-user" / "install" / "operator" — operator-set when
#      known).
#   2. SUDO_USER non-empty → "sudo".
#   3. Default → "direct".
#
# sudo_self detection: BRIDGE_DAEMON_SUDO_SELF env truthy → 1, else 0.
bridge_daemon_ensure_singleton() {
  local pid_file="${BRIDGE_DAEMON_PID_FILE:-${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}/daemon.pid}"
  local lock_path
  lock_path="$(_bridge_daemon_singleton_lock_path)"
  # r2: lock_timeout retained ONLY for the mkdir-fallback branch (hosts
  # without flock(1)). The flock branch is non-blocking (flock -n), so
  # the timeout does not apply there.
  local lock_timeout="${BRIDGE_DAEMON_SINGLETON_LOCK_TIMEOUT_SECONDS:-15}"
  [[ "$lock_timeout" =~ ^[0-9]+$ ]] || lock_timeout=15

  # Ensure state dir exists so the lockfile parent is valid even on
  # fresh installs where cmd_start was bypassed (the direct `run` call
  # path is exactly the surface this helper guards).
  local state_parent
  state_parent="$(dirname -- "$pid_file" 2>/dev/null || printf '%s' "${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}")"
  mkdir -p -- "$state_parent" 2>/dev/null || true

  # Wrapper / sudo_self attribution (computed once so both audit rows
  # carry the same fields).
  local wrapper="${BRIDGE_DAEMON_WRAPPER:-}"
  if [[ -z "$wrapper" ]]; then
    if [[ -n "${SUDO_USER:-}" ]]; then
      wrapper="sudo"
    else
      wrapper="direct"
    fi
  fi
  local sudo_self="0"
  case "${BRIDGE_DAEMON_SUDO_SELF:-}" in
    1|yes|YES|Yes|on|ON|On|true|TRUE|True) sudo_self="1" ;;
  esac

  # Acquire the exclusive PID-file lock. Use a dedicated `.lock`
  # sidecar so the lockfile lifetime is independent of pid-file content
  # rewrites. flock(1) is the source of truth — concurrent ensure paths
  # contend on the fd, not on file mtime.
  #
  # r2 lock contract: non-blocking `flock -n` + PROCESS-LIFETIME hold.
  # The fd opened here stays open for the entire daemon process — it
  # is NEVER explicitly closed by this helper. The kernel auto-releases
  # the flock when the daemon process (the last fd holder) exits. A
  # second `ensure_singleton` invocation while the original daemon is
  # still alive immediately sees `flock -n` fail → audit
  # `daemon_spawn_lock_busy` → return 1 → caller aborts (does NOT
  # evict the healthy original). See header comment for the rationale
  # vs the r1 "release-before-return + blocking flock -w" shape that
  # admitted a last-spawn-wins eviction race.
  local lock_fd=""
  local lock_backend=""
  local lock_dir=""
  if command -v flock >/dev/null 2>&1; then
    # shellcheck disable=SC2093
    if ! exec {lock_fd}>"$lock_path" 2>/dev/null; then
      bridge_warn "daemon-singleton: cannot open lockfile $lock_path"
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_spawn_lock_open_failed daemon \
             --detail pid="$$" \
             --detail lock_path="$lock_path" >/dev/null 2>&1 || true
      return 1
    fi
    # Non-blocking acquire (r2). Loser aborts; never waits, never evicts.
    if ! flock -n "$lock_fd" 2>/dev/null; then
      # Another daemon process holds the lock (process-lifetime hold).
      # Refuse to spawn — do NOT close the fd in a way that disturbs
      # the holder. Closing our own non-holding fd is safe; the kernel
      # flock is keyed to the open file description, which we do not
      # share with the holder (separate `exec {lock_fd}>` open).
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_spawn_lock_busy daemon \
             --detail attempting_pid="$$" \
             --detail parent_pid="$PPID" \
             --detail wrapper="$wrapper" \
             --detail sudo_self="$sudo_self" \
             --detail lock_mode="flock_n" >/dev/null 2>&1 || true
      # #1563 point 2 — the named loser-exit contract row. A second `run`
      # that cannot acquire the lock exits cleanly as a LOSER and NEVER
      # evicts the live holder. This row carries the held-owner identity
      # (from the owner record) so an operator can confirm exactly which
      # process won, and proves (by its mere presence + absence of any
      # `daemon_spawn_replacing*` kill row) that the loser killed nothing.
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_singleton_loser_exit daemon \
             --detail attempting_pid="$$" \
             --detail parent_pid="$PPID" \
             --detail wrapper="$wrapper" \
             --detail sudo_self="$sudo_self" \
             --detail lock_backend="flock" \
             --detail held_by_pid="$(_bridge_daemon_singleton_owner_field pid 2>/dev/null || true)" \
             --detail evicted_holder="no" >/dev/null 2>&1 || true
      bridge_warn "daemon-singleton: refused to spawn — another daemon holds $lock_path (non-blocking flock -n)"
      exec {lock_fd}>&- 2>/dev/null || true
      return 1
    fi
    lock_backend="flock"
    # Issue #1388: record the held fd number so the daemon's agent-launch
    # path can close it FOR THE SPAWNED CHILD (tmux server) only. This
    # daemon keeps the fd open (kernel holds the flock for our lifetime);
    # we only deny the descriptor to exec'd children that would otherwise
    # outlive us and pin the lock. Set ONLY in the flock backend — the
    # mkdir fallback (macOS dev hosts without flock(1)) has no fd to leak,
    # so the global stays empty and the launch wrapper is a no-op there.
    if [[ "$lock_fd" =~ ^[0-9]+$ ]]; then
      BRIDGE_DAEMON_SINGLETON_LOCK_FD="$lock_fd"
    fi
  else
    # No flock(1) — fall back to mkdir-as-lock. Less robust but still
    # serializes the local critical section. This branch matters on
    # macOS dev hosts without coreutils-style flock installed; the
    # production Linux server path always has util-linux flock.
    #
    # r2 contract: non-blocking — one acquire attempt; if the dir is
    # held by a live owner, abort immediately (mirrors `flock -n`).
    # Stale-owner reclaim still allowed (dead PID in owner.pid =
    # crashed predecessor, safe to take over). The dir is later
    # released by `_bridge_daemon_singleton_release_lock` on every
    # exit path of THIS function — but the host fd-equivalent
    # process-lifetime hold is enforced by the actual daemon's
    # heartbeat at the call site (no kernel auto-release for dirs).
    # Since fd-less hosts are macOS dev only, this divergence is
    # acceptable (no production duplicate-daemon risk).
    lock_dir="${lock_path}.d"
    local acquired=0
    if mkdir -- "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock_dir/owner.pid" 2>/dev/null || true
      acquired=1
    else
      # Dir already exists — check if owner is dead and reclaim.
      local owner_pid=""
      if [[ -r "$lock_dir/owner.pid" ]]; then
        owner_pid="$(head -n1 "$lock_dir/owner.pid" 2>/dev/null | tr -dc '0-9')"
      fi
      if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f "$lock_dir/owner.pid" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
        if mkdir -- "$lock_dir" 2>/dev/null; then
          printf '%s\n' "$$" >"$lock_dir/owner.pid" 2>/dev/null || true
          acquired=1
        fi
      fi
    fi
    if (( acquired == 0 )); then
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_spawn_lock_busy daemon \
             --detail attempting_pid="$$" \
             --detail parent_pid="$PPID" \
             --detail wrapper="$wrapper" \
             --detail sudo_self="$sudo_self" \
             --detail lock_backend="mkdir" \
             --detail lock_mode="non_blocking" >/dev/null 2>&1 || true
      # #1563 point 2 — named loser-exit contract row (mkdir backend).
      # The competitor aborts WITHOUT touching the live owner's lock dir or
      # process; the live owner.pid stays intact (we only reclaim a dir
      # whose owner.pid is a DEAD pid, above).
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_singleton_loser_exit daemon \
             --detail attempting_pid="$$" \
             --detail parent_pid="$PPID" \
             --detail wrapper="$wrapper" \
             --detail sudo_self="$sudo_self" \
             --detail lock_backend="mkdir" \
             --detail held_by_pid="$(_bridge_daemon_singleton_owner_field pid 2>/dev/null || true)" \
             --detail evicted_holder="no" >/dev/null 2>&1 || true
      bridge_warn "daemon-singleton: refused to spawn — $lock_dir held (non-blocking)"
      return 1
    fi
    lock_backend="mkdir"
  fi

  # Internal lock-release closure. r2 contract:
  #   - flock backend: NO-OP on success. The lock fd is held for the
  #     daemon's process lifetime; the kernel releases it when the
  #     last fd holder exits. We DO release on the error paths below
  #     (pid-file write failed) so a half-claimed start doesn't pin
  #     the slot.
  #   - mkdir backend: release the dir on every return path (no kernel
  #     auto-release for filesystem dir locks).
  _bridge_daemon_singleton_release_lock() {
    case "$lock_backend" in
      flock)
        # Only invoked from explicit-failure return paths. On success
        # we deliberately leave the fd open so the kernel holds the
        # flock for the process lifetime.
        if [[ "$lock_fd" =~ ^[0-9]+$ ]]; then
          eval "exec ${lock_fd}>&-" 2>/dev/null || true
        fi
        # Issue #1388: this fd is being closed (half-claimed start
        # failed), so clear the recorded number — the agent-launch
        # wrapper must not reference a closed descriptor.
        BRIDGE_DAEMON_SINGLETON_LOCK_FD=""
        ;;
      mkdir)
        if [[ -n "${lock_dir:-}" && -d "$lock_dir" ]]; then
          rm -f "$lock_dir/owner.pid" 2>/dev/null || true
          rmdir "$lock_dir" 2>/dev/null || true
        fi
        ;;
    esac
  }

  # Inspect the PID file. We have already WON the lock above (flock -n /
  # mkdir), so by the singleton invariant no OTHER live process is the
  # lock holder right now — a pid recorded in the pid-file is either a
  # crashed/exiting predecessor whose fd the kernel already released, a
  # recycled pid the OS handed to an unrelated process, or (mkdir-fallback
  # only) a genuinely-live predecessor whose dir we reclaimed because its
  # owner.pid was dead. Reclaiming the pid-file SLOT is always safe once we
  # hold the lock; the question this block answers is the narrower one of
  # whether to also SEND SIGNALS to that recorded pid.
  #
  # #1563 point 3 — reclaim/evict ONLY after POSITIVE PROOF the recorded
  # pid is a stale bridge-daemon predecessor: it must be alive AND its
  # cmdline must look like `bridge-daemon.sh run` AND its start-time must
  # MATCH the start-time we recorded for that pid in the prior owner record.
  # A recycled pid (same number, DIFFERENT `ps -o lstart=`) is NOT the
  # predecessor we recorded — signalling it would TERM/KILL an unrelated
  # process — so we reclaim the slot WITHOUT signalling. Belt-and-braces:
  # never signal our own pid.
  local existing_pid=""
  if [[ -f "$pid_file" ]]; then
    existing_pid="$(cat "$pid_file" 2>/dev/null | tr -dc '0-9' | head -c 16)"
  fi
  if [[ -n "$existing_pid" ]] && [[ "$existing_pid" != "$$" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    local existing_cmdline=""
    existing_cmdline="$(_bridge_daemon_singleton_cmdline "$existing_pid" 2>/dev/null || true)"
    # Start-time proof: compare the live pid's CURRENT lstart against the
    # lstart recorded for that pid in the prior owner record. A match
    # proves this is the SAME process generation we recorded as the owner
    # (so it is a real stale predecessor, safe to evict). A mismatch — or
    # an absent owner record / unreadable start-time — means we CANNOT
    # prove identity, so we fail closed on the kill and only reclaim the
    # slot (codex #1563: a recycled pid with a different start-time is NOT
    # the holder).
    local recorded_owner_pid="" recorded_owner_start="" live_start="" start_proven="no"
    recorded_owner_pid="$(_bridge_daemon_singleton_owner_field pid 2>/dev/null || true)"
    recorded_owner_start="$(_bridge_daemon_singleton_owner_field start_time 2>/dev/null || true)"
    live_start="$(_bridge_daemon_proc_start_time "$existing_pid" 2>/dev/null || true)"
    if [[ -n "$recorded_owner_pid" && "$recorded_owner_pid" == "$existing_pid" \
          && -n "$recorded_owner_start" && -n "$live_start" \
          && "$recorded_owner_start" == "$live_start" ]]; then
      start_proven="yes"
    fi
    if [[ "$existing_cmdline" == *"bridge-daemon.sh run"* ]] && [[ "$start_proven" == "yes" ]]; then
      # Proven stale predecessor (live, daemon cmdline, start-time matches
      # the owner record). Safe to evict: TERM + 10s grace + KILL.
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_spawn_replacing daemon \
             --detail existing_pid="$existing_pid" \
             --detail new_pid="$$" \
             --detail wrapper="$wrapper" \
             --detail sudo_self="$sudo_self" \
             --detail start_time_proven="yes" >/dev/null 2>&1 || true
      kill -TERM "$existing_pid" 2>/dev/null || true
      local waited_evict=0
      while kill -0 "$existing_pid" 2>/dev/null && (( waited_evict < 10 )); do
        sleep 1
        waited_evict=$(( waited_evict + 1 ))
      done
      if kill -0 "$existing_pid" 2>/dev/null; then
        kill -KILL "$existing_pid" 2>/dev/null || true
        sleep 1
        command -v bridge_audit_log >/dev/null 2>&1 \
          && bridge_audit_log daemon daemon_spawn_replacing_killed daemon \
               --detail existing_pid="$existing_pid" \
               --detail new_pid="$$" >/dev/null 2>&1 || true
      fi
    elif [[ "$existing_cmdline" == *"bridge-daemon.sh run"* ]]; then
      # Cmdline LOOKS like a daemon but the start-time does NOT match the
      # owner record (recycled pid, or no owner record to prove identity
      # against). Do NOT signal — reclaim the slot only. Killing here would
      # be the exact recycled-pid eviction #1563 forbids.
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_spawn_reclaim_unproven_pid daemon \
             --detail recorded_pid="$existing_pid" \
             --detail new_pid="$$" \
             --detail owner_record_pid="${recorded_owner_pid:-none}" \
             --detail owner_record_start="${recorded_owner_start:-none}" \
             --detail live_start="${live_start:-none}" \
             --detail recorded_cmdline_head="${existing_cmdline:0:120}" >/dev/null 2>&1 || true
    else
      # Recorded PID belongs to a non-bridge process (recycled PID).
      # Don't kill; just reclaim the pid-file slot.
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_spawn_reclaim_recycled_pid daemon \
             --detail recorded_pid="$existing_pid" \
             --detail new_pid="$$" \
             --detail recorded_cmdline_head="${existing_cmdline:0:120}" >/dev/null 2>&1 || true
    fi
  fi

  # Atomic PID-file write — tmp + rename so a partial write cannot
  # leave an empty pid-file under crash.
  local pid_tmp="${pid_file}.new.$$"
  if ! printf '%s\n' "$$" >"$pid_tmp" 2>/dev/null; then
    bridge_warn "daemon-singleton: cannot write $pid_tmp"
    rm -f "$pid_tmp" 2>/dev/null || true
    _bridge_daemon_singleton_release_lock
    return 1
  fi
  if ! mv -f -- "$pid_tmp" "$pid_file" 2>/dev/null; then
    bridge_warn "daemon-singleton: cannot rename $pid_tmp -> $pid_file"
    rm -f "$pid_tmp" 2>/dev/null || true
    _bridge_daemon_singleton_release_lock
    return 1
  fi

  # #1563 point 1 — publish the active-generation OWNER RECORD now that we
  # hold the lock and own the pid-file. This (pid, cmdline, start_time,
  # generation) record is what a future competitor reads to prove whether a
  # pid-file pid is THIS live process or a recycled number, so the eviction
  # path above can fail closed on the kill. Best-effort: a write failure is
  # non-fatal — the live `ps -o lstart=` of our pid is still the primary
  # proof; the record is a cache. We never abort the daemon over it.
  _bridge_daemon_singleton_write_owner || \
    bridge_warn "daemon-singleton: owner record write failed (non-fatal; start-time proof falls back to live ps)"

  # Emit the canonical `daemon_started` audit row. This is the row the
  # issue identified as missing on the sudo-wrapped spawn path; we now
  # emit it from cmd_run's entry, so every invocation path (cmd_start
  # fork, direct `bridge-daemon.sh run`, sudo-wrapped, systemd ExecStart)
  # produces exactly one row per live daemon process.
  #
  # #9882 / BUG B INVARIANT (emit at the FINAL daemon pid, never a wrapper):
  # `daemon_started` MUST be emitted only by the surviving singleton holder
  # AT the pid that becomes the long-lived daemon — because BUG A's proof
  # gate compares this `pid` against the live process. The invariant holds
  # because this is the SOLE `bridge_audit_log daemon daemon_started` emit
  # in the tree (grep-asserted by scripts/smoke/9882-daemon-audit-fp.sh),
  # it lives inside `ensure_singleton`, and `ensure_singleton` is called
  # from EXACTLY ONE site — cmd_run (bridge-daemon.sh, the `run` verb). In
  # every spawn path the process that runs `run` IS the long-lived daemon:
  #   - cmd_start FORKS `bridge-daemon.sh run &`; the fork CHILD runs
  #     cmd_run, so $$ here is the child = the daemon (cmd_start itself
  #     emits `daemon_start_supervised`, NOT `daemon_started`).
  #   - direct `bridge-daemon.sh run` dispatches cmd_run in-process.
  #   - the sudo / systemd ExecStart wrappers EXEC the bash `run` child
  #     (the wrapper is the parent, the bash child is the daemon and the
  #     emitter).
  # So no wrapper that forks-and-stays ever emits this row at its own pid.
  # If you add a NEW spawn path, route it through `ensure_singleton` in the
  # FINAL daemon process (exec-replace any wrapper) — do NOT emit
  # `daemon_started` from a forking parent, or you reintroduce BUG B (a
  # phantom wrapper pid that feeds BUG A's mismatch path).
  command -v bridge_audit_log >/dev/null 2>&1 \
    && bridge_audit_log daemon daemon_started daemon \
         --detail pid="$$" \
         --detail parent_pid="$PPID" \
         --detail wrapper="$wrapper" \
         --detail sudo_self="$sudo_self" \
         --detail interval_seconds="${BRIDGE_DAEMON_INTERVAL:-unknown}" >/dev/null 2>&1 || true

  # r2: DO NOT release the lock on success. The flock fd stays open
  # for the daemon's process lifetime; the kernel auto-releases it
  # when this process exits. A concurrent `ensure_singleton` invoked
  # while we are still alive will see `flock -n` fail and abort with
  # `daemon_spawn_lock_busy` (does NOT evict us — this is the r2 fix
  # vs the r1 last-spawn-wins eviction race).
  return 0
}

# bridge_daemon_run_without_singleton_lock — run a command (typically a
# daemon-initiated `bridge-start.sh <agent>` launch) with the singleton
# lock fd CLOSED FOR THE CHILD ONLY, so a long-lived grandchild (the
# `tmux new-session` server, which reparents to PPID 1 and outlives this
# daemon) cannot inherit the descriptor and pin the flock after we exit.
# See Issue #1388 + the bridge_daemon_ensure_singleton header.
#
# Mechanics: bash has no FD_CLOEXEC builtin, and a subprocess cannot
# mutate a parent's fd flags, so close-on-exec at open time is not
# available in pure bash. Instead we close the recorded fd in the
# forked child via the `{var}>&-` redirection — when $var already holds
# a numeric fd, `{var}>&-` closes THAT fd for the child instead of
# allocating a new one, and it leaves the parent's copy (and the flock)
# untouched. The `{var}>&-` form is eval-free and argv-safe (verified on
# Linux bash 5.2 with arguments containing spaces / `;` / `$(...)`),
# unlike an `eval`-built redirection which mangles such arguments.
#
# When the fd was never recorded (mkdir-lock fallback on hosts without
# flock(1), or the lock was not acquired), this is a transparent
# pass-through: the command runs exactly as `"$@"` would.
bridge_daemon_run_without_singleton_lock() {
  local fd="${BRIDGE_DAEMON_SINGLETON_LOCK_FD:-}"
  if [[ "$fd" =~ ^[0-9]+$ ]]; then
    "$@" {BRIDGE_DAEMON_SINGLETON_LOCK_FD}>&-
  else
    "$@"
  fi
}

# Issue #1463 — launchd KeepAlive vs out-of-band supervisor restart.
#
# On macOS launchd installs the daemon LaunchAgent runs with
# `KeepAlive=true` + `ThrottleInterval=30`. When a supervisor (liveness
# or silence watchdog) restarts the daemon out-of-band of launchd — via
# a direct `bridge-daemon.sh stop --force` + `start` — the fresh daemon
# takes the singleton lock OUTSIDE launchd's supervised process tree.
# launchd's own KeepAlive job instance can then never acquire the lock:
# it fails `ensure_singleton`, exits 1, and KeepAlive respawns it every
# ThrottleInterval (30s) indefinitely (observed: 300+ runs / ~40h). The
# real working daemon is the out-of-band lock holder and is healthy, but
# the launchd slot thrashes against it forever.
#
# The canonical restart primitive below resolves this by cycling
# launchd's OWN supervised job (`launchctl kickstart -k gui/$UID/<label>`)
# instead of forking a non-launchd daemon. After a kickstart the lock
# holder is always launchd's instance, so KeepAlive has nothing to fight.
#
# Returns:
#   0  — kickstart issued (the supervisor must NOT also stop+start).
#   1  — not a launchd install / launchctl unavailable / non-Darwin: the
#        caller should fall back to its existing stop+start primitive
#        (Linux systemd installs are unaffected and keep the old path).
#   2  — REFUSE: this is a launchd install but the live lock holder is
#        NOT launchd's job pid (an existing out-of-band split). Blindly
#        kickstarting would TERM/KILL the supervised slot while the real
#        holder survives, re-arming the thrash. Refuse and require an
#        explicit one-time operator reconcile (`bridge-daemon.sh stop
#        --force` once, then let launchd's KeepAlive bring the slot back
#        as the sole holder). Audited as `daemon_launchd_restart_refused`.

# Resolve the launchd label for this install. Prefers the installer-
# written marker (`state/launchagent.config`, which is also the
# "we are launchd-managed" signal), then the exported bridge-lib default.
# Prints the label on stdout; empty string when not launchd-managed.
_bridge_daemon_launchd_label() {
  local config_path="${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}/launchagent.config"
  if [[ -f "$config_path" ]]; then
    local label
    label="$(
      # shellcheck disable=SC1090
      source "$config_path" 2>/dev/null
      printf '%s' "${BRIDGE_LAUNCHAGENT_LABEL:-}"
    )"
    if [[ -n "$label" ]]; then
      printf '%s' "$label"
      return 0
    fi
  fi
  # No marker → not launchd-managed via our installer. Fall through to the
  # bridge-lib default ONLY if the plist actually exists on disk, so a
  # systemd/nohup Linux install (which has the env default but no plist)
  # is correctly treated as not-launchd.
  local label="${BRIDGE_DAEMON_LAUNCHAGENT_LABEL:-}"
  local plist="${BRIDGE_DAEMON_LAUNCHAGENT_PLIST:-}"
  if [[ -n "$label" && -n "$plist" && -f "$plist" ]]; then
    printf '%s' "$label"
    return 0
  fi
  printf ''
  return 1
}

# Read the live pid of launchd's supervised job for $label. Parses
# `launchctl print gui/$UID/<label>` for the `pid = NNN` line. Prints the
# pid on stdout (empty when the job is not currently running / not loaded).
_bridge_daemon_launchd_job_pid() {
  local label="$1"
  [[ -n "$label" ]] || return 1
  command -v launchctl >/dev/null 2>&1 || return 1
  local uid
  uid="$(id -u 2>/dev/null || printf '%s' "${UID:-}")"
  [[ -n "$uid" ]] || return 1
  local pid
  pid="$(
    launchctl print "gui/${uid}/${label}" 2>/dev/null \
      | awk -F'=' '/^[[:space:]]*pid[[:space:]]*=/ { gsub(/[^0-9]/, "", $2); print $2; exit }'
  )"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$pid"
}

# bridge_daemon_launchd_restart — the canonical launchd-aware restart used
# by the out-of-band supervisors (#1463). See header block above for the
# rationale and return-code contract. `$1` is an optional forensic reason
# string recorded in the audit trail.
bridge_daemon_launchd_restart() {
  local reason="${1:-supervisor}"

  # Linux / non-launchd hosts: signal the caller to use its stop+start
  # fallback. systemd installs are unaffected by the launchd KeepAlive
  # thrash and keep their existing restart path.
  [[ "$(uname 2>/dev/null)" == "Darwin" ]] || return 1
  command -v launchctl >/dev/null 2>&1 || return 1

  local label
  label="$(_bridge_daemon_launchd_label 2>/dev/null || true)"
  [[ -n "$label" ]] || return 1

  local uid
  uid="$(id -u 2>/dev/null || printf '%s' "${UID:-}")"
  [[ -n "$uid" ]] || return 1

  # Split detection: the recorded daemon pid must be launchd's job pid.
  # If a prior out-of-band restart already established a non-launchd lock
  # holder, kickstart would cycle the (lock-starved) supervised slot and
  # leave the real holder running → the thrash re-arms. Refuse instead.
  local pid_file="${BRIDGE_DAEMON_PID_FILE:-${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}/daemon.pid}"
  local recorded_pid=""
  if [[ -f "$pid_file" ]]; then
    recorded_pid="$(cat "$pid_file" 2>/dev/null | tr -dc '0-9' | head -c 16)"
  fi
  local job_pid=""
  job_pid="$(_bridge_daemon_launchd_job_pid "$label" 2>/dev/null || true)"

  # FAIL CLOSED on an out-of-band split (codex #9603 B1). A live recorded
  # daemon pid is safe to kickstart over ONLY when launchd PROVES that same
  # pid is its supervised job (job_pid non-empty AND == recorded_pid).
  # Otherwise — launchd reports a DIFFERENT pid, OR launchd has NO current
  # job pid (it is between KeepAlive attempts / lock-starved) — the live
  # recorded holder is out-of-band: a kickstart would cycle the lock-starved
  # supervised slot while the real holder survives, leaving the thrash armed
  # and the supervisor falsely reporting success. Refuse. (A non-live /
  # absent recorded pid means no holder to displace → kickstart is safe.)
  if [[ -n "$recorded_pid" ]] && kill -0 "$recorded_pid" 2>/dev/null \
     && { [[ -z "$job_pid" ]] || [[ "$recorded_pid" != "$job_pid" ]]; }; then
    command -v bridge_audit_log >/dev/null 2>&1 \
      && bridge_audit_log daemon daemon_launchd_restart_refused daemon \
           --detail reason="$reason" \
           --detail recorded_pid="$recorded_pid" \
           --detail launchd_job_pid="${job_pid:-none}" \
           --detail label="$label" >/dev/null 2>&1 || true
    bridge_warn "daemon-launchd: refusing kickstart — live recorded daemon pid=$recorded_pid is not proven to be launchd's job pid=${job_pid:-<none>} (out-of-band split). Run 'bridge-daemon.sh stop --force' once to reconcile, then KeepAlive will respawn the supervised slot."
    return 2
  fi

  command -v bridge_audit_log >/dev/null 2>&1 \
    && bridge_audit_log daemon daemon_launchd_restart daemon \
         --detail reason="$reason" \
         --detail recorded_pid="${recorded_pid:-none}" \
         --detail launchd_job_pid="${job_pid:-none}" \
         --detail label="$label" >/dev/null 2>&1 || true

  # Cycle launchd's own supervised job. -k sends SIGKILL to the current
  # instance (if any) then relaunches it; the relaunched instance is the
  # sole lock holder, ending the KeepAlive thrash.
  if launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1; then
    return 0
  fi

  command -v bridge_audit_log >/dev/null 2>&1 \
    && bridge_audit_log daemon daemon_launchd_restart_failed daemon \
         --detail reason="$reason" \
         --detail label="$label" >/dev/null 2>&1 || true
  bridge_warn "daemon-launchd: launchctl kickstart gui/${uid}/${label} failed"
  return 1
}

# bridge_daemon_self_check — periodic R3 visibility helper. Called
# from cmd_run's main loop on a throttled schedule. Compares $$ to the
# pid attribute of the most recent `daemon_started` audit row; mismatch
# → audit `daemon_pid_mismatch` + (ONLY on positively-proven duplicate)
# a best-effort admin alert task. The structured audit row + warn always
# surface the divergence on operator dashboards.
#
# #9882 / BUG A: a mismatch is escalated to the operator ONLY when the
# audited pid is positively proven to be a DISTINCT, LIVE daemon
# generation (alive + daemon cmdline + owner record names this pid + the
# owner-record start_time matches the live `ps -o lstart=` + it is not
# $$). Every inconclusive mismatch is audit-only
# (`escalation=suppressed_unproven`) — that gate is what stops the
# false-positive "duplicate daemon" task on a healthy single-daemon host.
# PR-1 (#1563) guarantees the surviving singleton always publishes the
# owner record before emitting `daemon_started`, so a GENUINE duplicate is
# still provable and still alerts.
#
# Returns 0 on match, 1 on mismatch (caller may decide whether to
# escalate further). Never aborts the daemon.
bridge_daemon_self_check() {
  local audit_log="${BRIDGE_AUDIT_LOG:-${BRIDGE_HOME}/logs/audit.jsonl}"
  [[ -f "$audit_log" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local latest_pid=""
  latest_pid="$(BRIDGE_AUDIT_LOG="$audit_log" python3 -c '
import json
import os
import sys

path = os.environ.get("BRIDGE_AUDIT_LOG", "")
if not path or not os.path.isfile(path):
    sys.exit(0)
latest = ""
try:
    # Tail-read up to the last 64KB so the scan is bounded even on
    # multi-GB audit logs.
    with open(path, "rb") as fh:
        try:
            fh.seek(-65536, os.SEEK_END)
        except OSError:
            fh.seek(0)
        chunk = fh.read().decode("utf-8", errors="replace")
    for line in chunk.splitlines():
        line = line.strip()
        if not line or "daemon_started" not in line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("action") != "daemon_started":
            continue
        detail = row.get("detail") or {}
        pid_val = detail.get("pid") if isinstance(detail, dict) else None
        if pid_val:
            latest = str(pid_val)
except OSError:
    sys.exit(0)
sys.stdout.write(latest)
' 2>/dev/null || true)"

  [[ -n "$latest_pid" ]] || return 0
  if [[ "$latest_pid" == "$$" ]]; then
    return 0
  fi

  # Mismatch: another daemon emitted `daemon_started` more recently.
  # If that recent pid is still alive, we MIGHT have a genuine duplicate —
  # but a bare `kill -0` also passes for a RECYCLED pid the OS handed to an
  # unrelated process after the audited daemon exited.
  #
  # #9882 / BUG A (the false-positive this PR fixes): the prior shape
  # DEFAULTED to escalation. It treated `cmdline matches bridge-daemon.sh
  # run` + `alive` as a duplicate UNLESS the owner record positively
  # disproved it (a start-time mismatch). That `else → other_alive=true`
  # fallthrough fired the admin "duplicate daemon" task on every
  # INCONCLUSIVE case — no owner record, `owner_rec_pid != latest_pid`, an
  # unreadable live start-time, or (perversely) start-times that happen to
  # MATCH. On a healthy single-daemon host the audited pid is most often
  # the daemon's OWN prior generation (or a wrapper briefly daemon-shaped)
  # with no usable cross-check, so the old code over-escalated. Measured:
  # the live audit false-positived twice in 15 minutes (#9872/#9880).
  #
  # #9882 fix: ESCALATION REQUIRES POSITIVE PROOF of a distinct, live
  # duplicate generation — symmetric with the #1563 fail-closed-on-kill
  # eviction gate. We only alert when EVERY proof holds:
  #   1. the audited pid is alive (kill -0); AND
  #   2. its cmdline looks like `bridge-daemon.sh run`; AND
  #   3. an owner record exists AND names exactly this pid
  #      (`owner_rec_pid == latest_pid`); AND
  #   4. the owner record's start_time and the live `ps -o lstart=` are
  #      both readable AND MATCH — i.e. this pid is the recorded singleton
  #      generation, not a recycled number; AND
  #   5. it is not THIS process (`latest_pid != $$`).
  # Only that combination proves a second live daemon generation. Anything
  # short of it (no/partial owner record, pid mismatch, unreadable
  # start-time) is INCONCLUSIVE → audit-only (`escalation=suppressed_unproven`),
  # NO operator alert.
  #
  # Why fail-closed-on-alert is now SAFE (balancing the old comment's
  # concern that we "never SUPPRESS a real duplicate just because the
  # record is missing"): PR-1 (#1563 singleton hardening) now GUARANTEES
  # the surviving singleton holder always publishes the owner record
  # (tmp+rename under the held lock) before it emits `daemon_started`. So a
  # GENUINE second live daemon DOES have a matching owner record and IS
  # provable here — see the `real-dup still alerts` smoke assertion. The
  # only cases that now lose the alert are exactly the unprovable ones that
  # were producing the false positives.
  #
  # `recycled_pid` (cmdline non-daemon OR start-time PROVABLY mismatched)
  # keeps its existing early-return as a no-alert classification.
  local other_alive="false"
  local recycled_pid="false"
  local proven_duplicate="false"
  if kill -0 "$latest_pid" 2>/dev/null; then
    local other_cmdline="" other_live_start="" owner_rec_pid="" owner_rec_start=""
    other_cmdline="$(_bridge_daemon_singleton_cmdline "$latest_pid" 2>/dev/null || true)"
    if [[ "$other_cmdline" == *"bridge-daemon.sh run"* ]]; then
      other_alive="true"
      owner_rec_pid="$(_bridge_daemon_singleton_owner_field pid 2>/dev/null || true)"
      owner_rec_start="$(_bridge_daemon_singleton_owner_field start_time 2>/dev/null || true)"
      other_live_start="$(_bridge_daemon_proc_start_time "$latest_pid" 2>/dev/null || true)"
      if [[ -n "$owner_rec_pid" && "$owner_rec_pid" == "$latest_pid" \
            && -n "$owner_rec_start" && -n "$other_live_start" \
            && "$owner_rec_start" != "$other_live_start" ]]; then
        # Owner record names this pid but with a DIFFERENT start-time →
        # the audited daemon exited and its pid was recycled. Not a dup.
        recycled_pid="true"
        other_alive="false"
      elif [[ -n "$owner_rec_pid" && "$owner_rec_pid" == "$latest_pid" \
              && -n "$owner_rec_start" && -n "$other_live_start" \
              && "$owner_rec_start" == "$other_live_start" \
              && "$latest_pid" != "$$" ]]; then
        # POSITIVE proof: a live, daemon-cmdline pid that is the recorded
        # singleton generation (owner_rec_pid == latest_pid AND start-times
        # match) and is not us → a genuine distinct live duplicate. Alert.
        proven_duplicate="true"
      fi
      # Else INCONCLUSIVE (no/partial owner record, pid mismatch, or
      # unreadable start-time): other_alive stays "true" for forensics but
      # proven_duplicate stays "false" → audit-only, no escalation below.
    else
      # Live pid is NOT a bridge-daemon → recycled to an unrelated process.
      recycled_pid="true"
    fi
  fi
  local escalation_class="proven_duplicate"
  if [[ "$proven_duplicate" != "true" ]]; then
    if [[ "$recycled_pid" == "true" ]]; then
      escalation_class="suppressed_recycled_pid"
    else
      escalation_class="suppressed_unproven"
    fi
  fi
  command -v bridge_audit_log >/dev/null 2>&1 \
    && bridge_audit_log daemon daemon_pid_mismatch daemon \
         --detail self_pid="$$" \
         --detail recent_audit_pid="$latest_pid" \
         --detail other_alive="$other_alive" \
         --detail recycled_pid="$recycled_pid" \
         --detail proven_duplicate="$proven_duplicate" \
         --detail escalation="$escalation_class" >/dev/null 2>&1 || true
  bridge_warn "daemon-self-check: pid mismatch — self=$$, latest audit daemon_started pid=$latest_pid, other_alive=$other_alive, recycled_pid=$recycled_pid, escalation=$escalation_class"

  # A recycled pid is provably NOT a live duplicate — do not raise an admin
  # task (that would be a false-positive duplicate-daemon alert). The audit
  # row above already records the mismatch + recycled classification for
  # forensics; return 1 (mismatch observed) without escalating.
  if [[ "$recycled_pid" == "true" ]]; then
    return 1
  fi

  # #9882 / BUG A: only a POSITIVELY PROVEN distinct live daemon generation
  # raises the operator alert. An inconclusive mismatch (no/partial owner
  # record, pid mismatch, unreadable start-time) is recorded in the audit
  # row above with `escalation=suppressed_unproven` and returns WITHOUT the
  # admin task — that audit-only path is what stops the false positive.
  if [[ "$proven_duplicate" != "true" ]]; then
    return 1
  fi

  # r2 (codex BLOCKING #1): the audit row + bridge_warn is not enough —
  # without an operator-visible queue task, a surviving duplicate daemon
  # is only discoverable by grepping audit.jsonl. Push a high-priority
  # task to the admin agent so the operator gets a normal inbox-level
  # surface. Best-effort: tolerate every failure (no bridge-task.sh,
  # admin name unset, queue locked) — self_check must NEVER abort the
  # daemon main loop.
  local admin_agent=""
  if command -v bridge_admin_agent_id >/dev/null 2>&1; then
    admin_agent="$(bridge_admin_agent_id 2>/dev/null || true)"
  fi
  [[ -n "$admin_agent" ]] || admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  # Resolve the bridge-task.sh path. Prefer BRIDGE_SCRIPT_DIR (canonical
  # source dir env); fall back to the directory of this lib file.
  local task_script=""
  if [[ -n "${BRIDGE_SCRIPT_DIR:-}" && -x "${BRIDGE_SCRIPT_DIR}/bridge-task.sh" ]]; then
    task_script="${BRIDGE_SCRIPT_DIR}/bridge-task.sh"
  else
    local _lib_parent
    _lib_parent="$(cd -P "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || true)"
    if [[ -n "$_lib_parent" && -x "${_lib_parent}/bridge-task.sh" ]]; then
      task_script="${_lib_parent}/bridge-task.sh"
    fi
  fi
  if [[ -n "$admin_agent" && -n "$task_script" ]]; then
    local alert_title="[ALERT] daemon duplicate execution detected (self=$$, audit-recent=${latest_pid})"
    local alert_body_file
    alert_body_file="$(mktemp -t bridge-daemon-pid-mismatch.XXXXXX 2>/dev/null || true)"
    if [[ -n "$alert_body_file" ]]; then
      {
        printf 'Daemon self-check detected a PROVEN distinct live daemon generation.\n'
        printf '(positive proof: alive + bridge-daemon.sh-run cmdline + owner record names this pid + owner-record start_time matches live ps lstart + pid != self)\n\n'
        printf 'self_pid: %s\n' "$$"
        printf 'recent_audit_pid: %s\n' "$latest_pid"
        printf 'other_alive: %s\n' "$other_alive"
        printf 'escalation: %s\n' "$escalation_class"
        printf 'host: %s\n' "$(hostname 2>/dev/null || echo unknown)"
        printf 'ts: %s\n' "$(date -u +%FT%TZ 2>/dev/null || date)"
        printf '\n'
        printf 'Action: investigate via `ps -ef | grep bridge-daemon` and kill the orphan if necessary.\n'
        printf 'Source: lib/bridge-daemon-control.sh bridge_daemon_self_check (issue #1276 Lane D R3; #9882 BUG A positive-proof gate).\n'
      } >"$alert_body_file" 2>/dev/null || true
      bash "$task_script" create \
        --from daemon \
        --to "$admin_agent" \
        --priority high \
        --title "$alert_title" \
        --body-file "$alert_body_file" >/dev/null 2>&1 || true
      rm -f "$alert_body_file" 2>/dev/null || true
    fi
  fi
  return 1
}

# ===========================================================================
# Issue #1563 PR-2 — T1 daemon self-abort BACKSTOP (runner-process default).
#
# THE WEDGE (the actual #1563 bug): the daemon can sit "alive-but-not-
# ticking" — `cmd_run`'s pid stays alive while `cmd_sync_cycle` is blocked
# on an unbounded child (the canonical stack: bash at __wait4 on a tmux
# send-keys whose far end is a closed SSL pipe that escaped a
# bridge_with_timeout wrapper). A naive `kill -0 $pid` health check passes
# this wedge. PR-2 makes a wedged daemon SELF-ABORT (exit non-zero) so T0
# (launchd KeepAlive / systemd Restart=always) restarts a FRESH daemon —
# WITHOUT ever aborting a HEALTHY daemon mid-long-step.
#
# THE HARD CONSTRAINT (why a naive per-tick deadline is WRONG): the tick
# legitimately does long BOUNDED work in-line — process_daily_backup (600s
# ceiling), A2A deliver (60s), bridge-sync (30s), watchdog (30s). A deadline
# tuned to desired nudge latency would KILL a healthy daemon mid-backup.
# So the deadline is a WEDGE BACKSTOP derived from the MAX legitimate single
# synchronous step budget + grace — NEVER from nudge latency.
#
# THE MECHANISM (runner-process, the codex-Q2-agreed DEFAULT — NOT bash
# SIGALRM, which leaks trap/timer state across ticks): `cmd_run` runs ONE
# scheduler tick (`cmd_sync_cycle`) as a CHILD in its own process group via
# bridge_daemon_run_tick_supervised. The child writes a PROGRESS heartbeat
# (epoch -> the progress file) around each long bounded step (the parent-
# side progress signal); the supervisor parent waits on the child and
# watches the FRESHNESS of that progress file. As long as the child makes
# progress within (longest single step budget + grace) the supervisor never
# fires — a healthy 600s backup refreshes progress right before the step and
# completes under its own 600s bridge_with_timeout, comfortably inside the
# (600 + grace) deadline. A genuine wedge = no progress update for longer
# than the deadline -> kill the child's process group, emit
# `daemon_tick_deadline_exceeded`, and signal the caller to exit non-zero.
# The timer is the child itself (it dies with the kill); there is no bash
# alarm/trap to leak into the NEXT tick (the supervisor re-forks a fresh
# child + fresh progress baseline each tick — assertion (c)).
# ===========================================================================

# Default FLOOR per-step budget (seconds). process_daily_backup is the longest
# legitimate synchronous step (600s default ceiling), so 600 is the floor. The
# EFFECTIVE max-step is the MAX of this floor and the ACTUAL resolved bounded-
# step budgets (see bridge_daemon_tick_resolved_max_step_seconds) — critically,
# the operator-tunable BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS, which the recovery
# runbook tells large-install operators to RAISE. Deriving from the resolved
# budget (not a fixed 600) is what guarantees the deadline always sits ABOVE
# the longest legitimately-configured step, so a healthy backup that runs under
# its own (possibly raised) bridge_with_timeout can never trip the backstop
# (codex #1563-PR2 review: a fixed 600 floor + a documented 900s backup timeout
# would FALSE-ABORT a healthy daemon — the exact flapping irony).
: "${BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS:=600}"
# Grace on top of the max step: covers progress-write latency, the
# supervisor poll interval, and process teardown. NOT a nudge-latency knob.
: "${BRIDGE_DAEMON_TICK_GRACE_SECONDS:=120}"
# How often the supervisor parent polls the child + progress freshness.
: "${BRIDGE_DAEMON_TICK_POLL_SECONDS:=2}"

# The operator-tunable synchronous bridge_with_timeout step ceilings reachable
# from cmd_sync_cycle, paired with their documented defaults. The effective
# max-step is the MAX of the floor and EVERY one of these, so raising ANY of
# them automatically widens the T1 deadline and a healthy step running under
# its own (possibly raised) bridge_with_timeout can never trip the backstop
# (codex #1563-PR2 review: daily-backup was not the only tunable step —
# claude-token-recovery and cron-staging-apply are also operator-raisable).
# Format: "ENV_VAR_NAME:default_seconds". Only SYNCHRONOUS step DURATIONS
# belong here — data-age thresholds (e.g. BRIDGE_PERMISSION_ESCALATION_TIMEOUT_
# SECONDS, a task-age comparison, NOT a step duration) and counts
# (BRIDGE_NUDGE_RECHECK_TIMEOUT_ESCALATE_AFTER) are deliberately excluded. Keep
# this list in sync when a new operator-tunable bridge_with_timeout ceiling is
# added to cmd_sync_cycle (the 1563-pr2 smoke pins the coupling).
_BRIDGE_DAEMON_TICK_STEP_TIMEOUT_KNOBS=(
  "BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS:600"
  "BRIDGE_CLAUDE_TOKEN_RECOVERY_TIMEOUT_SECONDS:60"
  "BRIDGE_CLAUDE_TOKEN_CHECK_TIMEOUT_SECONDS:45"
  "BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS:25"
  "BRIDGE_CRON_SYNC_TIMEOUT:30"
  # Issue #1563 PR-6: the watchdog drift-scan ceiling (per scan). The
  # watchdog phase runs two bounded scans (markdown + --json) with a
  # progress pulse BETWEEN them (process_watchdog_report), so each scan is a
  # single bounded step <= this ceiling — coupling the single-scan value here
  # (not 2x) keeps the supervisor deadline above any operator-raised watchdog
  # ceiling so a healthy raised scan can never be false-aborted by the PR-2
  # backstop. Default mirrors BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS:-30.
  "BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS:30"
)

# bridge_daemon_tick_resolved_max_step_seconds — the EFFECTIVE longest
# legitimate single synchronous step. Starts from the configured floor
# (BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS) and raises it to the LARGEST of every
# operator-tunable bridge_with_timeout step ceiling reachable from
# cmd_sync_cycle (see _BRIDGE_DAEMON_TICK_STEP_TIMEOUT_KNOBS), so the deadline
# can never be SMALLER than a configured bounded step. The daily-backup ceiling
# is resolved via bridge_daily_backup_resolve_timeout (in scope at runtime once
# bridge-lib.sh sources this lib into the daemon) when available, else its env
# var; every other knob is read from its env var with its documented default.
bridge_daemon_tick_resolved_max_step_seconds() {
  local max_step="${BRIDGE_DAEMON_TICK_MAX_STEP_SECONDS:-600}"
  [[ "$max_step" =~ ^[0-9]+$ ]] || max_step=600

  # Daily backup has a resolver helper (clamps/validates); prefer it.
  local backup="$max_step"
  if command -v bridge_daily_backup_resolve_timeout >/dev/null 2>&1; then
    local resolved
    resolved="$(bridge_daily_backup_resolve_timeout 2>/dev/null || printf '')"
    [[ "$resolved" =~ ^[0-9]+$ ]] && backup="$resolved"
  elif [[ "${BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS:-}" =~ ^[0-9]+$ ]]; then
    backup="$BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS"
  fi
  (( backup > max_step )) && max_step="$backup"

  # Every other operator-tunable step ceiling: env override or documented
  # default, whichever applies; raise the running max.
  local knob name default val
  for knob in "${_BRIDGE_DAEMON_TICK_STEP_TIMEOUT_KNOBS[@]}"; do
    name="${knob%%:*}"
    default="${knob#*:}"
    # daily-backup already handled via its resolver above.
    [[ "$name" == "BRIDGE_DAILY_BACKUP_TIMEOUT_SECONDS" ]] && continue
    val="${!name:-$default}"
    [[ "$val" =~ ^[0-9]+$ ]] || val="$default"
    (( val > max_step )) && max_step="$val"
  done

  printf '%s' "$max_step"
}

# bridge_daemon_tick_deadline_seconds — the wedge-backstop deadline =
# (effective resolved max-step) + grace. Emitted into the audit row so the
# value is operator-visible and the smoke can assert it is max-step-DERIVED
# (always >= the longest configured bounded step), NOT a fixed/nudge-latency
# number.
bridge_daemon_tick_deadline_seconds() {
  local max_step grace
  max_step="$(bridge_daemon_tick_resolved_max_step_seconds)"
  grace="${BRIDGE_DAEMON_TICK_GRACE_SECONDS:-120}"
  [[ "$max_step" =~ ^[0-9]+$ ]] || max_step=600
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=120
  printf '%s' "$(( max_step + grace ))"
}

# bridge_daemon_tick_progress_file — path of the per-tick progress heartbeat
# the in-tick markers write and the supervisor watches. Distinct from
# state/daemon.heartbeat (the cross-tick OS-watcher file) so the supervisor's
# in-tick wedge detection is not masked by anything else touching the OS file.
bridge_daemon_tick_progress_file() {
  local state_dir="${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
  printf '%s/daemon.tick-progress' "$state_dir"
}

# bridge_daemon_sd_notify — best-effort systemd sd_notify (Linux T0 backstop).
# Only fires when running under a systemd `Type=notify` unit (NOTIFY_SOCKET is
# exported by systemd in that case) AND `systemd-notify` is on PATH. A no-op
# everywhere else (macOS/launchd, non-notify units, bare runs). Used to send
# READY=1 at daemon startup and WATCHDOG=1 on each progress pulse so systemd's
# own WatchdogSec is an INDEPENDENT backstop to the T1 self-abort: if the
# daemon wedges so hard it cannot even reach its own supervisor poll, the
# missed WATCHDOG=1 makes systemd restart it. The WatchdogSec is sized ABOVE
# the T1 deadline so a healthy long step never trips systemd before T1's own
# (already-grace-padded) backstop — systemd is the slower outer ring.
bridge_daemon_sd_notify() {
  [[ -n "${NOTIFY_SOCKET:-}" ]] || return 0
  command -v systemd-notify >/dev/null 2>&1 || return 0
  systemd-notify "$@" >/dev/null 2>&1 || true
  return 0
}

# bridge_daemon_tick_progress_touch — the PARENT-SIDE progress heartbeat
# primitive: stamp the current epoch into the progress file (atomic via
# mv) AND refresh state/daemon.heartbeat so the cross-tick OS watcher
# (launchd liveness / systemd timer) also sees forward progress. Called by
# the in-tick step markers (_bridge_daemon_mark_progress in bridge-daemon.sh)
# around each long bounded step and at the top of each loop iteration.
#
# Optional arg $1 = the step label. The tick runs as a CHILD subshell, so its
# BRIDGE_DAEMON_LAST_STEP mutations never reach the supervisor parent; the
# child publishes the step label to a small sibling file so the supervisor's
# wedge audit can name the ACTUAL hung step (not the stale parent value).
# Best-effort: a failed stamp must never abort the tick.
bridge_daemon_tick_progress_touch() {
  local step="${1:-}"
  local now_ts
  now_ts="$(date +%s 2>/dev/null || printf '0')"
  local pf hb sf
  pf="$(bridge_daemon_tick_progress_file)"
  sf="${pf}.step"
  hb="${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}/daemon.heartbeat"
  local dir
  dir="$(dirname "$pf" 2>/dev/null || printf '.')"
  mkdir -p "$dir" 2>/dev/null || true
  if printf '%s\n' "$now_ts" 2>/dev/null >"$pf.tmp.$$"; then
    mv -f "$pf.tmp.$$" "$pf" 2>/dev/null || printf '%s\n' "$now_ts" 2>/dev/null >"$pf" || true
  else
    printf '%s\n' "$now_ts" 2>/dev/null >"$pf" || true
  fi
  if [[ -n "$step" ]]; then
    printf '%s\n' "$step" 2>/dev/null >"$sf" || true
  fi
  printf '%s\n' "$now_ts" 2>/dev/null >"$hb" || true
  # Linux T0 backstop: pet the systemd watchdog on every progress pulse so a
  # healthy long step keeps systemd's WatchdogSec satisfied (no-op off systemd
  # notify). A genuine wedge stops pulsing → systemd restarts as the outer ring.
  bridge_daemon_sd_notify WATCHDOG=1
  return 0
}

# _bridge_daemon_tick_last_step — read the step label the child last
# published (see bridge_daemon_tick_progress_touch). Used by the supervisor
# to attribute a wedge to the real hung step.
_bridge_daemon_tick_last_step() {
  local sf
  sf="$(bridge_daemon_tick_progress_file).step"
  if [[ -r "$sf" ]]; then
    local v
    v="$(head -n1 "$sf" 2>/dev/null | tr -dc 'A-Za-z0-9_.-' | head -c 64)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  fi
  printf '%s' "unknown"
}

# _bridge_daemon_tick_progress_age — seconds since the last progress stamp.
# Prints a large sentinel when the file is missing/unreadable so the
# supervisor treats "never wrote progress" as a wedge candidate only after
# the deadline (the first stamp happens at tick start, so a healthy child
# establishes the baseline immediately).
_bridge_daemon_tick_progress_age() {
  local pf now_ts last_ts
  pf="$(bridge_daemon_tick_progress_file)"
  now_ts="$(date +%s 2>/dev/null || printf '0')"
  if [[ -r "$pf" ]]; then
    last_ts="$(tr -dc '0-9' <"$pf" 2>/dev/null | head -c 18)"
  fi
  [[ "$last_ts" =~ ^[0-9]+$ ]] || { printf '%s' "999999"; return 0; }
  [[ "$now_ts" =~ ^[0-9]+$ ]] || { printf '%s' "999999"; return 0; }
  local age=$(( now_ts - last_ts ))
  (( age < 0 )) && age=0
  printf '%s' "$age"
}

# ---------------------------------------------------------------------------
# Cross-tick daemon-state counter persistence (#1563 PR-2 r3)
#
# Why this exists: the runner-process T1 (bridge_daemon_run_tick_supervised)
# runs each scheduler tick as a background CHILD subshell. Any in-memory shell
# variable mutated inside the tick (cmd_sync_cycle and its callees) is LOST when
# the child exits — the parent re-enters the NEXT tick with the variable's
# pre-fork value. That silently breaks ANY daemon-process-state counter that is
# supposed to ACCUMULATE across ticks. The audited instance is
# _BRIDGE_NUDGE_IDLE_READY_CONSEC_FAIL (issue #946 L4 / PR #952 r2): under a
# persistent idle-ready-writer failure it must climb 1,2,3,… across ticks so an
# operator sees the wedge escalate; child-local memory pins it at 1 every tick.
#
# Fix: persist such counters in a tiny per-key state file under $BRIDGE_STATE_DIR
# (one integer, newline-terminated). The child reads-at-tick-start, increments
# or resets, and writes — the file survives the child boundary cleanly, matching
# the daemon's existing tick-progress / nudge-state file patterns. Best-effort:
# a failed read returns 0, a failed write must never abort the tick.

# bridge_daemon_state_counter_file <key> — path of the persisted counter file.
# <key> is sanitized to [A-Za-z0-9_.-] so a caller key can never escape the dir.
bridge_daemon_state_counter_file() {
  local key="${1:-counter}"
  key="$(printf '%s' "$key" | tr -dc 'A-Za-z0-9_.-' | head -c 96)"
  [[ -n "$key" ]] || key="counter"
  local state_dir="${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
  printf '%s/daemon-state-counters/%s' "$state_dir" "$key"
}

# bridge_daemon_state_counter_get <key> — print the persisted integer (0 if the
# file is missing/unreadable/non-numeric). Never errors (set -u safe: a missing
# <key> resolves to the default counter, a missing file reads as 0).
bridge_daemon_state_counter_get() {
  local cf v=0
  cf="$(bridge_daemon_state_counter_file "${1:-}")"
  if [[ -r "$cf" ]]; then
    v="$(tr -dc '0-9' <"$cf" 2>/dev/null | head -c 18)"
  fi
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "$v"
}

# bridge_daemon_state_counter_set <key> <value> — persist <value> atomically and
# print it. Non-numeric/missing <value> is coerced to 0. Best-effort write
# (set -u safe: both positionals default).
bridge_daemon_state_counter_set() {
  local cf val dir
  cf="$(bridge_daemon_state_counter_file "${1:-}")"
  val="${2:-0}"
  [[ "$val" =~ ^[0-9]+$ ]] || val=0
  dir="$(dirname "$cf" 2>/dev/null || printf '.')"
  mkdir -p "$dir" 2>/dev/null || true
  if printf '%s\n' "$val" 2>/dev/null >"$cf.tmp.$$"; then
    mv -f "$cf.tmp.$$" "$cf" 2>/dev/null || printf '%s\n' "$val" 2>/dev/null >"$cf" || true
  else
    printf '%s\n' "$val" 2>/dev/null >"$cf" || true
  fi
  printf '%s' "$val"
}

# bridge_daemon_state_counter_incr <key> — read, +1, persist, print the NEW
# value. This is the accumulate-across-ticks primitive (set -u safe).
bridge_daemon_state_counter_incr() {
  local key="${1:-}" cur next
  cur="$(bridge_daemon_state_counter_get "$key")"
  next=$(( cur + 1 ))
  bridge_daemon_state_counter_set "$key" "$next"
}

# bridge_daemon_state_counter_reset <key> — persist 0 (and print it; set -u safe).
bridge_daemon_state_counter_reset() {
  bridge_daemon_state_counter_set "${1:-}" 0
}

# bridge_daemon_run_tick_supervised — the runner-process T1.
#
# Runs the tick function ("$@", normally `cmd_sync_cycle`) as a CHILD in its
# OWN process group, establishes a fresh progress baseline, then polls:
#   - reaps the child the instant it finishes -> returns the child's status
#     (0 = healthy tick, the daemon loop continues);
#   - on each poll, recomputes progress age; if it exceeds the
#     max-step-budget + grace deadline the child is WEDGED -> SIGTERM then
#     SIGKILL the child's whole process group (so a hung grandchild cannot
#     orphan), emit a structured `daemon_tick_deadline_exceeded` audit row
#     (tick_id, last_step, duration_seconds, deadline_seconds), and return
#     the reserved status BRIDGE_DAEMON_TICK_WEDGE_RC (99) so the caller
#     exits non-zero for OS-init restart.
#
# A fresh child + fresh progress baseline per call means a stale timer/child
# can never fire into the NEXT tick (assertion (c)): if this returns 0 the
# child has already been reaped; the next call forks a brand-new pgid.
BRIDGE_DAEMON_TICK_WEDGE_RC=99
bridge_daemon_run_tick_supervised() {
  local tick_id="${1:-0}"
  shift || true
  if (( $# == 0 )); then
    set -- cmd_sync_cycle
  fi

  local deadline poll
  deadline="$(bridge_daemon_tick_deadline_seconds)"
  poll="${BRIDGE_DAEMON_TICK_POLL_SECONDS:-2}"
  [[ "$poll" =~ ^[0-9]+$ ]] && (( poll > 0 )) || poll=2

  # Establish the progress baseline BEFORE forking so a child that wedges
  # before its first own stamp is still measured from tick start (not from
  # a stale prior-tick value). Seed the step label as "tick_start" so a child
  # that wedges before its own first marker is still attributed, not left
  # showing the previous tick's step.
  bridge_daemon_tick_progress_touch "tick_start"

  local tick_started_ts
  tick_started_ts="$(date +%s 2>/dev/null || printf '0')"

  # Run the tick as a child in its OWN process group so a wedge can be killed
  # as a group and a hung GRANDCHILD cannot orphan. The portable mechanism is
  # job control: when `set -m` is active in the PARENT at the moment a `&` job
  # is launched, bash places that job in a fresh process group whose pgid ==
  # the job's pid ($!). We then `kill -TERM -$child_pid` to signal the whole
  # group. `set -m` must be active in the parent (NOT inside the subshell —
  # that only makes the grandchild its own leader and leaves the subshell in
  # the daemon's group, so the group-kill misses the tree). We record the
  # prior `-m` state and restore it immediately so the long-lived daemon shell
  # is never left in job-control mode (which would emit spurious job
  # notifications). All job-control chatter from the launch is stderr-scoped.
  local _had_monitor=0
  case "$-" in *m*) _had_monitor=1 ;; esac
  local child_pid=""
  {
    set -m 2>/dev/null || true
    ( "$@" ) &
    child_pid=$!
    if (( _had_monitor == 0 )); then
      set +m 2>/dev/null || true
    fi
  } 2>/dev/null

  local child_status=0
  while true; do
    # Has the child finished? `kill -0` is true while alive.
    if ! kill -0 "$child_pid" 2>/dev/null; then
      # Reap and capture the real exit status.
      wait "$child_pid" 2>/dev/null
      child_status=$?
      return "$child_status"
    fi

    local age
    age="$(_bridge_daemon_tick_progress_age)"
    [[ "$age" =~ ^[0-9]+$ ]] || age=0
    if (( age >= deadline )); then
      # WEDGE. Kill the child's process group (TERM, grace, KILL) so a hung
      # grandchild cannot orphan, then emit the structured audit + signal a
      # non-zero exit. A negative pid targets the process group of the leader.
      # The child publishes its step label to a sibling file (its subshell
      # BRIDGE_DAEMON_LAST_STEP never reaches us); prefer that, then fall back
      # to the parent's last-set step.
      local last_step
      last_step="$(_bridge_daemon_tick_last_step 2>/dev/null || printf 'unknown')"
      if [[ -z "$last_step" || "$last_step" == "unknown" ]]; then
        last_step="${BRIDGE_DAEMON_LAST_STEP:-unknown}"
      fi
      local now_ts duration
      now_ts="$(date +%s 2>/dev/null || printf '0')"
      if [[ "$now_ts" =~ ^[0-9]+$ && "$tick_started_ts" =~ ^[0-9]+$ ]]; then
        duration=$(( now_ts - tick_started_ts ))
        (( duration < 0 )) && duration=0
      else
        duration="$age"
      fi

      # Kill + grace + reap, confined to a stderr-redirected block so the
      # parent shell's job-control "Terminated: 15" notification (emitted
      # when it reaps a signal-killed background job) does not leak into the
      # daemon/launchagent log. The structured audit + warn below carry the
      # real, intentional operator signal.
      {
        kill -TERM "-$child_pid" || kill -TERM "$child_pid" || true
        local waited=0
        while kill -0 "$child_pid" 2>/dev/null && (( waited < 5 )); do
          sleep 1
          waited=$(( waited + 1 ))
        done
        if kill -0 "$child_pid" 2>/dev/null; then
          kill -KILL "-$child_pid" || kill -KILL "$child_pid" || true
        fi
        wait "$child_pid" || true
      } >/dev/null 2>&1

      if command -v bridge_audit_log >/dev/null 2>&1; then
        bridge_audit_log daemon daemon_tick_deadline_exceeded daemon \
          --detail tick_id="$tick_id" \
          --detail last_step="$last_step" \
          --detail duration_seconds="$duration" \
          --detail deadline_seconds="$deadline" \
          --detail progress_age_seconds="$age" \
          --detail pid="$$" >/dev/null 2>&1 || true
      fi
      if command -v bridge_warn >/dev/null 2>&1; then
        bridge_warn "daemon-tick: WEDGE detected at step=$last_step (no progress for ${age}s >= deadline ${deadline}s) — self-aborting for OS-init restart (issue #1563)"
      fi
      return "$BRIDGE_DAEMON_TICK_WEDGE_RC"
    fi

    sleep "$poll"
  done
}
