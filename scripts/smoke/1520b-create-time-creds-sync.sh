#!/usr/bin/env bash
#
# scripts/smoke/1520b-create-time-creds-sync.sh — PR-B / #1520b regression.
#
# Pins the credential-pending hold contract that keeps a freshly-created
# linux-user-isolated Claude agent from authless daemon auto-start until its
# per-agent `.credentials.json` is seeded.
#
# THE RACE (pre-PR): `agent create` makes a queued / always-on / cron static
# role DAEMON-VISIBLE at the roster commit (bridge_write_role_block), which
# runs BEFORE linux-user isolation-prep and BEFORE any credential seed. So
# the daemon's next reconcile tick warm-starts the agent into its isolated
# HOME before a credential exists → the engine launches unauthenticated and
# every channel reports "Channels not available" (patch cm-prod PR-B).
#
# THE FIX: a transient `state/agents/<a>/credential-pending` marker, written
# MANDATORILY pre-roster for every linux-user + claude agent, plus a
# self-clearing predicate in bridge_daemon_autostart_allowed that holds all
# three daemon start surfaces until the credential lands.
#
# Cases (all run in an isolated BRIDGE_HOME — never touches live runtime;
# reuses scripts/smoke/lib.sh):
#
#   T1. Marker hard-fail BEFORE the roster commit: in bridge-agent.sh the
#       mandatory credential_pending_mark gate is wired with `bridge_die`
#       on failure and is positioned BEFORE bridge_write_role_block. If the
#       ordering is removed (mark after roster, or non-fatal), the daemon
#       race reopens. Asserted statically (the create flow is too heavy to
#       drive end-to-end in a fixture) + by driving the helper's own
#       fail-closed return.
#
#   T2. Mark gating: the marker helpers create the leaf at
#       `state/agents/<a>/credential-pending`; the create-flow gate is
#       scoped to isolation_mode==linux-user AND engine==claude regardless
#       of always_on. shared-mode OR codex-engine takes NO marker branch.
#
#   T3. Daemon gate denial under slow/failed seed: marker present + cred
#       absent → bridge_daemon_autostart_allowed (extracted verbatim)
#       returns 1 (deny) AND writes NO autostart backoff state file.
#
#   T4. Later-credential self-clear: with the marker present, once a
#       non-empty `.credentials.json` exists at the resolved config dir the
#       gate clears the marker + allows (return 0).
#
#   T5. Queued/on-demand AND cron-dispatch wake denial: both wake surfaces
#       gate on bridge_daemon_autostart_allowed, so the SAME marker holds
#       them. Asserted via the shared gate return + a static check that the
#       wake call sites consult the gate.
#
#   T6. Delete / retire / create-rollback cleanup: each path clears the
#       marker (static wiring assertion) + the clear helper actually removes
#       a present marker.
#
#   T7. Create-not-rolled-back: the create-time seed is best-effort (`|| true`
#       + time-box); a forced seed failure leaves the marker in place (agent
#       held) but does NOT abort create. Asserted via the seed-block wiring
#       (`|| true`, no bridge_die) + the held-marker survives a failed seed.
#
# Footgun #11 mitigation: zero heredoc-stdin into a subprocess — helper
# bodies are written to standalone driver files and invoked with
# `bash <driver>`, mirroring scripts/smoke/1353-setup-pending-grace.sh.

_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:1520b-create-time-creds-sync] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="1520b-create-time-creds-sync"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd awk
smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENT="test_clean"

