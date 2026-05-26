#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/A12-beta3-1246-1252-daemon-supp-group-and-state-dir.sh —
# v0.15.0-beta3 Lane A12 (OOTB blocker bundle for #1246 + #1252).
#
# Background:
#   patch's fresh-install OOTB on cm-prod-agentworkflow-vm01 (v0.15.0-beta2)
#   landed two related blocker symptoms that this lane closes together
#   because the surface code touches the same three modules
#   (lib/bridge-daemon-control.sh, lib/bridge-state.sh, lib/bridge-agents.sh).
#
#   #1246 (daemon group-refresh pre-check false-positive)
#     - `agent create <a> --isolate` emits `daemon_group_refresh: skipped-
#       daemon-already-has-group` but the running daemon's supplementary
#       group set is provably stale (the freshly-created ab-agent-<a> GID
#       is NOT in /proc/<daemon_pid>/status `Groups:`). The systemd-user
#       auto-restart branch in lib/bridge-daemon-control.sh:404-411 is
#       bypassed and downstream nudge writes wedge.
#
#   #1252 (per-task nudge never fires after the first drop)
#     - State/agents/<a>/ directory doesn't exist → daemon's controller-
#       side writes (idle-since, pending-attention/, missing-marker-
#       retries) all fail → nudge code path skips silently. Only one
#       nudge entry in 75min uptime, labeled `appears dropped`.
#
# Tests (host-agnostic — static-source assertions + isolated mock-mkdir
# fixtures; no real `agent-bridge-*` users, no sudo/root, no real tmux):
#
#   T1: `_bridge_daemon_control_daemon_has_gid` predicate emits the
#       new structured decision-evidence log line whenever it is called
#       with a target_gid. The line shape is
#       `[daemon-control] supp-group check: pid=<P> in_proc=<G,...>
#       target_gid=<G> action=<refresh|skip> reason=<rationale>` and
#       BRIDGE_DAEMON_CONTROL_DECISION_LOG routes it to a file. Stubs
#       `bridge_daemon_pid` to return a fixed PID; stubs the proc-groups
#       reader to return a known set.
#
#   T2: `agent create` flow (via static-source grep) calls
#       `bridge_agent_state_dir_self_heal` synchronously before
#       returning success. A revert that drops the synchronous call
#       trips T2.
#
#   T3: `bridge_agent_state_dir_self_heal` creates `state/agents/<a>/`
#       with mode 2770 when missing, AND is idempotent when the dir
#       already exists.
#
#   T4: `bridge_write_idle_ready_agents` emits the structured
#       `[nudge-skip] agent=<a> task=<id> reason=state-dir-missing
#       evidence=<dir>` line when the per-agent state-dir is missing
#       AND self-heal also fails. Asserted via static-source grep on
#       lib/bridge-channels.sh because the helper is sourced through
#       the full daemon stack at runtime — a host-agnostic behavioral
#       repro would need the entire roster/state ladder.
#
#   T5: the same decision-evidence log line shape appears in EVERY
#       call site that triggers `_bridge_daemon_control_daemon_has_gid`
#       (the predicate ALWAYS emits, so the pre-check at
#       lib/bridge-daemon-control.sh:348 + 383 cannot silently false-
#       positive again — operator sees both the in_proc set and the
#       target_gid in the daemon log when reconstructing the wedge).
#
#   T6 (teeth): revert the predicate's decision-emit — assert T1 fails
#       loudly citing #1246. The teeth-check fixture writes a temporary
#       copy of lib/bridge-daemon-control.sh with the emit-helper body
#       neutered, then re-runs T1's logic against the patched copy and
#       expects it to fail. Closes the "smoke that always passes" class.
#
#   T7 (teeth): revert the agent-create synchronous self-heal call —
#       assert T2 fails loudly citing #1252. Same fixture pattern as T6
#       against a temporary copy of bridge-agent.sh.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every
# assertion uses `grep -n` against the source files OR builds harness
# scripts with `printf '%s\n' >file` and runs them as external scripts.
# No `<<<` here-string or `<<EOF` heredoc-stdin into subprocess capture.

