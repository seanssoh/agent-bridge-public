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
#   T3. PRODUCTION ordering rollback (codex r1 finding 1):
#       - Step 1: pre-update snapshot captured BEFORE roster mutation
#         (via `bridge_agent_restart_snapshot_pre_update`) — this is
#         the LAST-KNOWN-GOOD config.
#       - Step 2: roster mutated to the new (failing) config.
#       - Step 3: `bridge_agent_restart_find_pre_update_snapshot`
#         selects the pre-update snapshot (NOT a stale at-entry one).
#       - Step 4: restore reverts roster to the PRIOR (working) config.
#       The PRIOR T3 inverted the ordering (snapshot AFTER mutation)
#       and would have masked finding 1.
#
#   T4. Marker TTL expiry: a marker with `started=$(date +%s) - 9999`
#       and `ttl=60` is NOT considered active by
#       `bridge_agent_restart_marker_active`. A fresh marker IS active.
#
#   T5. Snapshot cleanup-on-success: after `bridge_agent_restart_marker_
#       clear`, ALL `restart.snapshot.*` files (both at-entry and the
#       new `pre-update` shape) under state/agents/<a>/ are gone.
#
#   T6 (teeth, EXTENDED). Two layers:
#       Layer 1 — restore_managed_block actually restores (original).
#       Layer 2 — the production ordering is in place: snapshot_pre_update
#                 writes BEFORE mutation, find_pre_update_snapshot prefers
#                 the pre-update path, restore reverts to PRIOR. Any future
#                 revert of finding 1 (codex r1) trips this.
#
#   T8 (NEW, codex r1 finding 2). `marker_active` honours
#       `kill -0 <pid>`: a dead-PID marker is NOT active even when fresh.
#       `marker_stale_pid` diagnostic agrees. Live-PID marker IS active.
#
#   T9 (NEW, codex r1 finding 3). `marker_write` applies explicit
#       `chmod 0640` + `chgrp ab-agent-<a>` under v2 isolation. Forcing
#       `umask 0077` before the write proves the chmod is doing the work
#       (otherwise the file would land 0600 and the iso UID — group
#       member — could not read it).
#
#   T10 (teeth, codex r1 finding 2). Re-defines `marker_active` to the
#       pre-fix shape (no PID gate) and asserts a dead-PID marker reads
#       ACTIVE — proving the test would catch any future revert.
#
#   T11 (teeth, codex r1 finding 3). Forces the iso branch on but
#       stubs the group resolver empty so the chmod/chgrp block is
#       skipped (= revert simulation). Asserts the marker mode is NOT
#       0640 under that revert.
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
  # Isolation predicate is toggled per-test via C1_ISO_ON env var so T9
  # (marker file mode) can exercise the iso-side chgrp/chmod branch in
  # bridge_agent_restart_marker_write without dragging the whole iso-v2
  # source tree in. Default OFF (return 1) keeps T1-T8 in the non-iso
  # branch (umask-default permissions).
  printf 'bridge_agent_linux_user_isolation_effective() { [[ "${C1_ISO_ON:-0}" == "1" ]]; }\n'
  printf 'bridge_resolve_engine_binary() { command -v "$1" 2>/dev/null; }\n'
  printf 'bridge_claude_plugin_status() { printf "%%s" "${C1_PLUGIN_STATUS:-enabled}"; }\n'
  # Stubs for the marker_write iso branch (#1251 r1 finding 3). The
  # group name maps to the operator's CURRENT primary group so a chgrp
  # call inside the smoke environment does not require sudo / the real
  # ab-agent-<a> group. C1_MARKER_GROUP_OVERRIDE lets T11 force the
  # branch into the "no group resolved → skip both ops" path so the
  # teeth assertion can prove the chmod-skipped state.
  printf 'bridge_host_platform() { printf "%%s" "${C1_HOST_PLATFORM_OVERRIDE:-Linux}"; }\n'
  printf 'bridge_isolation_v2_agent_group_name() { if [[ -n "${C1_MARKER_GROUP_OVERRIDE-}" ]]; then printf "%%s" "$C1_MARKER_GROUP_OVERRIDE"; else id -gn 2>/dev/null; fi; }\n'
  printf 'bridge_linux_sudo_root() { "$@"; }\n'
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
  extract_function bridge_agent_restart_marker_stale_pid "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_marker_clear "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_snapshot_managed_block "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_snapshot_pre_update "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_find_pre_update_snapshot "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_restore_managed_block "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_preflight_full_reason "$REPO_ROOT/lib/bridge-agents.sh"
  extract_function bridge_agent_restart_preflight_full_guidance "$REPO_ROOT/lib/bridge-agents.sh"
} >"$FUNCS_FILE"

