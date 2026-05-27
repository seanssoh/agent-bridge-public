#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/gamma-beta5-reconcile-helper-status.sh —
# v0.15.0-beta5 Lane gamma (Greek gamma) — reconcile stat helper status
# disambiguation + manual mode agent-home-contract parity (issue #1298).
#
# Background:
#   On patch's beta4 OOTB verify (cm-prod-agentworkflow-vm01, 2026-05-27
#   16:13-16:23 UTC), `agent-bridge upgrade --apply` iso-reconcile stage
#   logged 4 `[failed]` rows for each iso v2 agent:
#
#     [iso-reconcile] agent-home-contract-home    [failed] /home/...
#       expected=...:ab-agent-X 2750
#       actual=(helper emitted no status line for /home/...)
#     [iso-reconcile] agent-home-contract-claude  [failed] /home/.../.claude
#       ...
#     [iso-reconcile] agent-home-contract-plugins [failed] /home/.../.claude/plugins
#     [iso-reconcile] agent-home-contract-session-env [failed]
#       /home/.../.claude/session-env
#     [iso-reconcile] end mode=apply reason=upgrade overall_rc=1
#
#   And `bridge_upgrade` then surfaced:
#     [bridge-upgrade] WARN: install-tree reconciler reported drift or
#       partial apply (rc=1)
#
#   Two distinct gaps:
#
#   Gap A — sudo helper return-value disambiguation: the reconcile's stat
#     helper `bridge_linux_normalize_isolated_home_contract` emitted no
#     stdout in three different conditions, all collapsing to "no status
#     line":
#       1. Path does not exist (legitimate drift / `missing`).
#       2. Permission denied / agent's tmux session is alive at apply time
#          (probe failure / `denied`).
#       3. Helper error — invariant violation (bad args, unresolved group,
#          anchor unset / anchor mismatch) (helper bug / `error`).
#     Reconcile reported `[failed]` for all three, conflating "row says
#     missing" (drift) with "probe failed" (operator action != re-apply).
#     Root cause of the upgrade-WARN noise: agents are LIVE during
#     upgrade-time reconcile so the helper's stopped-session guard fires
#     the silent early-return on every agent, every upgrade.
#
#   Gap B — manual mode contract gap: `agent-bridge isolation reconcile
#     --apply` (manual mode, all_agents=0, agent="") DID NOT check
#     `agent-home-contract-*` rows at all. Returned overall_rc=0 (false-
#     OK). Operator who hit the upgrade WARN had no manual-reconcile way
#     to either see or repair agent-home-contract drift.
#
# Fix shape (this smoke pins):
#   1. `bridge_linux_normalize_isolated_home_contract` (lib/bridge-agents.sh)
#      now emits a structured per-target tab-separated status line on
#      EVERY early-return path:
#        path\tdenied\t-\t-   — runtime probe failure (sudo refused,
#                               session running, anchor mismatch, symlink
#                               siblings) — operator action is NOT
#                               re-apply.
#        path\terror\t-\t-    — invariant violation (bad args, unresolved
#                               group, anchor unset) — operator must fix
#                               configuration.
#      The existing `failed` (per-target apply failure), `ok`, `changed`
#      statuses are unchanged.
#
#   2. `_bridge_iso_reconcile_row_agent_home_contract`
#      (lib/bridge-isolation-v2-reconcile.sh) now classifies new helper
#      statuses:
#        denied|error  -> emit `degraded` row (probe failure, NOT drift),
#                         return 0 so overall_rc is not flipped.
#        missing       -> emit `missing` row (real drift), return 1.
#        no-line       -> emit `degraded` row (true helper bug, surface
#                         diagnostic but do not flag drift).
#
#   3. `bridge_isolation_v2_apply_install_tree_matrix`
#      (lib/bridge-isolation-v2-reconcile.sh) now treats
#      `reason=manual` + no `--agent` + no `--all-agents` as an implicit
#      `--all-agents` so manual reconcile reports the same row set as
#      upgrade / install / agent-create. Non-manual callers (install /
#      upgrade / agent-create) still honor explicit --agent / --all-
#      agents.
#
# Tests:
#   T1: helper emits per-target denied status line for tmux-alive early-
#       return (the upgrade-time root cause).
#   T2: caller classifies `denied` -> degraded row + rc=0 (NOT drift).
#       Classifies `error` -> degraded + rc=0. Classifies `missing` ->
#       missing + rc=1. Classifies `ok` -> ok + rc=0.
#   T3: manual mode parity — manual reason + no --agent + no --all =>
#       all_agents auto-expanded to 1.
#   T4: back-compat — `--agent X` and `--all-agents` paths preserve
#       explicit semantics (no implicit re-expansion).
#   T5 (teeth): revert helper structured status emission -> caller falls
#       through to no-line branch -> still rc=0/degraded (not failed/drift),
#       proving the caller-side classification is the safety net.
#   T6 (teeth): revert manual mode parity branch -> manual reconcile
#       skips agent-home-contract (Gap B regression reappears).
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every assertion
# uses `grep -n` against source files OR builds harness scripts with
# `printf '%s\n' >file` and runs them as external scripts. No `<<<`
# here-string or `<<EOF` heredoc-stdin into subprocess capture.

