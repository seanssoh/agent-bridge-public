#!/usr/bin/env bash
# codex-hooks-propagate.sh — re-render Codex hooks for every codex-engine
# static agent during an upgrade run. Invoked by bridge-upgrade.sh via
# bridge_upgrade_with_target_env so it runs inside the target runtime env.
#
# Invocation contract:
#   $1 = source_root  (the agent-bridge source checkout)
#   $2 = target_root  (the live install root being upgraded)
#
# Output: one line per agent indicating the hook render result.
#
# Footgun #11: this body lives as a standalone file so bridge-upgrade.sh can
# invoke it with file-as-argv — no heredoc-stdin / here-string anywhere on
# this path. Follows the same pattern as lib/upgrade-helpers/isolation-v2-migrate.sh.
#
# Issue #1067 (S08): static Codex agents previously had no Codex hook render
# step on upgrade — only Claude agents were covered by
# bridge_upgrade_propagate_claude_hooks. This helper closes the gap by
# iterating every codex-engine agent and calling `bridge-hooks.py
# ensure-codex-hooks` with the descriptor-owned per-agent hook config path
# (`<agent_home>/.codex/hooks.json`), not the legacy shared `$HOME/.codex/hooks.json`.
# shellcheck shell=bash
set -euo pipefail

source_root="$1"
target_root="$2"

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"
bridge_load_roster

python_bin="$(command -v python3 || printf '/usr/bin/python3')"

for agent in "${BRIDGE_AGENT_IDS[@]}"; do
  [[ "$(bridge_agent_engine "$agent" 2>/dev/null || printf '')" == "codex" ]] || continue
  # Resolve the per-agent identity home (layer 2: the authored identity source).
  # bridge_layout_agent_home wraps bridge_agent_default_home — on a v2 install
  # this is $BRIDGE_AGENT_ROOT_V2/<agent>/home; on legacy it is
  # $BRIDGE_AGENT_HOME_ROOT/<agent>.
  agent_home=""
  if declare -F bridge_layout_agent_home >/dev/null 2>&1; then
    agent_home="$(bridge_layout_agent_home "$agent" 2>/dev/null || printf '')"
  else
    agent_home="$(bridge_agent_default_home "$agent" 2>/dev/null || printf '')"
  fi
  [[ -n "$agent_home" ]] || continue

  # Descriptor-owned hook config path: <agent_home>/.codex/hooks.json
  hook_config_path=""
  if declare -F bridge_engine_hook_config_path >/dev/null 2>&1; then
    hook_config_path="$(bridge_engine_hook_config_path "$agent" codex 2>/dev/null || printf '')"
  else
    hook_config_path="$agent_home/.codex/hooks.json"
  fi
  [[ -n "$hook_config_path" ]] || continue

  mkdir -p "$(dirname "$hook_config_path")" 2>/dev/null || continue
  rc=0
  "$python_bin" "$source_root/bridge-hooks.py" ensure-codex-hooks \
    --codex-hooks-file "$hook_config_path" \
    --bridge-home "$target_root" \
    --python-bin "$python_bin" \
    >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    # Issue #2007: pre-trust the bridge's own first-party hooks in the sibling
    # config.toml so the hook-changing upgrade (e.g. v0.16.12->v0.16.15 expanded
    # the suite) does not wedge this codex agent at the trust gate on the next
    # restart. STRICT first-party boundary + fail-closed inside bridge-hooks.py;
    # non-fatal here so a pretrust hiccup never fails the upgrade run (the
    # detector still surfaces any prompt).
    trust_rc=0
    # Suppress only the shell-parseable STDOUT fields; let STDERR flow so the
    # helper's fail-closed warn line reaches the upgrade log (the detector
    # relies on that signal, not the exit code alone — codex review #2007 r1,
    # Finding 3). Still non-fatal: pretrust never fails the upgrade run.
    "$python_bin" "$source_root/bridge-hooks.py" ensure-codex-hook-trust \
      --codex-hooks-file "$hook_config_path" \
      --codex-config-file "$(dirname "$hook_config_path")/config.toml" \
      --bridge-home "$target_root" \
      --python-bin "$python_bin" \
      >/dev/null || trust_rc=$?
    if [[ $trust_rc -eq 0 ]]; then
      printf 'codex-hooks-propagate: agent=%s hook_config=%s status=ok pretrust=ok\n' "$agent" "$hook_config_path"
    else
      printf 'codex-hooks-propagate: agent=%s hook_config=%s status=ok pretrust=skipped(rc=%d)\n' "$agent" "$hook_config_path" "$trust_rc"
    fi
  else
    printf 'codex-hooks-propagate: agent=%s hook_config=%s status=error(rc=%d)\n' "$agent" "$hook_config_path" "$rc" >&2
  fi
done