for fn in bridge_agent_restart_state_dir bridge_agent_restart_marker_path \
          bridge_agent_restart_snapshot_path bridge_agent_restart_marker_write \
          bridge_agent_restart_marker_read_field bridge_agent_restart_marker_active \
          bridge_agent_restart_marker_stale_pid \
          bridge_agent_restart_marker_clear bridge_agent_restart_snapshot_managed_block \
          bridge_agent_restart_snapshot_pre_update \
          bridge_agent_restart_find_pre_update_snapshot \
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
    # Write a marker with our LIVE PID so marker_active can validate
    # both TTL and PID-liveness gates in the round-trip. (Codex r1
    # finding 2 added the kill -0 check; a hardcoded fake PID like
    # 12345 would no longer read ACTIVE.)
    printf 'bridge_agent_restart_marker_write "%s" $$ 60 in_progress ""\n' "$AGENT"
    # Read each field.
    printf 'pid_val="$(bridge_agent_restart_marker_read_field "%s" pid)"\n' "$AGENT"
    printf 'if [[ "$pid_val" =~ ^[0-9]+$ ]]; then printf "pid=NUMERIC\\n"; else printf "pid=BAD\\n"; fi\n'
    printf 'printf "ttl=%%s\\n" "$(bridge_agent_restart_marker_read_field "%s" ttl)"\n' "$AGENT"
    printf 'printf "state=%%s\\n" "$(bridge_agent_restart_marker_read_field "%s" state)"\n' "$AGENT"
    printf 'started="$(bridge_agent_restart_marker_read_field "%s" started)"\n' "$AGENT"
    printf 'if [[ "$started" =~ ^[0-9]+$ ]]; then printf "started=NUMERIC\\n"; else printf "started=BAD\\n"; fi\n'
    # Active check (in_progress + fresh + alive PID).
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
  smoke_assert_contains "$out" "pid=NUMERIC" "T2.a: pid field round-trips as a unix pid"
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
# T3 — PRODUCTION ordering rollback path (codex r1 finding 1).
#
# Production flow (the case the issue trace describes):
#   Step 1: operator runs `agent update --channels-add <new>` →
#           `run_update` writes the pre-update snapshot (LAST-KNOWN-GOOD
#           block), then mutates the roster.
#   Step 2: operator runs `agent restart` → `run_restart` calls
#           `find_pre_update_snapshot`, gets the LAST-KNOWN-GOOD path,
#           starts the launch.
#   Step 3: launch fails (e.g. plugin not seeded) → rollback restores
#           from the pre-update snapshot.
#
# The PRIOR T3 used the INVERSE ordering (snapshot AFTER mutation) which
# would have masked finding 1: an at-entry snapshot taken AFTER the
# update would capture the FAILING config and "restore" would put the
# broken config back in place of broken config. This T3 walks the
# production path and asserts the prior (working) config is restored.
# ---------------------------------------------------------------------------
step_t3_rollback_production_ordering() {
  smoke_log "T3: PRODUCTION ordering — pre-update snapshot lands LAST-KNOWN-GOOD; rollback restores it"

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
    # ---- Step 1 (operator): seed the PRIOR (working) config. ----
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_CHANNELS["%s"]="plugin:teams@agent-bridge"\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --prior"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    # ---- Step 1 (continued): pre-update snapshot captured by run_update
    #      BEFORE the writer mutates the roster. ----
    printf 'pre_snap="$(bridge_agent_restart_snapshot_pre_update "%s")"\n' "$AGENT"
    printf 'printf "pre-update-snapshot=%%s\\n" "$pre_snap"\n'
    printf 'if [[ -f "$pre_snap" ]]; then printf "pre-update-snapshot-file=present\\n"; else printf "pre-update-snapshot-file=absent\\n"; fi\n'
    # Verify the pre-update snapshot captured the PRIOR config (not the
    # post-mutation one).
    printf 'if grep -qF "claude --prior" "$pre_snap"; then printf "pre-update-snapshot-content=prior\\n"; else printf "pre-update-snapshot-content=NOT-prior\\n"; fi\n'
    # ---- Step 1 (continued): `agent update` mutates the roster to the
    #      NEW (failing) config. ----
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_CHANNELS["%s"]="plugin:teams@agent-bridge,plugin:cosmax-crm@cosmax-marketplace"\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --new-failing-launch"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    printf 'if grep -qF "claude --new-failing-launch" "$BRIDGE_ROSTER_LOCAL_FILE"; then printf "post-mutation-roster=failing\\n"; fi\n'
    # ---- Step 2 (operator): `agent restart` enters `run_restart`. The
    #      selector picks the pre-update snapshot (LAST-KNOWN-GOOD), NOT
    #      an at-entry snapshot of the now-failing roster. ----
    printf 'selected="$(bridge_agent_restart_find_pre_update_snapshot "%s")"\n' "$AGENT"
    printf 'printf "selected-snapshot=%%s\\n" "$selected"\n'
    printf 'if [[ "$selected" == "$pre_snap" ]]; then printf "selector-prefers-pre-update=yes\\n"; else printf "selector-prefers-pre-update=no\\n"; fi\n'
    # ---- Step 3 (mid-flight launch failure): write rolled_back marker
    #      + restore from the selected snapshot. ----
    printf 'bridge_agent_restart_marker_write "%s" $$ 60 rolled_back "launch-failed: simulated"\n' "$AGENT"
    printf 'if bridge_agent_restart_restore_managed_block "%s" "$selected"; then printf "restore=ok\\n"; else printf "restore=FAIL\\n"; fi\n' "$AGENT"
    # Final state assertions (the ones that fail when finding 1 is
    # reverted): roster MUST contain PRIOR launch_cmd, NOT the failing
    # one.
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
  smoke_assert_contains "$out" "pre-update-snapshot-file=present"      "T3.a: pre-update snapshot file landed before mutation"
  smoke_assert_contains "$out" "pre-update-snapshot-content=prior"     "T3.b: pre-update snapshot captured PRIOR (working) config"
  smoke_assert_contains "$out" "post-mutation-roster=failing"          "T3.c: post-mutation roster carries the failing launch_cmd"
  smoke_assert_contains "$out" "selector-prefers-pre-update=yes"       "T3.d: run_restart selector prefers the pre-update snapshot"
  smoke_assert_contains "$out" "restore=ok"                            "T3.e: restore helper returned ok"
  smoke_assert_contains "$out" "post-rollback-launch=prior"            "T3.f: roster contains PRIOR launch_cmd after rollback"
  smoke_assert_contains "$out" "post-rollback-failing-still-present=no" "T3.g: the failing launch_cmd is gone"
  smoke_assert_contains "$out" "marker-state=rolled_back"              "T3.h: marker state=rolled_back after rollback"
  smoke_assert_contains "$out" "marker-reason-prefix=launch-failed"    "T3.i: marker reason carries the structured tag prefix"
  smoke_assert_contains "$out" "marker-reason-has-detail=yes"          "T3.j: marker reason carries the detail substring"

  smoke_log "T3 PASS — production ordering rollback restores prior config via pre-update snapshot"
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
    # Hand-write an expired marker (started=now-9999, ttl=60). Use $$
    # for the PID so the PID-liveness gate (codex r1 finding 2) is
    # satisfied — the test target here is the TTL gate, not PID.
    printf 'marker="$(bridge_agent_restart_marker_path "%s")"\n' "$AGENT"
    printf 'now="$(date +%%s)"\n'
    printf 'expired_started=$(( now - 9999 ))\n'
    printf 'cat >"$marker" <<EOF\n'
    printf 'pid=$$\n'
    printf 'started=$expired_started\n'
    printf 'ttl=60\n'
    printf 'state=in_progress\n'
    printf 'EOF\n'
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "expired-active=yes\\n"; else printf "expired-active=no\\n"; fi\n' "$AGENT"
    # Now write a fresh marker via the production helper (default pid=$$).
    printf 'bridge_agent_restart_marker_write "%s" $$ 60 in_progress ""\n' "$AGENT"
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "fresh-active=yes\\n"; else printf "fresh-active=no\\n"; fi\n' "$AGENT"
    # And a marker in state=rolled_back (terminal — NOT active even if fresh + alive).
    printf 'bridge_agent_restart_marker_write "%s" $$ 60 rolled_back "launch-failed: t4"\n' "$AGENT"
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
  # Seed multiple snapshot files from "prior crashed restarts" — mix the
  # at-entry shape (`restart.snapshot.<ts>`) with the production-ordering
  # pre-update shape (`restart.snapshot.pre-update.<ts>`) so the cleanup
  # sweep is asserted against BOTH shapes (codex r1 finding 1 added the
  # second shape; without sweeping it, pre-update snapshots would
  # accumulate forever).
  : >"$state_dir/restart.snapshot.111"
  : >"$state_dir/restart.snapshot.222"
  : >"$state_dir/restart.snapshot.333"
  : >"$state_dir/restart.snapshot.pre-update.444"
  : >"$state_dir/restart.snapshot.pre-update.555"
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
# T6 (teeth, EXTENDED) — assert the rollback PATH + production ordering
# are both in place.
#
# Layer 1: original teeth — if a future PR drops the restore call from
# the rollback path, the roster keeps --broken-config and this trips.
#
# Layer 2: finding-1 teeth (codex r1) — if a future PR reverts the
# snapshot selector to the INVERSE ordering (snapshot AFTER mutation),
# `find_pre_update_snapshot` would return empty AND the at-entry
# snapshot would capture the post-mutation (failing) block. The
# assertion runs the production flow start-to-finish: pre-update
# snapshot → mutate → select → restore → roster MUST carry the prior
# working config, NOT the failing one.
# ---------------------------------------------------------------------------
step_t6_teeth_revert_rollback_would_fail() {
  smoke_log "T6 (teeth): without restore + pre-update snapshot ordering, prior config would be lost"

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
    # ---- Layer 1: original restore-helper teeth (snapshot via the
    #      at-entry helper, simulate restore, verify roster reverted). ----
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --prior-working"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    printf 'snap="$(bridge_agent_restart_snapshot_managed_block "%s")"\n' "$AGENT"
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --broken-config"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    printf 'bridge_agent_restart_restore_managed_block "%s" "$snap"\n' "$AGENT"
    printf 'if grep -qF "claude --broken-config" "$BRIDGE_ROSTER_LOCAL_FILE"; then\n'
    printf '  printf "TEETH-REGRESSION=#1251 — rollback dropped restore_managed_block; agent would be left running broken config after restart failure\\n"\n'
    printf '  exit 7\n'
    printf 'fi\n'
    printf 'if ! grep -qF "claude --prior-working" "$BRIDGE_ROSTER_LOCAL_FILE"; then\n'
    printf '  printf "TEETH-REGRESSION=#1251 — restore did not put prior config back\\n"\n'
    printf '  exit 8\n'
    printf 'fi\n'
    printf 'printf "teeth-layer1-ok=yes\\n"\n'
    # ---- Layer 2: production-ordering teeth (finding 1). Reset to a
    #      clean roster + state and walk the full flow that codex called
    #      out. ----
    printf ': >"$BRIDGE_ROSTER_LOCAL_FILE"\n'
    printf 'rm -rf "$BRIDGE_STATE_DIR/agents/%s"\n' "$AGENT"
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --pre-update-working"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    # Step 1: pre-update snapshot, BEFORE mutation.
    printf 'pre_snap="$(bridge_agent_restart_snapshot_pre_update "%s")"\n' "$AGENT"
    printf 'if [[ -z "$pre_snap" || ! -f "$pre_snap" ]]; then\n'
    printf '  printf "TEETH-REGRESSION=#1251 finding 1 — bridge_agent_restart_snapshot_pre_update did not write a snapshot before mutation; rollback would restore the FAILING config\\n"\n'
    printf '  exit 9\n'
    printf 'fi\n'
    # Step 2: mutate the roster to the failing config.
    printf 'cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF\n'
    printf '# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'BRIDGE_AGENT_LAUNCH_CMD["%s"]="claude --post-update-broken"\n' "$AGENT"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$AGENT"
    printf 'EOF\n'
    # Step 3: selector MUST return the pre-update snapshot.
    printf 'selected="$(bridge_agent_restart_find_pre_update_snapshot "%s")"\n' "$AGENT"
    printf 'if [[ "$selected" != "$pre_snap" ]]; then\n'
    printf '  printf "TEETH-REGRESSION=#1251 finding 1 — find_pre_update_snapshot did NOT prefer the pre-update path; selector=%%s pre_snap=%%s\\n" "$selected" "$pre_snap"\n'
    printf '  exit 10\n'
    printf 'fi\n'
    # Step 4: restore from selected snapshot; roster MUST be the working config.
    printf 'bridge_agent_restart_restore_managed_block "%s" "$selected"\n' "$AGENT"
    printf 'if ! grep -qF "claude --pre-update-working" "$BRIDGE_ROSTER_LOCAL_FILE"; then\n'
    printf '  printf "TEETH-REGRESSION=#1251 finding 1 — post-rollback roster does not carry pre-update working config (codex r1: \\"snapshot taken AFTER channel update applies\\" symptom)\\n"\n'
    printf '  exit 11\n'
    printf 'fi\n'
    printf 'if grep -qF "claude --post-update-broken" "$BRIDGE_ROSTER_LOCAL_FILE"; then\n'
    printf '  printf "TEETH-REGRESSION=#1251 finding 1 — failing config still present after rollback (restore restored failing-over-failing)\\n"\n'
    printf '  exit 12\n'
    printf 'fi\n'
    printf 'printf "teeth-layer2-ok=yes\\n"\n'
  } >"$driver"

  local out rc
  out="$("$BRIDGE_BASH" "$driver" 2>&1)" && rc=$? || rc=$?
  if (( rc != 0 )); then
    smoke_fail "T6 teeth: $out (rc=$rc)"
  fi
  smoke_assert_contains "$out" "teeth-layer1-ok=yes" "T6.a: rollback teeth intact (restore_managed_block still works)"
  smoke_assert_contains "$out" "teeth-layer2-ok=yes" "T6.b: production-ordering teeth intact (codex r1 finding 1)"

  smoke_log "T6 PASS — rollback + production-ordering teeth both confirmed"
}

