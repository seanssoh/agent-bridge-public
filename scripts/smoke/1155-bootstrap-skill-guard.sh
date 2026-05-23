#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1155-bootstrap-skill-guard.sh — Issue #1155
#
# Beta10 follow-up to #1151. PR #1153 added `bridge_agent_workdir_step_a_
# complete` + applied a v2-isolation defer guard to 6 controller-touch
# sites. patch's 4-gate beta10 verification on a fresh Linux install
# found a 7th missed site: `bridge_bootstrap_project_skill`
# (`lib/bridge-skills.sh`).
#
# That helper calls `bridge_write_managed_markdown` which does shell
# `mkdir -p` + `mv` under `$workdir/.claude/skills/agent-bridge/{SKILL.md,
# references/bridge-commands.md}`. Under v2, `$workdir` is owned by the
# isolated UID after Step A, so the controller cannot write there. Worse,
# 2 of the 5 call sites (`bridge-start.sh:481` Claude, `:534` Codex) do
# NOT redirect stdout/stderr, so the failures flood operator stdout
# right before the tmux session dies (Gate 3 fail).
#
# Fix: add an optional `agent` 3rd arg + pair-gate on
# `bridge_agent_linux_user_isolation_effective` (always-skip-under-v2,
# same simple form `bridge_link_shared_claude_skill` uses at
# `lib/bridge-skills.sh:122-127`). The workdir-side write is dead-code
# under v2 — Claude reads skills from the isolated home's `~/.claude/
# skills/` via `CLAUDE_CONFIG_DIR` (populated by
# `bridge_sync_isolated_home_claude_skills` via `bridge_linux_sudo_root`).
#
# Truth table the guard enforces:
#
#   agent="" (legacy/no-context)             → proceeds (legacy path)
#   agent + isolation NOT effective          → proceeds (legacy non-isolated)
#   agent + isolation effective              → returns 0 immediately, no write
#
# This smoke is HOST-AGNOSTIC: every driver runs in a fixture tree with
# stubs for the bridge-side helpers. No sudo, no python invocation, no
# real workdir provisioning.
#
# Footgun #11 (heredoc_write deadlock class): every driver is built with
# `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash functions; no
# `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1155-bootstrap-skill-guard"
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

# ---------- shared driver template ----------
#
# Each case builds a tiny bash driver that:
#   1. Extracts `bridge_bootstrap_project_skill` verbatim from
#      `lib/bridge-skills.sh` (between the function header and the next
#      top-level `^}`). Keeps the smoke aligned to live source.
#   2. Stubs every bridge-side helper the body reaches:
#      - `bridge_project_skill_dir_for` (returns a fixed path under workdir)
#      - `bridge_render_claude_project_skill` / `bridge_render_codex_project_skill`
#        / `bridge_render_project_bridge_reference` (emit a single-line body
#        on stdout so the pipe into `bridge_write_managed_markdown` has data)
#      - `bridge_write_managed_markdown` (records its invocation in $CALL_LOG;
#        consumes stdin so the pipe stage finishes cleanly)
#      - `bridge_is_managed_markdown` (returns 0 — unused in the all-fresh path)
#      - `bridge_agent_linux_user_isolation_effective` (case-specific:
#        return 0 = effective, return 1 = not effective)
#   3. Invokes the function under test with chosen args.
#   4. Writes "RC=$?" to the log.
#
# The case-specific stub file overrides `bridge_agent_linux_user_isolation_
# effective` to flip behavior. The driver sources the common stubs first
# then the case stubs (the latter wins), then the extracted function.

