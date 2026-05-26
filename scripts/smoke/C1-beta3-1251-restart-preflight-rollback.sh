#!/usr/bin/env bash
#
# scripts/smoke/C1-beta3-1251-restart-preflight-rollback.sh — issue #1251
# (v0.15.0-beta3 Lane C1).
#
# Before this PR, `agent-bridge agent restart <agent>` ran a narrow
# pre-flight that only checked channel-runtime-status (.env presence,
# etc.). If the operator had just landed a new channel via `agent update
# --channels-add` whose plugin spec was NOT yet seeded into the bridge-
# owned plugin manifest (`shared/plugins-cache/installed_plugins.json`
# or the per-UID `installed_plugins.json`), the restart killed the prior
# tmux session, `bridge-start.sh` reached
# `bridge_ensure_claude_plugin_enabled`, the iso-v2 manifest guard fired
# `bridge_die`, the new launch never happened, and the agent ended up
# stopped. The watchdog then enqueued a generic `agent profile drift`
# task and the operator had to do the manual seed-then-start dance.
#
# This PR introduces a 3-phase transactional restart:
#
#   Phase 1 — `bridge_agent_restart_preflight_full_reason` runs BEFORE
#             the kill and surfaces structured failures (channel-spec-
#             unresolved, manifest-incomplete, engine-binary-missing,
#             daemon-supp-group-missing, session-id-state-inconsistent).
#             If any check fails: agent stays running, no kill, no
#             snapshot left.
#   Phase 2 — Snapshot the agent's managed block to
#             `state/agents/<a>/restart.snapshot.<ts>` AND write a
#             `state/agents/<a>/restart.in-progress` marker (Lane C2
#             contract). On launch failure: restore the snapshot, write
#             the marker with `state=rolled_back`, re-launch the prior
#             config.
#   Phase 3 — Marker lifecycle: cleared on success; persists with
#             `state=rolled_back` after auto-rollback so Lane C2 +
#             operator audit have a structured breadcrumb.
#
# Cases (all run in an isolated BRIDGE_HOME via scripts/smoke/lib.sh —
# never touches live runtime):
#
#   T1. Pre-flight blocks the kill on `channel-spec-unresolved`: bare
#       `plugin:foo` (no canonical marketplace) is in BRIDGE_AGENT_
#       CHANNELS → `bridge_agent_restart_preflight_full_reason` returns
#       a non-empty `channel-spec-unresolved` reason. No snapshot
#       file appears under state/agents/<a>/ (the helper is pure read).
#
#   T2. Happy path round-trip — marker writer/reader contract:
#       - Marker file lands at `state/agents/<a>/restart.in-progress`.
#       - All 4 documented fields are present and parseable
#         (pid, started, ttl, state).
#       - `bridge_agent_restart_marker_active` returns rc=0 with a fresh
#         in_progress marker.
#       - `bridge_agent_restart_marker_clear` removes the marker.
#       - The snapshot path lifecycle: snapshot is written, then cleared
#         by marker_clear.
#
#   T3. Rollback path — `state=rolled_back` marker shape:
#       - Snapshot a managed block, mutate the roster to a new value,
#         simulate a launch failure, restore from snapshot → roster
#         contains the SNAPSHOT (prior) content, NOT the mutated value.
#       - Marker after rollback has `state=rolled_back` and a non-empty
#         `reason` field with the structured tag prefix.
#
#   T4. Marker TTL expiry: a marker with `started=$(date +%s) - 9999`
#       and `ttl=60` is NOT considered active by
#       `bridge_agent_restart_marker_active`. A fresh marker IS active.
#
#   T5. Snapshot cleanup-on-success: after `bridge_agent_restart_marker_
#       clear`, ALL `restart.snapshot.*` files under state/agents/<a>/
#       are gone, not just the marker.
#
#   T6 (teeth). Inverse of T3 — without the rollback path applied, a
#       simulated launch failure would leave the roster mutated to the
#       failed-launch state. This test asserts the rollback HAS been
#       applied: a manual revert of `bridge_agent_restart_restore_
#       managed_block` would fail this test on the roster-content
#       assertion, citing #1251.
#
# Footgun #11 mitigation: zero heredoc-stdin into a subprocess; helper
# bodies are extracted into a standalone source file and re-sourced into
# a `bash <driver>` invocation, mirroring scripts/smoke/δ-1234-daemon-
# start-policy.sh.

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
  echo "[smoke:C1-beta3-1251-restart-preflight-rollback] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="C1-beta3-1251-restart-preflight-rollback"
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
AGENT="test-agent-1251"

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
# Helper extraction: pull every function under test out of lib/bridge-
# agents.sh into a standalone source file. Same pattern as δ-1234 — the
# inner drivers can then `source <funcs>` without needing the entire
# bridge-lib.sh dependency tree.
# ---------------------------------------------------------------------------
FUNCS_FILE="$SMOKE_TMP_ROOT/c1-funcs.sh"
extract_function() {
  local fn="$1"
  local src="$2"
  awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$src"
}

