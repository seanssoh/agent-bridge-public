#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1357-iso-boundary-quickref.sh — Issue #1357.
#
# v0.15.0-beta5-2 Lane E. Pins the iso v2 boundary quickref contract:
#
#   T1. `lib/bridge-agents.sh` defines `bridge_agent_iso_boundary_quickref_
#       text` and the helper emits at least the 5 contract rows (body_file,
#       controller HOME files, shared/wiki, plugins-cache mcp.json,
#       cross-iso sudo). The rows are emitted as plain `key: value` lines
#       so a future grep/awk consumer can parse without a multiline parser.
#
#   T2. `bridge-agent.sh::run_show` calls the helper, gated by
#       `bridge_agent_linux_user_isolation_effective`. A shared-mode agent
#       (predicate returns 1) MUST NOT see the `iso_boundary_quickref:`
#       header — surfacing it there would misinform the operator.
#
#   T3. `CLAUDE.md` carries the long-form "Agent's own POV: what blocks
#       where + workaround" sub-section under "Working with isolated agents
#       (iso v2)". The docs row is the contract; the helper's compressed
#       output is the operator-visible reminder at `agb agent show` time.
#
#   T4. The same docs sub-section names the most surprising row
#       (`body_file direct read`) verbatim. This is the row a fresh iso
#       agent will hit first (controller-side `agb show` prints the path,
#       agent's `cat` is denied) — the docs catalog must call it out by
#       name so a doc reader can grep for it.
#
#   T5 (teeth). Removing the helper definition makes T1 fail; removing the
#       call site makes T2 fail. The test verifies the contract by
#       toggling each on a temp copy and confirming the corresponding
#       assertion flips.
#
# Footgun #11 (heredoc_write deadlock class): no `<<EOF` to a subprocess,
# no `<<<` here-strings. All multi-line text uses `printf`/`grep`/`awk`.

set -euo pipefail

SMOKE_NAME="1357-iso-boundary-quickref"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

smoke_make_temp_root "$SMOKE_NAME"
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
LIB_AGENTS="$REPO_ROOT/lib/bridge-agents.sh"
DISPATCHER="$REPO_ROOT/bridge-agent.sh"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

smoke_assert_file_exists "$LIB_AGENTS" "lib/bridge-agents.sh present"
smoke_assert_file_exists "$DISPATCHER" "bridge-agent.sh present"
smoke_assert_file_exists "$CLAUDE_MD" "CLAUDE.md present"

# ---------------------------------------------------------------------------
# T1 — helper defined + emits the 5 contract rows.
# ---------------------------------------------------------------------------
smoke_log "T1: bridge_agent_iso_boundary_quickref_text emits the 5 contract rows"

if ! grep -qE '^bridge_agent_iso_boundary_quickref_text\(\) \{' "$LIB_AGENTS"; then
  smoke_fail "T1: helper bridge_agent_iso_boundary_quickref_text() missing from lib/bridge-agents.sh"
fi

# Parse the helper body (between the function signature and the closing
# `}`) to verify each contract row is emitted. Using awk so we don't
# false-positive on a different function's identically-named string.
T1_BODY_FILE="$SMOKE_TMP_ROOT/t1-helper-body.txt"
awk '
  /^bridge_agent_iso_boundary_quickref_text\(\) \{/ { in_fn = 1; next }
  in_fn && /^\}/ { exit }
  in_fn { print }
' "$LIB_AGENTS" >"$T1_BODY_FILE"

if [[ ! -s "$T1_BODY_FILE" ]]; then
  smoke_fail "T1: helper body parse returned 0 lines — function shape changed?"
fi

T1_REQUIRED_KEYS=(
  "body_file direct read:"
  "controller HOME files:"
  "shared/wiki/\\*:"
  "plugins-cache mcp.json:"
  "cross-iso sudo:"
)

for key in "${T1_REQUIRED_KEYS[@]}"; do
  if ! grep -qE "$key" "$T1_BODY_FILE"; then
    smoke_fail "T1: helper body missing required row '$key'"
  fi
done

