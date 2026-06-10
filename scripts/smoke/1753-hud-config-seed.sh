#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1753-hud-config-seed.sh — Issue #1753.
#
# Re-exec under bash 4+ so the source-checkout shim coverage runs against
# the same shell layer as bridge-agent.sh / bridge-start.sh. macOS ships
# bash 3.2; the lib helpers (bridge_agent_*) rely on associative arrays.
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1753-hud-config-seed][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Pins the contract that the operator's per-plugin display config
# (default: claude-hud) is seeded-if-absent into a fresh Claude agent's
# `.claude/plugins/<plugin>/config.json`. Without this, a freshly
# scaffolded agent runs in its own config dir with no claude-hud config
# and renders the abbreviated HUD even when the operator enabled the full
# view in their own ~/.claude.
#
# Test plan:
#   T1. src present + dst absent -> seeded with identical content.
#   T2. dst present -> NOT overwritten (a diverged agent-local config is
#       preserved byte-for-byte).
#   T3. src absent -> no-op, no error, dst stays absent.
#   T4. non-allowlisted plugin config NOT copied (allowlist is the gate).
#   T5. engine gate: the shell shim is a no-op for a codex-flagged agent.
#   T6. shared-mode shell shim seeds end-to-end for a Claude agent (engine
#       gate -> operator-home resolve -> shared-mode copy wiring).
#   T7. path-traversal/absolute allowlist tokens are rejected (shared helper):
#       nothing written outside <config_dir>/plugins/.
#   T8. atomic no-clobber: the exclusive create (open "xb") skips an existing
#       dst (no `seeded=` line, content preserved) — not check-then-copyfile.
#   T9. iso helper rejects traversal tokens: no out-of-root path ever reaches
#       the (mocked) bridge_iso_run publish step; the safe plugin still publishes.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout) plus a
# fake operator home; the smoke never reads or writes the operator's live
# ~/.claude.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only printf /
# python3 stdin-free invocations — no command substitution feeding a
# heredoc-stdin into a bridge function, no `<<<` here-strings into bridge
# functions.

set -euo pipefail

SMOKE_NAME="1753-hud-config-seed"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
SEED_HELPER="$REPO_ROOT/scripts/python-helpers/seed-operator-plugin-config.py"

[[ -f "$SEED_HELPER" ]] || smoke_fail "missing helper: $SEED_HELPER"

# Shared fixture: a fake operator home with a claude-hud config and a
# non-allowlisted plugin config.
OP_HOME="$SMOKE_TMP_ROOT/operator-home"
mkdir -p "$OP_HOME/.claude/plugins/claude-hud"
mkdir -p "$OP_HOME/.claude/plugins/secret-plugin"
printf '{"showTools": true, "showDuration": true}\n' \
  >"$OP_HOME/.claude/plugins/claude-hud/config.json"
printf '{"apiToken": "do-not-leak"}\n' \
  >"$OP_HOME/.claude/plugins/secret-plugin/config.json"

# --- T1: src present + dst absent -> seeded with identical content -------
test_seeds_when_dst_absent() {
  local config_dir="$SMOKE_TMP_ROOT/agent-A/.claude"
  python3 "$SEED_HELPER" "$OP_HOME" "$config_dir" "claude-hud" >/dev/null
  local dst="$config_dir/plugins/claude-hud/config.json"
  smoke_assert_file_exists "$dst" \
    "T1 helper seeds claude-hud config into the agent config dir"
  if ! cmp -s "$OP_HOME/.claude/plugins/claude-hud/config.json" "$dst"; then
    smoke_fail "T1 seeded config content differs from the operator source"
  fi
  smoke_log "T1 seeded content is identical to operator source"
}

# --- T2: dst present -> NOT overwritten ---------------------------------
test_never_overwrites_existing_dst() {
  local config_dir="$SMOKE_TMP_ROOT/agent-B/.claude"
  local dst="$config_dir/plugins/claude-hud/config.json"
  mkdir -p "$config_dir/plugins/claude-hud"
  # Agent legitimately diverged to a minimal HUD.
  printf '{"showTools": false}\n' >"$dst"
  python3 "$SEED_HELPER" "$OP_HOME" "$config_dir" "claude-hud" >/dev/null
  local content
  content="$(cat "$dst")"
  smoke_assert_eq '{"showTools": false}' "$content" \
    "T2 existing agent-local config is preserved (never overwritten)"
}

# --- T3: src absent -> no-op, no error ----------------------------------
test_noop_when_src_absent() {
  local op_empty="$SMOKE_TMP_ROOT/operator-empty"
  mkdir -p "$op_empty/.claude"
  local config_dir="$SMOKE_TMP_ROOT/agent-C/.claude"
  python3 "$SEED_HELPER" "$op_empty" "$config_dir" "claude-hud" >/dev/null \
    || smoke_fail "T3 helper errored when operator source was absent"
  if [[ -e "$config_dir/plugins/claude-hud/config.json" ]]; then
    smoke_fail "T3 helper created a dst with no operator source present"
  fi
  smoke_log "T3 no-op when operator source absent (no dst, no error)"
}

# --- T4: non-allowlisted plugin config NOT copied -----------------------
test_non_allowlisted_plugin_not_copied() {
  local config_dir="$SMOKE_TMP_ROOT/agent-D/.claude"
  # Allowlist is exactly claude-hud; secret-plugin must never be touched
  # even though its operator config exists.
  python3 "$SEED_HELPER" "$OP_HOME" "$config_dir" "claude-hud" >/dev/null
  if [[ -e "$config_dir/plugins/secret-plugin/config.json" ]]; then
    smoke_fail "T4 non-allowlisted plugin config was copied (allowlist breached)"
  fi
  smoke_assert_file_exists "$config_dir/plugins/claude-hud/config.json" \
    "T4 allowlisted plugin still seeded alongside the skipped one"
}

# --- T7: path-traversal allowlist tokens are rejected (shared helper) ----
# A malicious allowlist token must never write outside the agent config dir.
# The helper must reject `../x`, `../../x`, absolute paths, and `..` exactly.
test_traversal_tokens_rejected_shared() {
  local config_dir="$SMOKE_TMP_ROOT/agent-traversal/.claude"
  mkdir -p "$config_dir"
  # Seed an operator config under each malicious "plugin name" so that, if the
  # helper followed the token, there WOULD be a src to copy — proving the
  # rejection is the gate, not a missing source.
  mkdir -p "$OP_HOME/.claude/plugins/../escape-src"
  printf '{"leaked": true}\n' >"$OP_HOME/.claude/plugins/../escape-src/config.json"

  # Tokens: parent escape, double-parent escape, absolute, and bare `..`.
  python3 "$SEED_HELPER" "$OP_HOME" "$config_dir" \
    "../escape-src, ../../secret-root, /etc/passwd-plugin, .." >/dev/null 2>&1 \
    || smoke_fail "T7 helper errored on malicious tokens (should skip, not crash)"

  # Nothing may be written outside <config_dir>/plugins/.
  if [[ -e "$config_dir/escape-src/config.json" \
        || -e "$config_dir/../escape-src/config.json" \
        || -e "$SMOKE_TMP_ROOT/agent-traversal/escape-src/config.json" \
        || -e "$SMOKE_TMP_ROOT/secret-root/config.json" ]]; then
    smoke_fail "T7 malicious token escaped the agent config dir"
  fi
  # And the plugins dir must not have gained a `..`-named or escape entry.
  if [[ -e "$config_dir/plugins/escape-src" \
        || -e "$config_dir/plugins/../escape-src" ]]; then
    smoke_fail "T7 malicious token wrote under plugins/ via traversal"
  fi
  smoke_log "T7 shared helper rejected all traversal/absolute tokens"
}

# --- T5: engine gate: shell shim is a no-op for codex agents ------------
# Source the bash lib so the shim is in scope. bridge-lib.sh transitively
# sources lib/bridge-agents.sh (where bridge_seed_operator_plugin_config
# lives) plus the rest of the runtime. Mirrors the 1073 smoke pattern.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

declare -F bridge_seed_operator_plugin_config >/dev/null \
  || smoke_fail "bridge_seed_operator_plugin_config not defined after sourcing bridge-lib.sh"
declare -F bridge_reset_roster_maps >/dev/null \
  || smoke_fail "bridge_reset_roster_maps not defined"

test_shim_noop_for_codex_agent() {
  bridge_reset_roster_maps
  local agent="codex-T5"
  local workdir="$SMOKE_TMP_ROOT/codex-T5-workdir"
  mkdir -p "$workdir"
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="codex"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""

  # Point the operator-home resolver at the fixture so a (wrongly) firing
  # shim would have a real source to copy from — making a leak detectable.
  BRIDGE_CONTROLLER_HOME="$OP_HOME"
  export BRIDGE_CONTROLLER_HOME

  bridge_seed_operator_plugin_config "$agent" "$workdir" \
    || smoke_fail "T5 shim returned non-zero for non-Claude agent"
  local config_dir
  config_dir="$(bridge_agent_claude_config_dir "$agent" 2>/dev/null || true)"
  if [[ -n "$config_dir" && -e "$config_dir/plugins/claude-hud/config.json" ]]; then
    smoke_fail "T5 shim seeded a plugin config for a codex agent: $config_dir"
  fi
  unset BRIDGE_CONTROLLER_HOME
}

# --- T6: shared-mode shell shim seeds end-to-end for a Claude agent -----
# Exercises the full shim (engine gate -> operator-home resolve -> shared-mode
# python copy), not just the helper, so the fresh-create wiring is covered.
test_shim_seeds_for_shared_claude_agent() {
  bridge_reset_roster_maps
  local agent="claude-T6"
  local workdir="$SMOKE_TMP_ROOT/claude-T6-workdir"
  mkdir -p "$workdir"
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]="$workdir"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""

  # Disable iso so the shim takes the shared-mode python copy path, and point
  # the operator-home resolver at the fixture operator home.
  BRIDGE_DISABLE_ISOLATION=1
  export BRIDGE_DISABLE_ISOLATION
  BRIDGE_CONTROLLER_HOME="$OP_HOME"
  export BRIDGE_CONTROLLER_HOME

  bridge_seed_operator_plugin_config "$agent" "$workdir" \
    || smoke_fail "T6 shim returned non-zero for a shared Claude agent"
  local config_dir
  config_dir="$(bridge_agent_claude_config_dir "$agent" 2>/dev/null || true)"
  [[ -n "$config_dir" ]] || smoke_fail "T6 could not resolve config dir"
  smoke_assert_file_exists "$config_dir/plugins/claude-hud/config.json" \
    "T6 shim seeds claude-hud config for a shared Claude agent"
  if [[ -e "$config_dir/plugins/secret-plugin/config.json" ]]; then
    smoke_fail "T6 shim copied a non-allowlisted plugin config"
  fi
  unset BRIDGE_CONTROLLER_HOME BRIDGE_DISABLE_ISOLATION
}