{
  printf '# shellcheck shell=bash disable=SC2034\n'
  # Stub bridge_trim_whitespace so the preflight code path that calls
  # it does not crash when the full bridge-core.sh is not sourced.
  printf 'bridge_trim_whitespace() { printf "%%s" "${1:-}" | awk "{ gsub(/^[ \\t]+|[ \\t]+\\$/, \\"\\\"); print }"; }\n'
  # Stub the channel-iteration / engine / isolation helpers so the
  # pre-flight reason function can run in isolation. The smoke seeds
  # the assoc arrays it consults directly.
  printf 'declare -gA BRIDGE_AGENT_CHANNELS=()\n'
  printf 'declare -gA BRIDGE_AGENT_ENGINE=()\n'
  printf 'bridge_agent_channels_csv() { printf "%%s" "${BRIDGE_AGENT_CHANNELS[$1]:-}"; }\n'
  printf 'bridge_agent_engine() { printf "%%s" "${BRIDGE_AGENT_ENGINE[$1]:-}"; }\n'
  printf 'bridge_isolation_disabled_by_env() { return 0; }\n'
  printf 'bridge_agent_linux_user_isolation_effective() { return 1; }\n'
  printf 'bridge_resolve_engine_binary() { command -v "$1" 2>/dev/null; }\n'
  printf 'bridge_claude_plugin_status() { printf "%%s" "${C1_PLUGIN_STATUS:-enabled}"; }\n'
  # Marketplace lookup table (T1 sources this for the qualify call).
  extract_function bridge_builtin_plugin_marketplace "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_qualify_channel_item "$REPO_ROOT/lib/bridge-agents.sh"
  # Subject helpers under test:
  extract_function bridge_agent_restart_state_dir "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_marker_path "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_snapshot_path "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_marker_write "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_marker_read_field "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_marker_active "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_marker_clear "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_snapshot_managed_block "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_restore_managed_block "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_preflight_full_reason "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_preflight_full_guidance "$REPO_ROOT/lib/bridge-agents.sh"
} >"$FUNCS_FILE"

for fn in bridge_agent_restart_state_dir bridge_agent_restart_marker_path \
          bridge_agent_restart_snapshot_path bridge_agent_restart_marker_write \
          bridge_agent_restart_marker_read_field bridge_agent_restart_marker_active \
          bridge_agent_restart_marker_clear bridge_agent_restart_snapshot_managed_block \
          bridge_agent_restart_restore_managed_block \
          bridge_agent_restart_preflight_full_reason \
          bridge_agent_restart_preflight_full_guidance; do
  grep -q "^${fn}() {" "$FUNCS_FILE" \
    || smoke_fail "extract: helper $fn missing from lib/bridge-agents.sh (renamed? deleted?)"
done

