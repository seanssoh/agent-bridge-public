#!/usr/bin/env bash
# scripts/smoke/17927-p2-statusline-usage-feed.sh — #17927 P2 (Option C)
# daemon-core: statusLine usage feed → preemptive claude-token rotation.
#
# Three contracts (all exercised in an isolated BRIDGE_HOME; no live network,
# no live ~/.agent-bridge, mock caches only):
#
#   E5  — bridge_usage_resolve_claude_cache_path resolves the daemon-READ path
#         to the SAME per-agent CLAUDE_CONFIG_DIR cache the launch path WRITES,
#         so a non-isolated per-agent Claude session is no longer read at the
#         controller $HOME (the root-cause bug). Iso branch unchanged;
#         dynamic-vanilla / unregistered preserve the $HOME fallback.
#
#   E6/E8 — rotation eligibility is gated BEFORE the candidate is emitted /
#         latched: a monitored-but-non-managed agent crossing threshold drives
#         an ALERT only, never a rotation/latch/sync. (helper, behavioral)
#
#   E10 — `_written_at` staleness-guard (a stale cache is "no signal", never 0%)
#         + rotation-path audit (preemptive vs reactive) + the daemon wiring
#         that threads both down. (helper + in-source wiring guards)

set -euo pipefail

SMOKE_NAME="17927-p2-statusline-usage-feed"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

USAGE_SH="$REPO_ROOT/bridge-usage.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
HELPER="$SCRIPT_DIR/17927-p2-statusline-usage-feed-helper.py"

# Isolated runtime root — never touch the live ~/.agent-bridge.
BRIDGE_HOME="$(mktemp -d)/bridge-home"
export BRIDGE_HOME
mkdir -p "$BRIDGE_HOME"

echo "[smoke:${SMOKE_NAME}] starting (BRIDGE_HOME=$BRIDGE_HOME)"

failed=0
ok() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; failed=1; }

CACHE_SUFFIX="plugins/claude-hud/.usage-cache.json"

# ---------------------------------------------------------------------------
# E5 — resolver path-match. Extract the REAL function body from bridge-usage.sh
# and eval it with stubbed dependencies so we exercise the shipped resolver
# (not a copy) across the three launch modes. Uses the same awk-extract-a-bash-
# function pattern as scripts/smoke/1468-usage-429-positive-signal.sh.
# ---------------------------------------------------------------------------
echo "[E5] resolver path == launch CLAUDE_CONFIG_DIR cache path (3 modes + \$HOME fallback)"

RESOLVER_SRC="$(awk '/^bridge_usage_resolve_claude_cache_path\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$USAGE_SH")"
if [[ -z "$RESOLVER_SRC" ]]; then
  fail "E5: could not extract bridge_usage_resolve_claude_cache_path from bridge-usage.sh"
else
  ok "E5: extracted the real resolver body from bridge-usage.sh"
fi

# Mode A — static / shared per-agent (non-iso): config-dir resolver returns the
# agent's own <agent-home>/.claude → cache path lives THERE, not at $HOME.
mode_static="$(
  set +e
  HOME="/controller-home"
  bridge_agent_linux_user_isolation_effective() { return 1; }
  bridge_resolve_agent_claude_config_dir() { printf '/srv/agents/lib/.claude'; }
  eval "$RESOLVER_SRC"
  bridge_usage_resolve_claude_cache_path lib
)"
[[ "$mode_static" == "/srv/agents/lib/.claude/$CACHE_SUFFIX" ]] \
  && ok "E5 mode=static/shared per-agent → $mode_static" \
  || fail "E5 mode=static expected /srv/agents/lib/.claude/$CACHE_SUFFIX got '$mode_static'"

# Mode B — linux-user isolated: iso branch returns FIRST, unchanged. The
# config-dir resolver is poisoned to prove the iso branch never consults it.
mode_iso="$(
  set +e
  HOME="/controller-home"
  bridge_agent_linux_user_isolation_effective() { return 0; }
  bridge_agent_os_user() { printf 'agent-bridge-lib'; }
  bridge_agent_linux_user_home() { printf '/home/agent-bridge-lib'; }
  bridge_resolve_agent_claude_config_dir() { printf '/POISON/should-not-be-used'; }
  eval "$RESOLVER_SRC"
  bridge_usage_resolve_claude_cache_path lib
)"
[[ "$mode_iso" == "/home/agent-bridge-lib/.claude/$CACHE_SUFFIX" ]] \
  && ok "E5 mode=linux-user-isolated → $mode_iso (iso branch unchanged)" \
  || fail "E5 mode=iso expected /home/agent-bridge-lib/.claude/$CACHE_SUFFIX got '$mode_iso'"