# --- T8: atomic no-clobber — exclusive create skips an existing dst -----
# The shared helper writes with an exclusive create (open(dst,"xb")), not a
# check-then-copyfile. When the dst exists at write time the open fails closed
# (FileExistsError) and the plugin is skipped: no `seeded=` line, and the
# pre-existing content is preserved byte-for-byte.
test_atomic_no_clobber_skips_existing() {
  local config_dir="$SMOKE_TMP_ROOT/agent-atomic/.claude"
  local dst="$config_dir/plugins/claude-hud/config.json"
  mkdir -p "$config_dir/plugins/claude-hud"
  printf '{"diverged": "keep-me"}\n' >"$dst"
  local out
  out="$(python3 "$SEED_HELPER" "$OP_HOME" "$config_dir" "claude-hud" 2>/dev/null)"
  # The exclusive-create path must NOT report a seed for an existing dst.
  if printf '%s' "$out" | grep -q "seeded=claude-hud"; then
    smoke_fail "T8 helper reported seeded= for an already-present dst (clobber risk)"
  fi
  local content
  content="$(cat "$dst")"
  smoke_assert_eq '{"diverged": "keep-me"}' "$content" \
    "T8 exclusive-create preserves an existing agent-local config byte-for-byte"
}

# --- T9: iso helper rejects traversal tokens (no out-of-root publish) ----
# Drive bridge_seed_operator_plugin_config_iso directly with a mocked
# bridge_iso_run that records every path it is asked to stat/mkdir/publish.
# A malicious allowlist token must never reach the publish step with a path
# outside <config_dir>/plugins/.
test_iso_helper_rejects_traversal() {
  declare -F bridge_seed_operator_plugin_config_iso >/dev/null \
    || smoke_fail "bridge_seed_operator_plugin_config_iso not defined"

  local config_dir="$SMOKE_TMP_ROOT/agent-iso-traversal/.claude"
  mkdir -p "$config_dir"
  # Operator src that a followed-token WOULD copy, to prove rejection is the gate.
  mkdir -p "$OP_HOME/.claude/plugins/../iso-escape-src"
  printf '{"leaked": true}\n' >"$OP_HOME/.claude/plugins/../iso-escape-src/config.json"

  local iso_paths_log="$SMOKE_TMP_ROOT/iso-paths.log"
  : >"$iso_paths_log"
  # Mock: record the --path of every op; never touch the filesystem. Return 30
  # (absent) for stat so the helper would proceed to publish IF the token
  # passed validation — making any leak observable in the log.
  # shellcheck disable=SC2329  # invoked indirectly by the iso helper under test
  bridge_iso_run() {
    local _path="" _op="" _prev=""
    for _arg in "$@"; do
      case "$_prev" in
        --path) _path="$_arg" ;;
        --op) _op="$_arg" ;;
      esac
      _prev="$_arg"
    done
    printf '%s\t%s\n' "$_op" "$_path" >>"$iso_paths_log"
    [[ "$_op" == "stat" ]] && return 30
    return 0
  }

  bridge_seed_operator_plugin_config_iso "iso-agent-T9" "$OP_HOME" "$config_dir" \
    "../iso-escape-src, ../../secret-root, /abs-plugin, .., claude-hud" \
    || smoke_fail "T9 iso helper returned non-zero"

  # Every recorded path must stay under <config_dir>/plugins/.
  local bad
  bad="$(awk -F'\t' -v root="$config_dir/plugins/" 'NF==2 && $2!="" && index($2, root)!=1 {print}' "$iso_paths_log")"
  if [[ -n "$bad" ]]; then
    smoke_fail "T9 iso helper passed an out-of-root path to bridge_iso_run: $bad"
  fi
  # The safe token claude-hud should still have produced a publish under root.
  if ! grep -q "publish-root-file	$config_dir/plugins/claude-hud/config.json" "$iso_paths_log"; then
    smoke_fail "T9 iso helper did not publish the safe allowlisted plugin"
  fi
  unset -f bridge_iso_run
  smoke_log "T9 iso helper rejected traversal tokens; only safe plugin published"
}

smoke_run "T1 helper seeds when dst absent"                  test_seeds_when_dst_absent
smoke_run "T2 helper never overwrites existing dst"          test_never_overwrites_existing_dst
smoke_run "T3 helper no-op when operator source absent"      test_noop_when_src_absent
smoke_run "T4 non-allowlisted plugin config not copied"      test_non_allowlisted_plugin_not_copied
smoke_run "T7 shared helper rejects traversal tokens"        test_traversal_tokens_rejected_shared
smoke_run "T8 atomic exclusive-create skips existing dst"    test_atomic_no_clobber_skips_existing
smoke_run "T5 shim no-op for non-Claude (codex) agent"       test_shim_noop_for_codex_agent
smoke_run "T6 shim seeds for shared-mode Claude agent"       test_shim_seeds_for_shared_claude_agent
smoke_run "T9 iso helper rejects traversal tokens"           test_iso_helper_rejects_traversal

smoke_log "all checks passed"
