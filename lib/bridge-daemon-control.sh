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
#   ok
#   skipped-non-linux
#   skipped-daemon-not-running
#   skipped-daemon-already-has-group
#   manual-required-sudoers              (sudo -n returned a sudoers-class rc)
#   manual-required-sudo-refresh-no-gid  (sudo invoke succeeded but new daemon's
#                                         Groups still lacks the target GID)
#   failed-restart                       (restart cmd returned non-zero)
#   failed-timeout                       (new daemon pid never appeared)
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
_bridge_daemon_control_daemon_has_gid() {
  local target_gid="$1"
  [[ -n "$target_gid" ]] || return 2
  local pid
  pid="$(bridge_daemon_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 2
  local groups_output
  groups_output="$(_bridge_daemon_control_proc_groups "$pid" 2>/dev/null)" || return 2
  if printf '%s\n' "$groups_output" | grep -Fxq -- "$target_gid"; then
    return 0
  fi
  return 1
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

  # Step 7: poll new PID file for daemon up. The restart path exits as
  # soon as the new daemon forks, but bridge_daemon_pid resolves via the
  # cmdline-verified resolver so we wait until the new pid is observable.
  local waited=0
  local new_pid=""
  while (( waited < 10 )); do
    new_pid="$(bridge_daemon_pid 2>/dev/null || true)"
    if [[ -n "$new_pid" ]] && kill -0 "$new_pid" 2>/dev/null \
        && [[ "$new_pid" != "$daemon_pid" ]]; then
      break
    fi
    sleep 1
    waited=$(( waited + 1 ))
    new_pid=""
  done
  if [[ -z "$new_pid" ]]; then
    bridge_warn "daemon-refresh: new daemon pid did not appear within 10s"
    printf 'failed-timeout'
    return 1
  fi

  # Step 8: verify new daemon's Groups contains the target GID. If PAM
  # didn't refresh (unusual sudo configuration), flag manual-required so
  # the operator sees the diagnostic.
  if ! _bridge_daemon_control_daemon_has_gid "$target_gid"; then
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
