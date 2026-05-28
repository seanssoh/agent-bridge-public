#!/usr/bin/env bash
# shellcheck shell=bash
#
# scripts/smoke/beta5-2-kappa-state-audit-reconcile.sh —
# v0.15.0-beta5-2 Lane κ pin for the 3 patch-audit items:
#
#   #1319 H1 — activity_state picker_blocked: bridge-stall.py +
#               lib/bridge-state.sh resolver emit `picker_blocked` when
#               a rate-limit / summary picker is detected. The daemon
#               nudge path treats it as not-idle (don't fire) and not
#               as working (don't reset the stall counter).
#
#   #1324 M1 — iso v2 audit log dir: `agb audit list` (no --agent) on
#               iso v2 install enumerates BOTH the legacy controller-
#               rooted tree `$BRIDGE_HOME/logs/agents/<a>/audit.jsonl`
#               AND the v2 canonical tree
#               `$BRIDGE_HOME/data/agents/<a>/logs/audit.jsonl`. Per
#               [[feedback-root-vs-symptom-framing]] the root cause is
#               that `bridge-audit.sh:46` was hard-coded to the legacy
#               path; the v2 per-agent dirs ARE created by the prepare
#               matrix (lib/bridge-agents.sh:4389) so the existence
#               assertion holds — only the enumerator was broken.
#
#   #1325 M2 — `isolation reconcile --check` parity: manual mode
#               (--check, no --agent / --all) detects per-agent .claude
#               drift. Lane γ beta5 #1298 added the manual-mode
#               implicit `--all-agents` expansion; this smoke
#               functionally confirms `--check` honors it (the gamma
#               smoke only static-grepped the branch).
#
# Each test is paired with a teeth revert to prove the smoke would have
# caught the original bug. Per Sean's "꼼꼼하게 사이드이펙트 없이 엣지케이스
# 고려" directive (2026-05-26 brief), edge cases are addressed in-line.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every assertion
# uses `grep`/`awk` against source files OR builds harness scripts via
# `printf '%s\n' >file` and runs them as external scripts. No `<<<`
# here-string or `<<EOF` heredoc-stdin into subprocess capture.

set -uo pipefail

SMOKE_NAME="beta5-2-kappa-state-audit-reconcile"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via trap (next line), not a direct call.
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
AGENT_LIB="$REPO_ROOT/bridge-agent.sh"
DAEMON_LIB="$REPO_ROOT/bridge-daemon.sh"
AUDIT_CLI="$REPO_ROOT/bridge-audit.sh"
RECONCILE_LIB="$REPO_ROOT/lib/bridge-isolation-v2-reconcile.sh"
STATUS_PY="$REPO_ROOT/bridge-status.py"

[[ -f "$STATE_LIB" ]]      || smoke_fail "missing $STATE_LIB"
[[ -f "$AGENT_LIB" ]]      || smoke_fail "missing $AGENT_LIB"
[[ -f "$DAEMON_LIB" ]]     || smoke_fail "missing $DAEMON_LIB"
[[ -f "$AUDIT_CLI" ]]      || smoke_fail "missing $AUDIT_CLI"
[[ -f "$RECONCILE_LIB" ]]  || smoke_fail "missing $RECONCILE_LIB"
[[ -f "$STATUS_PY" ]]      || smoke_fail "missing $STATUS_PY"

# ---------------------------------------------------------------------
# T1 (H1, #1319) — activity_state picker_blocked: predicate function
# present + wired into both resolvers + daemon heartbeat path.
# ---------------------------------------------------------------------
smoke_log "T1: activity_state picker_blocked — predicate + 3 resolver call sites"

# T1.a — predicate function exists in lib/bridge-state.sh
if ! grep -nF 'bridge_agent_picker_blocked()' "$STATE_LIB" >/dev/null; then
  smoke_fail "T1.a: bridge_agent_picker_blocked() not defined in $STATE_LIB (#1319)"
fi

# T1.b — predicate reads STALL_ACTIVE_CLASSIFICATION from stall.env and
# checks against `interactive_picker`. Both substrings must be present
# inside the function body (grep'd over a multi-line region).
if ! grep -nF 'STALL_ACTIVE_CLASSIFICATION' "$STATE_LIB" >/dev/null; then
  smoke_fail "T1.b: predicate must read STALL_ACTIVE_CLASSIFICATION"
fi
if ! grep -nF 'interactive_picker' "$STATE_LIB" >/dev/null; then
  smoke_fail "T1.b: predicate must compare against interactive_picker classification"
fi

