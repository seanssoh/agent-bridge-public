# shellcheck shell=bash
# lib/bridge-reactive-rotate.sh — shared lock/cooldown + gate for reactive
# inference/picker 429 → preflighted token rotation (#2217 roadmap step 4).
#
# The daemon's `rate_limit` stall branch and scripts/picker-sweep.sh both react
# to a real provider 429 in a managed Claude pane. Today they rotate through
# DIFFERENT critical sections: the daemon's usage rotate (bridge-daemon.sh) and
# the picker-sweep local rotation.lock. A same-tick picker+daemon co-fire on the
# SAME rate-limit event could therefore rotate TWICE (burning two pool tokens for
# one event). This module is the SINGLE semantic "one rate-limit event" gate both
# callers route through:
#
#   * bridge_reactive_rotate_lock_acquire / _release — cross-process mkdir lock
#     (POSIX-atomic, macOS-portable; flock(1) is unavailable on stock macOS bash).
#     The lock dir is SHARED with picker-sweep so a daemon rotate and a picker
#     rotate serialize against each other.
#   * bridge_reactive_rotate_cooldown_active / _note — a cooldown window so a
#     rotate by EITHER caller suppresses a second rotate by the OTHER for the
#     cooldown period (the cross-process "already rotated this event" dedup).
#   * bridge_reactive_429_gate_passes — the strict reactive trigger gate
#     (amendment 3): CF/edge-adjacent and prose-grade 429s are rejected; only a
#     transport-qualified 429 fires. The daemon's bridge-stall.py classifier is
#     left AS-IS for retry/nudge — this stricter gate lives ONLY in the reactive
#     rotation trigger because a false-positive here costs managed-pool movement.
#   * bridge_reactive_rotate_agent_eligible — amendment 4 scope gate: only an
#     agent inside the rotation-eligible scope (BRIDGE_USAGE_ROTATION_AGENTS,
#     mirrored from the daemon) may DRIVE a rotation; an out-of-scope / non-managed
#     pane alerts only.
#   * bridge_reactive_rotate_feature_enabled — amendment 4 feature flag
#     (BRIDGE_REACTIVE_429_ROTATE_ENABLED, default 0 / off / canary-first).
#
# Footgun #11: no heredoc-stdin / here-string piped into command substitution.

# --- Paths -------------------------------------------------------------------
# The lock dir is SHARED with picker-sweep (scripts/picker-sweep.sh
# _psw_rotation_lock_dir) so the two callers contend for the SAME lock — the
# whole point of the dedup. Keep the default path in sync with picker-sweep.
bridge_reactive_rotate_lock_dir() {
  printf '%s' "${BRIDGE_REACTIVE_ROTATE_LOCK_DIR:-${BRIDGE_PICKER_SWEEP_ROTATION_LOCK_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state/picker-sweep/rotation.lock}}"
}

bridge_reactive_rotate_cooldown_file() {
  printf '%s' "${BRIDGE_REACTIVE_ROTATE_COOLDOWN_FILE:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state/reactive-rotate/cooldown.state}"
}

# --- Feature flag + scope (amendment 4) --------------------------------------
# Default OFF (canary-first). Returns 0 (enabled) only on an explicit "1".
bridge_reactive_rotate_feature_enabled() {
  [[ "${BRIDGE_REACTIVE_429_ROTATE_ENABLED:-0}" == "1" ]]
}

# bridge_reactive_rotate_agent_eligible <agent> <scope>
# <scope> mirrors the daemon's rotation-eligible scope (BRIDGE_USAGE_ROTATION_AGENTS
# → ${BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS:-static}). Semantics MUST mirror
# bridge-usage.py:_agent_rotation_eligible so the reactive path never re-points
# the managed pool from a non-managed pane:
#   ""        → no per-agent agent is eligible (controller sentinels only); a real
#               agent pane is NOT eligible → alert only.
#   "all"     → every managed agent is eligible.
#   "static"  → only static-roster agents are eligible.
#   csv       → membership test against the comma list.
bridge_reactive_rotate_agent_eligible() {
  local agent="$1"
  local scope="$2"
  [[ -n "$agent" ]] || return 1
  case "$scope" in
    "")
      return 1
      ;;
    all)
      return 0
      ;;
    static)
      bridge_agent_is_static "$agent" 2>/dev/null
      return $?
      ;;
    *)
      local item
      local IFS=','
      for item in $scope; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ "$item" == "$agent" ]] && return 0
      done
      return 1
      ;;
  esac
}