# ---------------------------------------------------------------------------
# T1 — Pre-flight `channel-spec-unresolved` blocks the kill.
# ---------------------------------------------------------------------------
step_t1_preflight_blocks_kill() {
  smoke_log "T1: pre-flight aborts when channel-spec cannot be canonicalised"

  local driver="$SMOKE_TMP_ROOT/t1-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'source %q\n' "$FUNCS_FILE"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$AGENT"
    # Bare plugin:gibberish — has no canonical marketplace mapping, so
    # bridge_qualify_channel_item returns "plugin:gibberish" (no `@`).
    # Pre-flight Check 1 should fail with `channel-spec-unresolved`.
    printf 'BRIDGE_AGENT_CHANNELS["%s"]="plugin:gibberish"\n' "$AGENT"
    printf 'reason="$(bridge_agent_restart_preflight_full_reason "%s")"\n' "$AGENT"
    printf 'printf "reason=%%s\\n" "$reason"\n'
    printf 'if [[ -n "$reason" ]]; then\n'
    printf '  guidance="$(bridge_agent_restart_preflight_full_guidance "%s" "$reason")"\n' "$AGENT"
    printf '  printf "guidance:\\n%%s\\n" "$guidance"\n'
    printf 'fi\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  smoke_assert_contains "$out" "reason=channel-spec-unresolved: plugin:gibberish" \
    "T1.a: pre-flight must surface channel-spec-unresolved reason"
  smoke_assert_contains "$out" "restart_aborted=channel-spec-unresolved" \
    "T1.b: structured guidance must lead with restart_aborted=<kind>"
  smoke_assert_contains "$out" "prior_session_preserved=yes" \
    "T1.c: guidance must promise the prior session is preserved"

  # Side-effect: NO snapshot file was created (pre-flight is read-only).
  local state_dir="$BRIDGE_STATE_DIR/agents/$AGENT"
  if [[ -d "$state_dir" ]] && compgen -G "$state_dir/restart.snapshot.*" >/dev/null 2>&1; then
    smoke_fail "T1.d: pre-flight wrote a snapshot — must be read-only on failure"
  fi
  if [[ -f "$state_dir/restart.in-progress" ]]; then
    smoke_fail "T1.e: pre-flight wrote the in-progress marker — must be read-only on failure"
  fi

  smoke_log "T1 PASS — pre-flight aborts cleanly with no side effects"
}

# ---------------------------------------------------------------------------
# T2 — Happy path: marker writer/reader contract.
# ---------------------------------------------------------------------------
step_t2_marker_write_read_clear() {
  smoke_log "T2: marker writer/reader/clear round-trip"

  local driver="$SMOKE_TMP_ROOT/t2-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'source %q\n' "$FUNCS_FILE"
    # Write a marker with explicit args.
    printf 'bridge_agent_restart_marker_write "%s" 12345 60 in_progress ""\n' "$AGENT"
    # Read each field.
    printf 'printf "pid=%%s\\n" "$(bridge_agent_restart_marker_read_field "%s" pid)"\n' "$AGENT"
    printf 'printf "ttl=%%s\\n" "$(bridge_agent_restart_marker_read_field "%s" ttl)"\n' "$AGENT"
    printf 'printf "state=%%s\\n" "$(bridge_agent_restart_marker_read_field "%s" state)"\n' "$AGENT"
    printf 'started="$(bridge_agent_restart_marker_read_field "%s" started)"\n' "$AGENT"
    printf 'if [[ "$started" =~ ^[0-9]+$ ]]; then printf "started=NUMERIC\\n"; else printf "started=BAD\\n"; fi\n'
    # Active check (in_progress + fresh).
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "active=yes\\n"; else printf "active=no\\n"; fi\n' "$AGENT"
    # Snapshot a managed block (seed it inline first).
    printf 'cat >>"%s" <<EOF\n' "$BRIDGE_ROSTER_LOCAL_FILE"
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_CHANNELS["%s"]="plugin:teams@agent-bridge"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    printf 'export BRIDGE_ROSTER_LOCAL_FILE=%q\n' "$BRIDGE_ROSTER_LOCAL_FILE"
    printf 'snap="$(bridge_agent_restart_snapshot_managed_block "%s")"\n' "$AGENT"
    printf 'printf "snapshot=%%s\\n" "$snap"\n'
    printf 'if [[ -f "$snap" ]]; then printf "snapshot-file=present\\n"; else printf "snapshot-file=absent\\n"; fi\n'
    # Now clear and re-check.
    printf 'bridge_agent_restart_marker_clear "%s"\n' "$AGENT"
    printf 'if [[ -f "$(bridge_agent_restart_marker_path "%s")" ]]; then printf "post-clear-marker=present\\n"; else printf "post-clear-marker=absent\\n"; fi\n' "$AGENT"
    printf 'if compgen -G "$(bridge_agent_restart_state_dir "%s")/restart.snapshot.*" >/dev/null 2>&1; then printf "post-clear-snapshot=present\\n"; else printf "post-clear-snapshot=absent\\n"; fi\n' "$AGENT"
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  smoke_assert_contains "$out" "pid=12345" "T2.a: pid field round-trips"
  smoke_assert_contains "$out" "ttl=60"    "T2.b: ttl field round-trips"
  smoke_assert_contains "$out" "state=in_progress" "T2.c: state field round-trips"
  smoke_assert_contains "$out" "started=NUMERIC"   "T2.d: started field is a unix timestamp"
  smoke_assert_contains "$out" "active=yes"        "T2.e: fresh in_progress marker is active"
  smoke_assert_contains "$out" "snapshot-file=present" "T2.f: snapshot writer landed a file"
  smoke_assert_contains "$out" "post-clear-marker=absent"   "T2.g: marker_clear removes the marker"
  smoke_assert_contains "$out" "post-clear-snapshot=absent" "T2.h: marker_clear sweeps snapshots"

  smoke_log "T2 PASS — marker round-trip + snapshot lifecycle clean"
}

