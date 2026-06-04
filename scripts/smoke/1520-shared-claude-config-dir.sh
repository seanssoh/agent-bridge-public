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
  /^bridge_run_agent_claude_root\(\) \{/              { copy = 1 }
  /^bridge_run_ensure_shared_claude_credential\(\) \{/ { copy = 1 }
  /^bridge_run_shared_launch\(\) \{/                  { copy = 1 }
  copy { print }
  copy && /^\}$/ { copy = 0; print "" }
' "$RUN_SH" >"$EXTRACT"

grep -q '^bridge_run_shared_launch()' "$EXTRACT" \
  || smoke_fail "failed to extract bridge_run_shared_launch from bridge-run.sh"
grep -q '^bridge_run_agent_claude_root()' "$EXTRACT" \
  || smoke_fail "failed to extract bridge_run_agent_claude_root from bridge-run.sh"
grep -q '^bridge_run_ensure_shared_claude_credential()' "$EXTRACT" \
  || smoke_fail "failed to extract bridge_run_ensure_shared_claude_credential from bridge-run.sh"

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
declare -F bridge_run_ensure_shared_claude_credential >/dev/null \
  || smoke_fail "bridge_run_ensure_shared_claude_credential not defined after sourcing extract"
declare -F bridge_agent_claude_config_dir >/dev/null \
  || smoke_fail "bridge_agent_claude_config_dir not defined after sourcing bridge-lib.sh"
declare -F bridge_reset_roster_maps >/dev/null \
  || smoke_fail "bridge_reset_roster_maps not defined"

# Test seam for the credential seed (r2). bridge_run_ensure_shared_claude_-
# credential seeds a missing per-agent credential by calling
# `bridge_with_timeout ... bridge-auth.sh claude-token sync --agents <agent>`.
# In an isolated BRIDGE_HOME there is no token registry / controller
# credential, so the real subprocess would always no-op — we could never
# exercise the "seed succeeds -> export fires" branch. Override
# bridge_with_timeout to simulate the seed outcome the daemon's real sync
# would produce: when SEED_SHOULD_SUCCEED=1, write a fake credential file
# into the agent's per-agent .claude dir (exactly where the real writer puts
# it); when 0, no-op (models "operator never authed / no resolvable cred").
# Every other bridge_with_timeout caller is unaffected — we only special-case
# the shared_claude_credential_seed label, delegating all else to a passthru.
SEED_SHOULD_SUCCEED=0
SEED_CALLED=0
bridge_with_timeout() {
  local _secs="$1" _label="$2"
  if [[ "$_label" == "shared_claude_credential_seed" ]]; then
    SEED_CALLED=1
    if [[ "$SEED_SHOULD_SUCCEED" == "1" && -n "${SEED_TARGET_CRED:-}" ]]; then
      mkdir -p "$(dirname "$SEED_TARGET_CRED")"
      printf '{"claudeAiOauth":{"accessToken":"smoke-fixture-token"}}\n' \
        >"$SEED_TARGET_CRED"
      chmod 0600 "$SEED_TARGET_CRED" 2>/dev/null || true
    fi
    return 0
  fi
  shift 2
  "$@"
}

# Keep keychain-free auth OFF for the standard-credential tests (the isolated
# home has no runtime config; force the env override to be explicit/stable).
export BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=0

bridge_reset_roster_maps

# Register one shared-mode agent in the in-memory roster. On this host
# bridge_agent_linux_user_isolation_effective returns false (no real
# linux-user isolation), so the agent resolves to the shared / default-home
# config dir — the #1520 subject. The launch site reads $AGENT + $ENGINE
# globals, exactly as bridge-run.sh's main flow sets them.
register_agent() {
  local agent="$1" engine="$2" workdir="$3" source="${4:-static}"
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="$engine"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="$source"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
}

# Write a per-agent credential file into <agent>/home/.claude — models what
# the daemon's `claude-token sync` already does for static agents (and what
# the r2 seed-at-launch does for dynamic agents).
seed_agent_credential() {
  local cred_dir="$1"
  mkdir -p "$cred_dir"
  printf '{"claudeAiOauth":{"accessToken":"smoke-fixture-token"}}\n' \
    >"$cred_dir/.credentials.json"
  chmod 0600 "$cred_dir/.credentials.json" 2>/dev/null || true
}

# Remove any per-agent credential so a test starts from the "not yet seeded"
# state (the shared DYNAMIC agent's reality before the r2 seed-at-launch).
clear_agent_credential() {
  rm -f "$1/.credentials.json" 2>/dev/null || true
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

# T1 — shared STATIC Claude agent with its per-agent credential already
# seeded (the daemon's static-scope sync covers static agents): launched
# CLAUDE_CONFIG_DIR == per-agent dir, and no seed-at-launch is needed.
test_shared_claude_exports_config_dir() {
  : >"$MARKER"
  SEED_SHOULD_SUCCEED=0; SEED_CALLED=0
  register_agent "$CLAUDE_AGENT" claude "$CLAUDE_WORKDIR" static
  AGENT="$CLAUDE_AGENT"
  ENGINE="claude"

  local expected_dir launched_dir resolver_dir
  expected_dir="$(bridge_agent_claude_config_dir "$CLAUDE_AGENT")"
  resolver_dir="$(bridge_run_agent_claude_root)"
  smoke_assert_eq "$expected_dir" "$resolver_dir" \
    "T1 bridge_run_agent_claude_root matches bridge_agent_claude_config_dir"

  # Static reality: credential already present in the per-agent dir.
  seed_agent_credential "$expected_dir"

  bridge_run_shared_launch "$BASH" "$(probe_launch_cmd)" "$ERRFILE" \
    || smoke_fail "T1 shared launch returned non-zero"
  launched_dir="$(cat "$MARKER" 2>/dev/null || true)"

  [[ -n "$launched_dir" && "$launched_dir" != "__UNSET__" ]] \
    || smoke_fail "T1 launched CLAUDE_CONFIG_DIR is empty/unset (got '$launched_dir')"
  smoke_assert_eq "$expected_dir" "$launched_dir" \
    "T1 shared Claude launch exports the per-agent CLAUDE_CONFIG_DIR"
  smoke_assert_eq "0" "$SEED_CALLED" \
    "T1 already-seeded static agent does not trigger a seed-at-launch"

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

# T5 — shared DYNAMIC Claude agent (codex Phase-4 r2 BLOCKING): no per-agent
# credential to start with (daemon static-scope sync skips dynamic agents),
# so the launch must seed it on demand, then export. After the launch:
#   - CLAUDE_CONFIG_DIR == per-agent dir (per-agent config isolation applies),
#   - the per-agent credential file is PRESENT (auth not broken).
# This is the exact regression the export would otherwise cause for a
# previously operator-global-authed dynamic agent.
DYN_AGENT="scd-1520-dyn"
DYN_WORKDIR="$SMOKE_TMP_ROOT/dyn-workdir"
mkdir -p "$DYN_WORKDIR"
DYN_WORKDIR="$(cd -P "$DYN_WORKDIR" && pwd -P)"
test_shared_dynamic_seeds_then_exports() {
  : >"$MARKER"
  register_agent "$DYN_AGENT" claude "$DYN_WORKDIR" dynamic
  AGENT="$DYN_AGENT"
  ENGINE="claude"

  local expected_dir
  expected_dir="$(bridge_agent_claude_config_dir "$DYN_AGENT")"
  clear_agent_credential "$expected_dir"
  [[ ! -f "$expected_dir/.credentials.json" ]] \
    || smoke_fail "T5 precondition: dynamic agent should start without a credential"

  # Simulate the daemon's real sync succeeding for this on-demand seed.
  SEED_SHOULD_SUCCEED=1
  SEED_CALLED=0
  SEED_TARGET_CRED="$expected_dir/.credentials.json"

  bridge_run_shared_launch "$BASH" "$(probe_launch_cmd)" "$ERRFILE" \
    || smoke_fail "T5 dynamic shared launch returned non-zero"

  smoke_assert_eq "1" "$SEED_CALLED" \
    "T5 missing credential triggers an on-demand seed-at-launch"
  smoke_assert_file_exists "$expected_dir/.credentials.json" \
    "T5 per-agent credential is present after the seed (auth not broken)"

  local launched_dir
  launched_dir="$(cat "$MARKER" 2>/dev/null || true)"
  smoke_assert_eq "$expected_dir" "$launched_dir" \
    "T5 dynamic launch exports CLAUDE_CONFIG_DIR == per-agent dir after seeding"

  unset SEED_TARGET_CRED
  SEED_SHOULD_SUCCEED=0
}

# T6 — graceful degrade (codex r2): a shared Claude agent whose per-agent dir
# has NO credential AND the seed cannot produce one (operator never authed)
# must NOT be exported onto an empty dir — the launch falls back to the
# operator-global config (CLAUDE_CONFIG_DIR unset), exactly the pre-#1520
# behavior the agent was previously relying on. Never strand it authless.
test_degrade_when_seed_fails() {
  : >"$MARKER"
  register_agent "$DYN_AGENT" claude "$DYN_WORKDIR" dynamic
  AGENT="$DYN_AGENT"
  ENGINE="claude"

  local expected_dir
  expected_dir="$(bridge_agent_claude_config_dir "$DYN_AGENT")"
  clear_agent_credential "$expected_dir"

  # Seed cannot produce a credential (models no resolvable controller cred).
  SEED_SHOULD_SUCCEED=0
  SEED_CALLED=0
  SEED_TARGET_CRED="$expected_dir/.credentials.json"

  # Unset in the parent scope (not a subshell) so the override's SEED_CALLED
  # write is observable here; the launch helper does its own subshell for the
  # child env, so the parent's unset only affects what the export-skip path
  # would otherwise inherit.
  unset CLAUDE_CONFIG_DIR
  bridge_run_shared_launch "$BASH" "$(probe_launch_cmd)" "$ERRFILE" \
    || smoke_fail "T6 degrade launch returned non-zero"

  smoke_assert_eq "1" "$SEED_CALLED" \
    "T6 missing credential attempts a seed"
  local launched_dir
  launched_dir="$(cat "$MARKER" 2>/dev/null || true)"
  [[ -z "$launched_dir" || "$launched_dir" == "__UNSET__" ]] \
    || smoke_fail "T6 degrade: unseedable agent must NOT export CLAUDE_CONFIG_DIR (got '$launched_dir')"

  unset SEED_TARGET_CRED
}

# T7 — keychain-free auth: the per-agent dir authenticates via the
# apiKeyHelper wired into settings.json, so a missing `.credentials.json` is
# expected and must NOT block the export (and must not attempt a token-sync
# seed). The export is safe; the keychain-free preflight validated settings.
test_keychain_free_exports_without_credential_file() {
  : >"$MARKER"
  register_agent "$CLAUDE_AGENT" claude "$CLAUDE_WORKDIR" static
  AGENT="$CLAUDE_AGENT"
  ENGINE="claude"
  local expected_dir
  expected_dir="$(bridge_agent_claude_config_dir "$CLAUDE_AGENT")"
  clear_agent_credential "$expected_dir"

  SEED_CALLED=0
  BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    bridge_run_shared_launch "$BASH" "$(probe_launch_cmd)" "$ERRFILE" \
    || smoke_fail "T7 keychain-free launch returned non-zero"

  smoke_assert_eq "0" "$SEED_CALLED" \
    "T7 keychain-free path does not attempt a credential seed"
  local launched_dir
  launched_dir="$(cat "$MARKER" 2>/dev/null || true)"
  smoke_assert_eq "$expected_dir" "$launched_dir" \
    "T7 keychain-free exports CLAUDE_CONFIG_DIR despite no credential file"
}

smoke_run "T1 shared STATIC Claude launch exports per-agent CLAUDE_CONFIG_DIR" test_shared_claude_exports_config_dir
smoke_run "T2 teeth: reverting the export empties CLAUDE_CONFIG_DIR"           test_teeth_revert_makes_config_dir_empty
smoke_run "T3 codex shared launch sets no CLAUDE_CONFIG_DIR"                   test_codex_shared_no_config_dir
smoke_run "T4 launch resolver agrees with config-dir SSOT"                    test_resolver_agreement
smoke_run "T5 shared DYNAMIC seeds credential then exports (auth not broken)"  test_shared_dynamic_seeds_then_exports
smoke_run "T6 degrade: unseedable agent skips the export (no auth break)"      test_degrade_when_seed_fails
smoke_run "T7 keychain-free exports without a credential file"                 test_keychain_free_exports_without_credential_file

smoke_log "all checks passed"