set -uo pipefail

SMOKE_NAME="gamma-beta5-reconcile-helper-status"
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
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
RECONCILE_LIB="$REPO_ROOT/lib/bridge-isolation-v2-reconcile.sh"
AGENT_BRIDGE_CLI="$REPO_ROOT/agent-bridge"

[[ -f "$AGENTS_LIB" ]]        || smoke_fail "missing $AGENTS_LIB"
[[ -f "$RECONCILE_LIB" ]]     || smoke_fail "missing $RECONCILE_LIB"
[[ -f "$AGENT_BRIDGE_CLI" ]]  || smoke_fail "missing $AGENT_BRIDGE_CLI"

# ---------------------------------------------------------------------
# T1: helper emits per-target denied status line for tmux-alive early
# return (the upgrade-time root cause from #1298).
#
# Build an isolated harness that loads ONLY the helper function +
# minimal stubs, forces the tmux-alive code path, and verifies the
# stdout protocol carries one denied line per target sub-path.
# ---------------------------------------------------------------------
smoke_log "T1: helper emits structured denied status for tmux-alive early-return"

T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.sh"
: >"$T1_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Minimal stubs: every function the helper calls before the loop.
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_host_platform() { printf "Linux\n"; }'
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "ab-agent-%s\n" "$1"; }'
  printf '%s\n' 'bridge_agent_session() { printf "agent-session-%s\n" "$1"; }'
  printf '%s\n' 'bridge_tmux_session_exists() { return 0; }  # always alive -> tmux-alive early return'
  printf '%s\n' 'tmux() { return 0; }'
  printf '%s\n' 'BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="/home"'
  printf '%s\n' 'export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT'
  # Source ONLY the helper definition from bridge-agents.sh. Extract
  # the function block via awk into a temp file. This avoids dragging
  # the whole 8000-line lib into the harness (and the macOS-bash
  # incompatibility on unrelated lines).
  printf '%s\n' "source \"$SMOKE_TMP_ROOT/helper-extract.sh\""
  printf '%s\n' 'bridge_linux_normalize_isolated_home_contract test-agent test-os-user /home/test-os-user; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T1_DRIVER"
chmod +x "$T1_DRIVER"

# Extract just the function body via awk (start at the function header,
# end at the first `^}` at column 0). This is a stable, easily-grep-able
# region in bridge-agents.sh.
awk '/^bridge_linux_normalize_isolated_home_contract\(\) \{/,/^\}/' "$AGENTS_LIB" \
  >"$SMOKE_TMP_ROOT/helper-extract.sh"

