#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1416-onboarding-state-field-anchor.sh — onboarding-state
# parser field-line anchor (parser-trap hardening).
#
# Root cause (operator report, fresh rc1 mac server, admin agent `patch`):
# `bridge_agent_onboarding_state` (lib/bridge-agents.sh) extracted the
# onboarding state with an UNANCHORED `grep -E 'Onboarding State:…'`
# + `head -n 1`. The SESSION-TYPE.md templates carry the real state on a
# top-block metadata line `- Onboarding State: <state>` (line ~4) AND the
# admin / static-codex / dynamic / cron checklist BODIES quote the literal
# string `Onboarding State: pending` / `Onboarding State: complete` as
# instruction text (line ~18+). `head -n 1` only happened to win because
# the metadata line precedes the body in the shipped templates — a fragile
# accident that breaks the moment the lines reorder.
#
# Fix (A): anchor both the grep and the BASH_REMATCH to the field-line
# shape `^` + optional whitespace + optional `- ` markdown list marker +
# `Onboarding State:`. A body line with prose before the quoted string can
# never match, so the parser reads the real field regardless of line
# order. Mirrors `bridge-upgrade.py:detect_prior_onboarding_complete`
# (`^-?\s*Onboarding State:`) and the watchdog `parse_session_type`
# anchor.
#
# Fix (B): the SESSION-TYPE.md template checklist bodies were also
# reworded so they no longer reproduce the bare field-shaped literal
# (defense in depth); this smoke verifies the shipped templates still
# parse to their declared field value.
#
# T1 (the trap, FAILS pre-fix): a SESSION-TYPE.md whose body `pending`
#     line is placed BEFORE the field `complete` line must resolve to
#     `complete`. Pre-fix `head -n 1` picked the body line → `pending`.
# T2: dual-copy read-order is the runtime-canonical workdir-first contract
#     (watchdog #1108/#1109 + live session cwd == workdir). With
#     workdir=pending + home=complete the resolver returns `pending`
#     (workdir wins). This is a CHANGE-DETECTOR for that ordering, not the
#     bug — documenting it keeps a future read-order edit from sliding in
#     unnoticed. The operator's symptom was this ordering, not the trap.
# T3: the actual shipped templates parse to their declared field value.
# T4: field flipped to `complete` round-trips to `complete`.
#
# This smoke is HOST-AGNOSTIC: every driver runs in a fixture tree with
# stubs for `bridge_agent_workdir` / `bridge_agent_default_home` /
# `bridge_agent_onboarding_markers_complete`. No sudo, no iso-UID probe,
# no real workdir provisioning.
#
# Footgun #11 (heredoc_write deadlock class): the driver is built with
# `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash functions; no
# `$()` capture of heredoc-stdin into a subprocess.

set -uo pipefail

SMOKE_NAME="1416-onboarding-state-field-anchor"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# ---------- shared driver ----------
#
# Pulls just `bridge_agent_onboarding_state` from the lib, stubs the
# workdir/home resolvers to point at the fixture tree, stubs the marker
# helper to return 0 (markers OK — we are testing the SESSION-TYPE.md
# field extraction, not the #1139 marker downgrade), then prints the
# resolved state.
DRIVER="$SMOKE_TMP_ROOT/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'set -uo pipefail' >>"$DRIVER"
printf '%s\n' 'REPO_ROOT="$1"; FIXTURE_DIR="$2"' >>"$DRIVER"
printf '%s\n' 'awk "/^bridge_agent_onboarding_state\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh" >"$FIXTURE_DIR/state-fn.sh"' >>"$DRIVER"
printf '%s\n' 'bridge_agent_workdir() { printf "%s" "$FIXTURE_DIR/workdir"; }' >>"$DRIVER"
printf '%s\n' 'bridge_agent_default_home() { printf "%s" "$FIXTURE_DIR/home"; }' >>"$DRIVER"
printf '%s\n' 'bridge_agent_onboarding_markers_complete() { return 0; }' >>"$DRIVER"
printf '%s\n' '# shellcheck disable=SC1091' >>"$DRIVER"
printf '%s\n' 'source "$FIXTURE_DIR/state-fn.sh"' >>"$DRIVER"
printf '%s\n' 'bridge_agent_onboarding_state "smoke-agent"' >>"$DRIVER"

run_state() {
  # $1 = fixture dir
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$1" 2>"$1/driver.err"
}