build_driver() {
  # $1 = driver path
  # $2 = stubs file path (case-specific) — sourced AFTER common stubs
  local driver="$1"
  local stubs="$2"
  printf '%s\n' '#!/usr/bin/env bash' >"$driver"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  printf '%s\n' 'set -uo pipefail' >>"$driver"
  printf '%s\n' 'REPO_ROOT="$1"' >>"$driver"
  printf '%s\n' 'STUBS="$2"' >>"$driver"
  printf '%s\n' 'CALL_LOG="$3"' >>"$driver"
  printf '%s\n' 'WORKDIR="$4"' >>"$driver"
  printf '%s\n' 'AGENT="$5"' >>"$driver"
  printf '%s\n' ': >"$CALL_LOG"' >>"$driver"
  printf '%s\n' '# Extract the function under test verbatim from source.' >>"$driver"
  printf '%s\n' 'EXTRACT="$(dirname "$CALL_LOG")/fn.sh"' >>"$driver"
  printf '%s\n' 'awk "/^bridge_bootstrap_project_skill\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-skills.sh" >"$EXTRACT"' >>"$driver"
  printf '%s\n' '# BRIDGE_HOME is sourced by `bridge_render_*` stubs (no-op here, but'  >>"$driver"
  printf '%s\n' '# the function passes "$BRIDGE_HOME" as the first arg to each renderer'  >>"$driver"
  printf '%s\n' '# — define it so set -u does not trip).'  >>"$driver"
  printf '%s\n' 'export BRIDGE_HOME="${BRIDGE_HOME:-$WORKDIR/.bridge-home}"' >>"$driver"
  printf '%s\n' '# Common stubs.' >>"$driver"
  printf '%s\n' 'bridge_project_skill_dir_for() {' >>"$driver"
  printf '%s\n' '  # $1 = engine, $2 = workdir' >>"$driver"
  printf '%s\n' '  local engine="$1"; local workdir="$2"' >>"$driver"
  printf '%s\n' '  case "$engine" in' >>"$driver"
  printf '%s\n' '    claude) printf "%s" "$workdir/.claude/skills/agent-bridge" ;;' >>"$driver"
  printf '%s\n' '    codex)  printf "%s" "$workdir/.codex/skills/agent-bridge" ;;' >>"$driver"
  printf '%s\n' '    *) return 1 ;;' >>"$driver"
  printf '%s\n' '  esac' >>"$driver"
  printf '%s\n' '}' >>"$driver"
  printf '%s\n' 'bridge_render_claude_project_skill() { printf "claude-skill-body\n"; }' >>"$driver"
  printf '%s\n' 'bridge_render_codex_project_skill() { printf "codex-skill-body\n"; }' >>"$driver"
  printf '%s\n' 'bridge_render_project_bridge_reference() { printf "bridge-ref-body\n"; }' >>"$driver"
  printf '%s\n' '# bridge_write_managed_markdown: record the call, consume stdin, return 0.' >>"$driver"
  printf '%s\n' '# Recording the call is the key assertion — the guard MUST short-circuit' >>"$driver"
  printf '%s\n' '# BEFORE this is reached on the isolation-effective path.' >>"$driver"
  printf '%s\n' 'bridge_write_managed_markdown() {' >>"$driver"
  printf '%s\n' '  local file="$1"; local label="$2"' >>"$driver"
  printf '%s\n' '  cat >/dev/null  # drain the pipe' >>"$driver"
  printf '%s\n' '  echo "bridge_write_managed_markdown:${label}:${file}" >>"$CALL_LOG"' >>"$driver"
  printf '%s\n' '  return 0' >>"$driver"
  printf '%s\n' '}' >>"$driver"
  printf '%s\n' 'bridge_is_managed_markdown() { return 0; }' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1090' >>"$driver"
  printf '%s\n' 'source "$STUBS"' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1090' >>"$driver"
  printf '%s\n' 'source "$EXTRACT"' >>"$driver"
  printf '%s\n' '# Invoke with the chosen engine (always "claude" for this smoke — the' >>"$driver"
  printf '%s\n' '# guard logic is engine-agnostic; codex path is exercised by T4).' >>"$driver"
  printf '%s\n' 'ENGINE="${SMOKE_ENGINE:-claude}"' >>"$driver"
  printf '%s\n' 'bridge_bootstrap_project_skill "$ENGINE" "$WORKDIR" "$AGENT"' >>"$driver"
  printf '%s\n' 'echo "RC=$?" >>"$CALL_LOG"' >>"$driver"
  chmod +x "$driver"
  : "$stubs"  # silence "unused" lint — caller writes it
}

