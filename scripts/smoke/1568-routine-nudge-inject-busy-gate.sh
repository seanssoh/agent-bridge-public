#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1568-routine-nudge-inject-busy-gate.sh — Issue #1568.
#
# The daemon's routine queued-task idle-nudge (nudge_agent_session in
# bridge-daemon.sh) used to suppress the nudge whenever the target tmux
# session had ANY client attached — a bare `if (( attached > 0 ))` guard.
# Under a persistent-client multiplexer GUI (cmux, or `tmux attach` left
# open) every roster session stays attached permanently, so the routine
# idle-nudge was ALWAYS skipped and queued work was only delivered via the
# 60s redelivery / urgent path. Measured 2026-06-05 on a cmux-driven install:
# all 7 roster sessions read attached=1 simultaneously while only one tab was
# focused.
#
# Fix (#1568): gate the routine idle-nudge on the SAME real-interaction
# predicate the urgent/inject primitive already uses —
# `bridge_tmux_session_inject_busy` (composer pending input / mid-turn banner
# / recent keypress). The guard becomes:
#
#   if (( attached > 0 )) && bridge_tmux_session_inject_busy "$session" "$_nudge_engine"; then
#
# so an attached-but-IDLE session falls through and actually receives the
# nudge, while an attached session that is genuinely busy still defers (no
# regression on "don't clobber a human mid-typing"). The inject path below
# the guard is already spool-safe (re-spools when busy instead of clobbering).
#
# This smoke is a STATIC teeth check (no daemon spin-up): it asserts the
# routine idle-nudge guard in bridge-daemon.sh requires BOTH `attached > 0`
# AND `bridge_tmux_session_inject_busy`, and FAILS if the bare
# `attached > 0`-only form is reintroduced at that site. A future PR that
# reverts the guard re-strands queued tasks behind any persistent tmux client.
#
# Footgun #11 (heredoc-stdin deadlock class): this fixture uses no
# heredoc-stdin into subprocess and no `<<<` here-strings into bridge
# functions. All inspection is via grep/awk on the source file.

set -euo pipefail

# Re-exec under Bash 4+ for parity with sibling smokes (associative arrays
# / consistent regex semantics).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1568-routine-nudge-inject-busy-gate] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1568-routine-nudge-inject-busy-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Static teeth check — no bridge home needed, just a temp dir for the
# extracted function body.
smoke_make_temp_root "1568-routine-nudge-inject-busy-gate"

REPO_ROOT="$SMOKE_REPO_ROOT"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"

smoke_assert_file_exists "$DAEMON_SH" "bridge-daemon.sh present"

# Extract the nudge_agent_session() function body so the teeth assertions
# are scoped to the routine idle-nudge site and cannot be satisfied by an
# unrelated guard elsewhere in the file (e.g. the second `attached > 0`
# guard in a DIFFERENT function that must stay bare).
FN_BODY="$SMOKE_TMP_ROOT/nudge_agent_session.body"
awk '
  /^nudge_agent_session\(\)[[:space:]]*\{/ { capture=1 }
  capture { print }
  capture && /^\}/ { exit }
' "$DAEMON_SH" >"$FN_BODY"

if [[ ! -s "$FN_BODY" ]]; then
  smoke_fail "could not extract nudge_agent_session() body from bridge-daemon.sh"
fi

# ---------------------------------------------------------------------
# T1 — The routine idle-nudge guard requires the inject-busy predicate.
# The fixed guard is `if (( attached > 0 )) && bridge_tmux_session_inject_busy ...`.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t1_guard_requires_inject_busy() {
  smoke_log "T1: routine idle-nudge guard couples attached>0 with inject-busy"
  local guard_line
  guard_line="$(grep -nE 'if[[:space:]]*\(\([[:space:]]*attached[[:space:]]*>[[:space:]]*0[[:space:]]*\)\)' "$FN_BODY" || true)"
  if [[ -z "$guard_line" ]]; then
    smoke_fail "T1: no \`attached > 0\` guard found in nudge_agent_session() (function moved/renamed?)"
  fi
  # There must be exactly one such guard in this function (the routine
  # idle-nudge site). A second one would mean the function gained an
  # unexpected bare guard the teeth do not cover.
  local guard_count
  guard_count="$(printf '%s\n' "$guard_line" | grep -c . || true)"
  smoke_assert_eq "1" "$guard_count" "T1: exactly one attached>0 guard in nudge_agent_session()"
  # The guard line itself must AND-couple inject-busy.
  if ! printf '%s\n' "$guard_line" | grep -q 'bridge_tmux_session_inject_busy'; then
    smoke_fail "T1: routine idle-nudge guard is bare \`attached > 0\` — #1568 inject-busy gate missing (re-strands queued tasks behind any attached client)"
  fi
  # It must be an AND coupling (`&& bridge_tmux_session_inject_busy`), NOT an
  # OR. `(( attached > 0 )) || inject_busy` would skip on EITHER condition,
  # re-stranding queued work behind any attached client (re-opening #1568).
  if ! printf '%s\n' "$guard_line" | grep -qE '\)\)[[:space:]]*&&[[:space:]]*bridge_tmux_session_inject_busy'; then
    smoke_fail "T1: guard does not AND-couple inject-busy (\`)) && bridge_tmux_session_inject_busy\` required) — an \`||\` regression re-opens #1568"
  fi
  if printf '%s\n' "$guard_line" | grep -qE '\)\)[[:space:]]*\|\|'; then
    smoke_fail "T1: guard OR-couples inject-busy (\`)) ||\`) — skip would fire on attach-OR-busy, re-stranding queued work (#1568 regression)"
  fi
}