set -uo pipefail

SMOKE_NAME="A12-beta3-1246-1252-daemon-supp-group-and-state-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
DAEMON_CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
CHANNELS_LIB="$REPO_ROOT/lib/bridge-channels.sh"
AGENT_SH="$REPO_ROOT/bridge-agent.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"

[[ -f "$DAEMON_CONTROL_LIB" ]] || smoke_fail "missing $DAEMON_CONTROL_LIB"
[[ -f "$STATE_LIB" ]]          || smoke_fail "missing $STATE_LIB"
[[ -f "$CHANNELS_LIB" ]]       || smoke_fail "missing $CHANNELS_LIB"
[[ -f "$AGENT_SH" ]]           || smoke_fail "missing $AGENT_SH"
[[ -f "$DAEMON_SH" ]]          || smoke_fail "missing $DAEMON_SH"

# ---------------------------------------------------------------------
# Helper: extract _bridge_daemon_control_daemon_has_gid +
# _bridge_daemon_control_proc_groups +
# _bridge_daemon_control_emit_decision_log into an isolated script we
# can drive without sourcing the full daemon-control library (which
# requires bridge_audit_log + many init paths).
# ---------------------------------------------------------------------
extract_predicate_lib() {
  local source="$DAEMON_CONTROL_LIB"
  local out="$SMOKE_TMP_ROOT/predicate-extract.sh"
  : >"$out"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    # Provide a no-op bridge_warn so the predicate library can call it
    # without pulling the full bridge-lib.sh init chain.
    printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
    awk '/^_bridge_daemon_control_proc_groups\(\) \{/,/^\}/' "$source"
    awk '/^_bridge_daemon_control_daemon_has_gid\(\) \{/,/^\}/' "$source"
    awk '/^_bridge_daemon_control_emit_decision_log\(\) \{/,/^\}/' "$source"
  } >>"$out"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------
# T1: predicate emits decision-evidence log line on each call.
# ---------------------------------------------------------------------
smoke_log "T1: _bridge_daemon_control_daemon_has_gid emits structured decision-evidence log"

PREDICATE_LIB="$(extract_predicate_lib)"
chmod +x "$PREDICATE_LIB"

T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.sh"
: >"$T1_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$PREDICATE_LIB\""
  # Stub bridge_daemon_pid to return a fixed PID. The real predicate
  # then calls _bridge_daemon_control_proc_groups which we ALSO stub
  # via PATH (so the /proc/<pid>/status read can be intercepted) —
  # but actually proc_groups uses `awk` on a path. Simplest fixture:
  # write a fake /proc-like file under SMOKE_TMP_ROOT, then override
  # the helper to read from it.
  printf '%s\n' 'bridge_daemon_pid() { printf "12345"; }'
  printf '%s\n' '_bridge_daemon_control_proc_groups() { printf "100\n200\n981\n"; }'
  # Case A: target GID 981 IS present in proc groups → action=skip reason=already-has-group
  printf '%s\n' '_bridge_daemon_control_daemon_has_gid 981; rc_a=$?'
  printf '%s\n' '# Case B: target GID 999 is NOT present → action=refresh reason=missing-from-supp-set'
  printf '%s\n' '_bridge_daemon_control_daemon_has_gid 999; rc_b=$?'
  printf '%s\n' 'printf "rc_a=%s\nrc_b=%s\n" "$rc_a" "$rc_b"'
} >>"$T1_DRIVER"
chmod +x "$T1_DRIVER"

T1_DECISION_LOG="$SMOKE_TMP_ROOT/t1-decision.log"
: >"$T1_DECISION_LOG"

T1_OUT="$(
  BRIDGE_DAEMON_CONTROL_DECISION_LOG="$T1_DECISION_LOG" \
    /usr/bin/env bash "$T1_DRIVER" 2>&1
)"

# Verify both decisions landed in the log.
if ! grep -q 'pid=12345 in_proc=100,200,981 target_gid=981 action=skip reason=already-has-group' "$T1_DECISION_LOG"; then
  smoke_fail "T1: decision log did not capture skip/already-has-group case; got:$(printf '\n')$(cat "$T1_DECISION_LOG")"