# Mode C — dynamic-vanilla / unregistered: config-dir resolver returns empty →
# controller $HOME fallback PRESERVED.
mode_home="$(
  set +e
  HOME="/controller-home"
  bridge_agent_linux_user_isolation_effective() { return 1; }
  bridge_resolve_agent_claude_config_dir() { printf ''; }
  eval "$RESOLVER_SRC"
  bridge_usage_resolve_claude_cache_path vanilla-dyn
)"
[[ "$mode_home" == "/controller-home/.claude/$CACHE_SUFFIX" ]] \
  && ok "E5 mode=dynamic-vanilla/unregistered → \$HOME fallback ($mode_home)" \
  || fail "E5 mode=fallback expected /controller-home/.claude/$CACHE_SUFFIX got '$mode_home'"

# ---------------------------------------------------------------------------
# E6/E8 + E10 — behavioral, via the real bridge-usage.py monitor subprocess.
# ---------------------------------------------------------------------------
echo "[E6/E8 + E10] rotation eligibility gate + staleness-guard + rotation-path audit"
if python3 "$HELPER"; then
  ok "behavioral helper: all E6/E8 + E10 scenarios pass"
else
  fail "behavioral helper: one or more E6/E8 + E10 scenarios failed"
fi

# ---------------------------------------------------------------------------
# Daemon / usage wiring guards (in-source) — the daemon-core threads the new
# scope + audit field end-to-end.
# ---------------------------------------------------------------------------
echo "[wiring] daemon-core threads rotation scope + rotation_trigger end-to-end"

# bridge-usage.sh forwards the resolved eligible set to the python monitor.
grep -q -- '--rotation-eligible-agents' "$USAGE_SH" \
  && ok "wiring: bridge-usage.sh forwards --rotation-eligible-agents to the monitor" \
  || fail "wiring: bridge-usage.sh does not forward --rotation-eligible-agents"

# The daemon scopes rotation to the managed pool and passes it to the monitor.
grep -q 'BRIDGE_USAGE_ROTATION_AGENTS' "$DAEMON_SH" \
  && grep -q -- 'monitor --json --agents .* --rotation-agents' "$DAEMON_SH" \
  && ok "wiring: process_usage_monitor passes --rotation-agents (managed pool) to the monitor" \
  || fail "wiring: process_usage_monitor does not pass --rotation-agents"

# The daemon reads rotation_trigger and records it on the rotation audit row.
grep -q 'worst_case_agent rotation_trigger body' "$DAEMON_SH" \
  && grep -q 'rotation_trigger="\${rotation_trigger:-preemptive}"' "$DAEMON_SH" \
  && ok "wiring: claude_token_rotation audit records rotation_trigger (Obs#2)" \
  || fail "wiring: daemon does not record rotation_trigger on the audit row"

# ---------------------------------------------------------------------------
# Daemon contract round-trip — the candidates parser → bash sentinel-decode the
# daemon performs must surface the cache reset_at (for --limited-until) and the
# rotation_trigger intact even when an earlier column (agent) is empty. This is
# the exact decode the daemon's process_usage_monitor read loop applies.
# ---------------------------------------------------------------------------
echo "[contract] reset_at + rotation_trigger survive the parse → sentinel-decode round-trip"
RESET="2026-07-01T00:00:00+00:00"
MONITOR_JSON="$(printf '{"rotation_candidates":[{"provider":"claude","account":"subscription","window":"weekly","used_percent":96,"reset_at":"%s","source":"native-oauth-probe","rotation_trigger":"preemptive","message":"m"}]}' "$RESET")"
ROW="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" usage-rotation-candidates-parse "$MONITOR_JSON")"
dec_reset=""; dec_trigger=""
# #17927 P2 (codex r2): read the parsed row from a temp file rather than a
# here-string, which lint-heredoc-ban flags as an H3 non-interpreter site.
ROW_FILE="$(mktemp)"
printf '%s\n' "$ROW" >"$ROW_FILE"
while IFS=$'\t' read -r d_provider d_account d_window d_used d_reset d_source d_agent d_trigger d_body; do
  [[ "$d_reset" == "-" ]] && d_reset=""
  [[ "$d_trigger" == "-" ]] && d_trigger=""
  dec_reset="$d_reset"; dec_trigger="$d_trigger"
done <"$ROW_FILE"
rm -f "$ROW_FILE"
[[ "$dec_reset" == "$RESET" && "$dec_trigger" == "preemptive" ]] \
  && ok "contract: decoded reset_at='$dec_reset' trigger='$dec_trigger' (limited-until + audit intact)" \
  || fail "contract: expected reset_at='$RESET'/preemptive, got reset='$dec_reset' trigger='$dec_trigger'"

if [[ "$failed" -ne 0 ]]; then
  echo "[smoke:${SMOKE_NAME}] FAIL" >&2
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] PASS"
