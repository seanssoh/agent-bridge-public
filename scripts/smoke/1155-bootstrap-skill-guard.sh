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
# `mkdir -p` + `mv` under `$workdir/<engine-prefix>/skills/agent-bridge/...`.
# Under v2, `$workdir` is owned by the isolated UID after Step A, so the
# controller cannot write there. Worse, 2 of the 5 call sites
# (`bridge-start.sh:481` Claude, `:534` Codex) do NOT redirect stdout/
# stderr, so the failures flood operator stdout right before the tmux
# session dies (Gate 3 fail).
#
# r1 fix (PR #1156 first commit): blanket engine-agnostic DEFER guard.
# Codex r1 review (BLOCKING 1 + 2) caught two engine-asymmetry bugs:
#   - Codex has NO isolated-home reading path (no CODEX_CONFIG_DIR
#     analog, no isolated-home sync), so the blanket DEFER silently
#     dropped Codex's documented project skill at
#     `$workdir/.agents/skills/agent-bridge/`. r1's "workdir-side is
#     dead-code" reasoning only holds for Claude.
#   - The original smoke claimed T4 exercised Codex but only had T1-T3
#     (Claude-default), and stubbed the wrong Codex path
#     (`.codex/skills` vs production `.agents/skills`).
#
# r2 fix (this file's contract): per-engine policy in
# `bridge_bootstrap_project_skill`:
#
#   - Claude under v2 (Step A complete or pending): DEFER. Workdir-side
#     write is dead-code; `bridge_sync_isolated_home_claude_skills`
#     populates the isolated home which `CLAUDE_CONFIG_DIR` points at.
#   - Codex under v2 Step A pending: DEFER. Workdir not yet chowned.
#   - Codex under v2 Step A complete: SUDO-ESCALATE. Render to
#     controller-owned tmpfiles, `bridge_linux_sudo_root install` +
#     chown to isolated UID. Same model as
#     `bridge_ensure_project_claude_guidance` r3
#     (lib/bridge-skills.sh:783-901).
#   - Legacy non-isolated (any engine) and empty-agent: unchanged legacy
#     direct write via `bridge_write_managed_markdown`.
#
# Truth table the guard enforces:
#
#   engine  | iso effective | step A    | agent | behavior
#   --------|---------------|-----------|-------|----------------------------
#   claude  | yes           | (any)     | set   | DEFER (T1)
#   claude  | no            | -         | set   | legacy direct write (T2)
#   any     | (any)         | -         | ""    | legacy direct write (T3)
#   codex   | yes           | complete  | set   | SUDO-ESCALATE (T4)
#   codex   | no            | -         | set   | legacy direct write (T5)
#   codex   | yes           | pending   | set   | DEFER (T6)
#
# This smoke is HOST-AGNOSTIC: every driver runs in a fixture tree with
# stubs for the bridge-side helpers. No sudo, no python invocation, no
# real workdir provisioning. The Codex sudo-escalate path is exercised
# by stubbing `bridge_linux_sudo_root` to record its argv into a call
# log (no real privilege elevation).
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
#      - `bridge_project_skill_dir_for` (returns the production path under
#         workdir; Codex → .agents/skills, Claude → .claude/skills)
#      - `bridge_render_claude_project_skill` / `bridge_render_codex_project_skill`
#        / `bridge_render_project_bridge_reference` (emit a single-line body
#        on stdout so the pipe into `bridge_write_managed_markdown` (legacy
#        path) or the redirect to tmpfile (v2 sudo path) has data)
#      - `bridge_write_managed_markdown` (records its invocation in $CALL_LOG;
#        consumes stdin so the pipe stage finishes cleanly — used by legacy
#        path only)
#      - `bridge_linux_sudo_root` (records each invocation in $CALL_LOG;
#        executes the arguments directly so install/mv/mkdir actually
#        materialize the tmpfile dance — used by the Codex v2 sudo path)
#      - `bridge_is_managed_markdown` (returns 0 — unused in the all-fresh path)
#      - `bridge_agent_linux_user_isolation_effective` (case-specific:
#        return 0 = effective, return 1 = not effective)
#      - `bridge_agent_workdir_step_a_complete` (case-specific)
#      - `bridge_agent_os_user` (returns a fixed test username)
#      - `bridge_warn` (records to $CALL_LOG — so soft-fail warnings are
#        visible to assertions)
#   3. Invokes the function under test with the engine chosen by
#      `SMOKE_ENGINE` (default: per case), `WORKDIR`, and `AGENT`.
#   4. Writes "RC=$?" to the log.