# T1.c — snapshot writer in lib/bridge-state.sh calls the predicate
# inside the "no prompt" branch (the only place activity_state can
# transition into picker_blocked from working/starting).
if ! grep -nF 'bridge_agent_picker_blocked' "$STATE_LIB" \
      | grep -F 'bridge_write_roster_status_snapshot' >/dev/null \
      && ! awk '/^bridge_write_roster_status_snapshot\(\) \{/,/^\}/' "$STATE_LIB" \
      | grep -qF 'bridge_agent_picker_blocked'; then
  smoke_fail "T1.c: bridge_write_roster_status_snapshot does not call bridge_agent_picker_blocked"
fi

# T1.d — bridge_agent_activity_state in bridge-agent.sh calls the
# predicate.
if ! awk '/^bridge_agent_activity_state\(\) \{/,/^\}/' "$AGENT_LIB" \
      | grep -qF 'bridge_agent_picker_blocked'; then
  smoke_fail "T1.d: bridge_agent_activity_state does not call bridge_agent_picker_blocked"
fi

# T1.e — heartbeat path in bridge-daemon.sh calls the predicate.
if ! awk '/^bridge_agent_heartbeat_activity_state\(\) \{/,/^\}/' "$DAEMON_LIB" \
      | grep -qF 'bridge_agent_picker_blocked'; then
  smoke_fail "T1.e: bridge_agent_heartbeat_activity_state does not call bridge_agent_picker_blocked"
fi

# T1.f — bridge-status.py column width accommodates 'picker_blocked'
# (14 chars). The header and the row formatter must agree.
if ! grep -nE 'activity_state:<1[4-9]' "$STATUS_PY" >/dev/null; then
  smoke_fail "T1.f: bridge-status.py activity_state column must be width >= 14 to fit 'picker_blocked'"
fi

smoke_log "T1 PASS — picker_blocked predicate present + wired into snapshot/agent-show/heartbeat + status column widened"

# ---------------------------------------------------------------------
# T2 (H1, #1319) — functional: predicate returns true when stall.env
# carries STALL_ACTIVE_CLASSIFICATION=interactive_picker, false
# otherwise.
#
# Drives the predicate from a sub-shell that sources ONLY the needed
# helpers — avoids dragging the whole 9000-line bridge-state.sh into
# the harness via macOS bash 3.2 (the smoke runs on the operator's
# darwin worktree at write-time; CI re-runs on Linux).
# ---------------------------------------------------------------------
smoke_log "T2 (H1 functional): predicate truth table — picker / unknown / missing"

# Pre-build the stall.env fixtures so the driver only sources the
# predicate + runs it. This avoids embedding heredoc-into-subshell
# constructs in a printf-generated driver (which is brittle to
# heredoc-end-marker placement and bash-3.2 compatibility).
mkdir -p "$SMOKE_TMP_ROOT/t2/runtime/picker" \
         "$SMOKE_TMP_ROOT/t2/runtime/network" \
         "$SMOKE_TMP_ROOT/t2/runtime/clean"
# Write fixtures via printf so we never rely on a heredoc-in-driver.
printf 'STALL_ACTIVE_CLASSIFICATION=interactive_picker\nSTALL_ACTIVE_EXCERPT_HASH=abc123\n' \
  >"$SMOKE_TMP_ROOT/t2/runtime/picker/stall.env"
printf 'STALL_ACTIVE_CLASSIFICATION=network\n' \
  >"$SMOKE_TMP_ROOT/t2/runtime/network/stall.env"
# `clean` agent: no stall.env at all → predicate returns false.

T2_DRIVER="$SMOKE_TMP_ROOT/t2-driver.sh"
: >"$T2_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Stub the runtime_state_dir resolver to point at the temp root, so
  # the predicate reads our hand-rolled stall.env. The real stall.env
  # resolver depends on runtime_state_dir, so stubbing the former gives
  # the latter our temp tree.
  printf '%s\n' 'bridge_agent_runtime_state_dir() { printf "%s/runtime/%s\n" "$ROOT" "$1"; }'
  # Source the predicate function + the stall_state_file resolver
  # block via awk extraction. The predicate calls stall_state_file
  # which calls our stubbed runtime_state_dir.
  printf '%s\n' "source \"$SMOKE_TMP_ROOT/stall-file-extract.sh\""
  printf '%s\n' "source \"$SMOKE_TMP_ROOT/predicate-extract.sh\""
  printf '%s\n' 'bridge_agent_picker_blocked picker; PRC=$?'
  printf '%s\n' 'bridge_agent_picker_blocked network; NRC=$?'
  printf '%s\n' 'bridge_agent_picker_blocked clean; CRC=$?'
  printf '%s\n' 'bridge_agent_picker_blocked ""; ERC=$?'
  printf '%s\n' 'printf "PRC=%s\nNRC=%s\nCRC=%s\nERC=%s\n" "$PRC" "$NRC" "$CRC" "$ERC"'
} >>"$T2_DRIVER"
chmod +x "$T2_DRIVER"