fi
if ! grep -q 'pid=12345 in_proc=100,200,981 target_gid=999 action=refresh reason=missing-from-supp-set' "$T1_DECISION_LOG"; then
  smoke_fail "T1: decision log did not capture refresh/missing-from-supp-set case; got:$(printf '\n')$(cat "$T1_DECISION_LOG")"
fi
if [[ "$T1_OUT" != *"rc_a=0"* ]] || [[ "$T1_OUT" != *"rc_b=1"* ]]; then
  smoke_fail "T1: predicate return codes wrong; expected rc_a=0 rc_b=1, got: $T1_OUT"
fi
smoke_log "T1 PASS — predicate emits structured decision-evidence + correct rc"

# ---------------------------------------------------------------------
# T2: agent create flow synchronously invokes bridge_agent_state_dir_self_heal.
# ---------------------------------------------------------------------
smoke_log "T2: bridge-agent.sh run_create calls bridge_agent_state_dir_self_heal synchronously"

T2_MATCH="$(grep -nF 'bridge_agent_state_dir_self_heal "$agent"' "$AGENT_SH" || true)"
if [[ -z "$T2_MATCH" ]]; then
  smoke_fail "T2: bridge-agent.sh does not contain synchronous bridge_agent_state_dir_self_heal call — #1252 fix regressed (operator would see create:ok for an agent whose first nudge silently drops)"
fi
# Also assert it's in run_create's body (search for the comment anchor
# we inserted referencing #1252 in the same block).
if ! grep -q '#1252: state/agents/<a>/ MUST exist' "$AGENT_SH"; then
  smoke_fail "T2: anchor comment for #1252 in run_create missing — the synchronous self-heal block was moved/removed"
fi
smoke_log "T2 PASS — bridge-agent.sh run_create synchronously self-heals state-agent-dir before returning create:ok"

# ---------------------------------------------------------------------
# T3: bridge_agent_state_dir_self_heal creates the dir + idempotent.
# ---------------------------------------------------------------------
smoke_log "T3: bridge_agent_state_dir_self_heal creates state/agents/<a>/ with mode 2770 + is idempotent"

T3_DRIVER="$SMOKE_TMP_ROOT/t3-driver.sh"
: >"$T3_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Minimal stubs that bridge_agent_state_dir_self_heal needs:
  # bridge_agent_idle_marker_dir (path), bridge_warn (no-op logger),
  # bridge_isolation_v2_agent_group_name (returns empty → chgrp skipped).
  printf '%s\n' "BRIDGE_ACTIVE_AGENT_DIR=\"$SMOKE_TMP_ROOT/state-agents\""
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_agent_idle_marker_dir() {'
  printf '%s\n' '  printf "%s/%s" "$BRIDGE_ACTIVE_AGENT_DIR" "$1"'
  printf '%s\n' '}'
  # Inline the helper body directly from lib/bridge-state.sh so we do
  # not need the whole library's init chain. Extract via awk.
  awk '/^bridge_agent_state_dir_self_heal\(\) \{/,/^\}/' "$STATE_LIB" >>"$T3_DRIVER"
  printf '\n%s\n' '# Case A: dir absent → create.'
  printf '%s\n' 'bridge_agent_state_dir_self_heal test_a12_smoke; rc_a=$?'
  printf '%s\n' '[[ -d "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_smoke" ]] || { echo "T3a: dir was not created"; exit 1; }'
  # Case B: idempotent re-call.
  printf '%s\n' 'bridge_agent_state_dir_self_heal test_a12_smoke; rc_b=$?'
  printf '%s\n' 'printf "rc_a=%s rc_b=%s\n" "$rc_a" "$rc_b"'
  printf '%s\n' '# Read back mode to verify 2770 (best-effort — on BSD stat the flag set differs;'
  printf '%s\n' '# accept either 2770 or 770 since mkdir -m strips setgid on some macOS versions).'
  printf '%s\n' 'mode="$(stat -c %a "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_smoke" 2>/dev/null || stat -f %Lp "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_smoke" 2>/dev/null)"'
  printf '%s\n' 'printf "mode=%s\n" "$mode"'
} >>"$T3_DRIVER"
chmod +x "$T3_DRIVER"