build_driver() {
  # $1 = driver path
  # $2 = stubs file path (case-specific) — sourced AFTER common stubs
  # $3 = engine to test (claude | codex)
  local driver="$1"
  local stubs="$2"
  local engine="$3"
  printf '%s\n' '#!/usr/bin/env bash' >"$driver"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  printf '%s\n' 'set -uo pipefail' >>"$driver"
  printf '%s\n' 'REPO_ROOT="$1"' >>"$driver"
  printf '%s\n' 'STUBS="$2"' >>"$driver"
  printf '%s\n' 'CALL_LOG="$3"' >>"$driver"
  printf '%s\n' 'WORKDIR="$4"' >>"$driver"
  printf '%s\n' 'AGENT="$5"' >>"$driver"
  printf '%s\n' 'ENGINE="$6"' >>"$driver"
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
  printf '%s\n' '  # $1 = engine, $2 = workdir — match production paths' >>"$driver"
  printf '%s\n' '  # (lib/bridge-skills.sh:22-29): codex → .agents/, claude → .claude/.' >>"$driver"
  printf '%s\n' '  local engine="$1"; local workdir="$2"' >>"$driver"
  printf '%s\n' '  case "$engine" in' >>"$driver"
  printf '%s\n' '    claude) printf "%s" "$workdir/.claude/skills/agent-bridge" ;;' >>"$driver"
  printf '%s\n' '    codex)  printf "%s" "$workdir/.agents/skills/agent-bridge" ;;' >>"$driver"
  printf '%s\n' '    *) return 1 ;;' >>"$driver"
  printf '%s\n' '  esac' >>"$driver"
  printf '%s\n' '}' >>"$driver"
  printf '%s\n' 'bridge_render_claude_project_skill() { printf "claude-skill-body\n"; }' >>"$driver"
  printf '%s\n' 'bridge_render_codex_project_skill() { printf "codex-skill-body\n"; }' >>"$driver"
  printf '%s\n' 'bridge_render_project_bridge_reference() { printf "bridge-ref-body\n"; }' >>"$driver"
  printf '%s\n' '# bridge_write_managed_markdown: record the call, consume stdin, return 0.' >>"$driver"
  printf '%s\n' '# Recording the call is the key assertion — the guard MUST short-circuit' >>"$driver"
  printf '%s\n' '# BEFORE this is reached on the isolation-effective DEFER paths (T1, T6).' >>"$driver"
  printf '%s\n' 'bridge_write_managed_markdown() {' >>"$driver"
  printf '%s\n' '  local file="$1"; local label="$2"' >>"$driver"
  printf '%s\n' '  cat >/dev/null  # drain the pipe' >>"$driver"
  printf '%s\n' '  echo "bridge_write_managed_markdown:${label}:${file}" >>"$CALL_LOG"' >>"$driver"
  printf '%s\n' '  return 0' >>"$driver"
  printf '%s\n' '}' >>"$driver"
  printf '%s\n' 'bridge_is_managed_markdown() { return 0; }' >>"$driver"
  printf '%s\n' '# bridge_linux_sudo_root: record the argv, then execute it for real so the' >>"$driver"
  printf '%s\n' '# Codex v2 sudo-escalate path actually moves files. Records every call so' >>"$driver"
  printf '%s\n' '# assertions can verify install/mv/mkdir/chown invocations occurred in the' >>"$driver"
  printf '%s\n' '# right order against the expected paths.' >>"$driver"
  printf '%s\n' 'bridge_linux_sudo_root() {' >>"$driver"
  printf '%s\n' '  echo "bridge_linux_sudo_root:$*" >>"$CALL_LOG"' >>"$driver"
  printf '%s\n' '  "$@"' >>"$driver"
  printf '%s\n' '}' >>"$driver"
  printf '%s\n' 'bridge_agent_os_user() { printf "smoke-user\n"; }' >>"$driver"
  printf '%s\n' 'bridge_warn() { echo "bridge_warn:$*" >>"$CALL_LOG"; }' >>"$driver"
  printf '%s\n' 'bridge_info() { :; }' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1090' >>"$driver"
  printf '%s\n' 'source "$STUBS"' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1090' >>"$driver"
  printf '%s\n' 'source "$EXTRACT"' >>"$driver"
  printf '%s\n' 'bridge_bootstrap_project_skill "$ENGINE" "$WORKDIR" "$AGENT"' >>"$driver"
  printf '%s\n' 'echo "RC=$?" >>"$CALL_LOG"' >>"$driver"
  chmod +x "$driver"
  : "$stubs" "$engine"  # silence "unused" lint
}

