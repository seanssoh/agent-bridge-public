#!/usr/bin/env bash
# bridge-daemon-liveness.sh — issue #265 proposal D
#
# OS-level liveness watcher for the Agent Bridge daemon. Designed to run
# OUTSIDE the daemon process tree (under launchd on macOS or systemd .timer
# on Linux) so a hung daemon main loop cannot prevent the watcher from
# observing it.
#
# Behavior:
#   1. Read mtime of $BRIDGE_STATE_DIR/daemon.heartbeat (touched by
#      bridge-daemon.sh::cmd_run on every BRIDGE_DAEMON_HEARTBEAT_SECONDS
#      tick — see commit that added the printf next to bridge_audit_log
#      daemon_tick).
#   2. If the file does not exist, do nothing — fresh install or daemon
#      not yet started; let the daemon's normal start path establish the
#      baseline.
#   3. If mtime is younger than BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS
#      (default 600s = 10 min), do nothing.
#   4. If stale AND the daemon pid is recorded AND alive, AND the cooldown
#      since the last restart attempt has elapsed, run
#      `bridge-daemon.sh stop --force && bridge-daemon.sh start`. Cooldown prevents
#      a broken daemon from triggering a restart-loop every minute.
#   5. If stale but the daemon is not running, do nothing — the normal
#      start path (launchd KeepAlive / systemd Restart=always) will bring
#      it back; the liveness watcher only addresses the silent-hang case
#      where the process is alive but the loop has frozen.
#
# Issue #1973 (Track C) — gateway-stall detection. The original watcher only
# recovered a pid-alive-but-heartbeat-frozen daemon. The #1973 incident was a
# different class: the heartbeat KEPT advancing (the main loop ticked) but the
# file-transport queue gateway DRAIN stalled, so `agb claim`/`agb done` hard-
# timed-out for ~1.5h while every health check said "running". A heartbeat
# watcher cannot see that. We add a second restart trigger:
#
#   6. If the gateway has pending OR working requests whose OLDEST age exceeds
#      BRIDGE_DAEMON_GATEWAY_STALL_SECONDS AND that oldest age STAYS above the
#      threshold across one poll (the prior observation, persisted to disk),
#      AND the daemon pid is alive, restart the daemon (same cooldown gate as
#      the heartbeat path). The cross-poll requirement plus the "must have OLD
#      pending/working requests" requirement is what keeps an *idle* daemon
#      (zero queued requests, or a brief in-flight request) from ever being
#      restarted — a false restart would itself be an outage.
#
# The gateway state comes from Track A's `bridge-queue-gateway.py status --json`
# (pending/working counts + oldest ages). We consume it through a configurable
# command (BRIDGE_DAEMON_GATEWAY_STATUS_CMD) so this watcher targets A's
# contract without re-implementing it, and so the smoke can stub it.
#
# Before any restart (heartbeat OR gateway) the watcher writes a recovery
# marker (BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE) so the freshly-started daemon
# knows to run a one-shot re-nudge pass for idle agents whose queued tasks were
# stranded by the stall (see bridge-daemon.sh cmd_run consumption).
#
# Audit:
#   Writes one of `daemon_liveness_ok`, `daemon_liveness_skip_no_baseline`,
#   `daemon_liveness_skip_not_running`, `daemon_liveness_skip_cooldown`,
#   `daemon_liveness_restart_attempt`, `daemon_liveness_restart_failed`,
#   `daemon_liveness_gateway_stall_observed`, or
#   `daemon_liveness_gateway_stall_restart` to $BRIDGE_AUDIT_LOG when
#   bridge-audit.py is invokable. Failures to write audit are non-fatal — the
#   watcher's job is restarting, not logging.
#
# Environment:
#   BRIDGE_HOME                                  default $HOME/.agent-bridge
#   BRIDGE_STATE_DIR                             default $BRIDGE_HOME/state
#   BRIDGE_AUDIT_LOG                             default $BRIDGE_HOME/logs/audit.jsonl
#   BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS     default 600
#   BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS      default 600
#   BRIDGE_DAEMON_HEARTBEAT_FILE                 default $BRIDGE_STATE_DIR/daemon.heartbeat
#   BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE         default $BRIDGE_STATE_DIR/daemon-liveness-cooldown.ts
#   BRIDGE_DAEMON_LIVENESS_DRY_RUN               set to 1 to log the decision but skip the actual stop/start
#   BRIDGE_DAEMON_GATEWAY_STALL_SECONDS          default 300; oldest pending/working age that counts as a stall
#   BRIDGE_DAEMON_GATEWAY_STATUS_CMD             override the `status --json` command (smoke stub seam)
#   BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE       default $BRIDGE_STATE_DIR/daemon-gateway-stall.ts (cross-poll witness)
#   BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE          default $BRIDGE_STATE_DIR/daemon-recovery-renudge.env (recovery marker)
#   BRIDGE_DAEMON_GATEWAY_STALL_DISABLE          set to 1 to skip gateway-stall detection entirely (heartbeat-only)
#
# Issue #2207 (never-die wave Track C) — out-of-process token lifeline. The
# daemon owns the token lifeline (recover-due quota recovery + periodic token-
# sync). When the daemon is DOWN/wedged, that lifeline stops and a quota-limited
# agent stays disabled until the daemon returns — a fleet-wide quota cascade.
# This OS-supervised watcher already survives a daemon-down window, so we fold a
# bounded emergency token-lifeline tick into its stale-heartbeat return paths:
# delegate recover-due + sync (+ the gated operator-global sync) to bridge-auth.sh
# so the fleet degrades gracefully instead of stranding on dead tokens. V1 scope
# is recover-due + propagation ONLY — NO rotation, NO usage monitor, NO active-
# token swap (all daemon-coupled). The watcher is a DRIVER only — every credential
# mutation stays inside bridge-auth.py (registry_lock + opt-in gates + root-fail-
# closed). Envs:
#   BRIDGE_DAEMON_TOKEN_LIFELINE_ENABLED         default 1 (kill-switch; set 0 to disable)
#   BRIDGE_DAEMON_TOKEN_LIFELINE_STALE_SECONDS   default = BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS (600)
#   BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS default 300 (a stale host runs the lifeline at most once per interval)
#   BRIDGE_DAEMON_TOKEN_LIFELINE_STATE_FILE      default $BRIDGE_STATE_DIR/daemon/token-lifeline.ts (interval throttle witness)
#   BRIDGE_DAEMON_TOKEN_LIFELINE_TIMEOUT_SECONDS default 60 (per bridge-auth.sh call ceiling)

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
: "${BRIDGE_STATE_DIR:=$BRIDGE_HOME/state}"
: "${BRIDGE_AUDIT_LOG:=$BRIDGE_HOME/logs/audit.jsonl}"
: "${BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS:=600}"
: "${BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS:=600}"
: "${BRIDGE_DAEMON_HEARTBEAT_FILE:=$BRIDGE_STATE_DIR/daemon.heartbeat}"
: "${BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE:=$BRIDGE_STATE_DIR/daemon-liveness-cooldown.ts}"
: "${BRIDGE_DAEMON_LIVENESS_DRY_RUN:=0}"
: "${BRIDGE_DAEMON_GATEWAY_STALL_SECONDS:=300}"
: "${BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE:=$BRIDGE_STATE_DIR/daemon-gateway-stall.ts}"
# Cross-poll witness identity tolerance (seconds). The witness stores the
# oldest stalled request's approximate BIRTH time (observation_ts - oldest_age),
# which is stable across polls for the SAME request. A second poll only counts
# as a true cross-poll witness when the current oldest-request birth matches the
# stored birth within this tolerance (absorbs age-measurement jitter). A birth
# outside tolerance means the prior old request drained / a different request is
# now oldest, so the witness resets to a fresh first observation rather than
# restarting on a request seen only once (review fix: same-request witness).
: "${BRIDGE_DAEMON_GATEWAY_STALL_WITNESS_TOLERANCE_SECONDS:=10}"
: "${BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE:=$BRIDGE_STATE_DIR/daemon-recovery-renudge.env}"
: "${BRIDGE_DAEMON_GATEWAY_STALL_DISABLE:=0}"
# Issue #2207 (never-die Track C) — out-of-process token lifeline knobs. The
# stale threshold defaults to the SAME signal the restart trigger uses
# (BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS) so the lifeline fires on exactly the
# daemon-down windows the watcher already detects. The interval throttle is
# SEPARATE from the restart cooldown so a refused/cooldown-suppressed restart does
# not also suppress token recovery — the lifeline runs on its own cadence.
: "${BRIDGE_DAEMON_TOKEN_LIFELINE_ENABLED:=1}"
: "${BRIDGE_DAEMON_TOKEN_LIFELINE_STALE_SECONDS:=$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS}"
: "${BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS:=300}"
: "${BRIDGE_DAEMON_TOKEN_LIFELINE_STATE_FILE:=$BRIDGE_STATE_DIR/daemon/token-lifeline.ts}"
: "${BRIDGE_DAEMON_TOKEN_LIFELINE_TIMEOUT_SECONDS:=60}"
# bridge-auth.sh path + the agent scope the daemon syncs (mirrors the daemon's
# BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS default of `static`). BRIDGE_BASH_BIN is the
# bash the watcher re-invokes bridge-auth.sh under (the daemon sets it; default
# to the running interpreter, then `bash` on PATH).
: "${BRIDGE_AUTH_SH:=$REPO_ROOT/bridge-auth.sh}"
: "${BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS:=static}"
: "${BRIDGE_BASH_BIN:=${BASH:-bash}}"
# Issue #2055: the upgrade's durable quiesce-intent marker. bridge-upgrade.sh
# writes it (recording the upgrade pid + platform/label) when it disables the
# daemon job for the #1820 reconcile window, and clears it on a successful
# restore-enable. Its presence — with a DEAD recorded upgrade pid — is how this
# watcher tells an interrupted-upgrade disable (recoverable) from an operator
# `agb daemon stop` (stay down). Must match bridge-upgrade.sh's default path.
: "${BRIDGE_UPGRADE_QUIESCE_MARKER_FILE:=$BRIDGE_STATE_DIR/upgrade/daemon-quiesce.intent}"
# Issue #2064 r3 (Finding 4): bounded stale-marker AGE ceiling. The marker records
# its write time (BRIDGE_QUIESCE_TS). A legitimate quiesce window is seconds-to-
# minutes (the #1820 reconcile), so a marker older than this ceiling is, by
# construction, an ORPHAN — the upgrade that wrote it is long gone even if its pid
# now resolves to a live (reused / unrelated) process. Treat such a marker as
# reapable regardless of pid liveness, as defense-in-depth behind the start-identity
# check below. Default 3600s (1h) — wildly beyond any real reconcile window.
: "${BRIDGE_DAEMON_QUIESCE_MAX_AGE_SECONDS:=3600}"