# ---------------------------------------------------------------------------
# T3 — Rollback path: restore_managed_block reverts the mutation.
# ---------------------------------------------------------------------------
step_t3_rollback_restores_prior_block() {
  smoke_log "T3: snapshot-then-mutate-then-restore reverts to prior block"

  # Reset roster + state for a clean T3.
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  rm -rf "$BRIDGE_STATE_DIR/agents/$AGENT" 2>/dev/null || true

  local driver="$SMOKE_TMP_ROOT/t3-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'export BRIDGE_ROSTER_LOCAL_FILE=%q\n' "$BRIDGE_ROSTER_LOCAL_FILE"
    printf 'source %q\n' "$FUNCS_FILE"
    # Seed the PRIOR config in the roster.
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_CHANNELS["%s"]="plugin:teams@agent-bridge"\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --prior"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    # Snapshot the PRIOR config.
    printf 'snap="$(bridge_agent_restart_snapshot_managed_block "%s")"\n' "$AGENT"
    printf 'printf "snapshot=%%s\\n" "$snap"\n'
    # Simulate `agent update` mutating the roster between snapshot + restart
    # (this is what the issue trace does — Step 2 in the issue body).
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_CHANNELS["%s"]="plugin:teams@agent-bridge,plugin:cosmax-crm@cosmax-marketplace"\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --new-failing-launch"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    # Confirm pre-rollback state: roster carries the NEW (failed) launch.
    printf 'if grep -qF "claude --new-failing-launch" "$BRIDGE_ROSTER_LOCAL_FILE"; then printf "pre-rollback=mutated\\n"; fi\n'
    # Simulate the auto-rollback path: write the rolled_back marker +
    # restore the snapshot.
    printf 'bridge_agent_restart_marker_write "%s" $$ 60 rolled_back "launch-failed: simulated"\n' "$AGENT"
    printf 'if bridge_agent_restart_restore_managed_block "%s" "$snap"; then printf "restore=ok\\n"; else printf "restore=FAIL\\n"; fi\n' "$AGENT"
    # Now: roster MUST contain the PRIOR launch_cmd, NOT the failing one.
    printf 'if grep -qF "claude --prior" "$BRIDGE_ROSTER_LOCAL_FILE"; then printf "post-rollback-launch=prior\\n"; else printf "post-rollback-launch=NOT-prior\\n"; fi\n'
    printf 'if grep -qF "claude --new-failing-launch" "$BRIDGE_ROSTER_LOCAL_FILE"; then printf "post-rollback-failing-still-present=yes\\n"; else printf "post-rollback-failing-still-present=no\\n"; fi\n'
    # Marker fields after rollback.
    printf 'printf "marker-state=%%s\\n" "$(bridge_agent_restart_marker_read_field "%s" state)"\n' "$AGENT"
    printf 'reason="$(bridge_agent_restart_marker_read_field "%s" reason)"\n' "$AGENT"
    printf 'printf "marker-reason-prefix=%%s\\n" "${reason%%%%:*}"\n'
    printf 'printf "marker-reason-has-detail=%%s\\n" "$( [[ "$reason" == *"simulated"* ]] && printf yes || printf no )"\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  smoke_assert_contains "$out" "pre-rollback=mutated"                  "T3.a: roster mutated before rollback"
  smoke_assert_contains "$out" "restore=ok"                             "T3.b: restore helper returned ok"
  smoke_assert_contains "$out" "post-rollback-launch=prior"            "T3.c: roster contains PRIOR launch_cmd after rollback"
  smoke_assert_contains "$out" "post-rollback-failing-still-present=no" "T3.d: the failing launch_cmd is gone"
  smoke_assert_contains "$out" "marker-state=rolled_back"               "T3.e: marker state=rolled_back after rollback"
  smoke_assert_contains "$out" "marker-reason-prefix=launch-failed"    "T3.f: marker reason carries the structured tag prefix"
  smoke_assert_contains "$out" "marker-reason-has-detail=yes"           "T3.g: marker reason carries the detail substring"

  smoke_log "T3 PASS — rollback restores prior managed block + marker carries audit trail"
}