# ---------- T1 — Claude + isolation effective → DEFER, NO write ----------
#
# Workdir-side write is dead-code for Claude under v2 (CLAUDE_CONFIG_DIR
# points at isolated home; `bridge_sync_isolated_home_claude_skills`
# handles it). Guard must short-circuit before
# `bridge_write_managed_markdown` is called.
T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR"
T1_WORKDIR="$T1_DIR/workdir"
mkdir -p "$T1_WORKDIR"
T1_STUBS="$T1_DIR/stubs.sh"
printf '%s\n' '# T1 stubs — Claude + isolation EFFECTIVE.' >"$T1_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T1_STUBS"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 0; }  # unused for claude branch' >>"$T1_STUBS"
T1_DRIVER="$T1_DIR/driver.sh"
build_driver "$T1_DRIVER" "$T1_STUBS" claude
T1_CALL_LOG="$T1_DIR/calls.log"
"$BRIDGE_BASH" "$T1_DRIVER" "$REPO_ROOT" "$T1_STUBS" "$T1_CALL_LOG" "$T1_WORKDIR" "smoke-agent" "claude" \
  2>"$T1_DIR/err" \
  || smoke_fail "T1 driver rc=$? — see $T1_DIR/err"

if grep -q '^bridge_write_managed_markdown:' "$T1_CALL_LOG"; then
  smoke_fail "T1 expected NO bridge_write_managed_markdown call (Claude+v2 DEFER). calls: $(tr '\n' '|' <"$T1_CALL_LOG")"
fi
if grep -q '^bridge_linux_sudo_root:' "$T1_CALL_LOG"; then
  smoke_fail "T1 expected NO bridge_linux_sudo_root call (Claude+v2 DEFER, not SUDO-ESCALATE). calls: $(tr '\n' '|' <"$T1_CALL_LOG")"
fi
grep -q '^RC=0$' "$T1_CALL_LOG" \
  || smoke_fail "T1 expected RC=0 (guard returns 0). calls: $(tr '\n' '|' <"$T1_CALL_LOG")"
smoke_log "T1 PASS: claude + isolation effective → DEFER, no managed-markdown write, no sudo"

# ---------- T2 — Claude + isolation NOT effective → bootstrap proceeds (legacy) ----------
#
# Legacy non-isolated Claude: guard's isolation conjunct is false, so the
# function falls through to the existing render + write path. We expect
# TWO `bridge_write_managed_markdown` calls (SKILL.md + the
# bridge-commands reference).
T2_DIR="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_DIR"
T2_WORKDIR="$T2_DIR/workdir"
mkdir -p "$T2_WORKDIR"
T2_STUBS="$T2_DIR/stubs.sh"
printf '%s\n' '# T2 stubs — Claude + isolation NOT effective.' >"$T2_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$T2_STUBS"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 0; }  # unused, isolation not effective' >>"$T2_STUBS"
T2_DRIVER="$T2_DIR/driver.sh"
build_driver "$T2_DRIVER" "$T2_STUBS" claude
T2_CALL_LOG="$T2_DIR/calls.log"
"$BRIDGE_BASH" "$T2_DRIVER" "$REPO_ROOT" "$T2_STUBS" "$T2_CALL_LOG" "$T2_WORKDIR" "smoke-agent" "claude" \
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
smoke_log "T2 PASS: claude + isolation not effective → bootstrap proceeds (legacy path preserved)"