# --- Reactive gate (amendment 3) ---------------------------------------------
# bridge_reactive_429_gate_passes <excerpt>
# Returns 0 ONLY when the captured pane excerpt is a transport-qualified 429 that
# is NOT adjacent to a Cloudflare / cf-ray edge marker. This is STRICTER than the
# bridge-stall.py rate_limit classifier (which also matches prose-grade
# "429 too many requests" / "at capacity" sub-patterns and drives retry/nudge):
# the reactive ROTATION trigger must not fire on
#   * a Cloudflare edge throttle (only the /api/oauth/usage probe endpoint is
#     edge-throttled; an edge 429 is NOT the Anthropic-origin cap signal), or
#   * prose / narration / quoted text that merely mentions a rate limit.
# FP cost = managed-pool movement, so gate hard.
bridge_reactive_429_gate_passes() {
  local excerpt="$1"
  [[ -n "$excerpt" ]] || return 1

  # CF / edge exclusion: reject if the excerpt carries a Cloudflare or cf-ray
  # marker anywhere (case-insensitive). An edge-throttled response is not the
  # origin cap and must never rotate the managed pool.
  if printf '%s\n' "$excerpt" | grep -qiE 'cloudflare|cf-ray'; then
    return 1
  fi

  # Transport-qualified 429 ONLY: an http|status|error|code|api_error_status
  # qualifier adjacent to a bare \b429\b. This is the ONE transport-qualified
  # sub-pattern from bridge-stall.py rate_limit — NOT the prose-grade
  # "429 too many/rate/throttl" or "at capacity" / "hit your limit" siblings.
  if printf '%s\n' "$excerpt" | grep -qiE '(http[[:space:]/]?|status[[:space:]:=]+|error[[:space:]:=]+|code[[:space:]:=]+|api_error_status[[:space:]:=]?)[[:space:]]*\b429\b'; then
    return 0
  fi
  return 1
}

# --- Cross-process lock (mkdir-as-lock; mirrors picker-sweep) ----------------
_bridge_reactive_rotate_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

_bridge_reactive_rotate_lock_mtime() {
  local path="$1" mtime=0
  if [[ -e "$path" ]]; then
    mtime="$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || printf '0')"
  fi
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  printf '%s' "$mtime"
}

bridge_reactive_rotate_lock_acquire() {
  local lock_dir="" stale_secs="${BRIDGE_REACTIVE_ROTATE_LOCK_STALE_SECONDS:-${BRIDGE_PICKER_SWEEP_ROTATION_LOCK_STALE_SECONDS:-300}}"
  local owner_pid="" mtime=0 now=0 age=0
  lock_dir="$(bridge_reactive_rotate_lock_dir)"
  [[ "$stale_secs" =~ ^[0-9]+$ ]] || stale_secs=300

  mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || return 1

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock_dir/owner.pid" 2>/dev/null || true
    return 0
  fi

  owner_pid="$(cat "$lock_dir/owner.pid" 2>/dev/null || true)"
  mtime="$(_bridge_reactive_rotate_lock_mtime "$lock_dir")"
  now="$(date +%s)"
  age=$(( now - mtime ))

  if [[ -n "$owner_pid" ]] && _bridge_reactive_rotate_pid_alive "$owner_pid"; then
    return 1
  fi
  if (( age < stale_secs )); then
    return 1
  fi

  rm -rf "$lock_dir" 2>/dev/null || true
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock_dir/owner.pid" 2>/dev/null || true
    return 0
  fi
  return 1
}

bridge_reactive_rotate_lock_release() {
  local lock_dir="" current_owner=""
  lock_dir="$(bridge_reactive_rotate_lock_dir)"
  if [[ -f "$lock_dir/owner.pid" ]]; then
    current_owner="$(cat "$lock_dir/owner.pid" 2>/dev/null || true)"
    if [[ "$current_owner" != "$$" ]]; then
      return 0
    fi
  fi
  rm -rf "$lock_dir" 2>/dev/null || true
}

# --- Cross-process cooldown --------------------------------------------------
# A rotation by either caller writes a cooldown stamp; both callers consult it
# BEFORE rotating, so a second caller in the same window is suppressed. This is
# the "already rotated this event" dedup that complements the lock (the lock
# serializes concurrent attempts; the cooldown stops a back-to-back second
# attempt once the first has released).
bridge_reactive_rotate_cooldown_active() {
  local file="" now=0 next_ts=0
  local max_cap="${BRIDGE_REACTIVE_ROTATE_COOLDOWN_MAX_SECONDS:-3600}"
  [[ "$max_cap" =~ ^[0-9]+$ ]] || max_cap=3600
  file="$(bridge_reactive_rotate_cooldown_file)"
  [[ -f "$file" ]] || return 1
  # shellcheck disable=SC1090
  source "$file" 2>/dev/null || return 1
  next_ts="${REACTIVE_ROTATE_NEXT_TS:-0}"
  [[ "$next_ts" =~ ^[0-9]+$ ]] || { rm -f "$file" 2>/dev/null || true; return 1; }
  now="$(date +%s 2>/dev/null || true)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  # A window further out than the max cap is corrupt — never honor it.
  if (( next_ts > now + max_cap )); then
    rm -f "$file" 2>/dev/null || true
    return 1
  fi
  if (( now < next_ts )); then
    return 0
  fi
  rm -f "$file" 2>/dev/null || true
  return 1
}

bridge_reactive_rotate_cooldown_note() {
  local cooldown="${BRIDGE_REACTIVE_ROTATE_COOLDOWN_SECONDS:-300}"
  local file="" now=0 next_ts=0
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=300
  file="$(bridge_reactive_rotate_cooldown_file)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  now="$(date +%s 2>/dev/null || printf '0')"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  next_ts=$(( now + cooldown ))
  {
    printf 'REACTIVE_ROTATE_UPDATED_TS=%s\n' "$now"
    printf 'REACTIVE_ROTATE_NEXT_TS=%s\n' "$next_ts"
  } >"$file" 2>/dev/null || true
}