# Run with Homebrew bash 5 (the repo's documented platform note: Bash 4+
# required; macOS /bin/bash 3.2 cannot parse [[ -v assoc[k] ]]).
if command -v /opt/homebrew/bin/bash >/dev/null 2>&1; then
  T1_BASH=/opt/homebrew/bin/bash
elif command -v /usr/local/bin/bash >/dev/null 2>&1; then
  T1_BASH=/usr/local/bin/bash
else
  T1_BASH="$(command -v bash)"
fi

T1_OUT="$("$T1_BASH" "$T1_DRIVER" 2>/dev/null || true)"
T1_RC="$(printf '%s\n' "$T1_OUT" | awk -F= '/^rc=/ {print $2}')"

if [[ "$T1_RC" != "1" ]]; then
  smoke_fail "T1: helper rc=$T1_RC (expected 1 for tmux-alive early return). Out: $T1_OUT"
fi

# Expect 4 denied lines, one per sub-path. Each line shape:
#   <path>\tdenied\t-\t-
for _sub in "/home/test-os-user" "/home/test-os-user/.claude" \
            "/home/test-os-user/.claude/plugins" \
            "/home/test-os-user/.claude/session-env"; do
  if ! printf '%s\n' "$T1_OUT" | grep -Fq "$(printf '%s\tdenied\t-\t-' "$_sub")"; then
    smoke_fail "T1: expected denied status line for $_sub not found in helper output: $T1_OUT"
  fi
done

smoke_log "T1 PASS — helper emits 4 denied status lines on tmux-alive early-return"

# ---------------------------------------------------------------------
# T2: caller dispatcher classifies new helper statuses.
#
# Strategy: stub `bridge_linux_normalize_isolated_home_contract` to emit
# a controlled status, then call `_bridge_iso_reconcile_row_agent_home_contract`
# in apply mode and verify (a) emitted status word, (b) return code.
# ---------------------------------------------------------------------
smoke_log "T2: caller classifies denied/error/missing/ok statuses"