# ---------- T3 — empty agent arg → bootstrap proceeds (no-context fallback) ----------
#
# Some scaffold paths may not have an agent in scope. The guard's first
# conjunct (`[[ -n "$agent" ]]`) short-circuits the isolation check on
# empty agent → legacy behavior preserved. Run against Claude here; T5
# covers the Codex empty-agent case implicitly through the same conjunct.
T3_DIR="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_DIR"
T3_WORKDIR="$T3_DIR/workdir"
mkdir -p "$T3_WORKDIR"
T3_STUBS="$T3_DIR/stubs.sh"
printf '%s\n' '# T3 stubs — isolation reports effective, but agent="" should NOT consult it.' >"$T3_STUBS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() {' >>"$T3_STUBS"
printf '%s\n' '  echo "ISOLATION_EFFECTIVE_CONSULTED_WITH_EMPTY_AGENT" >>"$CALL_LOG"' >>"$T3_STUBS"
printf '%s\n' '  return 0' >>"$T3_STUBS"
printf '%s\n' '}' >>"$T3_STUBS"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 0; }' >>"$T3_STUBS"
T3_DRIVER="$T3_DIR/driver.sh"
build_driver "$T3_DRIVER" "$T3_STUBS" claude
T3_CALL_LOG="$T3_DIR/calls.log"
"$BRIDGE_BASH" "$T3_DRIVER" "$REPO_ROOT" "$T3_STUBS" "$T3_CALL_LOG" "$T3_WORKDIR" "" "claude" \
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

# ---------- T4 — Codex + isolation effective + Step A complete → SUDO-ESCALATE ----------
#
# Codex's documented project-local contract (`.agents/skills/agent-bridge/`
# in $workdir) has no v2 replacement: there's no CODEX_CONFIG_DIR analog
# and no `bridge_sync_isolated_home_codex_skills`. After Step A the
# workdir is owned by the isolated UID, so the controller cannot write
# directly — but the file MUST exist for the launched Codex to load the
# skill from CWD. r2 fix: SUDO-ESCALATE — render to tmpfiles, then
# `bridge_linux_sudo_root install + chown` into place.
#
# Assertions:
#   - NO `bridge_write_managed_markdown` calls (legacy pipe path skipped)
#   - `bridge_linux_sudo_root mkdir -p` for the references subdir
#   - `bridge_linux_sudo_root install -m 0644` twice (SKILL.md + reference)
#   - `bridge_linux_sudo_root chown smoke-user:smoke-user` for staged files
#   - `bridge_linux_sudo_root mv -f` twice (atomic install)
#   - Final files exist with the expected content under the production
#     path (`.agents/skills/agent-bridge/`)
#   - RC=0
T4_DIR="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_DIR"
T4_WORKDIR="$T4_DIR/workdir"
mkdir -p "$T4_WORKDIR"
T4_STUBS="$T4_DIR/stubs.sh"
printf '%s\n' '# T4 stubs — Codex + isolation EFFECTIVE + Step A COMPLETE.' >"$T4_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T4_STUBS"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 0; }  # Step A complete → SUDO-ESCALATE' >>"$T4_STUBS"
T4_DRIVER="$T4_DIR/driver.sh"
build_driver "$T4_DRIVER" "$T4_STUBS" codex
T4_CALL_LOG="$T4_DIR/calls.log"
"$BRIDGE_BASH" "$T4_DRIVER" "$REPO_ROOT" "$T4_STUBS" "$T4_CALL_LOG" "$T4_WORKDIR" "smoke-agent" "codex" \
  2>"$T4_DIR/err" \
  || smoke_fail "T4 driver rc=$? — see $T4_DIR/err"

if grep -q '^bridge_write_managed_markdown:' "$T4_CALL_LOG"; then
  smoke_fail "T4 expected NO bridge_write_managed_markdown call (Codex+v2 SUDO-ESCALATE, not legacy pipe). calls: $(tr '\n' '|' <"$T4_CALL_LOG")"
fi

# Production path assertion — Codex MUST land at .agents/skills/agent-bridge,
# NOT .codex/skills (the r1 stub path that was wrong).
T4_SKILL_FILE="$T4_WORKDIR/.agents/skills/agent-bridge/SKILL.md"
T4_REF_FILE="$T4_WORKDIR/.agents/skills/agent-bridge/references/bridge-commands.md"
[[ -f "$T4_SKILL_FILE" ]] \
  || smoke_fail "T4 expected SKILL.md at production path $T4_SKILL_FILE. calls: $(tr '\n' '|' <"$T4_CALL_LOG")"