# Count printf lines so a future refactor that drops to <5 rows triggers
# loudly (rather than silently shipping a 2-row quickref).
T1_PRINTF_COUNT="$(grep -cE "^[[:space:]]+printf " "$T1_BODY_FILE" || true)"
if (( T1_PRINTF_COUNT < 5 )); then
  smoke_fail "T1: helper body printf row count ($T1_PRINTF_COUNT) < 5 contract rows"
fi

# ---------------------------------------------------------------------------
# T2 — run_show invokes the helper gated by the iso-effective predicate.
# ---------------------------------------------------------------------------
smoke_log "T2: bridge-agent.sh run_show invokes the quickref helper gated by iso-effective"

# Locate run_show body. The function lives in bridge-agent.sh and spans
# until the next top-level `^}` after its signature. We snapshot the body
# so subsequent assertions all run against the same parse.
T2_RUN_SHOW_BODY="$SMOKE_TMP_ROOT/t2-run-show-body.txt"
awk '
  /^run_show\(\) \{/ { in_fn = 1; next }
  in_fn && /^\}/ { exit }
  in_fn { print }
' "$DISPATCHER" >"$T2_RUN_SHOW_BODY"

if [[ ! -s "$T2_RUN_SHOW_BODY" ]]; then
  smoke_fail "T2: run_show body parse returned 0 lines — function shape changed?"
fi

if ! grep -q "bridge_agent_iso_boundary_quickref_text" "$T2_RUN_SHOW_BODY"; then
  smoke_fail "T2: run_show does not call bridge_agent_iso_boundary_quickref_text"
fi

# Gate predicate must be present so shared-mode agents skip the block.
if ! grep -q "bridge_agent_linux_user_isolation_effective" "$T2_RUN_SHOW_BODY"; then
  smoke_fail "T2: run_show calls quickref helper but lacks iso-effective gate"
fi

# Header label must appear too (so the text output names the section).
if ! grep -q "iso_boundary_quickref:" "$T2_RUN_SHOW_BODY"; then
  smoke_fail "T2: run_show emits the helper output without the 'iso_boundary_quickref:' header"
fi

# ---------------------------------------------------------------------------
# T3 — CLAUDE.md carries the long-form sub-section.
# ---------------------------------------------------------------------------
smoke_log "T3: CLAUDE.md carries the 'Agent's own POV' sub-section"

if ! grep -q "Agent's own POV" "$CLAUDE_MD"; then
  smoke_fail "T3: CLAUDE.md missing 'Agent's own POV' sub-section header"
fi

# The sub-section must live under the "Working with isolated agents (iso v2)"
# parent so a doc reader sees the controller view + agent view together.
# Verified by checking the parent header precedes the sub-section line.
T3_PARENT_LINE="$(grep -n '^## Working with isolated agents (iso v2)' "$CLAUDE_MD" | head -1 | cut -d: -f1)"
T3_SUB_LINE="$(grep -n "Agent's own POV" "$CLAUDE_MD" | head -1 | cut -d: -f1)"

if [[ -z "$T3_PARENT_LINE" || -z "$T3_SUB_LINE" ]]; then
  smoke_fail "T3: parent header or sub-section anchor missing in CLAUDE.md"
fi

if (( T3_SUB_LINE <= T3_PARENT_LINE )); then
  smoke_fail "T3: 'Agent's own POV' must appear AFTER the parent header (parent=$T3_PARENT_LINE, sub=$T3_SUB_LINE)"
fi

# ---------------------------------------------------------------------------
# T4 — CLAUDE.md names the 'body_file direct read' row verbatim.
# ---------------------------------------------------------------------------
smoke_log "T4: CLAUDE.md catalogs the body_file direct-read paper cut"

if ! grep -q "body_file direct read" "$CLAUDE_MD"; then
  smoke_fail "T4: CLAUDE.md must name the 'body_file direct read' row verbatim (the first paper cut a fresh iso agent hits)"
fi

# ---------------------------------------------------------------------------
# T5 (teeth) — toggling the helper or the call site re-runs the T1 / T2
# contract assertions against the stripped copies and confirms they FAIL.
# This is the real teeth: a future refactor that drops the helper or its
# call site must trip the same checks T1/T2 use, not just produce a file
# that lacks the literal token.
# ---------------------------------------------------------------------------
smoke_log "T5 (teeth): re-run T1/T2 contract against stripped copies and assert they fail"