# Helper to build a one-shot driver that:
#   - stubs the helper to emit the requested status line for the target
#     path (plus dummy `ok` lines for the other 3 to keep the row search
#     happy when needed)
#   - calls the row dispatcher in apply mode
#   - prints the per-row emitted line + the rc
#
# All four targets are addressed for completeness; the test path under
# inspection is $TARGET. The caller's row dispatcher only looks at the
# helper line matching its own row path.
build_t2_driver() {
  local target_status="$1"  # ok|denied|error|missing|changed|<unknown>
  local target_path="$2"
  local out="$SMOKE_TMP_ROOT/t2-driver-${target_status}.sh"
  : >"$out"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    # Stubs the row dispatcher needs.
    printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
    # _bridge_iso_reconcile_log appends to stderr; stub silently.
    printf '%s\n' '_bridge_iso_reconcile_log() { :; }'
    printf '%s\n' '_bridge_iso_reconcile_path_is_protected() { return 1; }'
    printf '%s\n' '_bridge_iso_reconcile_stat_mode() { printf "%s\n" "${TARGET_STAT_MODE:-2750}"; }'
    printf '%s\n' '_bridge_iso_reconcile_stat_owner_group() { printf "%s\n" "${TARGET_STAT_OWNER_GROUP:-test-os-user:ab-agent-test-agent}"; }'
    printf '%s\n' '_bridge_iso_reconcile_normalize_mode() { local m="${1:-0}"; printf "%o\n" "$((8#${m#0}))" 2>/dev/null || printf "%s\n" "$m"; }'
    printf '%s\n' 'bridge_agent_os_user() { printf "test-os-user\n"; }'
    printf '%s\n' 'bridge_agent_linux_user_home() { printf "/home/test-os-user\n"; }'
    printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() { "$@"; }'
    # Status constants — mirror lib/bridge-isolation-v2-reconcile.sh.
    printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_OK="ok"'
    printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_CHANGED="changed"'
    printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_SKIPPED="skipped"'
    printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_MISSING="missing"'
    printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_MISMATCH="mismatch"'
    printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_DEGRADED="degraded"'
    printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_FAILED="failed"'
    # Emit-row stub: print the status word + path to stdout so the
    # outer harness can grep for the row.
    printf '%s\n' '_bridge_iso_reconcile_emit_row() {'
    printf '%s\n' '  local _rn="$1" _st="$2" _p="$3"; shift 3 || true'
    printf '%s\n' '  printf "row=%s status=%s path=%s\n" "$_rn" "$_st" "$_p"'
    printf '%s\n' '}'
    # Stub the helper to emit the requested status line for the target,
    # plus ok lines for the siblings so apply-time scans don't spuriously
    # trip.
    printf 'bridge_linux_normalize_isolated_home_contract() {\n'
    printf '  printf "%%s\\t%s\\t-\\t-\\n" "%s"\n' "$target_status" "$target_path"
    printf '  return 1\n'
    printf '}\n'
    # Source the row dispatcher region from the real reconcile lib.
    printf '%s\n' "source \"$SMOKE_TMP_ROOT/row-dispatcher-extract.sh\""
    # Force apply mode so the helper path executes (not the check-mode
    # stat-and-compare branch).
    printf '%s\n' "TARGET_PATH=\"$target_path\""
    # Args to row dispatcher (single-line invocation to avoid the
    # printf-emits-backslash SC1003 false positive class):
    # mode row_name path agent owner group dir_mode notes
    printf '%s\n' '_bridge_iso_reconcile_row_agent_home_contract apply agent-home-contract-home "$TARGET_PATH" test-agent test-os-user ab-agent-test-agent 2750 test-notes; rc=$?'
    printf '%s\n' 'printf "rc=%s\n" "$rc"'
  } >>"$out"
  chmod +x "$out"
  printf '%s\n' "$out"
}

# Extract the row dispatcher region from the reconcile lib (the function
# definition is bounded by `_bridge_iso_reconcile_row_agent_home_contract() {`
# and its closing `^}`).
awk '/^_bridge_iso_reconcile_row_agent_home_contract\(\) \{/,/^\}/' "$RECONCILE_LIB" \
  >"$SMOKE_TMP_ROOT/row-dispatcher-extract.sh"

T2_TARGET_PATH="/home/test-os-user"

# T2a — denied -> degraded + rc=0
T2A_DRIVER="$(build_t2_driver denied "$T2_TARGET_PATH")"
T2A_OUT="$("$T1_BASH" "$T2A_DRIVER" 2>&1 || true)"
if ! printf '%s\n' "$T2A_OUT" | grep -Fq "status=degraded"; then
  smoke_fail "T2a: denied helper status -> expected degraded row, got: $T2A_OUT"
fi
T2A_RC="$(printf '%s\n' "$T2A_OUT" | awk -F= '/^rc=/ {print $2}')"
[[ "$T2A_RC" == "0" ]] || smoke_fail "T2a: denied -> degraded should return rc=0 (probe failure, NOT drift). rc=$T2A_RC. Out: $T2A_OUT"

# T2b — error -> degraded + rc=0
T2B_DRIVER="$(build_t2_driver error "$T2_TARGET_PATH")"
T2B_OUT="$("$T1_BASH" "$T2B_DRIVER" 2>&1 || true)"
if ! printf '%s\n' "$T2B_OUT" | grep -Fq "status=degraded"; then
  smoke_fail "T2b: error helper status -> expected degraded row, got: $T2B_OUT"
fi
T2B_RC="$(printf '%s\n' "$T2B_OUT" | awk -F= '/^rc=/ {print $2}')"
[[ "$T2B_RC" == "0" ]] || smoke_fail "T2b: error -> degraded should return rc=0. rc=$T2B_RC. Out: $T2B_OUT"