[[ -f "$T4_REF_FILE" ]] \
  || smoke_fail "T4 expected reference file at production path $T4_REF_FILE. calls: $(tr '\n' '|' <"$T4_CALL_LOG")"

grep -q '^bridge_linux_sudo_root:mkdir -p .*/\.agents/skills/agent-bridge/references' "$T4_CALL_LOG" \
  || smoke_fail "T4 expected sudo mkdir -p for .agents/skills/agent-bridge/references. calls: $(tr '\n' '|' <"$T4_CALL_LOG")"

T4_INSTALL_COUNT="$(grep -c '^bridge_linux_sudo_root:install -m 0644 ' "$T4_CALL_LOG" || true)"
[[ "$T4_INSTALL_COUNT" == "2" ]] \
  || smoke_fail "T4 expected exactly 2 sudo install -m 0644 invocations (SKILL.md + reference), got $T4_INSTALL_COUNT. calls: $(tr '\n' '|' <"$T4_CALL_LOG")"

T4_MV_COUNT="$(grep -c '^bridge_linux_sudo_root:mv -f ' "$T4_CALL_LOG" || true)"
[[ "$T4_MV_COUNT" == "2" ]] \
  || smoke_fail "T4 expected exactly 2 sudo mv -f invocations (atomic install of SKILL.md + reference), got $T4_MV_COUNT. calls: $(tr '\n' '|' <"$T4_CALL_LOG")"

grep -q '^bridge_linux_sudo_root:chown smoke-user:smoke-user ' "$T4_CALL_LOG" \
  || smoke_fail "T4 expected sudo chown smoke-user:smoke-user on staged files. calls: $(tr '\n' '|' <"$T4_CALL_LOG")"

# Verify the rendered content actually reached its destination.
grep -q 'codex-skill-body' "$T4_SKILL_FILE" \
  || smoke_fail "T4 expected SKILL.md content from bridge_render_codex_project_skill stub, got: $(head -c 200 "$T4_SKILL_FILE")"
grep -q 'bridge-ref-body' "$T4_REF_FILE" \
  || smoke_fail "T4 expected reference content from bridge_render_project_bridge_reference stub, got: $(head -c 200 "$T4_REF_FILE")"

grep -q '^RC=0$' "$T4_CALL_LOG" \
  || smoke_fail "T4 expected RC=0 (sudo-escalate succeeds). calls: $(tr '\n' '|' <"$T4_CALL_LOG")"
smoke_log "T4 PASS: codex + isolation effective + Step A complete → SUDO-ESCALATE to .agents/skills/agent-bridge/ via bridge_linux_sudo_root"

# ---------- T5 — Codex + isolation NOT effective → bootstrap proceeds (legacy) ----------
#
# Legacy non-isolated Codex: guard's isolation conjunct is false. The
# function falls through to the legacy direct-write path. Expects exactly
# 2 `bridge_write_managed_markdown` calls labeled for Codex, against the
# production `.agents/skills/agent-bridge/` path.
T5_DIR="$SMOKE_TMP_ROOT/t5"
mkdir -p "$T5_DIR"
T5_WORKDIR="$T5_DIR/workdir"
mkdir -p "$T5_WORKDIR"
T5_STUBS="$T5_DIR/stubs.sh"
printf '%s\n' '# T5 stubs — Codex + isolation NOT effective.' >"$T5_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$T5_STUBS"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 0; }  # unused, isolation not effective' >>"$T5_STUBS"
T5_DRIVER="$T5_DIR/driver.sh"
build_driver "$T5_DRIVER" "$T5_STUBS" codex
T5_CALL_LOG="$T5_DIR/calls.log"
"$BRIDGE_BASH" "$T5_DRIVER" "$REPO_ROOT" "$T5_STUBS" "$T5_CALL_LOG" "$T5_WORKDIR" "smoke-agent" "codex" \
  2>"$T5_DIR/err" \
  || smoke_fail "T5 driver rc=$? — see $T5_DIR/err"

