#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1881-channel-enable-live-mcp-readiness.sh — Issue #1881.
#
# Three coupled defects on `setup <channel>` plugin enable:
#   (A) `setup <channel>` left enabledPlugins.<spec>=false with NO operator
#       guidance that a bridge-native restart is the one remaining step that
#       materializes the engine-level enable + live MCP. The operator saw
#       "Claude plugin ready" and reasonably assumed nothing else was needed.
#   (B) Reaching for `/plugin enable` inside the session dies SymlinkWriteRefused
#       because the project .claude/settings.json is a symlink to
#       settings.effective.json and Claude Code refuses the write. The restart
#       hint must steer the operator AWAY from `/plugin enable` toward the
#       bridge-native restart (which runs `claude plugin enable --scope user`
#       under the correct config dir).
#   (C) After a manual (non bridge-native) restart, the FILE-level checks
#       (restart_readiness / plugin_enabled / channel_setup_complete) can all
#       read "ready" while the live tmux session has ZERO MCP tools connected.
#       `agent show <a> --json` now carries a `live_mcp_status` runtime-state
#       field (derived from bridge_agent_live_mcp_status, a thin classifier over
#       the existing MCP-descendant liveness scan) so consumers can tell
#       "config says enabled" from "MCP actually connected".
#
# Test plan (DEV-HOST-TESTABLE surfaces only — no live tmux / no MCP server):
#   T1. (A/B) bridge_setup_print_restart_hint emits operator guidance that
#       names the exact bridge-native `agent restart <a>` step (defect-A) AND
#       steers away from `/plugin enable` with the SymlinkWriteRefused reason
#       (defect-B route-away).
#   T2. (C) bridge_agent_session_health_json (the `agent show --json`
#       session_health path) includes a `live_mcp_status` key, and for a claude
#       agent with NO probeable channel plugin configured the value is
#       `not-applicable` (a graceful "nothing to probe" verdict, NOT a crash),
#       with the `live_mcp_disconnected_channels` list correctly ABSENT.
#
# DEFERRED TO A LIVE HOST / CI: the actual connected/disconnected verdict needs
# a running tmux session with a live MCP server (a bun MCP descendant under the
# pane pid). That path is exercised by 1844-plugin-liveness-probe + a live
# manual check in an isolated BRIDGE_HOME — this smoke deliberately does NOT
# stand up a live MCP server, so it only asserts the not-applicable branch +
# field presence here.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; never touches the
# operator's live runtime.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses no heredoc-stdin
# to an interpreter (`python3 - <<PY` / `bash -s <<EOF`) and no `<<<`
# here-strings into bridge functions — JSON is parsed with `python3 -c` (a `-c`
# string arg, not a heredoc), so it adds no new lint-heredoc-baseline sites.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (macOS ships /bin/bash 3.2).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1881-channel-enable-live-mcp-readiness] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1881-channel-enable-live-mcp-readiness"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1881-channel-enable-live-mcp-readiness"

REPO_ROOT="$SMOKE_REPO_ROOT"

# bridge-lib.sh supplies bridge_agent_session_health_json +
# bridge_agent_live_mcp_status (the (C) surfaces). The (A/B) restart-hint
# helper lives in the bridge-setup.sh entrypoint (it sources bridge-lib.sh
# itself), so source that too. Clear positionals first so bridge-setup.sh's
# top-level subcommand dispatch hits the no-op `usage` branch instead of trying
# to run a setup verb at source time.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"
set --
# shellcheck source=bridge-setup.sh disable=SC1091
source "$REPO_ROOT/bridge-setup.sh" >/dev/null 2>&1

for fn in \
  bridge_setup_print_restart_hint \
  bridge_agent_session_health_json \
  bridge_agent_live_mcp_status \
  bridge_reset_roster_maps; do
  if ! declare -F "$fn" >/dev/null; then
    smoke_fail "$fn not defined after sourcing bridge-lib.sh + bridge-setup.sh"
  fi
done

bridge_reset_roster_maps

# T1 — (A/B) the restart hint names the bridge-native restart AND routes the
# operator away from /plugin enable (with the SymlinkWriteRefused reason).
test_restart_hint_and_route_away() {
  bridge_reset_roster_maps
  local agent="t1881-a"
  local hint=""

  # bridge_info logs to STDERR (it is a logger, not a return-channel producer),
  # so capture both streams.
  hint="$(bridge_setup_print_restart_hint "$agent" 2>&1)"

  # Defect-A: the ONE remaining step is named explicitly.
  smoke_assert_contains "$hint" "agent restart $agent" \
    "T1 (A) restart hint names the bridge-native 'agent restart <agent>' step"

  # Defect-B: route the operator AWAY from /plugin enable, with the reason.
  smoke_assert_contains "$hint" "Do NOT use /plugin enable" \
    "T1 (B) restart hint steers the operator away from /plugin enable"
  smoke_assert_contains "$hint" "SymlinkWriteRefused" \
    "T1 (B) restart hint names the SymlinkWriteRefused reason for the route-away"
}

# T2 — (C) the agent-show session-health JSON carries live_mcp_status, and a
# claude agent with no probeable channel plugin reports not-applicable (no
# crash), with the disconnected-channel list ABSENT.
test_live_mcp_status_field_not_applicable() {
  bridge_reset_roster_maps
  smoke_require_cmd python3
  local agent="t1881-c"

  # Minimal in-memory registration: a claude agent with NO channels. The live
  # MCP classifier gates on engine==claude AND >=1 probeable channel; with none
  # configured there is nothing to probe, so the correct verdict is
  # not-applicable (a misleading "connected"/"disconnected" would be the bug).
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_ENGINE["$agent"]="claude"

  # Direct helper verdict first — proves the classifier returns the graceful
  # word rather than aborting on a no-channel agent.
  local direct=""
  direct="$(bridge_agent_live_mcp_status "$agent")"
  smoke_assert_eq "not-applicable" "$direct" \
    "T2 (C) bridge_agent_live_mcp_status is not-applicable for a no-channel claude agent (no crash)"

  # Now the JSON surface the `agent show --json` path emits. Parse with
  # `python3 -c` (no heredoc) so the assertions are robust to formatting and
  # the fixture adds no heredoc-baseline site.
  local json=""
  json="$(bridge_agent_session_health_json "$agent")"

  smoke_assert_eq "True" \
    "$(python3 -c 'import json,sys; print("live_mcp_status" in json.loads(sys.argv[1]))' "$json")" \
    "T2 (C) session-health JSON includes the live_mcp_status key"

  smoke_assert_eq "not-applicable" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("live_mcp_status"))' "$json")" \
    "T2 (C) live_mcp_status is not-applicable for a no-channel claude agent"

  # The disconnected list is only emitted when the live session is actually
  # missing tools — for not-applicable it must be absent (its presence IS the
  # "manual restart left MCP dead" signal).
  smoke_assert_eq "False" \
    "$(python3 -c 'import json,sys; print("live_mcp_disconnected_channels" in json.loads(sys.argv[1]))' "$json")" \
    "T2 (C) live_mcp_disconnected_channels is absent when status is not-applicable"
}

smoke_run "T1 restart hint names restart + routes away from /plugin enable (#1881 A/B)" test_restart_hint_and_route_away
smoke_run "T2 live_mcp_status field present + not-applicable for no-channel agent (#1881 C)" test_live_mcp_status_field_not_applicable

smoke_log "all checks passed"