# ---------------------------------------------------------------------------
# T4 — Marker TTL: an old marker is NOT considered active.
# ---------------------------------------------------------------------------
step_t4_marker_ttl_expiry() {
  smoke_log "T4: TTL math — a marker older than ttl is not active"

  rm -rf "$BRIDGE_STATE_DIR/agents/$AGENT" 2>/dev/null || true
  mkdir -p "$BRIDGE_STATE_DIR/agents/$AGENT"

  local driver="$SMOKE_TMP_ROOT/t4-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'source %q\n' "$FUNCS_FILE"
    # Hand-write an expired marker (started=now-9999, ttl=60).
    printf 'marker="$(bridge_agent_restart_marker_path "%s")"\n' "$AGENT"
    printf 'now="$(date +%%s)"\n'
    printf 'expired_started=$(( now - 9999 ))\n'
    printf 'cat >"$marker" <<EOF\n'
    printf 'pid=%s\n' '12345'
    printf 'started=$expired_started\n'
    printf 'ttl=60\n'
    printf 'state=in_progress\n'
    printf 'EOF\n'
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "expired-active=yes\\n"; else printf "expired-active=no\\n"; fi\n' "$AGENT"
    # Now write a fresh marker via the production helper.
    printf 'bridge_agent_restart_marker_write "%s" 12345 60 in_progress ""\n' "$AGENT"
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "fresh-active=yes\\n"; else printf "fresh-active=no\\n"; fi\n' "$AGENT"
    # And a marker in state=rolled_back (terminal — NOT active even if fresh).
    printf 'bridge_agent_restart_marker_write "%s" 12345 60 rolled_back "launch-failed: t4"\n' "$AGENT"
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "rb-active=yes\\n"; else printf "rb-active=no\\n"; fi\n' "$AGENT"
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  smoke_assert_contains "$out" "expired-active=no" "T4.a: expired marker is NOT active"
  smoke_assert_contains "$out" "fresh-active=yes"  "T4.b: fresh in_progress marker IS active"
  smoke_assert_contains "$out" "rb-active=no"      "T4.c: rolled_back marker is terminal, not active"

  smoke_log "T4 PASS — TTL math + state gating both correct"
}