T5_WRITE_COUNT="$(grep -c '^bridge_write_managed_markdown:' "$T5_CALL_LOG" || true)"
[[ "$T5_WRITE_COUNT" == "2" ]] \
  || smoke_fail "T5 expected exactly 2 bridge_write_managed_markdown calls (SKILL.md + bridge-commands ref), got $T5_WRITE_COUNT. calls: $(tr '\n' '|' <"$T5_CALL_LOG")"
grep -q '^bridge_write_managed_markdown:Codex bridge skill:.*/\.agents/skills/agent-bridge/SKILL\.md$' "$T5_CALL_LOG" \
  || smoke_fail "T5 expected SKILL.md write under 'Codex bridge skill' label at production .agents/skills/agent-bridge/ path. calls: $(tr '\n' '|' <"$T5_CALL_LOG")"
grep -q '^bridge_write_managed_markdown:bridge reference:.*/\.agents/skills/agent-bridge/references/bridge-commands\.md$' "$T5_CALL_LOG" \
  || smoke_fail "T5 expected reference write at production .agents/skills/agent-bridge/references/ path. calls: $(tr '\n' '|' <"$T5_CALL_LOG")"
if grep -q '^bridge_linux_sudo_root:' "$T5_CALL_LOG"; then
  smoke_fail "T5 expected NO bridge_linux_sudo_root call (legacy non-isolated path). calls: $(tr '\n' '|' <"$T5_CALL_LOG")"
fi
grep -q '^RC=0$' "$T5_CALL_LOG" \
  || smoke_fail "T5 expected RC=0. calls: $(tr '\n' '|' <"$T5_CALL_LOG")"
smoke_log "T5 PASS: codex + isolation not effective → bootstrap proceeds (legacy path, production .agents/skills path)"

# ---------- T6 — Codex + isolation effective + Step A PENDING → DEFER ----------
#
# Pre-Step-A the workdir is still controller-owned but the chown is
# imminent. The Codex branch DEFERs in this window so a controller-direct
# write does not race the chown. Next bridge-start fires this again post-
# Step-A and SUDO-ESCALATEs.
T6_DIR="$SMOKE_TMP_ROOT/t6"
mkdir -p "$T6_DIR"
T6_WORKDIR="$T6_DIR/workdir"
mkdir -p "$T6_WORKDIR"
T6_STUBS="$T6_DIR/stubs.sh"
printf '%s\n' '# T6 stubs — Codex + isolation EFFECTIVE + Step A PENDING.' >"$T6_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T6_STUBS"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 1; }  # Step A pending → DEFER' >>"$T6_STUBS"
T6_DRIVER="$T6_DIR/driver.sh"
build_driver "$T6_DRIVER" "$T6_STUBS" codex
T6_CALL_LOG="$T6_DIR/calls.log"
"$BRIDGE_BASH" "$T6_DRIVER" "$REPO_ROOT" "$T6_STUBS" "$T6_CALL_LOG" "$T6_WORKDIR" "smoke-agent" "codex" \
  2>"$T6_DIR/err" \
  || smoke_fail "T6 driver rc=$? — see $T6_DIR/err"

if grep -q '^bridge_write_managed_markdown:' "$T6_CALL_LOG"; then
  smoke_fail "T6 expected NO bridge_write_managed_markdown call (Codex+v2 Step-A-pending DEFER). calls: $(tr '\n' '|' <"$T6_CALL_LOG")"
fi
if grep -q '^bridge_linux_sudo_root:' "$T6_CALL_LOG"; then
  smoke_fail "T6 expected NO bridge_linux_sudo_root call (DEFER, not SUDO-ESCALATE). calls: $(tr '\n' '|' <"$T6_CALL_LOG")"
fi
grep -q '^RC=0$' "$T6_CALL_LOG" \
  || smoke_fail "T6 expected RC=0 (defer returns 0). calls: $(tr '\n' '|' <"$T6_CALL_LOG")"
smoke_log "T6 PASS: codex + isolation effective + Step A pending → DEFER (next start retries post-Step-A)"

smoke_log "all 6 tests PASS (#1155 r2 engine-aware bridge_bootstrap_project_skill: T1 claude+iso-defer, T2 claude-legacy, T3 empty-agent, T4 codex+iso sudo-escalate, T5 codex-legacy, T6 codex+iso step-A-pending defer)"