# ---------- T1 — agent + isolation effective → guard fires, NO write ----------
#
# The canonical v2 fresh-create / start shape: agent context is present
# AND `bridge_agent_linux_user_isolation_effective` returns 0. The guard
# must short-circuit before `bridge_write_managed_markdown` is called.
# This is the exact regression contract for the operator-stdout
# Permission denied flood observed in #1155.
T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR"
T1_WORKDIR="$T1_DIR/workdir"
mkdir -p "$T1_WORKDIR"
T1_STUBS="$T1_DIR/stubs.sh"
printf '%s\n' '# T1 stubs — isolation EFFECTIVE.' >"$T1_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T1_STUBS"
T1_DRIVER="$T1_DIR/driver.sh"
build_driver "$T1_DRIVER" "$T1_STUBS"
T1_CALL_LOG="$T1_DIR/calls.log"
"$BRIDGE_BASH" "$T1_DRIVER" "$REPO_ROOT" "$T1_STUBS" "$T1_CALL_LOG" "$T1_WORKDIR" "smoke-agent" \
  2>"$T1_DIR/err" \
  || smoke_fail "T1 driver rc=$? — see $T1_DIR/err"

if grep -q '^bridge_write_managed_markdown:' "$T1_CALL_LOG"; then
  smoke_fail "T1 expected NO bridge_write_managed_markdown call (guard must short-circuit on isolation-effective). calls: $(tr '\n' '|' <"$T1_CALL_LOG")"
fi
grep -q '^RC=0$' "$T1_CALL_LOG" \
  || smoke_fail "T1 expected RC=0 (guard returns 0). calls: $(tr '\n' '|' <"$T1_CALL_LOG")"
smoke_log "T1 PASS: agent + isolation effective → guard short-circuits, no managed-markdown write"

# ---------- T2 — agent + isolation NOT effective → bootstrap proceeds (legacy) ----------
#
# Legacy non-isolated agent: guard's second conjunct
# (`bridge_agent_linux_user_isolation_effective` returns non-zero) means
# the function falls through to the existing render + write path. We
# expect TWO `bridge_write_managed_markdown` calls (SKILL.md + the
# bridge-commands reference).
T2_DIR="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_DIR"
T2_WORKDIR="$T2_DIR/workdir"
mkdir -p "$T2_WORKDIR"
T2_STUBS="$T2_DIR/stubs.sh"
printf '%s\n' '# T2 stubs — isolation NOT effective.' >"$T2_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$T2_STUBS"
T2_DRIVER="$T2_DIR/driver.sh"
build_driver "$T2_DRIVER" "$T2_STUBS"
T2_CALL_LOG="$T2_DIR/calls.log"
"$BRIDGE_BASH" "$T2_DRIVER" "$REPO_ROOT" "$T2_STUBS" "$T2_CALL_LOG" "$T2_WORKDIR" "smoke-agent" \
  2>"$T2_DIR/err" \
  || smoke_fail "T2 driver rc=$? — see $T2_DIR/err"

T2_WRITE_COUNT="$(grep -c '^bridge_write_managed_markdown:' "$T2_CALL_LOG" || true)"
[[ "$T2_WRITE_COUNT" == "2" ]] \
  || smoke_fail "T2 expected exactly 2 bridge_write_managed_markdown calls (SKILL.md + bridge-commands ref), got $T2_WRITE_COUNT. calls: $(tr '\n' '|' <"$T2_CALL_LOG")"
grep -q '^bridge_write_managed_markdown:Claude bridge skill:' "$T2_CALL_LOG" \
  || smoke_fail "T2 expected SKILL.md write under 'Claude bridge skill' label. calls: $(tr '\n' '|' <"$T2_CALL_LOG")"