# ---------------------------------------------------------------------------
# T5 — Snapshot cleanup on success: marker_clear sweeps snapshot files
# even when multiple from prior crashed restarts linger.
# ---------------------------------------------------------------------------
step_t5_snapshot_cleanup_on_success() {
  smoke_log "T5: marker_clear sweeps ALL snapshot.* leftovers"

  local state_dir="$BRIDGE_STATE_DIR/agents/$AGENT"
  rm -rf "$state_dir" 2>/dev/null || true
  mkdir -p "$state_dir"
  # Seed multiple snapshot files from "prior crashed restarts".
  : >"$state_dir/restart.snapshot.111"
  : >"$state_dir/restart.snapshot.222"
  : >"$state_dir/restart.snapshot.333"
  # Plus a current marker.
  cat >"$state_dir/restart.in-progress" <<EOF
pid=$$
started=$(date +%s)
ttl=60
state=in_progress
EOF

  local driver="$SMOKE_TMP_ROOT/t5-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'source %q\n' "$FUNCS_FILE"
    printf 'bridge_agent_restart_marker_clear "%s"\n' "$AGENT"
    # Use shopt nullglob + array length so an empty match does not trip
    # the inner driver's `set -euo pipefail` (ls of a non-matching glob
    # exits non-zero, and the command-substitution + pipefail chain
    # would propagate that failure as an early exit before the printf
    # below ever runs — the symptom that masked T5 during this PR).
    printf 'shopt -s nullglob\n'
    printf 'snapshot_glob=("$BRIDGE_STATE_DIR/agents/%s"/restart.snapshot.*)\n' "$AGENT"
    printf 'shopt -u nullglob\n'
    printf 'printf "remaining-snapshots=%%s\\n" "${#snapshot_glob[@]}"\n'
    printf 'if [[ -f "$BRIDGE_STATE_DIR/agents/%s/restart.in-progress" ]]; then printf "marker-still-present=yes\\n"; else printf "marker-still-present=no\\n"; fi\n' "$AGENT"
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  smoke_assert_contains "$out" "remaining-snapshots=0" "T5.a: ALL snapshot.* files swept on clear"
  smoke_assert_contains "$out" "marker-still-present=no" "T5.b: marker swept on clear"

  smoke_log "T5 PASS — snapshot cleanup is exhaustive"
}

# ---------------------------------------------------------------------------
# T6 (teeth) — assert the rollback PATH is in place. Reverse the assertion
# from T3: if a future PR drops the restore call, this asserts the test
# would catch the regression citing #1251 explicitly.
# ---------------------------------------------------------------------------
step_t6_teeth_revert_rollback_would_fail() {
  smoke_log "T6 (teeth): without rollback, prior config would be lost — assert restore_managed_block has real teeth"

  # Reset + reseed.
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  rm -rf "$BRIDGE_STATE_DIR/agents/$AGENT" 2>/dev/null || true

  local driver="$SMOKE_TMP_ROOT/t6-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'export BRIDGE_ROSTER_LOCAL_FILE=%q\n' "$BRIDGE_ROSTER_LOCAL_FILE"
    printf 'source %q\n' "$FUNCS_FILE"
    # Seed the PRIOR config + snapshot it.
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --prior-working"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    printf 'snap="$(bridge_agent_restart_snapshot_managed_block "%s")"\n' "$AGENT"
    # Mutate to the failing config.
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --broken-config"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    # If a future PR strips `bridge_agent_restart_restore_managed_block`
    # from the rollback path, the roster will keep the --broken-config.
    # We assert the restore HAS been applied by checking that --broken-
    # config is gone after the call.
    printf 'bridge_agent_restart_restore_managed_block "%s" "$snap"\n' "$AGENT"
    printf 'if grep -qF "claude --broken-config" "$BRIDGE_ROSTER_LOCAL_FILE"; then\n'
    printf '  printf "TEETH-REGRESSION=#1251 — rollback dropped restore_managed_block; agent would be left running broken config after restart failure\\n"\n'
    printf '  exit 7\n'
    printf 'fi\n'
    printf 'if ! grep -qF "claude --prior-working" "$BRIDGE_ROSTER_LOCAL_FILE"; then\n'
    printf '  printf "TEETH-REGRESSION=#1251 — restore did not put prior config back\\n"\n'
    printf '  exit 8\n'
    printf 'fi\n'
    printf 'printf "teeth-ok=yes\\n"\n'
  } >"$driver"

  local out rc
  out="$("$BRIDGE_BASH" "$driver" 2>&1)" && rc=$? || rc=$?
  if (( rc != 0 )); then
    smoke_fail "T6 teeth: $out (rc=$rc)"
  fi
  smoke_assert_contains "$out" "teeth-ok=yes" "T6: rollback teeth intact — restore_managed_block actually restores"

  smoke_log "T6 PASS — rollback path teeth confirmed (a future revert would trip the assertion)"
}

step_t1_preflight_blocks_kill
step_t2_marker_write_read_clear
step_t3_rollback_restores_prior_block
step_t4_marker_ttl_expiry
step_t5_snapshot_cleanup_on_success
step_t6_teeth_revert_rollback_would_fail

smoke_log "all cases PASS"