# T2c — missing -> missing + rc=1
T2C_DRIVER="$(build_t2_driver missing "$T2_TARGET_PATH")"
T2C_OUT="$("$T1_BASH" "$T2C_DRIVER" 2>&1 || true)"
if ! printf '%s\n' "$T2C_OUT" | grep -Fq "status=missing"; then
  smoke_fail "T2c: missing helper status -> expected missing row, got: $T2C_OUT"
fi
T2C_RC="$(printf '%s\n' "$T2C_OUT" | awk -F= '/^rc=/ {print $2}')"
[[ "$T2C_RC" == "1" ]] || smoke_fail "T2c: missing -> missing should return rc=1 (drift). rc=$T2C_RC. Out: $T2C_OUT"

# T2d — ok -> ok + rc=0
T2D_DRIVER="$(build_t2_driver ok "$T2_TARGET_PATH")"
T2D_OUT="$("$T1_BASH" "$T2D_DRIVER" 2>&1 || true)"
if ! printf '%s\n' "$T2D_OUT" | grep -Fq "status=ok"; then
  smoke_fail "T2d: ok helper status -> expected ok row, got: $T2D_OUT"
fi
T2D_RC="$(printf '%s\n' "$T2D_OUT" | awk -F= '/^rc=/ {print $2}')"
[[ "$T2D_RC" == "0" ]] || smoke_fail "T2d: ok -> ok should return rc=0. rc=$T2D_RC. Out: $T2D_OUT"

smoke_log "T2 PASS — caller classifies denied/error/missing/ok with correct row + rc"

# ---------------------------------------------------------------------
# T3: manual mode parity static check — reason=manual + no --agent + no
# --all => all_agents auto-expanded.
#
# Static grep against the source: the implicit-expansion block carries a
# stable comment marker (#1298 Gap B) so future moves cannot regress
# the contract without the smoke catching it.
# ---------------------------------------------------------------------
smoke_log "T3: manual mode parity static grep — implicit --all-agents on reason=manual"

if ! grep -nF '#1298 Gap B' "$RECONCILE_LIB" >/dev/null 2>&1; then
  smoke_fail "T3: lib/bridge-isolation-v2-reconcile.sh missing '#1298 Gap B' marker for implicit-expansion block"
fi

# Pin the implicit-expansion shape — the block must contain both the
# `reason == manual` test and the `all_agents=1` assignment.
if ! awk '/#1298 Gap B/,/all_agents=1/' "$RECONCILE_LIB" \
      | grep -Eq 'reason.+==.+\"manual\"'; then
  smoke_fail "T3: implicit-expansion block missing 'reason == manual' guard"
fi
if ! awk '/#1298 Gap B/,/all_agents=1/' "$RECONCILE_LIB" \
      | grep -Eq 'all_agents=1'; then
  smoke_fail "T3: implicit-expansion block missing 'all_agents=1' assignment"
fi

# The block must precede the existing `target_agents=()` loop so the
# implicit expansion happens before per-agent dispatch (static line-
# number ordering check).
TARGET_AGENTS_LINE="$(grep -nE '^[[:space:]]*local -a target_agents=\(\)' "$RECONCILE_LIB" | head -n1 | cut -d: -f1)"
GAP_B_LINE="$(grep -nF '#1298 Gap B' "$RECONCILE_LIB" | head -n1 | cut -d: -f1)"
if [[ -z "$TARGET_AGENTS_LINE" || -z "$GAP_B_LINE" ]]; then
  smoke_fail "T3: cannot locate Gap B marker ($GAP_B_LINE) or target_agents loop ($TARGET_AGENTS_LINE) in $RECONCILE_LIB"
fi
if (( GAP_B_LINE > TARGET_AGENTS_LINE )); then
  smoke_fail "T3: Gap B marker (line $GAP_B_LINE) must precede target_agents loop (line $TARGET_AGENTS_LINE)"