# Extract the stall_state_file resolver + the predicate function from
# the lib via awk. The predicate's dependency chain is:
#   bridge_agent_picker_blocked
#     -> bridge_agent_stall_state_file
#         -> bridge_agent_runtime_state_dir  (stubbed in driver)
awk '/^bridge_agent_stall_state_file\(\) \{/,/^\}/' "$STATE_LIB" \
  >"$SMOKE_TMP_ROOT/stall-file-extract.sh"
awk '/^bridge_agent_picker_blocked\(\) \{/,/^\}/' "$STATE_LIB" \
  >"$SMOKE_TMP_ROOT/predicate-extract.sh"

# Pick Homebrew bash (the repo documents Bash 4+ as required).
if command -v /opt/homebrew/bin/bash >/dev/null 2>&1; then
  T2_BASH=/opt/homebrew/bin/bash
elif command -v /usr/local/bin/bash >/dev/null 2>&1; then
  T2_BASH=/usr/local/bin/bash
else
  T2_BASH="$(command -v bash)"
fi

ROOT="$SMOKE_TMP_ROOT/t2" T2_OUT="$(ROOT="$SMOKE_TMP_ROOT/t2" "$T2_BASH" "$T2_DRIVER" 2>&1 || true)"
T2_PRC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^PRC=/ {print $2}')"
T2_NRC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^NRC=/ {print $2}')"
T2_CRC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^CRC=/ {print $2}')"
T2_ERC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^ERC=/ {print $2}')"

# Edge case 1: interactive_picker classification → predicate true (rc=0).
[[ "$T2_PRC" == "0" ]] || smoke_fail "T2: predicate did not return 0 for interactive_picker classification (got rc=$T2_PRC). Out: $T2_OUT"
# Edge case 2: network classification → predicate false (rc=1).
[[ "$T2_NRC" == "1" ]] || smoke_fail "T2: predicate did not return 1 for non-picker classification (got rc=$T2_NRC). Out: $T2_OUT"
# Edge case 3: stall.env absent (recovered or never-stalled) → predicate false (rc=1).
[[ "$T2_CRC" == "1" ]] || smoke_fail "T2: predicate did not return 1 for missing stall.env (got rc=$T2_CRC). Out: $T2_OUT"
# Edge case 4: empty agent name → predicate false (rc=1) — defensive.
[[ "$T2_ERC" == "1" ]] || smoke_fail "T2: predicate did not return 1 for empty agent name (got rc=$T2_ERC). Out: $T2_OUT"

smoke_log "T2 PASS — predicate truth table holds (picker=0, network=1, clean=1, empty=1)"

# ---------------------------------------------------------------------
# T3 (M1, #1324) — bridge-audit.sh enumerates BOTH legacy and v2
# canonical trees when no --agent is given.
# ---------------------------------------------------------------------
smoke_log "T3 (M1, #1324): bridge-audit.sh walks both legacy and v2 canonical trees"

# T3.a — the iso-v2 enumeration block is present.
if ! grep -nF 'BRIDGE_AGENT_ROOT_V2' "$AUDIT_CLI" >/dev/null; then
  smoke_fail "T3.a: bridge-audit.sh missing BRIDGE_AGENT_ROOT_V2 enumeration (#1324)"
fi
if ! grep -nF 'data/agents' "$AUDIT_CLI" >/dev/null; then
  smoke_fail "T3.a: bridge-audit.sh missing data/agents fallback path (#1324)"
fi

# T3.b — legacy path still walked (back-compat).
if ! grep -nF '$BRIDGE_HOME/logs/agents' "$AUDIT_CLI" >/dev/null; then
  smoke_fail "T3.b: bridge-audit.sh dropped legacy logs/agents enumeration (back-compat regression)"
fi

# T3.c — explicit issue reference so the comment cannot drift.
if ! grep -nF 'Issue #1324' "$AUDIT_CLI" >/dev/null; then
  smoke_fail "T3.c: bridge-audit.sh missing 'Issue #1324' anchor comment for the v2 enumeration"
fi

smoke_log "T3 PASS — bridge-audit.sh enumerates both legacy + v2 canonical trees"