# ---------------------------------------------------------------------------
# T8 (codex r1 finding 2) — marker_active honours kill -0 PID liveness.
#
# A crashed orchestrator (e.g. the operator's `agent restart` shell was
# killed mid-Phase-2) used to leave a marker that suppressed the
# watchdog for the full TTL window even though no rollback would ever
# fire. Treating a dead-PID marker as INACTIVE lets Lane C2 take over
# and recover. This test writes a marker with a definitely-dead PID
# (99999999 — well past Linux's pid_max default of 32768 but accepted
# by `kill -0` as a "no such process" check) and asserts the active
# predicate returns false.
# ---------------------------------------------------------------------------
step_t8_marker_active_pid_liveness() {
  smoke_log "T8: marker_active treats a dead-PID marker as INACTIVE (codex r1 finding 2)"

  rm -rf "$BRIDGE_STATE_DIR/agents/$AGENT" 2>/dev/null || true
  mkdir -p "$BRIDGE_STATE_DIR/agents/$AGENT"

  local driver="$SMOKE_TMP_ROOT/t8-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'source %q\n' "$FUNCS_FILE"
    # Hand-write a marker with a definitely-dead PID, fresh started, ample TTL.
    printf 'marker="$(bridge_agent_restart_marker_path "%s")"\n' "$AGENT"
    printf 'now="$(date +%%s)"\n'
    printf 'cat >"$marker" <<EOF\n'
    printf 'pid=99999999\n'
    printf 'started=$now\n'
    printf 'ttl=600\n'
    printf 'state=in_progress\n'
    printf 'EOF\n'
    # Confirm the PID is dead from the smoke's perspective.
    printf 'if kill -0 99999999 2>/dev/null; then printf "pid-check=alive\\n"; else printf "pid-check=dead\\n"; fi\n'
    # marker_active MUST return false for a dead-PID marker even though
    # TTL is fresh.
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "marker-active=yes\\n"; else printf "marker-active=no\\n"; fi\n' "$AGENT"
    # stale_pid diagnostic MUST agree.
    printf 'if bridge_agent_restart_marker_stale_pid "%s"; then printf "stale-pid=yes\\n"; else printf "stale-pid=no\\n"; fi\n' "$AGENT"
    # And the live-PID positive case: re-write with $$ (our PID — alive).
    printf 'cat >"$marker" <<EOF\n'
    printf 'pid=$$\n'
    printf 'started=$now\n'
    printf 'ttl=600\n'
    printf 'state=in_progress\n'
    printf 'EOF\n'
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "live-marker-active=yes\\n"; else printf "live-marker-active=no\\n"; fi\n' "$AGENT"
    printf 'if bridge_agent_restart_marker_stale_pid "%s"; then printf "live-stale-pid=yes\\n"; else printf "live-stale-pid=no\\n"; fi\n' "$AGENT"
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  smoke_assert_contains "$out" "pid-check=dead"        "T8.a: probe PID 99999999 is dead"
  smoke_assert_contains "$out" "marker-active=no"      "T8.b: marker_active=no on dead-PID marker (codex r1 finding 2)"
  smoke_assert_contains "$out" "stale-pid=yes"         "T8.c: marker_stale_pid diagnostic agrees"
  smoke_assert_contains "$out" "live-marker-active=yes" "T8.d: marker_active=yes on live-PID marker"
  smoke_assert_contains "$out" "live-stale-pid=no"     "T8.e: marker_stale_pid=no when PID is alive"

  smoke_log "T8 PASS — PID liveness gate is wired correctly"
}