# Resolve a Bash 4+ interpreter for all inner `bash <driver>` invocations.
BRIDGE_BASH="${BASH4_BIN:-}"
if [[ -z "$BRIDGE_BASH" || ! -x "$BRIDGE_BASH" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  else
    BRIDGE_BASH="$(command -v bash)"
  fi
fi
"$BRIDGE_BASH" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1 || \
  smoke_fail "Bash 4+ interpreter not found (BASH4_BIN=${BASH4_BIN:-unset}); install homebrew bash"

# ---------------------------------------------------------------------------
# Extract the state-lib credential-pending helpers verbatim.
#   bridge_agent_idle_marker_dir
#   bridge_agent_credential_pending_file
#   bridge_agent_credential_pending_mark
#   bridge_agent_credential_pending_active
#   bridge_agent_credential_pending_clear
# ---------------------------------------------------------------------------
HELPERS_STATE="$SMOKE_TMP_ROOT/state-helpers.sh"
{
  awk '
    /^bridge_agent_idle_marker_dir\(\) \{/            { capture=1 }
    /^bridge_agent_credential_pending_file\(\) \{/    { capture=1 }
    /^bridge_agent_credential_pending_mark\(\) \{/    { capture=1 }
    /^bridge_agent_credential_pending_active\(\) \{/  { capture=1 }
    /^bridge_agent_credential_pending_clear\(\) \{/   { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/lib/bridge-state.sh"
} >"$HELPERS_STATE"

for fn in bridge_agent_idle_marker_dir bridge_agent_credential_pending_file \
          bridge_agent_credential_pending_mark bridge_agent_credential_pending_active \
          bridge_agent_credential_pending_clear; do
  if ! grep -q "^${fn}() {" "$HELPERS_STATE"; then
    smoke_fail "Could not extract helper $fn from lib/bridge-state.sh — check for rename"
  fi
done

# ---------------------------------------------------------------------------
# Extract the daemon autostart gate + its backoff state helpers verbatim.
#   bridge_daemon_autostart_state_file
#   bridge_daemon_note_autostart_failure  (presence proves no-backoff teeth)
#   bridge_daemon_autostart_allowed
# ---------------------------------------------------------------------------
HELPERS_DAEMON="$SMOKE_TMP_ROOT/daemon-helpers.sh"
{
  awk '
    /^bridge_daemon_autostart_state_file\(\) \{/      { capture=1 }
    /^bridge_daemon_note_autostart_failure\(\) \{/    { capture=1 }
    /^bridge_daemon_autostart_allowed\(\) \{/         { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/bridge-daemon.sh"
} >"$HELPERS_DAEMON"

for fn in bridge_daemon_autostart_state_file bridge_daemon_autostart_allowed; do
  if ! grep -q "^${fn}() {" "$HELPERS_DAEMON"; then
    smoke_fail "Could not extract helper $fn from bridge-daemon.sh — check for rename"
  fi
done

# ---------------------------------------------------------------------------
# Static wiring assertions (bite when the structural contract regresses).
# ---------------------------------------------------------------------------

# C1: the mandatory pre-roster marker is written BEFORE bridge_write_role_block
# and fails create (bridge_die) on a marker-write failure.
# `|| true` so an absent pattern (the bite-test scenario) falls through to the
# explicit smoke_fail below instead of aborting silently under set -e/pipefail.
MARK_LINE="$(grep -n 'bridge_agent_credential_pending_mark "\$agent"' "$REPO_ROOT/bridge-agent.sh" 2>/dev/null | head -1 | cut -d: -f1 || true)"
[[ -n "$MARK_LINE" ]] || smoke_fail "T1: bridge-agent.sh does not call bridge_agent_credential_pending_mark on create"
# The roster commit that opens the daemon-visibility race is the FIRST
# bridge_write_role_block call that appears AFTER the mark (run_create's
# call). There are other bridge_write_role_block sites (run_add, run_update)
# elsewhere in the file — anchoring on the nearest following one is what ties
# the ordering assertion to the create path specifically.
# shellcheck disable=SC1003  # the '\\' matches a literal line-continuation backslash, not an escaped quote
ROSTER_LINE="$(grep -n '^[[:space:]]*bridge_write_role_block \\' "$REPO_ROOT/bridge-agent.sh" 2>/dev/null | awk -F: -v m="$MARK_LINE" '$1 > m { print $1; exit }' || true)"
[[ -n "$ROSTER_LINE" ]] || smoke_fail "T1: no bridge_write_role_block follows the credential_pending_mark in bridge-agent.sh — create path lost the roster commit"
if (( MARK_LINE >= ROSTER_LINE )); then
  smoke_fail "T1: credential_pending_mark (line $MARK_LINE) is not BEFORE the run_create bridge_write_role_block (line $ROSTER_LINE) — the daemon race is reopened"
fi
# The mark gate must fail-close: a bridge_die must follow the mark call.
if ! awk -v start="$MARK_LINE" 'NR>=start && NR<start+6 && /bridge_die/ { found=1 } END { exit(found?0:1) }' "$REPO_ROOT/bridge-agent.sh"; then
  smoke_fail "T1: bridge_agent_credential_pending_mark failure is not gated with bridge_die — create would proceed unguarded"
fi

# C3: the create-flow mark is gated on linux-user + claude (both predicates
# present on the gate line region).
if ! awk -v start="$MARK_LINE" 'NR>=start-4 && NR<=start && /isolation_mode" == "linux-user/ { iso=1 } NR>=start-4 && NR<=start && /engine" == "claude/ { eng=1 } END { exit((iso&&eng)?0:1) }' "$REPO_ROOT/bridge-agent.sh"; then
  smoke_fail "T1/T2: create-flow marker gate is not scoped to (linux-user AND claude)"
fi

# C4: the daemon gate references the active-marker helper + the credential
# resolver, returns the hold WITHOUT sourcing bridge-auth.sh, and self-clears.
grep -q 'bridge_agent_credential_pending_active' "$HELPERS_DAEMON" \
  || smoke_fail "T3: bridge_daemon_autostart_allowed no longer consults bridge_agent_credential_pending_active"
grep -q 'bridge_agent_claude_config_dir' "$HELPERS_DAEMON" \
  || smoke_fail "T3: daemon gate no longer resolves the credential path via bridge_agent_claude_config_dir"
grep -q 'bridge_agent_credential_pending_clear' "$HELPERS_DAEMON" \
  || smoke_fail "T4: daemon gate no longer lazily self-clears the marker"
if grep -qE 'source[[:space:]].*bridge-auth\.sh|bridge-auth\.sh"' "$HELPERS_DAEMON"; then
  smoke_fail "T3: daemon gate must NOT source/import bridge-auth.sh (C4)"
fi
# C5: file-presence check is non-empty (-s), no JSON parse in the gate.
grep -q -- '-s "\$_cred_file"' "$HELPERS_DAEMON" \
  || smoke_fail "T4: daemon gate does not use a size>0 (-s) credential presence check (C5)"

# C6: the create-time seed reuses the external bridge-auth.sh sync path under
# bridge_with_timeout, captures the JSON for a trigger=create audit, and is
# best-effort (|| true, no bridge_die).
grep -q 'bridge_with_timeout 15 create_credential_seed' "$REPO_ROOT/bridge-agent.sh" \
  || smoke_fail "T7: create-time seed does not call bridge_with_timeout 15 create_credential_seed"
grep -q 'bridge-auth.sh" claude-token sync' "$REPO_ROOT/bridge-agent.sh" \
  || smoke_fail "C6: create-time seed does not reuse the bridge-auth.sh claude-token sync path"
grep -q -- '--detail trigger=create' "$REPO_ROOT/bridge-agent.sh" \
  || smoke_fail "C6: create-time seed does not emit a controller_credentials_aliveness audit row with trigger=create"

# C2 (T6): clear on delete + retire + create-rollback. Count actual CALL
# sites (`..._clear "$agent"`) — not the `command -v` availability guards —
# so dropping any one of the three clear paths bites here.
CLEAR_SITES="$(grep -c 'bridge_agent_credential_pending_clear "\$agent"' "$REPO_ROOT/bridge-agent.sh" 2>/dev/null || echo 0)"
if (( CLEAR_SITES < 3 )); then
  smoke_fail "T6: bridge-agent.sh has $CLEAR_SITES credential_pending_clear call sites; expected >=3 (delete + retire + create-rollback)"
fi

# T5: confirm the queued/on-demand AND cron-dispatch wake paths consult the
# shared gate (so the SAME marker holds them).
WAKE_GATE_REFS="$(grep -c 'bridge_daemon_autostart_allowed' "$REPO_ROOT/bridge-daemon.sh" 2>/dev/null || echo 0)"
if (( WAKE_GATE_REFS < 3 )); then
  smoke_fail "T5: bridge-daemon.sh references bridge_daemon_autostart_allowed only $WAKE_GATE_REFS time(s); expected >=3 (definition + on-demand/warm + cron-dispatch wake)"
fi

# ---------------------------------------------------------------------------
# T2 — mark writes the leaf; active sees it; path discipline.
# ---------------------------------------------------------------------------
step_t2_mark_and_path() {
  smoke_log "T2: credential_pending_mark writes state/agents/<a>/credential-pending"

  local driver="$SMOKE_TMP_ROOT/t2-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$1"\n'
    printf 'AGENT="$2"\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'bridge_agent_credential_pending_mark "$AGENT"\n'
    printf 'bridge_agent_credential_pending_active "$AGENT" && echo ACTIVE\n'
    printf 'bridge_agent_credential_pending_file "$AGENT"\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$BRIDGE_ACTIVE_AGENT_DIR" "$AGENT")"
  smoke_assert_contains "$out" "ACTIVE" "T2: marker must read active after mark"

  local marker_path
  marker_path="$(printf '%s\n' "$out" | tail -1)"
  smoke_assert_file_exists "$marker_path" "T2: credential-pending marker must exist after mark"
  local expected_dir="$BRIDGE_ACTIVE_AGENT_DIR/$AGENT"
  case "$marker_path" in
    "$expected_dir"/credential-pending) ;;
    *) smoke_fail "T2: marker path '$marker_path' is not '$expected_dir/credential-pending'" ;;
  esac
  smoke_log "T2 PASS — marker file landed at $marker_path"
}

# ---------------------------------------------------------------------------
# T3 — daemon gate denies when marker present + cred absent, NO backoff write.
# ---------------------------------------------------------------------------
step_t3_gate_denies_no_backoff() {
  smoke_log "T3: daemon gate denies (held) with cred absent + writes no backoff"

  local state_dir="$SMOKE_TMP_ROOT/t3-state"
  mkdir -p "$state_dir/daemon-autostart" "$state_dir/agents/$AGENT"
  local cred_dir="$SMOKE_TMP_ROOT/t3-claude"   # deliberately has NO .credentials.json

  local driver="$SMOKE_TMP_ROOT/t3-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"\n'
    printf 'AGENT="$2"\n'
    printf 'CRED_DIR="$3"\n'
    # Stub the resolvers the gate consults. Credential dir has no creds file.
    printf 'bridge_agent_broken_launch_file() { printf "%%s/%%s.broken" "$BRIDGE_STATE_DIR" "$1"; }\n'
    printf 'bridge_agent_claude_config_dir() { printf "%%s" "$CRED_DIR"; }\n'
    printf 'bridge_agent_engine() { echo claude; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 0; }\n'
    printf 'bridge_linux_sudo_root() { return 1; }\n'
    printf 'bridge_warn() { :; }\n'
    printf 'date() { command date "$@"; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'source "%s"\n' "$HELPERS_DAEMON"
    printf 'bridge_agent_credential_pending_mark "$AGENT"\n'
    printf 'if bridge_daemon_autostart_allowed "$AGENT"; then echo ALLOW; else echo DENY; fi\n'
    # The backoff state file for this agent must NOT have been created.
    printf 'if [[ -f "$BRIDGE_STATE_DIR/daemon-autostart/$AGENT.env" ]]; then echo BACKOFF_WRITTEN; else echo NO_BACKOFF; fi\n'  # noqa: iso-helper-boundary (test fixture asserts the daemon backoff state file's absence, not a runtime iso-boundary write)
    # Marker must still be present (hold persists).
    printf 'bridge_agent_credential_pending_active "$AGENT" && echo MARKER_HELD\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$state_dir" "$AGENT" "$cred_dir")"
  smoke_assert_contains "$out" "DENY"        "T3: gate must DENY (hold) when cred absent"
  smoke_assert_not_contains "$out" "ALLOW"   "T3: gate must not ALLOW while held"
  smoke_assert_contains "$out" "NO_BACKOFF"  "T3: gate must NOT write autostart backoff on a hold"
  smoke_assert_contains "$out" "MARKER_HELD" "T3: marker must persist while cred absent"
  smoke_log "T3 PASS — held, no backoff state written"
}

# ---------------------------------------------------------------------------
# T4 / T7 — once a non-empty cred lands, gate self-clears + allows. A failed
#           seed (no cred) leaves the held marker but never aborts create.
# ---------------------------------------------------------------------------
step_t4_self_clear_on_cred() {
  smoke_log "T4: gate self-clears marker + allows once a non-empty .credentials.json exists"

  local state_dir="$SMOKE_TMP_ROOT/t4-state"
  mkdir -p "$state_dir/daemon-autostart" "$state_dir/agents/$AGENT"
  local cred_dir="$SMOKE_TMP_ROOT/t4-claude"
  mkdir -p "$cred_dir"
  printf '{"claudeAiOauth":{"accessToken":"x"}}' > "$cred_dir/.credentials.json"  # non-empty (size>0)

  local driver="$SMOKE_TMP_ROOT/t4-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"\n'
    printf 'AGENT="$2"\n'
    printf 'CRED_DIR="$3"\n'
    printf 'bridge_agent_broken_launch_file() { printf "%%s/%%s.broken" "$BRIDGE_STATE_DIR" "$1"; }\n'
    printf 'bridge_agent_claude_config_dir() { printf "%%s" "$CRED_DIR"; }\n'
    printf 'bridge_agent_engine() { echo claude; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 0; }\n'
    printf 'bridge_linux_sudo_root() { return 1; }\n'
    printf 'bridge_warn() { :; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'source "%s"\n' "$HELPERS_DAEMON"
    printf 'bridge_agent_credential_pending_mark "$AGENT"\n'
    printf 'if bridge_daemon_autostart_allowed "$AGENT"; then echo ALLOW; else echo DENY; fi\n'
    # Marker must have been cleared by the gate.
    printf 'if bridge_agent_credential_pending_active "$AGENT"; then echo MARKER_STILL; else echo MARKER_CLEARED; fi\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$state_dir" "$AGENT" "$cred_dir")"
  smoke_assert_contains "$out" "ALLOW"          "T4: gate must ALLOW once cred present"
  smoke_assert_contains "$out" "MARKER_CLEARED" "T4: gate must self-clear the marker once cred present"
  smoke_log "T4 PASS — self-cleared + allowed"
}

# ---------------------------------------------------------------------------
# T6 — clear helper removes a present marker (delete/retire/rollback wiring
#      is asserted statically above; this drives the clear itself).
# ---------------------------------------------------------------------------
step_t6_clear_removes_marker() {
  smoke_log "T6: credential_pending_clear removes a present marker (idempotent)"

  local driver="$SMOKE_TMP_ROOT/t6-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$1"\n'
    printf 'AGENT="$2"\n'
    printf 'bridge_agent_engine() { echo claude; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 0; }\n'
    printf 'bridge_linux_sudo_root() { return 1; }\n'
    printf 'bridge_warn() { :; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'bridge_agent_credential_pending_mark "$AGENT"\n'
    printf 'bridge_agent_credential_pending_clear "$AGENT"\n'
    printf 'if bridge_agent_credential_pending_active "$AGENT"; then echo STILL; else echo CLEARED; fi\n'
    # Second clear is a no-op (idempotent).
    printf 'bridge_agent_credential_pending_clear "$AGENT" && echo CLEAR_IDEMPOTENT\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$BRIDGE_ACTIVE_AGENT_DIR" "${AGENT}_t6")"
  smoke_assert_contains "$out" "CLEARED"         "T6: clear must remove the marker"
  smoke_assert_contains "$out" "CLEAR_IDEMPOTENT" "T6: clear must be idempotent (no-op when absent)"
  smoke_log "T6 PASS — clear removes marker, idempotent"
}

# ---------------------------------------------------------------------------
# T7 — failed seed leaves the held marker (create not rolled back). The
#      create-flow seed-block wiring (best-effort, no bridge_die) is asserted
#      statically above; here we confirm a held marker survives a no-cred
#      world (the daemon keeps holding rather than the gate clearing).
# ---------------------------------------------------------------------------
step_t7_failed_seed_keeps_hold() {
  smoke_log "T7: a failed/slow seed leaves the marker held (create never rolled back)"

  # Static teeth: the create-time seed must NOT be gated with bridge_die and
  # must carry the best-effort `|| true`.
  if awk '/bridge_with_timeout 15 create_credential_seed/{found=NR} found && NR>=found && NR<found+3 && /\|\| true/{ok=1} END{exit(ok?0:1)}' "$REPO_ROOT/bridge-agent.sh"; then
    : # ok
  else
    smoke_fail "T7: create-time seed is missing the best-effort '|| true' (would propagate failure into create)"
  fi
  if awk '/bridge_with_timeout 15 create_credential_seed/{found=NR} found && NR>=found && NR<found+6 && /bridge_die/{bad=1} END{exit(bad?1:0)}' "$REPO_ROOT/bridge-agent.sh"; then
    : # ok — no bridge_die in the seed block
  else
    smoke_fail "T7: create-time seed block contains a bridge_die — a seed failure would roll back create"
  fi

  # Behavioral: with no cred file, a held marker stays held through the gate
  # (same shape as T3) — the agent is held, never authless, create succeeded.
  local state_dir="$SMOKE_TMP_ROOT/t7-state"
  mkdir -p "$state_dir/daemon-autostart" "$state_dir/agents/${AGENT}_t7"
  local driver="$SMOKE_TMP_ROOT/t7-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"\n'
    printf 'AGENT="$2"\n'
    printf 'bridge_agent_broken_launch_file() { printf "%%s/%%s.broken" "$BRIDGE_STATE_DIR" "$1"; }\n'
    printf 'bridge_agent_claude_config_dir() { printf "%%s/nope" "$BRIDGE_STATE_DIR"; }\n'
    printf 'bridge_agent_engine() { echo claude; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 0; }\n'
    printf 'bridge_linux_sudo_root() { return 1; }\n'
    printf 'bridge_warn() { :; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'source "%s"\n' "$HELPERS_DAEMON"
    printf 'bridge_agent_credential_pending_mark "$AGENT"\n'
    printf 'bridge_daemon_autostart_allowed "$AGENT" || true\n'
    printf 'if bridge_agent_credential_pending_active "$AGENT"; then echo MARKER_HELD; else echo MARKER_GONE; fi\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$state_dir" "${AGENT}_t7")"
  smoke_assert_contains "$out" "MARKER_HELD" "T7: a failed seed must leave the hold marker in place"
  smoke_log "T7 PASS — held after failed seed, create not rolled back"
}

# ---------------------------------------------------------------------------
# T8 (codex C4 negative control) — a STALE credential-pending marker on a
#     non-target agent (non-Claude engine, or not linux-user-isolated) must be
#     IGNORED by the daemon gate: it neither denies the agent's start nor
#     clears the marker based on the controller's view of .claude. Proves the
#     scope predicate (engine==claude && iso-effective) precedes the config-dir
#     resolution + the marker honoring.
# ---------------------------------------------------------------------------
step_t8_stale_marker_non_target_ignored() {
  smoke_log "T8: stale marker on a non-Claude/non-iso agent is IGNORED by the gate (codex C4 scope)"

  local state_dir="$SMOKE_TMP_ROOT/t8-state"
  mkdir -p "$state_dir/daemon-autostart" "$state_dir/agents/${AGENT}_t8"
  local cred_dir="$SMOKE_TMP_ROOT/t8-claude"   # controller-view .claude (used only if the scope leaked)
  mkdir -p "$cred_dir"

  local driver="$SMOKE_TMP_ROOT/t8-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"\n'
    printf 'AGENT="$2"\n'
    printf 'CRED_DIR="$3"\n'
    printf 'bridge_agent_broken_launch_file() { printf "%%s/%%s.broken" "$BRIDGE_STATE_DIR" "$1"; }\n'
    printf 'bridge_agent_claude_config_dir() { printf "%%s" "$CRED_DIR"; }\n'
    # NON-target: a codex agent that is also NOT linux-user-isolated, carrying a
    # stale marker. Either condition alone must defeat the scope predicate.
    printf 'bridge_agent_engine() { echo codex; }\n'
    printf 'bridge_agent_linux_user_isolation_effective() { return 1; }\n'
    printf 'bridge_linux_sudo_root() { return 1; }\n'
    printf 'bridge_warn() { :; }\n'
    printf 'source "%s"\n' "$HELPERS_STATE"
    printf 'source "%s"\n' "$HELPERS_DAEMON"
    # Plant a stale marker on this non-target agent.
    printf 'bridge_agent_credential_pending_mark "$AGENT"\n'
    # The gate must NOT be held by the marker (scope skips it) — allow path.
    printf 'if bridge_daemon_autostart_allowed "$AGENT"; then echo ALLOW; else echo DENY; fi\n'
    # And the marker must be left UNTOUCHED (the gate ignored it, did not clear).
    printf 'if bridge_agent_credential_pending_active "$AGENT"; then echo MARKER_UNTOUCHED; else echo MARKER_CLEARED; fi\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" "$state_dir" "${AGENT}_t8" "$cred_dir")"
  smoke_assert_contains "$out" "ALLOW"            "T8: gate must NOT hold a non-Claude/non-iso agent on a stale marker"
  smoke_assert_not_contains "$out" "DENY"         "T8: gate must not DENY a non-target agent's start"
  smoke_assert_contains "$out" "MARKER_UNTOUCHED" "T8: gate must not clear a non-target agent's stale marker (scope precedes honoring)"
  smoke_log "T8 PASS — stale marker on non-target agent ignored, not cleared"
}

step_t2_mark_and_path
step_t3_gate_denies_no_backoff
step_t4_self_clear_on_cred
step_t6_clear_removes_marker
step_t7_failed_seed_keeps_hold
step_t8_stale_marker_non_target_ignored

smoke_log "PASS — 1520b-create-time-creds-sync: all teeth (T1-T8) green"