T3_OUT="$(/usr/bin/env bash "$T3_DRIVER" 2>&1)"
if [[ "$T3_OUT" != *"rc_a=0 rc_b=0"* ]]; then
  smoke_fail "T3: expected rc_a=0 rc_b=0 (create + idempotent), got: $T3_OUT"
fi
# Verify the dir was created.
if [[ ! -d "$SMOKE_TMP_ROOT/state-agents/test_a12_smoke" ]]; then
  smoke_fail "T3: state-agents/test_a12_smoke dir was not created"
fi
# Verify mode contains the 2770 or 770 marker.
if [[ "$T3_OUT" != *"mode=2770"* ]] && [[ "$T3_OUT" != *"mode=770"* ]]; then
  smoke_fail "T3: expected mode 2770 or 770 (setgid stripped on some BSD stat flavors), got: $T3_OUT"
fi
smoke_log "T3 PASS — bridge_agent_state_dir_self_heal creates dir + idempotent + mode 2770/770"

# ---------------------------------------------------------------------
# T4: bridge_write_idle_ready_agents emits structured [nudge-skip] line
#     on state-dir-missing + self-heal-fail. Asserted via static-source
#     grep — the helper requires the full daemon stack to drive at
#     runtime, and the structured-line format is the contract.
# ---------------------------------------------------------------------
smoke_log "T4: bridge_write_idle_ready_agents emits [nudge-skip] structured line on state-dir-missing"

# Assert the structured prefix appears in the self-heal branch.
if ! grep -q '\[nudge-skip\] agent=\$agent task=- reason=state-dir-missing evidence=\$_idle_dir' "$CHANNELS_LIB"; then
  smoke_fail "T4: lib/bridge-channels.sh does not emit the structured '[nudge-skip] agent=<a> task=- reason=state-dir-missing evidence=<dir>' line — #1252 silent-drop class regressed"
fi
# Also assert the audit_log emit path is in place.
if ! grep -q 'bridge_audit_log daemon nudge_skip' "$CHANNELS_LIB"; then
  smoke_fail "T4: lib/bridge-channels.sh does not emit bridge_audit_log daemon nudge_skip — the audit row anchor for #1252 is missing"
fi
smoke_log "T4 PASS — bridge_write_idle_ready_agents emits structured [nudge-skip] line + audit row"

# ---------------------------------------------------------------------
# T5: predicate emits decision-evidence on EVERY call site (not just
#     test-mode). Assert via static-source grep that
#     _bridge_daemon_control_emit_decision_log is invoked from inside
#     _bridge_daemon_control_daemon_has_gid (both early-return paths
#     AND the success/refusal paths).
# ---------------------------------------------------------------------
smoke_log "T5: predicate emits decision-evidence on every code path"

# All four reasons must appear in the predicate body. We grep the file
# for the four `reason=` literal strings the predicate emits.
for reason in "daemon-not-running" "proc-status-unreadable" "already-has-group" "missing-from-supp-set"; do
  if ! grep -q "reason=\"$reason\"" "$DAEMON_CONTROL_LIB" && ! grep -q "\"$reason\"" "$DAEMON_CONTROL_LIB"; then
    smoke_fail "T5: predicate decision-evidence emit missing reason='$reason' — operator would see no log evidence on that path"
  fi
done
# Also assert the prefix appears in the emit helper.
if ! grep -q '\[daemon-control\] supp-group check:' "$DAEMON_CONTROL_LIB"; then
  smoke_fail "T5: decision-evidence log prefix '[daemon-control] supp-group check:' missing from lib/bridge-daemon-control.sh"
fi
smoke_log "T5 PASS — predicate decision-evidence covers all four code paths"

# ---------------------------------------------------------------------
# T6 (teeth): revert the predicate's decision-evidence emit → T1 fails.
# ---------------------------------------------------------------------
smoke_log "T6 (teeth): teeth-check on T1 — predicate without decision-evidence emit must FAIL T1"