# ---------------------------------------------------------------------------
# T9 (codex r1 finding 3) — marker file mode 0640 + group=ab-agent-<a>
# under v2 isolation.
#
# Default umask leaves the marker mode=0600, which the iso UID cannot
# read — Lane C2 watchdog probes from the iso side would fail with
# EACCES. The writer applies an explicit chmod 0640 + chgrp
# ab-agent-<a> AFTER the atomic rename, so both the controller (owner
# write) and the iso UID (group read) can reach the marker.
#
# This test forces the iso branch on (C1_ISO_ON=1) with the stub
# `bridge_isolation_v2_agent_group_name` mapping to the operator's
# current primary group so the chgrp call lands without sudo.
# ---------------------------------------------------------------------------
step_t9_marker_file_mode() {
  smoke_log "T9: marker writer enforces mode 0640 + chgrp under v2 isolation (codex r1 finding 3)"

  rm -rf "$BRIDGE_STATE_DIR/agents/$AGENT" 2>/dev/null || true
  mkdir -p "$BRIDGE_STATE_DIR/agents/$AGENT"

  # The stub's group name defaults to id -gn (operator's current primary
  # group). Capture it here so the assertion can compare.
  local expected_group
  expected_group="$(id -gn)"

  local driver="$SMOKE_TMP_ROOT/t9-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'export C1_ISO_ON=1\n'
    printf 'export C1_HOST_PLATFORM_OVERRIDE=Linux\n'
    printf 'source %q\n' "$FUNCS_FILE"
    # Force a restrictive umask first to demonstrate the chmod fix:
    # without the explicit chmod the file would land 0600.
    printf 'umask 0077\n'
    printf 'bridge_agent_restart_marker_write "%s" 12345 60 in_progress ""\n' "$AGENT"
    printf 'marker="$(bridge_agent_restart_marker_path "%s")"\n' "$AGENT"
    # Stat mode in octal — portable across GNU/BSD coreutils via `stat -f`
    # (BSD) and `stat -c` (GNU). We try both forms; whichever succeeds
    # wins. The mode bits we care about are the last 3 octal digits.
    printf 'mode="$(stat -c "%%a" "$marker" 2>/dev/null || stat -f "%%Lp" "$marker" 2>/dev/null || printf unknown)"\n'
    printf 'printf "marker-mode=%%s\\n" "$mode"\n'
    printf 'group="$(stat -c "%%G" "$marker" 2>/dev/null || stat -f "%%Sg" "$marker" 2>/dev/null || printf unknown)"\n'
    printf 'printf "marker-group=%%s\\n" "$group"\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  smoke_assert_contains "$out" "marker-mode=640"  "T9.a: marker mode is 0640 (controller owner-rw + iso-group r)"
  smoke_assert_contains "$out" "marker-group=$expected_group" "T9.b: marker group set to ab-agent-<a> (stubbed to operator group)"

  smoke_log "T9 PASS — marker file mode + group are explicitly applied"
}