# Teeth A: nuke the helper in a temp copy and re-run the T1 contract checks
# against it. They must fail (any T1 assertion firing means the contract
# would catch a regression that drops the helper).
T5_LIB_COPY="$SMOKE_TMP_ROOT/lib-bridge-agents.no-helper.sh"
awk '
  /^bridge_agent_iso_boundary_quickref_text\(\) \{/ { skip = 1; next }
  skip && /^\}/ { skip = 0; next }
  skip { next }
  { print }
' "$LIB_AGENTS" >"$T5_LIB_COPY"

# Re-run T1 step 1: signature grep against the stripped copy. Must NOT match.
if grep -qE '^bridge_agent_iso_boundary_quickref_text\(\) \{' "$T5_LIB_COPY"; then
  smoke_fail "T5 (teeth A.1): stripped copy still defines the helper — awk strip drifted"
fi

# Re-run T1 step 2: parse the (now-empty) helper body and confirm the
# required-rows grep would fail. We expect zero captured lines.
T5_BODY_AFTER="$SMOKE_TMP_ROOT/t5-helper-body-after.txt"
awk '
  /^bridge_agent_iso_boundary_quickref_text\(\) \{/ { in_fn = 1; next }
  in_fn && /^\}/ { exit }
  in_fn { print }
' "$T5_LIB_COPY" >"$T5_BODY_AFTER"

if [[ -s "$T5_BODY_AFTER" ]]; then
  smoke_fail "T5 (teeth A.2): stripped copy still has a helper body — T1 parse would not fail"
fi

# Re-run T1 step 3: the required-rows grep against the empty body. Each row
# would fire smoke_fail in T1; here we confirm at least one row's grep does
# fail (i.e. T1 would catch the regression).
T5_TEETH_A_CAUGHT=0
for key in "${T1_REQUIRED_KEYS[@]}"; do
  if ! grep -qE "$key" "$T5_BODY_AFTER"; then
    T5_TEETH_A_CAUGHT=1
    break
  fi
done

if (( T5_TEETH_A_CAUGHT == 0 )); then
  smoke_fail "T5 (teeth A.3): T1 required-rows grep would still pass against stripped copy — teeth not engaged"
fi

# Re-run T1 step 4: printf count must also fall below the contract floor.
T5_PRINTF_COUNT_AFTER="$(grep -cE "^[[:space:]]+printf " "$T5_BODY_AFTER" || true)"
if (( T5_PRINTF_COUNT_AFTER >= 5 )); then
  smoke_fail "T5 (teeth A.4): printf count ($T5_PRINTF_COUNT_AFTER) still >= 5 — T1 row count check would not fail"
fi

# Teeth B: drop the call site from a temp copy of bridge-agent.sh and
# re-run the T2 contract checks against it. They must fail.
T5_DISPATCHER_COPY="$SMOKE_TMP_ROOT/bridge-agent.no-call.sh"
grep -v "bridge_agent_iso_boundary_quickref_text" "$DISPATCHER" >"$T5_DISPATCHER_COPY"

T5_RUN_SHOW_AFTER="$SMOKE_TMP_ROOT/t5-run-show-after.txt"
awk '
  /^run_show\(\) \{/ { in_fn = 1; next }
  in_fn && /^\}/ { exit }
  in_fn { print }
' "$T5_DISPATCHER_COPY" >"$T5_RUN_SHOW_AFTER"

# Re-run T2 step 1: run_show body must have been captured (parse shape
# unchanged), otherwise our teeth would mask a real regression.
if [[ ! -s "$T5_RUN_SHOW_AFTER" ]]; then
  smoke_fail "T5 (teeth B.1): run_show parse on stripped copy returned 0 lines — strip damaged function shape"
fi

# Re-run T2 step 2: the helper-invocation grep on run_show body must NOT
# match (this is the T2 assertion that would fire smoke_fail in production).
if grep -q "bridge_agent_iso_boundary_quickref_text" "$T5_RUN_SHOW_AFTER"; then
  smoke_fail "T5 (teeth B.2): stripped run_show still references the helper — T2 grep would not fail"
fi

smoke_log "passed"
