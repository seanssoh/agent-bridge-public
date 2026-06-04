#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1520-shared-claude-config-dir.sh — Issue #1520.
#
# Re-exec under bash 4+ so we can `source bridge-lib.sh` directly for the
# shim-level coverage (matches scripts/smoke/1015-resume-claude-config-dir.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1520-shared-claude-config-dir][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Pins the contract that a SHARED-mode (isolation_mode: shared, non
# linux-user) Claude agent's FINAL launch exports the per-agent
# CLAUDE_CONFIG_DIR so the launched `claude` reads its own
# <agent-home>/.claude config instead of the operator's global
# ~/.claude.json.
#
# Root cause (issue #1520): the shared (non v2-secret-env) final-launch
# branch in bridge-run.sh ran `"$BRIDGE_BASH_BIN" -lc "$LAUNCH_CMD"` with
# CLAUDE_CONFIG_DIR unset. The v2-secret exec path (which DOES set it via
# launch-secrets.env) and the plugin-preflight subshell (which exports it
# only for plugin-enable) both bypassed the actual launch for shared
# agents, so the per-agent config dir the bridge pre-seeds
# (.credentials.json / settings.effective.json) was a dead read/write
# target and Claude fell back to the operator global config.
#
# The fix: bridge-run.sh's `bridge_run_shared_launch` resolves the per-agent
# Claude config root (the same value `bridge_agent_claude_config_dir`
# computes) and exports CLAUDE_CONFIG_DIR — and ONLY CLAUDE_CONFIG_DIR, NOT
# HOME — into the subshell that execs the launch, for Claude agents only.
# Codex agents take the same branch with no export.
#
# Test plan — drive the EXACT production function (extracted from
# bridge-run.sh, the same `awk`-extract-then-stub pattern
# scripts/test-resume-quarantine.sh uses). The launch command is a probe
# that echoes the env it was launched with, so we assert on the value the
# child process actually receives — no live `claude` binary required.
#
#   T1. Shared Claude agent: the launched env's CLAUDE_CONFIG_DIR is
#       non-empty AND equals bridge_agent_claude_config_dir(<agent>) =
#       <agent-home>/.claude. HOME is NOT repointed (stays the ambient
#       operator/shared home the launch inherited).
#   T2. TEETH — a copy of the function with the CLAUDE_CONFIG_DIR export
#       reverted (the pre-#1520 shape) launches with an EMPTY
#       CLAUDE_CONFIG_DIR. Proves the export is load-bearing.
#   T3. Codex shared agent: the launched env's CLAUDE_CONFIG_DIR is empty —
#       the per-agent config export is Claude-only, no regression for codex.
#   T4. The shared value matches what the iso path would set: pin that
#       bridge_run_agent_claude_root (the resolver the launch site uses)
#       equals bridge_agent_claude_config_dir for the registered agent, so
#       the launch env and the rest of the bridge agree on one config dir.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout); the
# smoke never reads or writes the operator's live `~/.claude` or bridge
# runtime. On a non-Linux host (or any host without real linux-user
# isolation) bridge_agent_linux_user_isolation_effective returns false, so
# the registered agent is genuinely shared-mode — exactly the #1520 subject.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `printf` / `cat >file <<EOF` plain-body writes and an `awk` extract — no
# command substitution feeding a heredoc-stdin, no `<<<` here-strings into
# bridge functions.

set -euo pipefail

SMOKE_NAME="1520-shared-claude-config-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd awk

smoke_setup_bridge_home "1520-shared-claude-config-dir"

REPO_ROOT="$SMOKE_REPO_ROOT"
RUN_SH="$REPO_ROOT/bridge-run.sh"
[[ -f "$RUN_SH" ]] || smoke_fail "missing bridge-run.sh: $RUN_SH"