# ---------------------------------------------------------------------------
# T10 (teeth, codex r1 finding 2) — revert the PID check → marker_active
# returns YES on a dead-PID marker.
#
# Builds a snapshot of the pre-fix `marker_active` (no kill -0 gate),
# sources it over the production helper, and asserts the regression
# detection: with the dead-PID marker the reverted predicate returns
# true (the BUG), proving this test would catch any future revert.
# ---------------------------------------------------------------------------
step_t10_teeth_marker_active_without_pid_check() {
  smoke_log "T10 (teeth): without the PID liveness gate, marker_active=YES on a dead PID"

  rm -rf "$BRIDGE_STATE_DIR/agents/$AGENT" 2>/dev/null || true
  mkdir -p "$BRIDGE_STATE_DIR/agents/$AGENT"

  local driver="$SMOKE_TMP_ROOT/t10-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'source %q\n' "$FUNCS_FILE"
    # Re-define marker_active as the PRE-FIX version (no PID gate).
    printf 'bridge_agent_restart_marker_active() {\n'
    printf '  local agent="$1"; local started ttl state now\n'
    printf '  started="$(bridge_agent_restart_marker_read_field "$agent" started)"\n'
    printf '  ttl="$(bridge_agent_restart_marker_read_field "$agent" ttl)"\n'
    printf '  state="$(bridge_agent_restart_marker_read_field "$agent" state)"\n'
    printf '  [[ -n "$started" && -n "$ttl" ]] || return 1\n'
    printf '  [[ "$state" == "in_progress" ]] || return 1\n'
    printf '  now="$(date +%%s)"\n'
    printf '  [[ "$started" =~ ^[0-9]+$ && "$ttl" =~ ^[0-9]+$ ]] || return 1\n'
    printf '  (( now < started + ttl )) || return 1\n'
    printf '  return 0\n'
    printf '}\n'
    printf 'marker="$(bridge_agent_restart_marker_path "%s")"\n' "$AGENT"
    printf 'now="$(date +%%s)"\n'
    printf 'cat >"$marker" <<EOF\n'
    printf 'pid=99999999\n'
    printf 'started=$now\n'
    printf 'ttl=600\n'
    printf 'state=in_progress\n'
    printf 'EOF\n'
    # With the PID gate reverted, dead-PID marker reads ACTIVE — that is
    # the BUG codex r1 finding 2 fixed. If a future PR reverts the gate,
    # this exits 0 with reverted-marker-active=YES — meaning the
    # OUTER assertion will trip on the "yes" expectation below.
    printf 'if bridge_agent_restart_marker_active "%s"; then printf "reverted-marker-active=yes\\n"; else printf "reverted-marker-active=no\\n"; fi\n' "$AGENT"
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  smoke_assert_contains "$out" "reverted-marker-active=yes" \
    "T10: simulated revert MUST surface the bug (reverted marker_active returns YES on dead PID — codex r1 finding 2)"

  smoke_log "T10 PASS — teeth confirm a future PID-gate revert would be caught"
}