fi

smoke_log "T3 PASS — manual mode parity branch present and correctly ordered"

# ---------------------------------------------------------------------
# T4: back-compat — explicit `--agent` and `--all-agents` semantics
# preserved (the implicit-expansion block only fires when BOTH all_agents=0
# AND agent="" AND reason="manual").
#
# Static check: the guard predicate uses `&& [[ -z "$agent" ]]` and
# `&& [[ "$reason" == "manual" ]]`, so an explicit --agent X or
# --all-agents bypasses the block.
# ---------------------------------------------------------------------
smoke_log "T4: back-compat guard predicate preserves explicit --agent / --all-agents"

# Pin the precise predicate so a future refactor that drops one of the
# three conjuncts (or flips `==` to `!=`) fails CI.
if ! awk '/#1298 Gap B/,/all_agents=1/' "$RECONCILE_LIB" \
      | grep -Eq '\(\(.+all_agents.+==.+0.+\)\).+&&.+\[\[.+-z.+agent.+\]\].+&&.+\[\[.+reason.+==.+manual.+\]\]'; then
  smoke_fail "T4: implicit-expansion predicate missing the (all_agents == 0) && (agent empty) && (reason == manual) conjunction"
fi

smoke_log "T4 PASS — back-compat guard predicate intact"

# ---------------------------------------------------------------------
# T5 (teeth): revert helper structured status emission. With the
# emit_probe_failure calls removed from the helper, the tmux-alive
# early-return path emits zero stdout. The caller dispatcher's no-line
# branch then activates, which (post-fix) classifies as `degraded` (NOT
# `failed`). Either branch must result in rc!=1 / NOT-drift to keep
# the upgrade-WARN noise suppressed.
#
# This teeth test verifies: even when the helper-side emission is
# reverted, the caller-side classification is the safety net that
# prevents Gap A's [failed] regression.
# ---------------------------------------------------------------------
smoke_log "T5: teeth — helper emits no line -> caller classifies degraded, NOT failed"

T5_DRIVER="$SMOKE_TMP_ROOT/t5-driver.sh"
: >"$T5_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'bridge_warn() { :; }'
  printf '%s\n' '_bridge_iso_reconcile_log() { :; }'
  printf '%s\n' '_bridge_iso_reconcile_path_is_protected() { return 1; }'
  printf '%s\n' 'bridge_agent_os_user() { printf "test-os-user\n"; }'
  printf '%s\n' 'bridge_agent_linux_user_home() { printf "/home/test-os-user\n"; }'
  printf '%s\n' '_bridge_iso_reconcile_stat_mode() { printf "2750\n"; }'
  printf '%s\n' '_bridge_iso_reconcile_stat_owner_group() { printf "test-os-user:ab-agent-test-agent\n"; }'
  printf '%s\n' '_bridge_iso_reconcile_normalize_mode() { printf "%s\n" "${1:-0}"; }'
  printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() { "$@"; }'
  printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_OK="ok"'
  printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_CHANGED="changed"'
  printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_SKIPPED="skipped"'
  printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_MISSING="missing"'
  printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_MISMATCH="mismatch"'
  printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_DEGRADED="degraded"'
  printf '%s\n' 'BRIDGE_ISO_RECONCILE_STATUS_FAILED="failed"'
  printf '%s\n' '_bridge_iso_reconcile_emit_row() {'
  printf '%s\n' '  printf "row=%s status=%s path=%s\n" "$1" "$2" "$3"'
  printf '%s\n' '}'
  # Reverted helper — emits no stdout, returns 1.
  printf '%s\n' 'bridge_linux_normalize_isolated_home_contract() { return 1; }'
  printf '%s\n' "source \"$SMOKE_TMP_ROOT/row-dispatcher-extract.sh\""
  printf '%s\n' '_bridge_iso_reconcile_row_agent_home_contract apply agent-home-contract-home /home/test-os-user test-agent test-os-user ab-agent-test-agent 2750 test-notes; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T5_DRIVER"