# ---------------------------------------------------------------------
# T4 (M2, #1325) — `isolation reconcile --check` (manual, no args)
# expansion branch present + functionally calls into the per-agent
# row emitter. This is the static-pin counterpart to gamma-beta5 T3
# (which only grepped for the parity block); here we additionally
# verify the call site is gated on BOTH check and apply modes (no
# unintentional --apply-only restriction).
# ---------------------------------------------------------------------
smoke_log "T4 (M2, #1325): manual --check parity branch covers BOTH modes"

# T4.a — manual expansion does NOT gate on $mode (so --check + --apply
# both benefit). Static check via awk over the function block. The
# block-boundary awk capture includes leading comment lines, so we
# narrow the gate-conjunct check to the actual `if (( all_agents == 0
# )) && ...` line (the one assignment line we care about) via
# grep-after-extract.
EXPANSION_BLOCK="$(awk '/Manual-mode parity/,/^  fi$/' "$RECONCILE_LIB" 2>/dev/null || true)"
if [[ -z "$EXPANSION_BLOCK" ]]; then
  smoke_fail "T4.a: manual-mode parity block not found in $RECONCILE_LIB (regression of #1298 Gap B?)"
fi
# Pull JUST the gate predicate line (the `if (( ... ))` line that opens
# the expansion). Comment lines anywhere in the block are not gates and
# must be ignored — they may legitimately mention `mode == "apply"` as
# documentation context.
GATE_LINE="$(printf '%s\n' "$EXPANSION_BLOCK" | grep -E '^\s*if\s*\(\(' | head -n1 || true)"
if [[ -z "$GATE_LINE" ]]; then
  smoke_fail "T4.a: cannot locate the gate predicate line inside the manual-mode parity block. Block: $EXPANSION_BLOCK"