grep -q '^bridge_write_managed_markdown:bridge reference:' "$T2_CALL_LOG" \
  || smoke_fail "T2 expected reference write under 'bridge reference' label. calls: $(tr '\n' '|' <"$T2_CALL_LOG")"
grep -q '^RC=0$' "$T2_CALL_LOG" \
  || smoke_fail "T2 expected RC=0 (legacy proceeds). calls: $(tr '\n' '|' <"$T2_CALL_LOG")"
smoke_log "T2 PASS: agent + isolation not effective → bootstrap proceeds (legacy path preserved)"

# ---------- T3 — empty agent arg → bootstrap proceeds (no-context fallback) ----------
#
# Some scaffold paths may not have an agent in scope (or callers may pass
# empty for a reason). The guard's first conjunct (`[[ -n "$agent" ]]`)
# short-circuits the entire isolation check on empty agent → legacy
# behavior preserved. This case asserts the no-context fallback so a
# future PR cannot tighten the guard into "always defer on isolation
# effective" (which would break shared-mode and pre-#1155 callers).
T3_DIR="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_DIR"
T3_WORKDIR="$T3_DIR/workdir"
mkdir -p "$T3_WORKDIR"
T3_STUBS="$T3_DIR/stubs.sh"
# Even though isolation_effective returns 0, the empty-agent first conjunct
# short-circuits BEFORE the helper is consulted — `bridge_bootstrap_
# project_skill` must proceed exactly as in legacy single-arg invocations
# (`bridge-setup.sh` callers prior to #1155).
printf '%s\n' '# T3 stubs — isolation reports effective, but agent="" should NOT consult it.' >"$T3_STUBS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() {' >>"$T3_STUBS"
printf '%s\n' '  # If the guard incorrectly reaches this on empty agent, record a marker' >>"$T3_STUBS"
printf '%s\n' '  # so the assertion below catches the regression. Returning 0 here would' >>"$T3_STUBS"
printf '%s\n' '  # incorrectly defer if the [[ -n "$agent" ]] short-circuit were dropped.' >>"$T3_STUBS"
printf '%s\n' '  echo "ISOLATION_EFFECTIVE_CONSULTED_WITH_EMPTY_AGENT" >>"$CALL_LOG"' >>"$T3_STUBS"
printf '%s\n' '  return 0' >>"$T3_STUBS"
printf '%s\n' '}' >>"$T3_STUBS"
T3_DRIVER="$T3_DIR/driver.sh"
build_driver "$T3_DRIVER" "$T3_STUBS"
T3_CALL_LOG="$T3_DIR/calls.log"
"$BRIDGE_BASH" "$T3_DRIVER" "$REPO_ROOT" "$T3_STUBS" "$T3_CALL_LOG" "$T3_WORKDIR" "" \
  2>"$T3_DIR/err" \
  || smoke_fail "T3 driver rc=$? — see $T3_DIR/err"

if grep -q '^ISOLATION_EFFECTIVE_CONSULTED_WITH_EMPTY_AGENT$' "$T3_CALL_LOG"; then
  smoke_fail "T3 expected guard to short-circuit on empty agent BEFORE consulting bridge_agent_linux_user_isolation_effective. calls: $(tr '\n' '|' <"$T3_CALL_LOG")"
fi
T3_WRITE_COUNT="$(grep -c '^bridge_write_managed_markdown:' "$T3_CALL_LOG" || true)"
[[ "$T3_WRITE_COUNT" == "2" ]] \
  || smoke_fail "T3 expected exactly 2 bridge_write_managed_markdown calls (legacy no-context fallback), got $T3_WRITE_COUNT. calls: $(tr '\n' '|' <"$T3_CALL_LOG")"
grep -q '^RC=0$' "$T3_CALL_LOG" \
  || smoke_fail "T3 expected RC=0. calls: $(tr '\n' '|' <"$T3_CALL_LOG")"
smoke_log "T3 PASS: empty agent arg → legacy path proceeds, isolation check not consulted"

smoke_log "all 3 tests PASS (#1155 bridge_bootstrap_project_skill v2-isolation guard: T1 + T2 + T3)"