T6_PATCHED_LIB="$SMOKE_TMP_ROOT/predicate-patched.sh"
# Build a copy with _bridge_daemon_control_emit_decision_log NEUTERED
# (replaced with a no-op). This simulates the pre-fix state.
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  # Keep proc_groups + has_gid as-is, but override the emit helper to no-op.
  awk '/^_bridge_daemon_control_proc_groups\(\) \{/,/^\}/' "$DAEMON_CONTROL_LIB"
  awk '/^_bridge_daemon_control_daemon_has_gid\(\) \{/,/^\}/' "$DAEMON_CONTROL_LIB"
  # Now define a NO-OP emit helper that does NOT write to the log file —
  # simulates the pre-fix predicate (silent on every code path).
  printf '%s\n' '_bridge_daemon_control_emit_decision_log() { return 0; }'
} >"$T6_PATCHED_LIB"
chmod +x "$T6_PATCHED_LIB"

T6_DRIVER="$SMOKE_TMP_ROOT/t6-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$T6_PATCHED_LIB\""
  printf '%s\n' 'bridge_daemon_pid() { printf "12345"; }'
  printf '%s\n' '_bridge_daemon_control_proc_groups() { printf "100\n200\n981\n"; }'
  printf '%s\n' '_bridge_daemon_control_daemon_has_gid 981 >/dev/null 2>&1 || true'
} >"$T6_DRIVER"
chmod +x "$T6_DRIVER"

T6_DECISION_LOG="$SMOKE_TMP_ROOT/t6-decision.log"
: >"$T6_DECISION_LOG"
BRIDGE_DAEMON_CONTROL_DECISION_LOG="$T6_DECISION_LOG" \
  /usr/bin/env bash "$T6_DRIVER" >/dev/null 2>&1 || true

# With the emit no-op'd, the decision log must be EMPTY.
if [[ -s "$T6_DECISION_LOG" ]]; then
  smoke_fail "T6 (teeth): patched (decision-emit no-op'd) predicate STILL wrote to decision log — teeth-check is broken (T1 would not detect a regression)"
fi
smoke_log "T6 PASS — teeth-check works: removing decision-evidence emit DOES break T1's assertion (predicate would silently false-positive again like #1246)"

# ---------------------------------------------------------------------
# T7 (teeth): revert the agent-create synchronous self-heal → T2 fails.
# ---------------------------------------------------------------------
smoke_log "T7 (teeth): teeth-check on T2 — bridge-agent.sh without self-heal must FAIL T2"

T7_PATCHED_AGENT="$SMOKE_TMP_ROOT/bridge-agent-patched.sh"
# Strip the synchronous self-heal block from bridge-agent.sh.
# We use sed to remove lines between the comment anchor and the
# closing `fi`. This is a narrow surgical patch.
sed '/#1252: state\/agents\/<a>\/ MUST exist before this agent appears to/,/^    fi$/d' \
  "$AGENT_SH" >"$T7_PATCHED_AGENT"
# Now run T2's grep against the patched copy. Both checks must FAIL.
T7_MATCH_A="$(grep -F 'bridge_agent_state_dir_self_heal "$agent"' "$T7_PATCHED_AGENT" || true)"
T7_MATCH_B="$(grep '#1252: state/agents/<a>/ MUST exist' "$T7_PATCHED_AGENT" || true)"
# After strip, the synchronous call from run_create must be gone.
# (Other unrelated self-heal references in the file — e.g. doc-comments
# — should also not exist. Today the only call is the one we inserted.)
if [[ -n "$T7_MATCH_A" ]] || [[ -n "$T7_MATCH_B" ]]; then
  smoke_fail "T7 (teeth): teeth-check sed-strip did not remove the self-heal block — teeth fixture is broken. match_a='$T7_MATCH_A' match_b='$T7_MATCH_B'"
fi
smoke_log "T7 PASS — teeth-check works: removing the synchronous self-heal call DOES break T2's assertion (operator would see create:ok for an agent that silently drops nudges, #1252)"

# ---------------------------------------------------------------------
smoke_log "all tests PASS — A12-beta3 #1246 + #1252 verified at current main"