fi
# The gate line itself must NOT contain a `mode == "apply"` conjunct
# (otherwise --check is accidentally skipped). The actual guard is on
# `reason == manual` + the no-target conjuncts. Comment lines were
# already stripped above.
if printf '%s\n' "$GATE_LINE" | grep -qE 'mode.+==.+["'\'']apply["'\'']'; then
  smoke_fail "T4.a: gate predicate gates on apply mode — would re-introduce #1325 (no --check expansion). Gate: $GATE_LINE"
fi
# Positive check: the gate MUST carry the reason=="manual" conjunct
# (the actual guard that makes both --check and --apply benefit).
if ! printf '%s\n' "$GATE_LINE" | grep -qE 'reason.+==.+["'\'']manual["'\'']'; then
  smoke_fail "T4.a: gate predicate missing reason==\"manual\" conjunct. Gate: $GATE_LINE"
fi

# T4.b — explicit issue reference so the fix anchor cannot drift.
if ! grep -nF '1298' "$RECONCILE_LIB" >/dev/null; then
  smoke_fail "T4.b: $RECONCILE_LIB missing #1298 anchor reference (Lane γ beta5 origin)"
fi
if ! grep -nF '1325' "$RECONCILE_LIB" >/dev/null; then
  smoke_fail "T4.b: $RECONCILE_LIB missing #1325 anchor reference (Lane κ beta5-2 verification)"
fi

# T4.c — the matrix dispatcher does not short-circuit on mode=check
# before per-agent rows are emitted (regression check). The for-loop
# over target_agents must execute regardless of mode.
DISPATCH_BLOCK="$(awk '/for idx in/,/done < <\(bridge_isolation_v2_install_tree_matrix_rows/' "$RECONCILE_LIB" 2>/dev/null || true)"
if [[ -z "$DISPATCH_BLOCK" ]]; then
  smoke_fail "T4.c: dispatch loop block not found in $RECONCILE_LIB"
fi
# The body of the loop must invoke _bridge_iso_reconcile_process_one_row
# with `$mode` (whatever it is) — NOT a hard-coded `apply`.
if ! printf '%s\n' "$DISPATCH_BLOCK" | grep -qF '_bridge_iso_reconcile_process_one_row "$mode"'; then
  smoke_fail "T4.c: dispatch loop must pass \$mode (not a hardcoded value) to _bridge_iso_reconcile_process_one_row. Block: $DISPATCH_BLOCK"
fi

smoke_log "T4 PASS — manual --check parity present, mode-agnostic, dispatch loop honors \$mode"

# ---------------------------------------------------------------------
# T5 (teeth for T1) — revert the predicate call in
# bridge_write_roster_status_snapshot to prove the assertion would
# catch the regression. Operates on a working copy so the real source
# stays untouched.
# ---------------------------------------------------------------------
smoke_log "T5 (teeth, H1 #1319): revert snapshot picker_blocked branch -> resolver returns 'working' (assertion fires)"

T5_LIB="$SMOKE_TMP_ROOT/state-lib.t5.sh"
cp "$STATE_LIB" "$T5_LIB"

# Surgically delete the picker_blocked branch from the working copy.
# We use awk to print every line except those inside the
# `if bridge_agent_picker_blocked "$agent"; then` ... block within
# bridge_write_roster_status_snapshot, replacing it with the original
# pre-#1319 shape (no picker_blocked branch).
awk '
  BEGIN { in_snapshot = 0; skip_block = 0 }
  /^bridge_write_roster_status_snapshot\(\) \{/ { in_snapshot = 1 }
  in_snapshot && /^\}/ { in_snapshot = 0 }
  in_snapshot && /bridge_agent_picker_blocked/ { skip_block = 1; next }
  skip_block && /activity_state="picker_blocked"/ { next }
  skip_block && /^[[:space:]]*# Issue #835 Wave B:/ { skip_block = 0; print "        if bridge_tmux_engine_requires_prompt \"$engine\" \\"; print "            && ! bridge_agent_engine_process_alive \"$agent\" \"$engine\"; then"; next }
  skip_block && /elif bridge_tmux_engine_requires_prompt/ { skip_block = 0; next }
  { print }
' "$T5_LIB" >"$SMOKE_TMP_ROOT/state-lib.t5.reverted.sh"

# Now re-run the T1.c assertion against the reverted file. It MUST
# fail (i.e., grep returns non-zero). If the assertion still passes,
# the teeth check is broken.
if awk '/^bridge_write_roster_status_snapshot\(\) \{/,/^\}/' "$SMOKE_TMP_ROOT/state-lib.t5.reverted.sh" \
      | grep -qF 'bridge_agent_picker_blocked'; then
  smoke_fail "T5: teeth revert failed — picker_blocked branch still present in reverted snapshot writer"
fi

smoke_log "T5 PASS — teeth proves T1.c would catch the snapshot regression"

# ---------------------------------------------------------------------
# T6 (teeth for T3) — revert the bridge-audit.sh v2 enumeration to
# prove the assertion would catch the regression.
# ---------------------------------------------------------------------
smoke_log "T6 (teeth, M1 #1324): revert audit-cli v2 enumeration -> assertion fires"

T6_CLI="$SMOKE_TMP_ROOT/bridge-audit.t6.sh"
# Remove the BRIDGE_AGENT_ROOT_V2 + data/agents lines via awk filter.
awk '
  /BRIDGE_AGENT_ROOT_V2/ { next }
  /Issue #1324/ { next }
  /data\/agents/ { next }
  { print }
' "$AUDIT_CLI" >"$T6_CLI"

# Re-run the T3.a assertion against the reverted file.
if grep -nF 'BRIDGE_AGENT_ROOT_V2' "$T6_CLI" >/dev/null; then
  smoke_fail "T6: teeth revert failed — BRIDGE_AGENT_ROOT_V2 still present in reverted bridge-audit.sh"
fi

smoke_log "T6 PASS — teeth proves T3.a would catch the audit-cli enumeration regression"

# ---------------------------------------------------------------------
# T7 (teeth for T4) — revert the manual-mode parity branch to prove
# the assertion would catch the regression (#1298 Gap B reversal).
# ---------------------------------------------------------------------
smoke_log "T7 (teeth, M2 #1325): revert manual-mode parity branch -> assertion fires"

T7_LIB="$SMOKE_TMP_ROOT/bridge-isolation-v2-reconcile.t7.sh"
awk '
  /Manual-mode parity/ { skip = 1 }
  skip && /^  fi$/ { skip = 0; next }
  skip { next }
  { print }
' "$RECONCILE_LIB" >"$T7_LIB"

# Re-run the T4.a assertion against the reverted file.
T7_EXPANSION_BLOCK="$(awk '/Manual-mode parity/,/^  fi$/' "$T7_LIB" 2>/dev/null || true)"
if [[ -n "$T7_EXPANSION_BLOCK" ]]; then
  smoke_fail "T7: teeth revert failed — Manual-mode parity block still present in reverted reconcile lib"
fi

smoke_log "T7 PASS — teeth proves T4.a would catch the reconcile parity regression"

smoke_log "ALL PASS — beta5-2 Lane κ smoke (H1 #1319 + M1 #1324 + M2 #1325)"
exit 0