# Sanitize numeric envs — fall back to defaults on garbage so a typo in a
# launchd EnvironmentVariables block can't disable the watcher.
[[ "$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]] || BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS=600
[[ "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]  || BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS=600
[[ "$BRIDGE_DAEMON_GATEWAY_STALL_SECONDS" =~ ^[0-9]+$ ]]      || BRIDGE_DAEMON_GATEWAY_STALL_SECONDS=300
[[ "$BRIDGE_DAEMON_QUIESCE_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]]    || BRIDGE_DAEMON_QUIESCE_MAX_AGE_SECONDS=3600
# Issue #2207: a typo in a launchd EnvironmentVariables block must not silently
# break the token lifeline's throttle/timeout into a hot-loop or an unbounded call.
[[ "$BRIDGE_DAEMON_TOKEN_LIFELINE_STALE_SECONDS" =~ ^[0-9]+$ ]]    || BRIDGE_DAEMON_TOKEN_LIFELINE_STALE_SECONDS="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
[[ "$BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS=300
[[ "$BRIDGE_DAEMON_TOKEN_LIFELINE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]  || BRIDGE_DAEMON_TOKEN_LIFELINE_TIMEOUT_SECONDS=60

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
DAEMON_PID_FILE="${BRIDGE_DAEMON_PID_FILE:-$BRIDGE_STATE_DIR/daemon.pid}"

now_ts() { date +%s; }

file_mtime() {
  # macOS / BSD: stat -f %m. Linux / GNU coreutils: stat -c %Y.
  local f="$1"
  local mtime
  if mtime="$(stat -f %m "$f" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi
  if mtime="$(stat -c %Y "$f" 2>/dev/null)"; then
    printf '%s\n' "$mtime"
    return 0
  fi
  return 1
}

emit_audit() {
  # Best-effort JSON-line audit. We deliberately do not source bridge-lib.sh
  # (heavy: pulls in tmux/queue/state modules) just for one log line — the
  # python script is small and standalone.
  local action="$1"
  shift || true
  local audit_py="$REPO_ROOT/bridge-audit.py"
  [[ -x "$audit_py" || -f "$audit_py" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$BRIDGE_AUDIT_LOG")" 2>/dev/null || true
  python3 "$audit_py" write \
    --file "$BRIDGE_AUDIT_LOG" \
    --actor daemon_liveness \
    --action "$action" \
    --target daemon \
    "$@" >/dev/null 2>&1 || true
}

daemon_pid_alive() {
  local pid
  [[ -f "$DAEMON_PID_FILE" ]] || return 1
  pid="$(head -n1 "$DAEMON_PID_FILE" 2>/dev/null | tr -d '[:space:]')"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

cooldown_active() {
  # Returns 0 (true) when last restart attempt is within cooldown window.
  local last_ts now
  [[ -f "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" ]] || return 1
  last_ts="$(tr -d '[:space:]' <"$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" 2>/dev/null)"
  [[ "$last_ts" =~ ^[0-9]+$ ]] || return 1
  now="$(now_ts)"
  (( now - last_ts < BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS ))
}

record_cooldown() {
  mkdir -p "$(dirname "$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE")" 2>/dev/null || true
  printf '%s\n' "$(now_ts)" 2>/dev/null >"$BRIDGE_DAEMON_LIVENESS_COOLDOWN_FILE" || true
}

# ── Issue #2055: interrupted-upgrade discriminator ────────────────────────────
#
# A DISABLED daemon job is normally an operator `agb daemon stop` and the #2040
# recovery FAIL-CLOSED skips it (★ never fight an operator stop). The one
# exception: an upgrade that was KILLED (SIGKILL / power-loss) between its
# quiesce-disable and its restore-enable also leaves the job disabled — and the
# operator never intended that down-state. bridge-upgrade.sh brackets its quiesce
# window with a durable marker (BRIDGE_UPGRADE_QUIESCE_MARKER_FILE) recording the
# upgrade pid; it clears the marker on a successful restore OR a deliberate
# fail-closed abort. So the marker is present ONLY for an interrupted upgrade.
#
# This returns 0 (recover: the disabled job is an interrupted-upgrade disable)
# ONLY when ALL hold:
#   - the marker file exists, and
#   - it records a numeric upgrade pid, and
#   - that pid is NOT alive (the upgrade is dead — an in-flight upgrade with a
#     LIVE pid is doing its own restore; we must not race it).
# Any other case (no marker / unreadable pid / pid still alive) returns 1 →
# the caller keeps the #2040 fail-closed skip. Sets QUIESCE_MARKER_PID /
# QUIESCE_MARKER_PLATFORM for the caller's audit detail. Pure read; no mutation.

# Issue #2064 r3 (Finding 4): recompute a live pid's START-IDENTITY token in the
# SAME shape bridge-upgrade.sh records at marker-write, so the watcher can prove a
# live pid is (or is NOT) the same process that wrote the marker. The kernel never
# reuses a (pid, start-time) pair within a boot, so a token MISMATCH is definitive
# proof the original upgrade is gone and this pid was REUSED. Empty when no source
# is readable. Mirrors _bridge_upgrade_pid_start_identity in bridge-upgrade.sh.
quiesce_pid_start_identity() {
  local pid="$1" tok=""
  [[ "$pid" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  if [[ -r "/proc/$pid/stat" ]]; then
    # Anchor on the LAST ')' (comm may contain spaces and ')'); starttime (field 22)
    # is the 20th whitespace token after the closing paren. Mirrors
    # _bridge_upgrade_pid_start_identity in bridge-upgrade.sh exactly.
    tok="$(awk '{ p=0; for (i=length($0); i>=1; i--) if (substr($0,i,1)==")") { p=i; break }
                 if (p==0) next; s=substr($0,p+1); n=split(s,a," "); if (n>=20) print a[20] }' \
      "/proc/$pid/stat" 2>/dev/null)" || tok=""
    if [[ -n "$tok" ]]; then printf 'linux-starttime:%s' "$tok"; return 0; fi
  fi
  if command -v ps >/dev/null 2>&1; then
    # Collapse ALL whitespace to '_' then hard-restrict to [A-Za-z0-9:_] via `tr -cd`,
    # IDENTICALLY to _bridge_upgrade_pid_start_identity at write time — a marker
    # recorded as `ps-lstart:Mon_Jun_24_...` must recompute to the same string here,
    # and the allowlist guarantees the token is a clean single shell word (no quote /
    # metacharacter) so the SOURCEABLE marker reads back intact.
    tok="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//' -e 's/ /_/g' | tr -cd 'A-Za-z0-9:_')" || tok=""
    if [[ -n "$tok" ]]; then printf 'ps-lstart:%s' "$tok"; return 0; fi
  fi
  printf ''
  return 0
}

# Issue #2064 r3 (Finding 4): age of the quiesce marker in seconds (now - the
# marker's recorded BRIDGE_QUIESCE_TS), or empty when the ts is missing/unparseable.
# Used by the bounded stale-marker fallback: a marker older than the ceiling is an
# orphan regardless of pid liveness. ISO-8601 UTC ("...Z") is parsed via `date -d`
# (GNU) / `date -j -f` (BSD/mac); on a host where neither parses it we return empty
# and the age fallback simply does not trigger (the identity check still guards).
quiesce_marker_age_seconds() {
  local marker="$BRIDGE_UPGRADE_QUIESCE_MARKER_FILE"
  [[ -f "$marker" ]] || { printf ''; return 0; }
  local ts epoch now
  ts="$(
    # shellcheck disable=SC1090
    source "$marker" 2>/dev/null
    printf '%s' "${BRIDGE_QUIESCE_TS:-}"
  )"
  [[ -n "$ts" ]] || { printf ''; return 0; }
  epoch="$(date -u -d "$ts" +%s 2>/dev/null)" \
    || epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)" \
    || epoch=""
  [[ "$epoch" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  now="$(now_ts)"
  printf '%s' "$(( now - epoch ))"
  return 0
}

# Issue #2064 r3 (Finding 4): is the marker's recorded upgrade pid a GENUINE live
# in-flight upgrade? Returns 0 (defer — a real upgrade holds the marker) ONLY when
# ALL hold:
#   - the marker records a numeric pid, and
#   - that pid is alive (kill -0), and
#   - EITHER the marker has no start-identity token (legacy marker → fall back to the
#     conservative bare-pid defer so a real in-flight upgrade is never reaped), OR
#     the live pid's recomputed start-identity MATCHES the marker's (same process),
#     and
#   - the marker is NOT older than the bounded age ceiling (a marker that has sat
#     past any sane reconcile window is an orphan even if its pid happens to be live).
# Returns 1 (reap — orphaned / reused-pid / stale) otherwise. Pure read; no mutation.
quiesce_live_in_flight() {
  local marker="$BRIDGE_UPGRADE_QUIESCE_MARKER_FILE"
  [[ -f "$marker" ]] || return 1
  local pid psid age live_psid
  pid="$(
    # shellcheck disable=SC1090
    source "$marker" 2>/dev/null
    printf '%s' "${BRIDGE_QUIESCE_UPGRADE_PID:-}"
  )"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Bounded age fallback (defense-in-depth): a marker older than the ceiling is an
  # orphan even if the pid resolves to a live (reused / unrelated) process.
  age="$(quiesce_marker_age_seconds)"
  if [[ "$age" =~ ^[0-9]+$ ]] && (( age > BRIDGE_DAEMON_QUIESCE_MAX_AGE_SECONDS )); then
    return 1
  fi
  # Start-identity check: a recorded token that does NOT match the live pid's
  # current identity is definitive proof of pid REUSE → reap, do not defer.
  psid="$(
    # shellcheck disable=SC1090
    source "$marker" 2>/dev/null
    printf '%s' "${BRIDGE_QUIESCE_UPGRADE_PSID:-}"
  )"
  if [[ -n "$psid" ]]; then
    live_psid="$(quiesce_pid_start_identity "$pid")"
    # Only a CONFIRMED mismatch reaps. If we cannot recompute the live identity
    # (empty token on this host), fall back to the bare-pid defer rather than reap a
    # possibly-real upgrade on an unverifiable identity.
    if [[ -n "$live_psid" && "$live_psid" != "$psid" ]]; then
      return 1
    fi
  fi
  return 0
}

QUIESCE_MARKER_PID=""
QUIESCE_MARKER_PLATFORM=""
QUIESCE_MARKER_REASON=""

# ── Issue #2205: per-path non-operator-disable marker proof ───────────────────
#
# #2055 closed the interrupted-UPGRADE disable hole with a durable quiesce marker.
# #2205 generalizes that marker into the proof contract for ANY first-party
# non-operator disable: a recoverable disabled state needs a durable marker the
# disabling code wrote IMMEDIATELY BEFORE the disable, recording platform, target,
# a `reason` enum, the writer pid + start-identity, and a timestamp. The watcher
# re-enables a disabled job ONLY when the marker platform+target match the job it
# is about to recover, the marker parses, the writer is dead/reused/over-age (the
# #2064 identity/age teeth), AND the disabled probe + cooldown/upgrade gates allow.
# A missing marker, a parse failure, a target MISMATCH, or a LIVE writer with a
# matching identity ⇒ fail closed (skip + audit) — the operator-stop-outranks
# invariant is sacred, so an unprovable disabled-drift always stays down.
#
# `interrupted_upgrade` (the upgrade quiesce) is one reason value; a marker written
# before #2205 carries no BRIDGE_QUIESCE_REASON field and defaults to it, so the
# #2055 path is preserved exactly. Sets QUIESCE_MARKER_PID / QUIESCE_MARKER_PLATFORM
# / QUIESCE_MARKER_REASON for the caller's audit detail. Pure read; no mutation.
#
# $1=expected platform (launchd|systemd) — the platform of the job being recovered.
# $2=expected target (the launchd label / systemd service) — the marker must name
#    THIS job, so a marker recorded for a DIFFERENT target can never re-enable this
#    one (cross-target confusion guard the design mandates).
non_operator_disable_marker() {
  local want_platform="$1" want_target="$2"
  QUIESCE_MARKER_PID=""
  QUIESCE_MARKER_PLATFORM=""
  QUIESCE_MARKER_REASON=""
  local marker="$BRIDGE_UPGRADE_QUIESCE_MARKER_FILE"
  [[ -f "$marker" ]] || return 1
  # ★ Schema validation BEFORE source (codex r2): every non-blank, non-comment line
  # must be a recognized `BRIDGE_QUIESCE_<KEY>=...` assignment from the marker's own
  # vocabulary. A line that sources cleanly (rc=0) but is OFF-SCHEMA — an unexpected
  # key, an arbitrary sourceable command, a corrupted half-line — is NOT this
  # marker's content and so is NOT proof of a first-party disable. Reject the whole
  # marker (fail closed) rather than trust the recognized early fields beside it.
  # The allowlist is the exact key set the writer emits (bridge-upgrade.sh
  # _bridge_upgrade_write_quiesce_marker); a future key must be added here in lock-
  # step (an unknown key fails closed until the watcher learns it — the safe default).
  local line stripped
  while IFS= read -r line || [[ -n "$line" ]]; do
    stripped="${line#"${line%%[![:space:]]*}"}"   # ltrim
    [[ -z "$stripped" || "$stripped" == \#* ]] && continue
    case "$stripped" in
      BRIDGE_QUIESCE_UPGRADE_PID=*|BRIDGE_QUIESCE_UPGRADE_PSID=*|\
      BRIDGE_QUIESCE_UPGRADE_UID=*|BRIDGE_QUIESCE_PLATFORM=*|\
      BRIDGE_QUIESCE_TARGET=*|BRIDGE_QUIESCE_REASON=*|\
      BRIDGE_QUIESCE_TS=*|BRIDGE_QUIESCE_VERSION=*) ;;
      *) return 1 ;;   # off-schema line ⇒ not a trustworthy marker ⇒ fail closed
    esac
  done <"$marker"
  # ★ Checked single-source parse (codex r1): the marker is SOURCED, so malformed
  # shell content (a truncated/corrupt marker, a half-written line) must FAIL CLOSED
  # — never treat an unparseable marker as proof of a first-party disable. We source
  # ONCE inside a subshell that `exit 1`s when `source` errors, emit the four fields
  # NUL-free on three lines, and reject the whole marker on a non-zero subshell rc.
  # (The prior per-field sources each ignored `source`'s status, so a marker with
  # valid pid/platform/target on its early lines followed by garbage could still
  # reach `launchctl enable` — the operator-stop hazard this closes.)
  local record pid platform target reason
  record="$(
    # shellcheck disable=SC1090
    source "$marker" 2>/dev/null || exit 1
    printf '%s\n%s\n%s\n%s\n' \
      "${BRIDGE_QUIESCE_UPGRADE_PID:-}" \
      "${BRIDGE_QUIESCE_PLATFORM:-}" \
      "${BRIDGE_QUIESCE_TARGET:-}" \
      "${BRIDGE_QUIESCE_REASON:-interrupted_upgrade}"
  )" || return 1
  pid="$(printf '%s' "$record" | sed -n '1p')"
  platform="$(printf '%s' "$record" | sed -n '2p')"
  target="$(printf '%s' "$record" | sed -n '3p')"
  reason="$(printf '%s' "$record" | sed -n '4p')"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # ★ Platform+target match: the marker must name the EXACT job we are about to
  # re-enable. A marker recorded on the other platform, or for a different launchd
  # label / systemd service, is NOT proof THIS job's disable was first-party — fail
  # closed (the operator-stop default holds for the job in front of us).
  [[ "$platform" == "$want_platform" ]] || return 1
  [[ "$target" == "$want_target" ]] || return 1
  # A GENUINELY-LIVE in-flight writer is mid-flight running its OWN restore — defer
  # to it (do not race), so this is NOT a recoverable disable. #2064 r3 (Finding 4):
  # "genuinely live" is identity-verified — a marker whose pid was REUSED by an
  # unrelated live process (the writer was SIGKILL'd) or that has sat past the
  # bounded age ceiling is an ORPHAN we MUST recover, not defer to forever.
  if quiesce_live_in_flight; then
    return 1
  fi
  QUIESCE_MARKER_PID="$pid"
  QUIESCE_MARKER_PLATFORM="$platform"
  QUIESCE_MARKER_REASON="$reason"
  return 0
}

# Back-compat shim: the launchd recovery historically called
# `interrupted_upgrade_quiesce` (no args — it implicitly meant a launchd marker).
# #2205 routes that through the generalized proof with the launchd platform + the
# resolved label as the expected target. Kept as a thin wrapper so the call site
# reads clearly and the #2055 smoke's name-presence guard still matches.
interrupted_upgrade_quiesce() {
  non_operator_disable_marker launchd "$REBOOTSTRAP_LABEL"
}

# Clear the quiesce-intent marker after the watcher has CONFIRMED a successful
# recovery of an interrupted upgrade (#2064 r2 fix). The marker must be consumed
# ONLY after the disabled→enabled transition is proven (re-enable verified), NOT
# before/around the best-effort re-enable. If we cleared it eagerly and the
# `launchctl enable` (or systemd start) then failed, the job would stay
# disabled/inactive with the marker gone — the next poll would fall back to the
# fail-closed skip_disabled and the daemon would stay silently down forever
# (exactly the #2055 hole #2064 closes). So: keep the marker on a FAILED re-enable
# (the next poll retries the interrupted-upgrade path); consume it only once the
# job is no longer disabled (the discriminator has served its purpose — any
# remaining unloaded recovery is the marker-independent #2040 standing path). A
# lingering marker on an enabled job is itself a hazard (a later operator
# `agb daemon stop` could be mis-read as an interrupted upgrade), so we DO clear
# on a confirmed enable even if the subsequent bootstrap is cooldown-deferred —
# at that point the #2040 enabled-but-unloaded path recovers without the marker.
# Best-effort.
clear_quiesce_marker() {
  rm -f "$BRIDGE_UPGRADE_QUIESCE_MARKER_FILE" 2>/dev/null || true
}

# Issue #2064 r2 (Finding 2): is an upgrade GENUINELY in flight right now? Returns
# 0 only when the quiesce marker exists, records a numeric upgrade pid, that pid is
# STILL ALIVE, AND (#2064 r3, Finding 4) the live pid's start-identity MATCHES the
# marker's recorded identity and the marker is not past the bounded age ceiling.
# This is the "do not race a live upgrade" guard the systemd liveness recovery uses
# to DEFER while a legitimate upgrade holds the daemon down inside its #1820
# reconcile window — mirrors the launchd I3 LIVE-pid defer. A DEAD-pid marker
# (orphaned by a SIGKILL'd upgrade), a REUSED-pid marker (the SIGKILL'd upgrade's
# pid now resolves to an unrelated long-lived process — identity mismatch), a stale
# (over-age) marker, or no marker returns 1 so the normal recovery proceeds and
# reaps the interrupted upgrade instead of deferring to a non-upgrade forever. The
# identity/age teeth live in the shared quiesce_live_in_flight helper above. Pure read.
live_upgrade_quiesce_in_flight() {
  quiesce_live_in_flight
}

# ── Issue #2040: standing recovery for an enabled-but-unloaded daemon ──────────
#
# The daemon can end up ENABLED-BUT-UNLOADED via ANY quiesce/restart path (a lost
# async-bootout race during upgrade, an ensure_singleton restart storm, a
# watchdog-disable that never re-bootstrapped). In that state launchd's
# KeepAlive / systemd's Restart= is MOOT — there is no loaded job to supervise —
# so the daemon stays down indefinitely (~64h observed). cron self-heal is
# impossible (cron dispatch needs the daemon). This INDEPENDENT liveness watcher
# (its own launchd job / systemd timer, survives the daemon's death) is the only
# viable recovery: when the heartbeat is stale AND no daemon pid is alive AND the
# job is PROVEN should-be-running-but-unloaded, re-bootstrap it (bounded +
# cooldown-gated + audited). It must NEVER fight an operator `agb daemon stop` /
# an intentionally-disabled job — the durable "should be running" signal is the
# launchd `disabled=false` + plist/config presence, or systemd `is-enabled`.

# Resolve the launchd uid for the current process. Empty on failure.
rebootstrap_launchd_uid() {
  id -u 2>/dev/null || printf '%s' "${UID:-}"
}

# Read the installer-written launchagent.config to learn the label + plist. Sets
# REBOOTSTRAP_LABEL / REBOOTSTRAP_PLIST globals. Returns 1 when the config is
# absent or the label cannot be resolved (→ not a launchd-managed install we can
# recover). Self-contained — the watcher deliberately does not source bridge-lib.
REBOOTSTRAP_LABEL=""
REBOOTSTRAP_PLIST=""
rebootstrap_launchd_resolve() {
  REBOOTSTRAP_LABEL=""
  REBOOTSTRAP_PLIST=""
  local config_path="${BRIDGE_LAUNCHAGENT_CONFIG_FILE:-$BRIDGE_STATE_DIR/launchagent.config}"
  [[ -f "$config_path" ]] || return 1
  local label plist
  label="$(
    # shellcheck disable=SC1090
    source "$config_path" 2>/dev/null
    printf '%s' "${BRIDGE_LAUNCHAGENT_LABEL:-}"
  )"
  plist="$(
    # shellcheck disable=SC1090
    source "$config_path" 2>/dev/null
    printf '%s' "${BRIDGE_LAUNCHAGENT_PLIST:-}"
  )"
  [[ -n "$label" ]] || return 1
  REBOOTSTRAP_LABEL="$label"
  REBOOTSTRAP_PLIST="$plist"
  return 0
}

# True (returns 0) when launchd has a LOADED job for gui/$uid/$label. `launchctl
# print` exits non-zero when the job is not loaded — the exit code is the signal.
rebootstrap_launchd_job_loaded() {
  local uid="$1" label="$2"
  launchctl print "gui/${uid}/${label}" >/dev/null 2>&1
}

# Report the launchd disabled-state for $label. `launchctl print-disabled
# gui/$uid` emits a label line whose value is the disabled flag. Modern macOS
# prints `"<label>" => disabled` / `"<label>" => enabled`; older releases print
# `=> true` (disabled) / `=> false` (enabled). The grep below matches BOTH the
# real `disabled` word and the legacy `true` (defensive). Prints one of:
#   disabled — the label line says `=> disabled` (or legacy `=> true`)
#   enabled  — the label line says `=> enabled` (or legacy `=> false`; or, absent
#              any line, the default is enabled — launchd only lists labels with
#              an explicit override)
#   unknown  — `print-disabled` itself failed (domain unreachable / unsupported)
# We FAIL CLOSED on `unknown`: the caller skips recovery, because we cannot prove
# the job is NOT operator-disabled, and the operator-stop guarantee outranks
# auto-recovery (★ never fight an `agb daemon stop`).
rebootstrap_launchd_disabled_state() {
  local uid="$1" label="$2" out
  out="$(launchctl print-disabled "gui/${uid}" 2>/dev/null)" || { printf 'unknown'; return 0; }
  if printf '%s\n' "$out" | grep -E "\"${label}\"[[:space:]]*=>[[:space:]]*(true|disabled)" >/dev/null 2>&1; then
    printf 'disabled'
  else
    printf 'enabled'
  fi
}

# Re-bootstrap an enabled-but-unloaded launchd daemon. Pre-gated by the caller
# (Darwin + launchctl + resolved label + plist exists + NOT disabled + NOT
# loaded). Cooldown-recorded BEFORE the attempt (storm control). bootstrap +
# kickstart, capture stderr, verify loaded. Audits attempt/success/failed.
# Returns 0 on success, 1 on failure.
rebootstrap_launchd_daemon() {
  local uid="$1" label="$2" plist="$3" age="$4"
  emit_audit daemon_liveness_rebootstrap_attempt \
    --detail platform="launchd" \
    --detail label="$label" \
    --detail heartbeat_age_seconds="$age"
  record_cooldown
  if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
    printf '[liveness] DRY_RUN — would re-bootstrap enabled-but-unloaded launchd job gui/%s/%s\n' "$uid" "$label"
    return 0
  fi
  local err=""
  err="$(launchctl bootstrap "gui/${uid}" "$plist" 2>&1 >/dev/null)" || true
  launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true
  if rebootstrap_launchd_job_loaded "$uid" "$label"; then
    emit_audit daemon_liveness_rebootstrap_success \
      --detail platform="launchd" \
      --detail label="$label"
    printf '[liveness] re-bootstrapped enabled-but-unloaded launchd daemon gui/%s/%s\n' "$uid" "$label"
    return 0
  fi
  emit_audit daemon_liveness_rebootstrap_failed \
    --detail platform="launchd" \
    --detail label="$label" \
    --detail launchctl_error="${err:-}"
  printf '[liveness] WARN: launchd daemon still UNLOADED after re-bootstrap (gui/%s/%s) — remediate by hand: launchctl bootstrap gui/%s %s%s\n' \
    "$uid" "$label" "$uid" "$plist" "${err:+ (last launchctl error: $err)}" >&2
  return 1
}

# Darwin entry point. Returns 0 when it HANDLED the not-running case (acted or
# deliberately skipped with its own audit) so main() must NOT fall through to
# daemon_liveness_skip_not_running; returns 1 when this is not a recoverable
# launchd situation and main() should emit the standard skip.
maybe_rebootstrap_launchd() {
  local age="$1"
  # Issue #2064 r2 (Finding 1): set to 1 in the interrupted-upgrade branch when the
  # post-enable print-disabled re-query came back `unknown` (unverifiable). In that
  # case the marker consume is DEFERRED to a confirmed-load signal below, so a
  # failed/cooldown-deferred bootstrap keeps the marker for the next poll.
  local _interrupted_marker_pending=0
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 1
  command -v launchctl >/dev/null 2>&1 || return 1
  rebootstrap_launchd_resolve || return 1
  local uid
  uid="$(rebootstrap_launchd_uid)"
  [[ -n "$uid" ]] || return 1
  # Require the plist on disk — bootstrap needs the file, and its presence is
  # half of the "we are launchd-managed" signal.
  [[ -n "$REBOOTSTRAP_PLIST" && -f "$REBOOTSTRAP_PLIST" ]] || return 1
  # ★ Operator-intent guard (TRI-STATE — #2205 Phase-4 r2): the print-disabled probe
  # is one of `enabled` / `disabled` / `unknown`, and recovery is authorized for the
  # POSITIVE `disabled` state ONLY.
  #   enabled  → not a disabled-drift; fall through to the enabled-but-unloaded path.
  #   disabled → an intentional stop UNLESS a valid matching marker proves a
  #              first-party non-operator disable; only then re-enable + recover.
  #   unknown  → print-disabled unreadable. ★FAIL CLOSED: a marker proves the LAST
  #              first-party action was a disable, NOT the CURRENT state — if we
  #              cannot read the live state we cannot rule out that the operator
  #              re-disabled the job AFTER the marker was written. So we SKIP, RETAIN
  #              any marker for a later readable poll, and perform NO enable / NO
  #              bootstrap. (This is the bug Phase-4 r1 rejected: the old code treated
  #              a valid marker as license to recover regardless of readability.)
  local disabled_state
  disabled_state="$(rebootstrap_launchd_disabled_state "$uid" "$REBOOTSTRAP_LABEL")"
  if [[ "$disabled_state" == "unknown" ]]; then
    # Unreadable live state → cannot confirm the job is not operator-(re-)disabled.
    # Skip + alert; never enable, never consume the marker (retain it so a later poll
    # with a READABLE positive-disabled probe can recover a genuine first-party drift).
    emit_audit daemon_liveness_rebootstrap_skip_unknown_disabled \
      --detail platform="launchd" \
      --detail label="$REBOOTSTRAP_LABEL" \
      --detail disabled_state="$disabled_state" \
      --detail heartbeat_age_seconds="$age"
    printf '[liveness] launchd job gui/%s/%s disabled-state=UNKNOWN (print-disabled unreadable) — skipping (cannot confirm current state; retaining any marker for a later readable poll, NOT re-enabling).\n' \
      "$uid" "$REBOOTSTRAP_LABEL"
    return 0
  fi
  if [[ "$disabled_state" == "disabled" ]]; then
    # Issue #2055 / #2205: a positively-disabled job is normally an operator stop
    # (skip). The sole exception is a first-party non-operator disable — a durable
    # per-path marker (dead writer pid) whose platform+target match THIS launchd
    # label proves the disable was first-party, not the operator's. Only then do we
    # RE-ENABLE the job and recover it; otherwise keep the #2040 fail-closed skip.
    # `interrupted_upgrade` is one reason value; the reason is surfaced for triage.
    if interrupted_upgrade_quiesce; then
      emit_audit daemon_liveness_rebootstrap_interrupted_upgrade \
        --detail platform="launchd" \
        --detail label="$REBOOTSTRAP_LABEL" \
        --detail disabled_state="$disabled_state" \
        --detail upgrade_pid="$QUIESCE_MARKER_PID" \
        --detail reason="$QUIESCE_MARKER_REASON" \
        --detail heartbeat_age_seconds="$age"
      printf '[liveness] launchd job gui/%s/%s disabled by a first-party non-operator action (reason=%s, dead writer pid=%s) — re-enabling + recovering (not an operator stop).\n' \
        "$uid" "$REBOOTSTRAP_LABEL" "$QUIESCE_MARKER_REASON" "$QUIESCE_MARKER_PID"
      # Issue #2064 r2 (Finding 1): do NOT consume the marker before/around the
      # best-effort re-enable. `launchctl enable` is `|| true`; if it fails the job
      # stays down, and an eagerly-cleared marker would leave the next poll with no
      # discriminator → fall back to the fail-closed skip_disabled and the daemon
      # stays silently down forever (the #2055 hole). The marker is consumed ONLY on
      # a CONFIRMED-healthy signal — either print-disabled re-querying as a positive
      # `enabled`, OR (codex r2) the job actually being LOADED after bootstrap below.
      # NOTE: we only reach here on a CONFIRMED positive-`disabled` probe (the
      # #2205 Phase-4 r2 tri-state entry guard already failed closed on `unknown`),
      # so the re-enable itself is authorized. A re-query that comes back `unknown`
      # below affects only the consume TIMING, not the decision to enable: it is NOT
      # a confirmed re-enable, so we DEFER consumption to the load-confirmation and a
      # failed/cooldown-deferred bootstrap KEEPS the marker for the next poll.
      # `_interrupted_marker_pending` (declared at function scope above) carries that.
      if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
        clear_quiesce_marker   # no real enable to fail — preserve the latch semantics
      else
        launchctl enable "gui/${uid}/${REBOOTSTRAP_LABEL}" >/dev/null 2>&1 || true
        local reenabled_state
        reenabled_state="$(rebootstrap_launchd_disabled_state "$uid" "$REBOOTSTRAP_LABEL")"
        case "$reenabled_state" in
          disabled)
            # POSITIVE proof the re-enable did NOT take (launchd refused; the job is
            # still explicitly disabled). The marker is our only proof this was an
            # interrupted upgrade — KEEP it so the next poll retries. Audit loudly.
            emit_audit daemon_liveness_rebootstrap_failed \
              --detail platform="launchd" \
              --detail label="$REBOOTSTRAP_LABEL" \
              --detail reason="reenable_did_not_take" \
              --detail reenabled_state="$reenabled_state" \
              --detail heartbeat_age_seconds="$age"
            printf '[liveness] WARN: launchd re-enable of interrupted-upgrade job gui/%s/%s did NOT take (still disabled) — KEEPING the quiesce marker for the next poll to retry.\n' \
              "$uid" "$REBOOTSTRAP_LABEL" >&2
            return 0
            ;;
          enabled)
            # CONFIRMED enabled. The disabled-state discriminator has served its
            # purpose — consume now; the remaining enabled-but-unloaded recovery is
            # the marker-independent #2040 standing path. Clearing avoids a lingering
            # marker mis-reading a later operator stop.
            clear_quiesce_marker
            ;;
          *)
            # unknown — print-disabled unreadable. NOT a confirmed re-enable (codex
            # r2). Proceed to recover (marker = independent proof), but DEFER the
            # consume to the post-bootstrap load-confirmation so a failed bootstrap
            # keeps the marker.
            _interrupted_marker_pending=1
            ;;
        esac
      fi
      # Fall through to the enabled-but-unloaded recovery below (loaded-check +
      # cooldown + bootstrap), now reachable because the job is enabled (or we are
      # proceeding on an unknown re-query with the marker still held). If the job is
      # already loaded, or a confirmed bootstrap loads it, a pending marker is
      # consumed there (see the _interrupted_marker_pending clears below).
    else
      emit_audit daemon_liveness_rebootstrap_skip_disabled \
        --detail platform="launchd" \
        --detail label="$REBOOTSTRAP_LABEL" \
        --detail disabled_state="$disabled_state" \
        --detail heartbeat_age_seconds="$age"
      printf '[liveness] launchd job gui/%s/%s is disabled with no valid first-party marker — skipping re-bootstrap (operator stop).\n' \
        "$uid" "$REBOOTSTRAP_LABEL"
      return 0
    fi
  fi
  # If the job IS loaded, this is not the enabled-but-unloaded case — let the
  # normal skip path handle it (a loaded-but-no-pid job is launchd's to respawn).
  if rebootstrap_launchd_job_loaded "$uid" "$REBOOTSTRAP_LABEL"; then
    # #2064 r2: a LOADED job is a confirmed-healthy signal — consume a marker whose
    # consume was deferred on an `unknown` re-query (the recovery succeeded).
    if [[ "$_interrupted_marker_pending" == "1" ]]; then clear_quiesce_marker; fi
    emit_audit daemon_liveness_rebootstrap_skip_loaded \
      --detail platform="launchd" \
      --detail label="$REBOOTSTRAP_LABEL" \
      --detail heartbeat_age_seconds="$age"
    return 1
  fi
  # Enabled-but-unloaded confirmed. Storm control: respect the cooldown.
  if cooldown_active; then
    # #2064 r2: do NOT consume a deferred-pending marker on a cooldown skip — the
    # bootstrap did not run, so recovery is not yet confirmed; keep it for retry.
    emit_audit daemon_liveness_rebootstrap_skip_cooldown \
      --detail platform="launchd" \
      --detail label="$REBOOTSTRAP_LABEL" \
      --detail heartbeat_age_seconds="$age" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 0
  fi
  if rebootstrap_launchd_daemon "$uid" "$REBOOTSTRAP_LABEL" "$REBOOTSTRAP_PLIST" "$age"; then
    # #2064 r2: bootstrap CONFIRMED the job loaded — consume a deferred-pending
    # marker now. A failed bootstrap leaves the marker for the next poll.
    if [[ "$_interrupted_marker_pending" == "1" ]]; then clear_quiesce_marker; fi
  fi
  return 0
}

# Linux entry point. The watcher runs from its own systemd --user timer
# (independent of the daemon service), so it survives the daemon's death and can
# restart an enabled-but-inactive `agent-bridge-daemon.service`. Recover ONLY
# when the service is-enabled=enabled/enabled-runtime AND is-active=inactive/
# failed. disabled/static/masked/not-found/bus-unreachable → SKIP, never enable.
# Returns 0 when HANDLED (acted or skipped-with-audit), 1 when main() should emit
# the standard skip.
maybe_rebootstrap_systemd() {
  local age="$1"
  [[ "$(uname -s 2>/dev/null)" == "Linux" ]] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  local svc="${BRIDGE_DAEMON_SYSTEMD_SERVICE:-agent-bridge-daemon.service}"
  local enabled_state
  # is-enabled prints enabled/enabled-runtime/disabled/static/masked/... on
  # stdout. A non-zero rc with empty output means the user bus is unreachable or
  # the unit is unknown → not recoverable here.
  enabled_state="$(systemctl --user is-enabled "$svc" 2>/dev/null)" || true
  case "$enabled_state" in
    enabled|enabled-runtime) ;;
    "")
      # No output → bus unreachable or unit not found. Skip + audit; never enable.
      emit_audit daemon_liveness_rebootstrap_skip_unavailable \
        --detail platform="systemd" \
        --detail service="$svc" \
        --detail heartbeat_age_seconds="$age"
      return 1
      ;;
    disabled|masked)
      # Operator/intentional stop. SKIP + audit, never re-enable/unmask.
      # Issue #2055/#2064/#2205: unlike launchd (whose upgrade quiesce `disable`s
      # the job, masquerading as an operator stop), NO first-party Agent Bridge code
      # `disable`s OR `mask`s the systemd daemon unit — bridge-upgrade.sh's systemd
      # quiesce only `stop`s the SERVICE (and as of #2064 it no longer stops THIS
      # liveness timer either). So an INTERRUPTED systemd upgrade leaves the unit
      # enabled+inactive, which the `enabled` arm below recovers (reset-failed +
      # start) once the live-upgrade defer clears. Because no first-party path
      # disables/masks the unit, a disabled/masked systemd unit is ALWAYS a genuine
      # operator action here — the #2205 per-path marker gives systemd nothing to
      # recover (it has no first-party disabler), so this stays fail-closed
      # alert-only (an honest boundary, see PR). ★`masked` is STRONGER than
      # `disabled`: even a future first-party disabler must never trigger an unmask
      # here (unmask would override a hard operator block). Fighting a real
      # `systemctl --user disable`/`mask` is a fleet-down regression.
      emit_audit daemon_liveness_rebootstrap_skip_disabled \
        --detail platform="systemd" \
        --detail service="$svc" \
        --detail enabled_state="$enabled_state" \
        --detail heartbeat_age_seconds="$age"
      printf '[liveness] systemd unit %s is %s (operator stop) — skipping re-start.\n' "$svc" "$enabled_state"
      return 0
      ;;
    *)
      # static / indirect / generated / unknown — not a unit we manage as a
      # standing daemon. Defer to the normal skip path.
      return 1
      ;;
  esac
  # Enabled. Recover only when NOT active (inactive/failed). An active service
  # with no pidfile is the daemon's own concern, not ours.
  if systemctl --user is-active "$svc" >/dev/null 2>&1; then
    emit_audit daemon_liveness_rebootstrap_skip_loaded \
      --detail platform="systemd" \
      --detail service="$svc" \
      --detail heartbeat_age_seconds="$age"
    return 1
  fi
  # Issue #2064 r2 (Finding 2): the enabled+inactive state is exactly what a
  # LEGITIMATE in-flight upgrade produces — its #1820 quiesce `stop`s the service
  # for the reconcile window. #2055 originally stopped THIS liveness timer during
  # quiesce so the watcher could not race the #1820 fence, but that left a
  # SIGKILL'd upgrade with no running invoker to observe the marker → daemon stuck
  # down. The fix keeps the timer RUNNING during quiesce; this guard is the
  # counterpart that prevents racing the fence: while an upgrade GENUINELY holds
  # the marker (a LIVE upgrade pid), DEFER + preserve the marker (mirror the
  # launchd I3 LIVE-pid defer). A SIGKILL'd upgrade leaves a DEAD-pid (orphaned)
  # marker — live_upgrade_quiesce_in_flight returns 1 then, so we fall through and
  # reap it via the normal enabled+inactive recovery below. No marker → normal
  # #2040 recovery (an operator `systemctl --user stop` without disable, already
  # recovered pre-#2064; the operator-stop guard for systemd remains disable/mask).
  if live_upgrade_quiesce_in_flight; then
    emit_audit daemon_liveness_rebootstrap_skip_live_upgrade \
      --detail platform="systemd" \
      --detail service="$svc" \
      --detail heartbeat_age_seconds="$age"
    printf '[liveness] systemd unit %s is enabled+inactive but a LIVE upgrade holds the quiesce marker — deferring to its own restore (not racing the #1820 fence).\n' "$svc"
    return 0
  fi
  if cooldown_active; then
    emit_audit daemon_liveness_rebootstrap_skip_cooldown \
      --detail platform="systemd" \
      --detail service="$svc" \
      --detail heartbeat_age_seconds="$age" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 0
  fi
  emit_audit daemon_liveness_rebootstrap_attempt \
    --detail platform="systemd" \
    --detail service="$svc" \
    --detail heartbeat_age_seconds="$age"
  record_cooldown
  if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
    printf '[liveness] DRY_RUN — would re-start enabled-but-inactive systemd unit %s\n' "$svc"
    return 0
  fi
  local err=""
  # reset-failed clears a prior failed state so `start` is not refused.
  systemctl --user reset-failed "$svc" >/dev/null 2>&1 || true
  err="$(systemctl --user start "$svc" 2>&1 >/dev/null)" || true
  if systemctl --user is-active "$svc" >/dev/null 2>&1; then
    emit_audit daemon_liveness_rebootstrap_success \
      --detail platform="systemd" \
      --detail service="$svc"
    printf '[liveness] re-started enabled-but-inactive systemd daemon %s\n' "$svc"
    # Issue #2064 r2 (Finding 1 parity): a CONFIRMED reap consumes any orphaned
    # quiesce marker (a SIGKILL'd upgrade's dead-pid marker) so it does not linger.
    # No-op (rm -f) when there was no marker — this path also recovers a plain
    # operator `systemctl stop` (no disable), which carries no marker. KEEP the
    # marker on the failure path below so the next poll retries.
    clear_quiesce_marker
    return 0
  fi
  emit_audit daemon_liveness_rebootstrap_failed \
    --detail platform="systemd" \
    --detail service="$svc" \
    --detail systemctl_error="${err:-}"
  printf '[liveness] WARN: systemd daemon %s still inactive after re-start — remediate: systemctl --user start %s%s\n' \
    "$svc" "$svc" "${err:+ (start error: $err)}" >&2
  return 0
}

# Standing-recovery dispatcher called from main() when the heartbeat is stale and
# no daemon pid is alive, BEFORE the daemon_liveness_skip_not_running fallback.
# Returns 0 when it HANDLED the case (so main must not also emit skip_not_running);
# 1 to fall through to the standard skip.
maybe_rebootstrap_unloaded_daemon() {
  local age="$1"
  maybe_rebootstrap_launchd "$age" && return 0
  maybe_rebootstrap_systemd "$age" && return 0
  return 1
}

# Issue #1973 (Track C). Write the recovery marker the freshly-started daemon
# consumes once to run a bounded re-nudge pass. The daemon path
# (bridge-daemon.sh cmd_run) deletes the file after one read, so it is a single
# latch per restart — a second restart re-writes it. Best-effort: a failed
# write must not block the restart itself.
write_recovery_marker() {
  local reason="$1"
  local oldest_age="$2"
  local heartbeat_age="$3"
  mkdir -p "$(dirname "$BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE")" 2>/dev/null || true
  {
    printf 'BRIDGE_RECOVERY_REASON=%q\n' "$reason"
    printf 'BRIDGE_RECOVERY_TS=%q\n' "$(now_ts)"
    printf 'BRIDGE_RECOVERY_OLDEST_REQUEST_AGE=%q\n' "${oldest_age:-0}"
    printf 'BRIDGE_RECOVERY_PRIOR_HEARTBEAT_AGE=%q\n' "${heartbeat_age:-0}"
  } 2>/dev/null >"$BRIDGE_DAEMON_RECOVERY_RENUDGE_FILE" || true
}

# Issue #1973 (Track C). Query Track A's gateway `status --json` and emit the
# OLDEST age (seconds) across pending+working requests, or empty when the
# gateway is idle / status is unavailable / status is unparseable. We default
# to `bridge-queue-gateway.py status --json`; the smoke overrides via
# BRIDGE_DAEMON_GATEWAY_STATUS_CMD. The status command itself is Track A's; we
# only read its `pending`/`working` oldest-age fields.
gateway_oldest_stalled_age() {
  local status_json=""
  if [[ -n "${BRIDGE_DAEMON_GATEWAY_STATUS_CMD:-}" ]]; then
    status_json="$(eval "$BRIDGE_DAEMON_GATEWAY_STATUS_CMD" 2>/dev/null || true)"
  else
    local gw="$REPO_ROOT/bridge-queue-gateway.py"
    [[ -f "$gw" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    status_json="$(python3 "$gw" status --json --bridge-home "$BRIDGE_HOME" 2>/dev/null || true)"
  fi
  [[ -n "$status_json" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  # Parse the MAX of the pending/working oldest-age fields, but ONLY when the
  # corresponding request COUNT is positive. Field names mirror Track A's
  # `status --json` contract (PR #1978): `pending`/`working` counts and
  # `oldest_pending_age`/`oldest_working_age` seconds. A zero count must never
  # contribute its oldest-age — a draining/idle gateway can still carry a stale
  # age field, and treating that as a stall would fire a false restart (review
  # fix: count-gate). A missing field or empty/idle gateway prints nothing → the
  # caller treats it as "no stall".
  printf '%s' "$status_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ages = []
for count_key, age_key in (("pending", "oldest_pending_age"), ("working", "oldest_working_age")):
    cnt = d.get(count_key)
    age = d.get(age_key)
    if isinstance(cnt, bool) or isinstance(age, bool):
        continue
    if isinstance(cnt, (int, float)) and cnt > 0 and isinstance(age, (int, float)) and age >= 0:
        ages.append(int(age))
if ages:
    print(max(ages))
' 2>/dev/null
}

# Shared restart mechanics for both the heartbeat-stale and gateway-stall
# triggers. The recovery marker + cooldown are written by the CALLER before
# this runs (so the marker exists even on a DRY_RUN), and the per-trigger audit
# (attempt) is the caller's too — this helper owns only the actual `restart
# --force` invocation + the rc handling shared by both paths. $1 is a short tag
# used in the log line + the refused/failed audit details.
_perform_daemon_restart() {
  local tag="$1"
  if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
    printf '[liveness] DRY_RUN — would restart daemon (%s)\n' "$tag"
    return 0
  fi
  # Use BRIDGE_HOME's daemon script so the watcher targets the same install
  # root the heartbeat file was observed in. The launchd plist sets
  # BRIDGE_HOME explicitly; override via env if running by hand.
  #
  # Issue #1463: route through the single `restart` verb instead of a
  # direct `stop --force` + `start`. On macOS launchd installs `restart`
  # cycles launchd's OWN supervised job (`launchctl kickstart -k`) so the
  # fresh daemon is launchd's instance and holds the singleton lock inside
  # the supervised process tree — KeepAlive then has nothing to thrash
  # against. A direct out-of-band stop+start (the old code) established a
  # NON-launchd lock holder and re-armed the KeepAlive vs lock thrash on
  # every ~600s liveness restart. On Linux (systemd/nohup) `restart` falls
  # through to the same stop+start it always did, so this is a no-op there.
  # rc=2 means restart REFUSED (out-of-band split needs a one-time operator
  # reconcile) — surface it distinctly rather than masking it as success.
  #
  # --force: the liveness watchdog only fires on a wedged daemon. Bypass the
  # #314/#315 active-agent guard so a stuck daemon can still be restarted on a
  # host with running agents.
  local restart_rc=0
  bash "$DAEMON_SH" restart --force >/dev/null 2>&1 || restart_rc=$?
  if (( restart_rc == 2 )); then
    emit_audit daemon_liveness_restart_refused \
      --detail reason="launchd_out_of_band_split" \
      --detail trigger="$tag"
    printf '[liveness] restart REFUSED (out-of-band launchd split) — run "bridge-daemon.sh stop --force" once to reconcile\n'
    return 1
  fi
  if (( restart_rc != 0 )); then
    emit_audit daemon_liveness_restart_failed \
      --detail restart_rc="$restart_rc" \
      --detail trigger="$tag"
    return 1
  fi
  return 0
}

restart_daemon() {
  local pid="$1"
  local age="$2"
  emit_audit daemon_liveness_restart_attempt \
    --detail pid="$pid" \
    --detail heartbeat_age_seconds="$age" \
    --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
  write_recovery_marker heartbeat_stale "" "$age"
  record_cooldown
  if _perform_daemon_restart heartbeat_stale; then
    printf '[liveness] restarted daemon pid=%s age=%ss\n' "$pid" "$age"
    return 0
  fi
  return 1
}

# Issue #1973 (Track C). Gateway-stall restart: the daemon pid is alive and the
# heartbeat is fresh, but the queue gateway has OLD pending/working requests
# (the drain stalled). Same cooldown + recovery-marker contract as the
# heartbeat path; the marker reason distinguishes the trigger for the daemon's
# one-shot re-nudge consumer.
restart_daemon_gateway() {
  local pid="$1"
  local oldest_age="$2"
  local heartbeat_age="$3"
  emit_audit daemon_liveness_gateway_stall_restart \
    --detail pid="$pid" \
    --detail oldest_request_age_seconds="$oldest_age" \
    --detail heartbeat_age_seconds="$heartbeat_age" \
    --detail gateway_stall_threshold_seconds="$BRIDGE_DAEMON_GATEWAY_STALL_SECONDS"
  write_recovery_marker gateway_stall "$oldest_age" "$heartbeat_age"
  record_cooldown
  if _perform_daemon_restart gateway_stall; then
    printf '[liveness] restarted daemon (gateway stall) pid=%s oldest_request_age=%ss\n' "$pid" "$oldest_age"
    return 0
  fi
  return 1
}

# Issue #1973 (Track C). Gateway-stall detection. Returns 0 and restarts only
# when ALL of: (a) gateway-stall detection enabled, (b) the gateway reports an
# OLD pending/working request (oldest age >= stall threshold — an idle gateway
# reports nothing and never trips this), (c) that oldest age was ALSO old on
# the prior poll (cross-poll witness on disk — a single transient slow request
# does not trip it), (d) the daemon pid is alive, (e) not within cooldown.
# Otherwise it records/clears the cross-poll witness and returns non-zero so
# main() falls through to its normal heartbeat verdict.
maybe_restart_on_gateway_stall() {
  local pid="$1"
  local heartbeat_age="$2"
  [[ "$BRIDGE_DAEMON_GATEWAY_STALL_DISABLE" == "1" ]] && return 1

  local oldest_age=""
  oldest_age="$(gateway_oldest_stalled_age || true)"
  if [[ -z "$oldest_age" || ! "$oldest_age" =~ ^[0-9]+$ ]] \
     || (( oldest_age < BRIDGE_DAEMON_GATEWAY_STALL_SECONDS )); then
    # No old pending/working request → the gateway is draining (or idle).
    # Clear the cross-poll witness so a future single slow request must again
    # be observed twice before it can trigger a restart.
    rm -f "$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" 2>/dev/null || true
    return 1
  fi

  # The gateway has an OLD request. Require a prior observation of the SAME
  # request (cross-poll witness) before restarting, so neither a single
  # transient slow request NOR a fresh old request that appears between polls
  # can fire a restart on a single sighting. The witness stores the oldest
  # request's approximate BIRTH time (observation_ts - oldest_age), which is
  # stable across polls for the same request; a current birth outside tolerance
  # of the stored one means the prior old request drained / a different request
  # is now oldest, so we reset to a fresh first observation instead of trusting
  # the stale witness (review fix: same-request cross-poll witness).
  local now obs_birth prior_birth witness_ok
  now="$(now_ts)"
  obs_birth=$(( now - oldest_age ))
  prior_birth=""
  if [[ -f "$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" ]]; then
    prior_birth="$(tr -d '[:space:]' <"$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" 2>/dev/null)"
  fi
  witness_ok=0
  if [[ -n "$prior_birth" && "$prior_birth" =~ ^-?[0-9]+$ ]]; then
    local delta=$(( obs_birth - prior_birth ))
    (( delta < 0 )) && delta=$(( -delta ))
    (( delta <= BRIDGE_DAEMON_GATEWAY_STALL_WITNESS_TOLERANCE_SECONDS )) && witness_ok=1
  fi
  if (( witness_ok == 0 )); then
    # First observation of THIS old request (no prior witness, or the oldest
    # request changed/drained between polls) — record its birth and wait for the
    # next poll. Never restart on a request witnessed only once.
    mkdir -p "$(dirname "$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE")" 2>/dev/null || true
    printf '%s\n' "$obs_birth" 2>/dev/null >"$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" || true
    emit_audit daemon_liveness_gateway_stall_observed \
      --detail oldest_request_age_seconds="$oldest_age" \
      --detail oldest_request_birth_ts="$obs_birth" \
      --detail gateway_stall_threshold_seconds="$BRIDGE_DAEMON_GATEWAY_STALL_SECONDS" \
      --detail observation="first"
    return 1
  fi

  # Second consecutive observation of an old request. Honor the cooldown so a
  # broken daemon does not restart-loop.
  if cooldown_active; then
    emit_audit daemon_liveness_skip_cooldown \
      --detail pid="$pid" \
      --detail oldest_request_age_seconds="$oldest_age" \
      --detail trigger="gateway_stall" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 1
  fi

  rm -f "$BRIDGE_DAEMON_GATEWAY_STALL_STATE_FILE" 2>/dev/null || true
  restart_daemon_gateway "$pid" "$oldest_age" "$heartbeat_age"
  return 0
}

# ── Issue #2207 (never-die wave Track C): out-of-process token lifeline ───────
#
# When the daemon is down/wedged, recover-due quota recovery + periodic token-
# sync stop, so a quota-limited agent stays disabled until the daemon returns.
# This watcher already survives that window. On a STALE heartbeat we run a
# bounded emergency token-lifeline tick: recover-due → UNCONDITIONAL sync →
# (gated) sync-global — delegating EVERY credential mutation to bridge-auth.sh.
# The watcher is a driver only; registry_lock / opt-in / root-fail-closed /
# credential-file lock all stay inside bridge-auth.py.

# Bounded local timeout wrapper. The watcher deliberately does NOT source
# bridge-lib (heavy: tmux/queue/state modules), so we cannot reuse
# bridge_with_timeout. timeout(1)/gtimeout(1) → preferred; absent, run unwrapped
# (status quo for a bare host). $1 = seconds, rest = command. rc is the command's
# (124/137 on a timeout kill — caller treats any non-zero as a failed phase).
token_lifeline_timeout() {
  local secs="$1"; shift
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=60
  local bin
  bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [[ -n "$bin" ]]; then
    "$bin" "$secs" "$@"
    return $?
  fi
  "$@"
  return $?
}

# Interval throttle. Returns 0 (due) when the lifeline has NOT run within
# BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS — the FIRST stale poll on a fresh
# host (no state file) is always due (fires immediately). Returns 1 (throttled)
# otherwise. The state file is SEPARATE from the restart cooldown so a refused/
# cooldown-suppressed restart never suppresses token recovery.
token_lifeline_due() {
  local interval="$BRIDGE_DAEMON_TOKEN_LIFELINE_INTERVAL_SECONDS"
  local last now
  [[ -f "$BRIDGE_DAEMON_TOKEN_LIFELINE_STATE_FILE" ]] || return 0
  last="$(tr -d '[:space:]' <"$BRIDGE_DAEMON_TOKEN_LIFELINE_STATE_FILE" 2>/dev/null)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  now="$(now_ts)"
  (( now - last >= interval ))
}

# Record the attempt timestamp — called EVEN ON FAILURE so a persistent auth
# error does not hot-loop the lifeline every 60s poll. Best-effort.
token_lifeline_record() {
  mkdir -p "$(dirname "$BRIDGE_DAEMON_TOKEN_LIFELINE_STATE_FILE")" 2>/dev/null || true
  printf '%s\n' "$(now_ts)" 2>/dev/null >"$BRIDGE_DAEMON_TOKEN_LIFELINE_STATE_FILE" || true
}

# The emergency tick body. Runs the same lifeline sequence the daemon runs:
#   1. recover-due  (quota recovery; re-enables a recovered registry row)
#   2. sync         (UNCONDITIONAL — writes .credentials.json so live sessions
#                    re-read the recovered token; this tick also REPLACES the
#                    daemon's periodic sync while the daemon is down, so it must
#                    run even when recover-due reports no due tokens)
#   3. sync-global  (ONLY when the operator opted in — same cheap exit-code gate
#                    the daemon's bridge_daemon_global_auth_sync_tick uses)
# Every phase is bounded by token_lifeline_timeout and audited (status only,
# never token material). DRY_RUN emits a would-run row and mutates nothing.
# Always returns 0 — a failed phase is audited, not fatal to the watcher.
run_token_lifeline() {
  local trigger="$1"        # the stale-return path that invoked us (audit detail)
  local heartbeat_age="$2"
  local auth_sh="$BRIDGE_AUTH_SH"
  local tmo="$BRIDGE_DAEMON_TOKEN_LIFELINE_TIMEOUT_SECONDS"
  local agent_scope="$BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS"

  [[ "${BRIDGE_DAEMON_TOKEN_LIFELINE_ENABLED:-1}" == "1" ]] || return 0
  [[ -f "$auth_sh" ]] || return 0
  command -v "$BRIDGE_BASH_BIN" >/dev/null 2>&1 || return 0

  # Interval throttle — at most one lifeline per interval per stale host.
  token_lifeline_due || return 0
  # Record the attempt BEFORE running (record-even-on-failure) so a hanging /
  # persistently-failing auth call cannot hot-loop the lifeline every poll.
  token_lifeline_record

  if [[ "$BRIDGE_DAEMON_LIVENESS_DRY_RUN" == "1" ]]; then
    emit_audit daemon_liveness_token_lifeline \
      --detail trigger="$trigger" \
      --detail heartbeat_age_seconds="$heartbeat_age" \
      --detail dry_run="1" \
      --detail recover_due="would-run" \
      --detail sync="would-run" \
      --detail sync_global="would-run"
    printf '[liveness] DRY_RUN — would run token lifeline (recover-due + sync%s) trigger=%s\n' \
      "$( [[ -n "${BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC:-}" ]] && printf ' + gated sync-global' )" "$trigger"
    return 0
  fi

  # Phase 1 — recover-due. Re-enables a recovered registry row; on its own it does
  # NOT propagate to live sessions (that is phase 2). rc!=0 → failed/timeout.
  local recover_status="ok"
  token_lifeline_timeout "$tmo" \
    "$BRIDGE_BASH_BIN" "$auth_sh" claude-token recover-due --json >/dev/null 2>&1 \
    || recover_status="failed"

  # Phase 2 — sync (UNCONDITIONAL). This is the correctness crux: recover-due
  # alone re-enables the registry but live sessions keep the dead credential
  # until sync writes .credentials.json. We must finish the PAIR in the same tick
  # so the registry cannot be re-enabled without file propagation. It is also
  # this tick's replacement for the daemon's periodic sync, so it runs even when
  # recover-due found nothing due.
  local sync_status="ok"
  token_lifeline_timeout "$tmo" \
    "$BRIDGE_BASH_BIN" "$auth_sh" claude-token sync --agents "$agent_scope" --json >/dev/null 2>&1 \
    || sync_status="failed"

  # Phase 3 — operator-global sync, gated by the SAME cheap exit-code probe the
  # daemon's bridge_daemon_global_auth_sync_tick uses. `global-auth-sync status
  # --check` exits 0 iff the persisted/env opt-in is EFFECTIVELY enabled. Only
  # then do we run sync-global (which keeps the auto_rotate gate, root-fail-
  # closed, and credential-file lock intact inside bridge-auth.py). A check
  # failure/timeout fails safe to skipped.
  local sync_global_status="skipped"
  if token_lifeline_timeout "$tmo" \
      "$BRIDGE_BASH_BIN" "$auth_sh" claude-token global-auth-sync status --check >/dev/null 2>&1; then
    sync_global_status="ok"
    token_lifeline_timeout "$tmo" \
      "$BRIDGE_BASH_BIN" "$auth_sh" claude-token sync-global --json >/dev/null 2>&1 \
      || sync_global_status="failed"
  fi

  emit_audit daemon_liveness_token_lifeline \
    --detail trigger="$trigger" \
    --detail heartbeat_age_seconds="$heartbeat_age" \
    --detail agent_scope="$agent_scope" \
    --detail recover_due="$recover_status" \
    --detail sync="$sync_status" \
    --detail sync_global="$sync_global_status"
  printf '[liveness] token lifeline ran (recover_due=%s sync=%s sync_global=%s) trigger=%s\n' \
    "$recover_status" "$sync_status" "$sync_global_status" "$trigger"
  return 0
}

# Gate the lifeline on the SAME stale-heartbeat signal the restart trigger uses.
# main() calls this at every stale-heartbeat return path (no-pid/not-running and
# the restart cooldown/refused paths) — exactly when the daemon is NOT recovering
# tokens. A fresh heartbeat means the daemon owns recovery → skip. Always best-
# effort (returns 0); never blocks the watcher's primary restart job.
maybe_run_token_lifeline() {
  local trigger="$1" heartbeat_age="$2"
  [[ "${BRIDGE_DAEMON_TOKEN_LIFELINE_ENABLED:-1}" == "1" ]] || return 0
  (( heartbeat_age >= BRIDGE_DAEMON_TOKEN_LIFELINE_STALE_SECONDS )) || return 0
  run_token_lifeline "$trigger" "$heartbeat_age"
  return 0
}

main() {
  local mtime now age pid

  if [[ ! -f "$BRIDGE_DAEMON_HEARTBEAT_FILE" ]]; then
    emit_audit daemon_liveness_skip_no_baseline \
      --detail heartbeat_file="$BRIDGE_DAEMON_HEARTBEAT_FILE"
    return 0
  fi

  if ! mtime="$(file_mtime "$BRIDGE_DAEMON_HEARTBEAT_FILE")"; then
    emit_audit daemon_liveness_skip_no_baseline \
      --detail heartbeat_file="$BRIDGE_DAEMON_HEARTBEAT_FILE" \
      --detail reason="stat_failed"
    return 0
  fi

  now="$(now_ts)"
  age=$(( now - mtime ))

  # Issue #2207 (never-die Track C). The heartbeat may be STALE — the daemon is
  # down/wedged, so its token lifeline (recover-due + sync) has stopped. Run the
  # bounded emergency token-lifeline tick HERE, before BOTH the gateway-stall
  # early-return below AND the restart/skip verdicts, so it fires on EVERY stale
  # path — including the case where a stale heartbeat ALSO has a gateway stall
  # whose restart is refused/failed (maybe_restart_on_gateway_stall still returns
  # "handled" and main() returns, so a lifeline call placed after it would be
  # skipped on exactly the daemon-not-recovering window — codex review #2207).
  # maybe_run_token_lifeline self-gates on staleness, so on a FRESH heartbeat
  # this is a no-op (the daemon owns recovery). It is interval-throttled,
  # restart-cooldown-independent, and delegates every mutation to bridge-auth.sh.
  # Best-effort: a failed/throttled tick must never block the verdicts below.
  maybe_run_token_lifeline stale_heartbeat "$age" || true

  # Issue #1973 (Track C). Gateway-stall detection runs FIRST and regardless of
  # heartbeat freshness — the #1973 wedge had a FRESH heartbeat (the loop kept
  # ticking) while the queue gateway drain stalled. It only acts when the
  # daemon pid is alive AND the gateway has an OLD pending/working request seen
  # across two polls; otherwise it is a no-op and we continue to the heartbeat
  # verdict below.
  if pid="$(daemon_pid_alive)"; then
    if maybe_restart_on_gateway_stall "$pid" "$age"; then
      return 0
    fi
  fi

  if (( age < BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS )); then
    emit_audit daemon_liveness_ok \
      --detail heartbeat_age_seconds="$age" \
      --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
    return 0
  fi

  if ! pid="$(daemon_pid_alive)"; then
    # Issue #2040: before deferring to KeepAlive / Restart=, check the
    # enabled-but-unloaded case those policies CANNOT recover. If the job is
    # proven should-be-running-but-unloaded (launchd: enabled, not disabled, not
    # loaded, plist present / systemd: is-enabled, inactive), re-bootstrap it
    # (cooldown-gated + audited). A DISABLED / operator-stopped job is skipped
    # with its own audit — we never fight an intentional stop.
    if maybe_rebootstrap_unloaded_daemon "$age"; then
      return 0
    fi
    # No live process to kill and nothing recoverable. launchd's KeepAlive /
    # systemd's Restart=always handles the genuine "process gone, job loaded"
    # case; the liveness watcher exists for the silent-hang case. Be
    # conservative and stay out of the way.
    emit_audit daemon_liveness_skip_not_running \
      --detail heartbeat_age_seconds="$age" \
      --detail threshold_seconds="$BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"
    return 0
  fi

  if cooldown_active; then
    emit_audit daemon_liveness_skip_cooldown \
      --detail pid="$pid" \
      --detail heartbeat_age_seconds="$age" \
      --detail cooldown_seconds="$BRIDGE_DAEMON_LIVENESS_COOLDOWN_SECONDS"
    return 0
  fi

  restart_daemon "$pid" "$age"
}

main "$@"