# ---------------------------------------------------------------------
# T2 — Teeth: the bare `attached > 0`-only guard form must NOT appear in
# nudge_agent_session(). Catches a revert that drops the && clause.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t2_no_bare_guard_form() {
  smoke_log "T2: no bare \`attached > 0\`-only guard remains in nudge_agent_session()"
  # A bare guard line is `if (( attached > 0 )); then` with nothing between
  # the closing `))` and the `; then`.
  if grep -qE 'if[[:space:]]*\(\([[:space:]]*attached[[:space:]]*>[[:space:]]*0[[:space:]]*\)\)[[:space:]]*;[[:space:]]*then' "$FN_BODY"; then
    smoke_fail "T2: bare \`if (( attached > 0 )); then\` present in nudge_agent_session() — #1568 regression"
  fi
}

# ---------------------------------------------------------------------
# T3 — Teeth: the engine is resolved via bridge_agent_engine, normalized to
# a known engine, and the resolved $_nudge_engine is what the guard passes to
# inject-busy. bridge_agent_engine returns `unknown` (rc=0) for a missing /
# clobbered engine map; for `unknown` inject-busy skips claude's midturn-banner
# detection, so a mid-turn session could be wrongly nudged. The fix normalizes
# anything that is not claude|codex to `claude` (the strictest busy predicate).
# A revert that drops the normalization re-opens the clobber-a-mid-turn risk.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t3_engine_resolved_for_inject_busy() {
  smoke_log "T3: _nudge_engine resolved + normalized, and passed to inject-busy"
  if ! grep -q 'bridge_agent_engine' "$FN_BODY"; then
    smoke_fail "T3: bridge_agent_engine not called in nudge_agent_session() (engine for inject-busy unresolved)"
  fi
  if ! grep -q '_nudge_engine' "$FN_BODY"; then
    smoke_fail "T3: _nudge_engine local missing in nudge_agent_session()"
  fi
  # The guard must pass the resolved engine, not a bare/empty/literal value.
  if ! grep -qE 'bridge_tmux_session_inject_busy[[:space:]]+"\$session"[[:space:]]+"\$_nudge_engine"' "$FN_BODY"; then
    smoke_fail "T3: guard does not pass \"\$_nudge_engine\" to inject-busy (engine resolution not threaded through)"
  fi
  # The non-claude|codex → claude normalization must be present so `unknown`
  # (the bridge_agent_engine fallback) cannot bypass claude's midturn gate.
  if ! grep -qE '_nudge_engine="?claude"?' "$FN_BODY"; then
    smoke_fail "T3: _nudge_engine normalization to claude missing — \`unknown\` engine would skip claude midturn detection (clobber-a-mid-turn risk)"
  fi
  if ! grep -qE 'claude\|codex' "$FN_BODY"; then
    smoke_fail "T3: known-engine allowlist (claude|codex) missing from the normalization guard"
  fi
}

# ---------------------------------------------------------------------
# T4 — Teeth: the #1568 rationale comment is present at the guard site so a
# future reader understands why the guard couples inject-busy (and does not
# "simplify" it back to bare attached>0).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t4_rationale_comment_present() {
  smoke_log "T4: #1568 rationale comment present at the guard site"
  if ! grep -q '#1568' "$FN_BODY"; then
    smoke_fail "T4: #1568 rationale comment missing from nudge_agent_session()"
  fi
}

# ---------------------------------------------------------------------
# T5 — Sanity: the dependency bridge_tmux_session_inject_busy is actually
# defined in lib/bridge-tmux.sh (the guard would fail closed otherwise).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329
test_t5_inject_busy_dependency_defined() {
  smoke_log "T5: bridge_tmux_session_inject_busy defined in lib/bridge-tmux.sh"
  local tmux_lib="$REPO_ROOT/lib/bridge-tmux.sh"
  smoke_assert_file_exists "$tmux_lib" "lib/bridge-tmux.sh present"
  if ! grep -qE '^bridge_tmux_session_inject_busy\(\)' "$tmux_lib"; then
    smoke_fail "T5: bridge_tmux_session_inject_busy() not defined in lib/bridge-tmux.sh"
  fi
}

smoke_run "T1: guard couples attached>0 with inject-busy" test_t1_guard_requires_inject_busy
smoke_run "T2: no bare attached>0-only guard remains" test_t2_no_bare_guard_form
smoke_run "T3: engine resolved for inject-busy" test_t3_engine_resolved_for_inject_busy
smoke_run "T4: #1568 rationale comment present" test_t4_rationale_comment_present
smoke_run "T5: inject-busy dependency defined" test_t5_inject_busy_dependency_defined

smoke_log "all T1-T5 pass"
exit 0