# bridge-run.sh is NOT sourceable (it does a credential-scrub re-exec at the
# top before sourcing bridge-lib.sh), so extract just the two functions
# under test out of it — the production launch-env construction path. Same
# awk-extract pattern as scripts/test-resume-quarantine.sh.
EXTRACT="$SMOKE_TMP_ROOT/bridge-run-launch-fns.sh"
awk '
  /^bridge_run_agent_claude_root\(\) \{/ { copy = 1 }
  /^bridge_run_shared_launch\(\) \{/      { copy = 1 }
  copy { print }
  copy && /^\}$/ { copy = 0; print "" }
' "$RUN_SH" >"$EXTRACT"

grep -q '^bridge_run_shared_launch()' "$EXTRACT" \
  || smoke_fail "failed to extract bridge_run_shared_launch from bridge-run.sh"
grep -q '^bridge_run_agent_claude_root()' "$EXTRACT" \
  || smoke_fail "failed to extract bridge_run_agent_claude_root from bridge-run.sh"

# Source bridge-lib.sh for the REAL collaborators bridge_run_agent_claude_root
# leans on (bridge_isolation_disabled_by_env,
# bridge_agent_linux_user_isolation_effective, bridge_agent_default_home,
# bridge_agent_claude_config_dir, the roster maps), then layer the extracted
# launch functions on top — so the resolved value is the genuine production
# resolution, not a re-implementation.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"
# shellcheck source=/dev/null
source "$EXTRACT"

declare -F bridge_run_shared_launch >/dev/null \
  || smoke_fail "bridge_run_shared_launch not defined after sourcing extract"
declare -F bridge_run_agent_claude_root >/dev/null \
  || smoke_fail "bridge_run_agent_claude_root not defined after sourcing extract"
declare -F bridge_agent_claude_config_dir >/dev/null \
  || smoke_fail "bridge_agent_claude_config_dir not defined after sourcing bridge-lib.sh"
declare -F bridge_reset_roster_maps >/dev/null \
  || smoke_fail "bridge_reset_roster_maps not defined"

bridge_reset_roster_maps

# Register one shared-mode agent in the in-memory roster. On this host
# bridge_agent_linux_user_isolation_effective returns false (no real
# linux-user isolation), so the agent resolves to the shared / default-home
# config dir — the #1520 subject. The launch site reads $AGENT + $ENGINE
# globals, exactly as bridge-run.sh's main flow sets them.
register_agent() {
  local agent="$1" engine="$2" workdir="$3"
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="$engine"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
}

# A probe launch command: echo the launched process's CLAUDE_CONFIG_DIR onto
# a marker file, so we assert on the value the child actually inherits.
# `${CLAUDE_CONFIG_DIR-__UNSET__}` distinguishes empty-set from unset, though
# both fail the non-empty assertion identically.
MARKER="$SMOKE_TMP_ROOT/launched-config-dir.txt"
ERRFILE="$SMOKE_TMP_ROOT/launch-err.log"
: >"$ERRFILE"
probe_launch_cmd() {
  printf 'printf %%s "${CLAUDE_CONFIG_DIR-__UNSET__}" > %q' "$MARKER"
}

CLAUDE_AGENT="scd-1520"
CLAUDE_WORKDIR="$SMOKE_TMP_ROOT/claude-workdir"
mkdir -p "$CLAUDE_WORKDIR"
CLAUDE_WORKDIR="$(cd -P "$CLAUDE_WORKDIR" && pwd -P)"

# T1 — shared Claude agent: launched CLAUDE_CONFIG_DIR == per-agent dir.
test_shared_claude_exports_config_dir() {
  : >"$MARKER"
  register_agent "$CLAUDE_AGENT" claude "$CLAUDE_WORKDIR"
  AGENT="$CLAUDE_AGENT"
  ENGINE="claude"

  local expected_dir launched_dir resolver_dir
  expected_dir="$(bridge_agent_claude_config_dir "$CLAUDE_AGENT")"
  resolver_dir="$(bridge_run_agent_claude_root)"
  smoke_assert_eq "$expected_dir" "$resolver_dir" \
    "T1 bridge_run_agent_claude_root matches bridge_agent_claude_config_dir"

  bridge_run_shared_launch "$BASH" "$(probe_launch_cmd)" "$ERRFILE" \
    || smoke_fail "T1 shared launch returned non-zero"
  launched_dir="$(cat "$MARKER" 2>/dev/null || true)"

  [[ -n "$launched_dir" && "$launched_dir" != "__UNSET__" ]] \
    || smoke_fail "T1 launched CLAUDE_CONFIG_DIR is empty/unset (got '$launched_dir')"
  smoke_assert_eq "$expected_dir" "$launched_dir" \
    "T1 shared Claude launch exports the per-agent CLAUDE_CONFIG_DIR"

  # Confirm it is the v2-layout per-agent dir, not the operator global.
  smoke_assert_contains "$launched_dir" "$BRIDGE_AGENT_ROOT_V2/$CLAUDE_AGENT/home/.claude" \
    "T1 launched config dir is the per-agent <agent-home>/.claude"
}

# T2 — TEETH: revert the export in a copy of the function and prove the
# launched CLAUDE_CONFIG_DIR goes empty again (the pre-#1520 shape).
test_teeth_revert_makes_config_dir_empty() {
  : >"$MARKER"
  register_agent "$CLAUDE_AGENT" claude "$CLAUDE_WORKDIR"
  AGENT="$CLAUDE_AGENT"
  ENGINE="claude"

  # Build a reverted variant: same body, but with the per-agent export
  # stripped (mimics the bug — bare `"$bash" -lc "$cmd"` with no config dir).
  # No stderr-tee here: the probe writes to $MARKER, not stderr, so the teeth
  # variant deliberately omits the production `2> >(tee...)` procsub (also
  # keeps this fixture out of the heredoc/procsub baseline).
  bridge_run_shared_launch_REVERTED() {
    local _bash_bin="$1"
    local _launch_cmd="$2"
    "$_bash_bin" -lc "$_launch_cmd"
  }

  # Ensure the env the parent shell carries does not itself leak a value
  # into the child (the bug is "no export here", which must surface as
  # empty when the ambient env has none).
  ( unset CLAUDE_CONFIG_DIR
    bridge_run_shared_launch_REVERTED "$BASH" "$(probe_launch_cmd)" ) \
    || smoke_fail "T2 reverted launch returned non-zero"
  local launched_dir
  launched_dir="$(cat "$MARKER" 2>/dev/null || true)"
  # The probe prints `__UNSET__` when CLAUDE_CONFIG_DIR is unset, or empty
  # if set-but-empty. Either way it must NOT equal the per-agent dir.
  local expected_dir
  expected_dir="$(bridge_agent_claude_config_dir "$CLAUDE_AGENT")"
  [[ "$launched_dir" != "$expected_dir" ]] \
    || smoke_fail "T2 teeth: reverted launch still set CLAUDE_CONFIG_DIR='$launched_dir'"
  [[ -z "$launched_dir" || "$launched_dir" == "__UNSET__" ]] \
    || smoke_fail "T2 teeth: reverted launch leaked a non-empty CLAUDE_CONFIG_DIR='$launched_dir'"
}

# T3 — codex shared agent: NO CLAUDE_CONFIG_DIR export (Claude-only).
test_codex_shared_no_config_dir() {
  : >"$MARKER"
  local codex_agent="scd-1520-codex"
  register_agent "$codex_agent" codex "$CLAUDE_WORKDIR"
  AGENT="$codex_agent"
  ENGINE="codex"

  ( unset CLAUDE_CONFIG_DIR
    bridge_run_shared_launch "$BASH" "$(probe_launch_cmd)" "$ERRFILE" ) \
    || smoke_fail "T3 codex shared launch returned non-zero"
  local launched_dir
  launched_dir="$(cat "$MARKER" 2>/dev/null || true)"
  [[ -z "$launched_dir" || "$launched_dir" == "__UNSET__" ]] \
    || smoke_fail "T3 codex launch must not export CLAUDE_CONFIG_DIR (got '$launched_dir')"
}

# T4 — the launch resolver agrees with bridge_agent_claude_config_dir, the
# value every other bridge component (resume resolution, credential sync,
# first-run seeding) keys off. Re-asserted standalone so a future refactor
# of either resolver cannot silently diverge the launch env from the rest.
test_resolver_agreement() {
  register_agent "$CLAUDE_AGENT" claude "$CLAUDE_WORKDIR"
  AGENT="$CLAUDE_AGENT"
  ENGINE="claude"
  local a b
  a="$(bridge_run_agent_claude_root)"
  b="$(bridge_agent_claude_config_dir "$CLAUDE_AGENT")"
  [[ -n "$a" ]] || smoke_fail "T4 bridge_run_agent_claude_root returned empty"
  smoke_assert_eq "$b" "$a" \
    "T4 launch resolver == bridge_agent_claude_config_dir (single config-dir SSOT)"
}

smoke_run "T1 shared Claude launch exports per-agent CLAUDE_CONFIG_DIR" test_shared_claude_exports_config_dir
smoke_run "T2 teeth: reverting the export empties CLAUDE_CONFIG_DIR"     test_teeth_revert_makes_config_dir_empty
smoke_run "T3 codex shared launch sets no CLAUDE_CONFIG_DIR"            test_codex_shared_no_config_dir
smoke_run "T4 launch resolver agrees with config-dir SSOT"             test_resolver_agreement

smoke_log "all checks passed"