chmod +x "$T5_DRIVER"

T5_OUT="$("$T1_BASH" "$T5_DRIVER" 2>&1 || true)"
if printf '%s\n' "$T5_OUT" | grep -Fq "status=failed"; then
  smoke_fail "T5 (teeth): caller no-line branch should NOT emit failed (would re-introduce Gap A upgrade-WARN noise). Out: $T5_OUT"
fi
if ! printf '%s\n' "$T5_OUT" | grep -Fq "status=degraded"; then
  smoke_fail "T5 (teeth): caller no-line branch must emit degraded (probe failure, NOT drift). Out: $T5_OUT"
fi
T5_RC="$(printf '%s\n' "$T5_OUT" | awk -F= '/^rc=/ {print $2}')"
[[ "$T5_RC" == "0" ]] || smoke_fail "T5 (teeth): caller no-line branch must return rc=0 (NOT drift). rc=$T5_RC. Out: $T5_OUT"

smoke_log "T5 PASS — caller no-line branch is the safety net (degraded + rc=0)"

# ---------------------------------------------------------------------
# T6 (teeth): revert manual mode parity branch via a comment-strip
# probe — verify that the production source carries the implicit-
# expansion block (the inverse static check of T3).
#
# A future revert that deletes the block but keeps the comment would
# slip past T3's marker search; this T6 line-grep verifies the actual
# code line is present, not just the marker comment.
# ---------------------------------------------------------------------
smoke_log "T6: teeth — production source carries the all_agents=1 implicit-expansion code line"

# Grep for the exact assignment line (with the Gap B marker block as
# anchor) so a comment-only revert doesn't pass.
if ! awk '/#1298 Gap B/,/all_agents=1/' "$RECONCILE_LIB" \
      | grep -nE '^[[:space:]]+all_agents=1$' >/dev/null 2>&1; then
  smoke_fail "T6 (teeth): Gap B fix code-line all_agents=1 missing — manual reconcile would skip agent-home-contract again"
fi

smoke_log "T6 PASS — production source carries Gap B fix code-line"

# ---------------------------------------------------------------------
# Bonus: confirm the helper carries the per-target emit-probe-failure
# helper function (Gap A fix code-line) so a future revert that strips
# the inline `printf '%s\tdenied\t-\t-\n'` block is caught here.
# ---------------------------------------------------------------------
smoke_log "T7 (bonus): helper carries _bridge_linux_home_contract_emit_probe_failure"

if ! grep -nF '_bridge_linux_home_contract_emit_probe_failure' "$AGENTS_LIB" >/dev/null 2>&1; then
  smoke_fail "T7: lib/bridge-agents.sh missing _bridge_linux_home_contract_emit_probe_failure (Gap A fix code-line)"
fi

# The helper must be called from at least the tmux-alive guard (the
# upgrade-time root cause).
if ! grep -nE 'tmux session.+is alive' "$AGENTS_LIB" \
      | head -n1 >/dev/null 2>&1; then
  smoke_fail "T7: lib/bridge-agents.sh missing tmux-alive guard anchor"
fi

# Walk from the tmux-alive bridge_warn line forward 8 lines; expect to
# see the emit_probe_failure call within that window.
if ! awk '/tmux session.+is alive/,/return 1/' "$AGENTS_LIB" \
      | grep -F '_bridge_linux_home_contract_emit_probe_failure' >/dev/null 2>&1; then
  smoke_fail "T7: tmux-alive guard does not invoke _bridge_linux_home_contract_emit_probe_failure"
fi

smoke_log "T7 PASS — helper carries probe-failure emitter on tmux-alive path"

smoke_log "$SMOKE_NAME — all tests PASS"
exit 0
