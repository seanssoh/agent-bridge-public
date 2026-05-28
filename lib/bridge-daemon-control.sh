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
# guard when flock is missing. Emits the lock token on stdout that the
# caller passes back to _bridge_daemon_control_lock_release. Returns
# rc=1 on contention or unrecoverable error.
#
# Token format:
#   flock:<fd>:<lockfile>
#   mkdir:<lockdir>
_bridge_daemon_control_lock_acquire() {
  local lock_path="$1"
  local timeout_secs="${2:-30}"
  [[ -n "$lock_path" ]] || return 1
  local lock_parent
  lock_parent="$(dirname -- "$lock_path")"
  mkdir -p -- "$lock_parent" 2>/dev/null || return 1

  if command -v flock >/dev/null 2>&1; then
    # flock with a non-stdio fd. exec assigns the fd so the lock
    # persists past the function return; caller closes it via the
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
      printf 'flock:%s:%s' "$lock_fd" "$lock_path"
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
      printf 'mkdir:%s' "$lock_dir"
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
  local lock_token=""
  lock_token="$(_bridge_daemon_control_lock_acquire "$lock_path" 30 2>/dev/null || true)"
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

# bridge_daemon_ensure_singleton — acquire the PID-file flock, evict
# any stale-but-living bridge-daemon process, atomically claim the PID
# file, and emit the `daemon_started` audit row.
#
# Returns 0 on success (PID file claimed, audit row written).
# Returns 1 when the lock cannot be acquired within the timeout (means
# a concurrent ensure_singleton is already in flight — this process
# MUST NOT proceed; the canonical pattern is `bridge_die` at the
# caller's site to abort the daemon's main loop before it starts
# polling).
#
# Side effects on success:
#   - $BRIDGE_DAEMON_PID_FILE contains $$ atomically (tmp + rename).
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
# (silence-watchdog, queue-gateway-socket-listener). The brief accepts
# this — those children's lifetime is intentionally bounded by the
# daemon process (they exit when the daemon exits), so the lock is
# released no later than the daemon process exits. Any child that
# outlives the daemon is a separate bug class (orphan reaper) and
# would block the next daemon start until the orphan is reaped — that
# is the correct safety behavior for the daemon-singleton contract.
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
      bridge_warn "daemon-singleton: refused to spawn — another daemon holds $lock_path (non-blocking flock -n)"
      exec {lock_fd}>&- 2>/dev/null || true
      return 1
    fi
    lock_backend="flock"
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
        ;;
      mkdir)
        if [[ -n "${lock_dir:-}" && -d "$lock_dir" ]]; then
          rm -f "$lock_dir/owner.pid" 2>/dev/null || true
          rmdir "$lock_dir" 2>/dev/null || true
        fi
        ;;
    esac
  }

  # Inspect the PID file. If a bridge-daemon process is still alive
  # under the recorded PID, evict it with TERM + 10s grace + KILL.
  local existing_pid=""
  if [[ -f "$pid_file" ]]; then
    existing_pid="$(cat "$pid_file" 2>/dev/null | tr -dc '0-9' | head -c 16)"
  fi
  if [[ -n "$existing_pid" ]] && [[ "$existing_pid" != "$$" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    local existing_cmdline=""
    existing_cmdline="$(_bridge_daemon_singleton_cmdline "$existing_pid" 2>/dev/null || true)"
    if [[ "$existing_cmdline" == *"bridge-daemon.sh run"* ]]; then
      command -v bridge_audit_log >/dev/null 2>&1 \
        && bridge_audit_log daemon daemon_spawn_replacing daemon \
             --detail existing_pid="$existing_pid" \
             --detail new_pid="$$" \
             --detail wrapper="$wrapper" \
             --detail sudo_self="$sudo_self" >/dev/null 2>&1 || true
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

  # Emit the canonical `daemon_started` audit row. This is the row the
  # issue identified as missing on the sudo-wrapped spawn path; we now
  # emit it from cmd_run's entry, so every invocation path (cmd_start
  # fork, direct `bridge-daemon.sh run`, sudo-wrapped, systemd ExecStart)
  # produces exactly one row per live daemon process.
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

# bridge_daemon_self_check — periodic R3 visibility helper. Called
# from cmd_run's main loop on a throttled schedule. Compares $$ to the
# pid attribute of the most recent `daemon_started` audit row; mismatch
# → audit `daemon_pid_mismatch` + best-effort alert task (admin nudge
# is the canonical pathway; we use a structured audit row + warn so
# operator-visible dashboards surface the divergence).
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
  # If that recent pid is still alive, we have a genuine duplicate.
  local other_alive="false"
  if kill -0 "$latest_pid" 2>/dev/null; then
    other_alive="true"
  fi
  command -v bridge_audit_log >/dev/null 2>&1 \
    && bridge_audit_log daemon daemon_pid_mismatch daemon \
         --detail self_pid="$$" \
         --detail recent_audit_pid="$latest_pid" \
         --detail other_alive="$other_alive" >/dev/null 2>&1 || true
  bridge_warn "daemon-self-check: pid mismatch — self=$$, latest audit daemon_started pid=$latest_pid, other_alive=$other_alive"

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
        printf 'Daemon self-check detected another `daemon_started` audit row with a different PID.\n\n'
        printf 'self_pid: %s\n' "$$"
        printf 'recent_audit_pid: %s\n' "$latest_pid"
        printf 'other_alive: %s\n' "$other_alive"
        printf 'host: %s\n' "$(hostname 2>/dev/null || echo unknown)"
        printf 'ts: %s\n' "$(date -u +%FT%TZ 2>/dev/null || date)"
        printf '\n'
        printf 'Action: investigate via `ps -ef | grep bridge-daemon` and kill the orphan if necessary.\n'
        printf 'Source: lib/bridge-daemon-control.sh bridge_daemon_self_check (issue #1276 Lane D R3).\n'
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