# ---------- T1 — the trap: body `pending` BEFORE field `complete` ----------
T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR/workdir" "$T1_DIR/home"
{
  printf '%s\n' '# Session Type'
  printf '%s\n' ''
  printf '%s\n' '## First-Session Checklist'
  printf '%s\n' '- If `Onboarding State: pending` when the first user message arrives, ask the two onboarding questions.'
  printf '%s\n' ''
  printf '%s\n' '- Session Type: admin'
  printf '%s\n' '- Onboarding State: complete'
} >"$T1_DIR/workdir/SESSION-TYPE.md"
T1_OUT="$(run_state "$T1_DIR")" || smoke_fail "T1 driver rc=$? — see $T1_DIR/driver.err"
[[ "$T1_OUT" == "complete" ]] \
  || smoke_fail "T1 (trap) expected 'complete' (field anchor must skip the body 'pending' line), got '$T1_OUT' — pre-fix head-1 picks the body line and returns 'pending'"
smoke_log "T1 PASS: body 'Onboarding State: pending' line before the field 'complete' line is ignored → complete"

# ---------- T2 — dual-copy read-order: workdir wins (canonical runtime contract) ----------
T2_DIR="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_DIR/workdir" "$T2_DIR/home"
{
  printf '%s\n' '# Session Type'
  printf '%s\n' ''
  printf '%s\n' '- Session Type: admin'
  printf '%s\n' '- Onboarding State: pending'
} >"$T2_DIR/workdir/SESSION-TYPE.md"
{
  printf '%s\n' '# Session Type'
  printf '%s\n' ''
  printf '%s\n' '- Session Type: admin'
  printf '%s\n' '- Onboarding State: complete'
} >"$T2_DIR/home/SESSION-TYPE.md"
T2_OUT="$(run_state "$T2_DIR")" || smoke_fail "T2 driver rc=$? — see $T2_DIR/driver.err"
[[ "$T2_OUT" == "pending" ]] \
  || smoke_fail "T2 (read-order change-detector) expected 'pending' — the runtime-canonical read is workdir-first (watchdog #1108/#1109 + live session cwd==workdir). Got '$T2_OUT'. If you intentionally changed the read order to home-first, update this assertion AND verify session-resume / watchdog / restart-readiness consumers."
smoke_log "T2 PASS: workdir=pending + home=complete → pending (workdir-first is the runtime-canonical contract; operator must edit the workdir copy or use the materialize path)"

# ---------- T3 — the actual shipped templates parse to their field value ----------
declare -A T3_EXPECT=(
  [admin]=pending
  [static-claude]=complete
  [static-codex]=pending
  [dynamic]=pending
  [cron]=pending
)
for st in admin static-claude static-codex dynamic cron; do
  tmpl="$REPO_ROOT/agents/_template/session-types/$st.md"
  [[ -f "$tmpl" ]] || smoke_fail "T3 missing template: $tmpl"
  T3_DIR="$SMOKE_TMP_ROOT/t3-$st"
  mkdir -p "$T3_DIR/workdir" "$T3_DIR/home"
  cp "$tmpl" "$T3_DIR/workdir/SESSION-TYPE.md"
  T3_OUT="$(run_state "$T3_DIR")" || smoke_fail "T3 ($st) driver rc=$? — see $T3_DIR/driver.err"
  [[ "$T3_OUT" == "${T3_EXPECT[$st]}" ]] \
    || smoke_fail "T3 ($st.md) expected '${T3_EXPECT[$st]}', got '$T3_OUT' — template field-line drift or a re-introduced body trap"
done
smoke_log "T3 PASS: all 5 shipped session-type templates parse to their declared Onboarding State field"

# ---------- T4 — field flipped to complete round-trips ----------
T4_DIR="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_DIR/workdir" "$T4_DIR/home"
# Start from the real admin template (field + reworded body) and flip the
# field line to complete, the way an agent completing onboarding would.
sed 's/^- Onboarding State: pending$/- Onboarding State: complete/' \
  "$REPO_ROOT/agents/_template/session-types/admin.md" >"$T4_DIR/workdir/SESSION-TYPE.md"
T4_OUT="$(run_state "$T4_DIR")" || smoke_fail "T4 driver rc=$? — see $T4_DIR/driver.err"
[[ "$T4_OUT" == "complete" ]] \
  || smoke_fail "T4 expected 'complete' after flipping the admin template field line, got '$T4_OUT'"
smoke_log "T4 PASS: admin template with field flipped to complete → complete"

smoke_log "all tests PASS (1416 onboarding-state field anchor: T1 trap + T2 read-order + T3 templates + T4 round-trip)"