# ---------------------------------------------------------------------------
# T11 (teeth, codex r1 finding 3) — revert the chmod/chgrp → marker mode
# is umask-default (0600), not 0640.
#
# This test forces the iso branch ON but stubs the agent group resolver
# to return EMPTY — that disables the chgrp/chmod block exactly as the
# pre-fix code did. The assertion then proves the marker mode is NOT
# 0640 under that revert.
# ---------------------------------------------------------------------------
step_t11_teeth_marker_mode_without_explicit_chmod() {
  smoke_log "T11 (teeth): without the explicit chmod/chgrp, marker mode is umask-default (not 0640)"

  rm -rf "$BRIDGE_STATE_DIR/agents/$AGENT" 2>/dev/null || true
  mkdir -p "$BRIDGE_STATE_DIR/agents/$AGENT"

  local driver="$SMOKE_TMP_ROOT/t11-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export BRIDGE_STATE_DIR=%q\n' "$BRIDGE_STATE_DIR"
    printf 'export C1_ISO_ON=1\n'
    printf 'export C1_HOST_PLATFORM_OVERRIDE=Linux\n'
    # Force the group resolver to return empty so the chmod/chgrp block
    # is skipped entirely (= a code-level revert of the explicit
    # permissions fix). The post-revert state is umask-default mode.
    printf 'export C1_MARKER_GROUP_OVERRIDE=""\n'
    printf 'source %q\n' "$FUNCS_FILE"
    # Override the resolver function INSIDE the driver because the
    # FUNCS_FILE stub already returned non-empty (id -gn). Re-define it
    # to honour C1_MARKER_GROUP_OVERRIDE strictly: empty means "not
    # resolvable", which is what the pre-fix code-path looked like.
    printf 'bridge_isolation_v2_agent_group_name() { printf "%%s" "${C1_MARKER_GROUP_OVERRIDE-}"; }\n'
    printf 'umask 0077\n'
    printf 'bridge_agent_restart_marker_write "%s" 12345 60 in_progress ""\n' "$AGENT"
    printf 'marker="$(bridge_agent_restart_marker_path "%s")"\n' "$AGENT"
    printf 'mode="$(stat -c "%%a" "$marker" 2>/dev/null || stat -f "%%Lp" "$marker" 2>/dev/null || printf unknown)"\n'
    printf 'printf "reverted-marker-mode=%%s\\n" "$mode"\n'
  } >"$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver")"
  # The bug surface: mode is NOT 640 when the resolver is unable to map
  # the agent group (i.e. the pre-fix branch). Asserting "not 640" gives
  # the test teeth without coupling to a single OS's umask quirk.
  if [[ "$out" == *"reverted-marker-mode=640"* ]]; then
    smoke_fail "T11: reverted marker writer landed mode 640 — the teeth cannot detect a chmod revert (codex r1 finding 3)"
  fi
  smoke_assert_contains "$out" "reverted-marker-mode=" "T11: reverted writer ran but did not apply 0640 explicitly"

  smoke_log "T11 PASS — teeth confirm a future chmod/chgrp revert would be caught"
}

step_t1_preflight_blocks_kill
step_t2_marker_write_read_clear
step_t3_rollback_production_ordering
step_t4_marker_ttl_expiry
step_t5_snapshot_cleanup_on_success
step_t6_teeth_revert_rollback_would_fail
step_t8_marker_active_pid_liveness
step_t9_marker_file_mode
step_t10_teeth_marker_active_without_pid_check
step_t11_teeth_marker_mode_without_explicit_chmod

smoke_log "all cases PASS"
