#!/usr/bin/env bash
# Regression coverage for issue #831 — per-agent usage monitor.
#
# The daemon's process_usage_monitor used to read the controller's $HOME
# .usage-cache.json, which on an isolated install belongs to no agent. When
# two Claude agents share the same Claude plan/account, the monitor latch
# previously keyed by provider::account::window — so a 99% on agent-A could
# be masked by the same key carrying a 60% from agent-B, and rotation never
# fired. This suite verifies:
#
#   U1 Per-agent latching: agent-99% triggers rotation, agent-60% does not
#      mask it; both surface in per_agent_breakdown.
#   U2 Order independence: U1 with the iteration order swapped produces an
#      identical rotation outcome (latch is not order-dependent).
#   U3 Missing cache: an agent with no .usage-cache.json is skipped silently.
#   U4 Sudo unavailable: helper rc=2 from the wrapper degrades to skip with
#      a warn-log line on stderr, no false-rotate.
#   U5 Back-compat: legacy single-cache invocation (no --agents flag, no
#      --per-agent-cache-json) produces the same row shape as before.
#   U6 set-e safety: invoking the wrapper with `set -e` in the calling
#      script does not abort on expected non-zero rc from helper.
#   U7 Audit attribution: rotation candidate row includes the triggering
#      agent so the daemon's audit detail can record worst_case_agent.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP_HOME="$(mktemp -d -t agb-usage-monitor-test.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export BRIDGE_HOME="$TMP_HOME/.agent-bridge"
mkdir -p "$BRIDGE_HOME/state/usage"

# Fixture cache builder — one Claude usage cache shape with given plan name
# and percent for the 5h window (the rotation-relevant one).
make_cache() {
  local out="$1" plan="$2" five_h="$3" reset_at="$4"
  python3 - "$out" "$plan" "$five_h" "$reset_at" <<'PY'
import json
import sys
from pathlib import Path

out, plan, five_h, reset_at = sys.argv[1:5]
Path(out).parent.mkdir(parents=True, exist_ok=True)
payload = {
    "data": {
        "planName": plan,
        "fiveHour": float(five_h),
        "fiveHourResetAt": reset_at,
        "sevenDay": 10.0,
        "sevenDayResetAt": reset_at,
    }
}
Path(out).write_text(json.dumps(payload), encoding="utf-8")
PY
}

# Build a synthetic per-agent payload array (the on-disk shape bridge-usage.sh
# emits via bridge_usage_build_per_agent_payload). We bypass the bash wrapper
# here so the python latching logic gets exercised directly without needing a
# real isolation rig.
make_per_agent_payload() {
  local out="$1"
  shift
  # Args: agent path
  python3 - "$out" "$@" <<'PY'
import json
import sys
from pathlib import Path

out = sys.argv[1]
items = sys.argv[2:]
entries = []
for i in range(0, len(items), 2):
    agent = items[i]
    path = items[i + 1]
    parsed = None
    present = False
    p = Path(path)
    if p.is_file():
        try:
            parsed = json.loads(p.read_text(encoding="utf-8"))
            present = True
        except Exception:
            parsed = None
            present = False
    entries.append({"agent": agent, "path": path, "present": present, "payload": parsed})
Path(out).write_text(json.dumps(entries), encoding="utf-8")
PY
}

run_monitor() {
  local state="$1" per_agent="$2"; shift 2
  python3 "$ROOT_DIR/bridge-usage.py" monitor \
    --claude-usage-cache "$TMP_HOME/nonexistent-controller-cache.json" \
    --codex-sessions-dir "$TMP_HOME/nonexistent-codex-sessions" \
    --state-file "$state" \
    --rotation-threshold 99 \
    --per-agent-cache-json "$per_agent" \
    --json "$@"
}

# --- U1: agent-A=99% triggers rotation; agent-B=60% does not mask -----------
step "U1: per-agent latching surfaces 99% rotation on agent-A regardless of agent-B"
CACHE_A="$TMP_HOME/u1/agent-a/.claude/plugins/claude-hud/.usage-cache.json"
CACHE_B="$TMP_HOME/u1/agent-b/.claude/plugins/claude-hud/.usage-cache.json"
make_cache "$CACHE_A" "subscription" 99.0 "2099-01-01T00:00:00+00:00"
make_cache "$CACHE_B" "subscription" 60.0 "2099-01-01T00:00:00+00:00"
PAYLOAD_U1="$TMP_HOME/u1-payload.json"
make_per_agent_payload "$PAYLOAD_U1" "agent-a" "$CACHE_A" "agent-b" "$CACHE_B"
STATE_U1="$TMP_HOME/u1-state.json"

OUT_U1="$(run_monitor "$STATE_U1" "$PAYLOAD_U1")"
U1_AGENT="$(printf '%s' "$OUT_U1" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("worst_case_agent") or "")')"
U1_ROT_COUNT="$(printf '%s' "$OUT_U1" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(len(d.get("rotation_candidates") or []))')"
U1_BREAKDOWN_LEN="$(printf '%s' "$OUT_U1" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(len(d.get("per_agent_breakdown") or []))')"
if [[ "$U1_AGENT" == "agent-a" && "$U1_ROT_COUNT" == "1" && "$U1_BREAKDOWN_LEN" -ge 2 ]]; then
  ok
else
  err "worst_case_agent='$U1_AGENT' rot_count='$U1_ROT_COUNT' breakdown_len='$U1_BREAKDOWN_LEN' (expected agent-a / 1 / >=2)"
fi

# --- U2: swap iteration order -- same outcome -------------------------------
step "U2: per-agent latch is order-independent (swap agent order, same outcome)"
PAYLOAD_U2="$TMP_HOME/u2-payload.json"
# Build with agent-b first this time.
make_per_agent_payload "$PAYLOAD_U2" "agent-b" "$CACHE_B" "agent-a" "$CACHE_A"
STATE_U2="$TMP_HOME/u2-state.json"
OUT_U2="$(run_monitor "$STATE_U2" "$PAYLOAD_U2")"
U2_AGENT="$(printf '%s' "$OUT_U2" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("worst_case_agent") or "")')"
U2_ROT_COUNT="$(printf '%s' "$OUT_U2" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(len(d.get("rotation_candidates") or []))')"
if [[ "$U2_AGENT" == "agent-a" && "$U2_ROT_COUNT" == "1" ]]; then
  ok
else
  err "worst_case_agent='$U2_AGENT' rot_count='$U2_ROT_COUNT' (expected agent-a / 1)"
fi

# --- U3: missing cache for one agent — skipped, others continue -------------
step "U3: missing per-agent cache file is skipped without false-rotate"
CACHE_C_PRESENT="$TMP_HOME/u3/agent-c/.claude/plugins/claude-hud/.usage-cache.json"
CACHE_D_MISSING="$TMP_HOME/u3/agent-d/.claude/plugins/claude-hud/.usage-cache.json"
make_cache "$CACHE_C_PRESENT" "subscription" 50.0 "2099-01-01T00:00:00+00:00"
# Don't create CACHE_D_MISSING.
PAYLOAD_U3="$TMP_HOME/u3-payload.json"
make_per_agent_payload "$PAYLOAD_U3" "agent-c" "$CACHE_C_PRESENT" "agent-d" "$CACHE_D_MISSING"
STATE_U3="$TMP_HOME/u3-state.json"
OUT_U3="$(run_monitor "$STATE_U3" "$PAYLOAD_U3")"
U3_SNAP_AGENTS="$(printf '%s' "$OUT_U3" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(",".join(sorted({s.get("agent","") for s in d.get("snapshots",[]) if s.get("agent")})))')"
U3_ROT_COUNT="$(printf '%s' "$OUT_U3" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(len(d.get("rotation_candidates") or []))')"
if [[ "$U3_SNAP_AGENTS" == "agent-c" && "$U3_ROT_COUNT" == "0" ]]; then
  ok
else
  err "snap_agents='$U3_SNAP_AGENTS' rot_count='$U3_ROT_COUNT' (expected agent-c / 0)"
fi

# --- U4: sudo unavailable from wrapper -> agent skipped, no false rotate ----
# Exercise the bash wrapper helper bridge_usage_read_claude_cache_for_agent
# with a stub for bridge_isolation_can_sudo_to_agent returning 2.
step "U4: wrapper degrades to skip-with-warn when isolated agent has no sudo"
WRAPPER_TEST="$TMP_HOME/u4-wrapper.sh"
cat >"$WRAPPER_TEST" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$ROOT_DIR"
# Stub the isolation helpers so we don't need real sudo.
bridge_agent_linux_user_isolation_effective() { return 0; }
bridge_agent_os_user() { printf 'fake-user'; }
bridge_isolation_can_sudo_to_agent() { return 2; }
bridge_isolation_run_as_agent_user_via_bash() { return 2; }
HOME="$TMP_HOME/u4-home"
# Extract just the wrapper function.
awk '/^bridge_usage_read_claude_cache_for_agent\(\) \{/{c=1} c{print} c && /^\}\$/{c=0}' "$ROOT_DIR/bridge-usage.sh" >"$TMP_HOME/u4-extract.sh"
# shellcheck source=/dev/null
source "$TMP_HOME/u4-extract.sh"
out=\$(bridge_usage_read_claude_cache_for_agent agent-x /nonexistent/path.json 2>"$TMP_HOME/u4-stderr")
printf 'STDOUT=[%s]\n' "\$out"
printf 'STDERR='; cat "$TMP_HOME/u4-stderr"
EOF
chmod +x "$WRAPPER_TEST"
U4_OUT="$(bash "$WRAPPER_TEST")"
if printf '%s' "$U4_OUT" | grep -q "no-passwordless-sudo" && printf '%s' "$U4_OUT" | grep -q 'STDOUT=\[\]'; then
  ok
else
  err "wrapper output unexpected: $U4_OUT"
fi

# --- U5: legacy single-cache call (no --agents, no --per-agent) -------------
step "U5: legacy single-cache invocation produces snapshots from controller cache"
LEGACY_CACHE="$TMP_HOME/legacy-controller-cache.json"
make_cache "$LEGACY_CACHE" "subscription" 88.0 "2099-01-01T00:00:00+00:00"
STATE_U5="$TMP_HOME/u5-state.json"
OUT_U5="$(python3 "$ROOT_DIR/bridge-usage.py" monitor \
  --claude-usage-cache "$LEGACY_CACHE" \
  --codex-sessions-dir "$TMP_HOME/nonexistent-codex" \
  --state-file "$STATE_U5" \
  --rotation-threshold 99 \
  --json)"
U5_CLAUDE_COUNT="$(printf '%s' "$OUT_U5" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(sum(1 for s in d.get("snapshots",[]) if s.get("provider")=="claude"))')"
U5_WCA_PRESENT="$(printf '%s' "$OUT_U5" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print("worst_case_agent" in d)')"
if [[ "$U5_CLAUDE_COUNT" == "2" && "$U5_WCA_PRESENT" == "True" ]]; then
  ok
else
  err "claude_count='$U5_CLAUDE_COUNT' worst_case_agent_field='$U5_WCA_PRESENT' (expected 2 / True)"
fi

# --- U6: set-e safety on the wrapper helper ---------------------------------
step "U6: bridge_usage_read_claude_cache_for_agent under set -e does not abort"
SETE_TEST="$TMP_HOME/u6-set-e.sh"
cat >"$SETE_TEST" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Stub helpers so the function takes the sudo_rc=2 branch.
bridge_agent_linux_user_isolation_effective() { return 0; }
bridge_agent_os_user() { printf 'fake-user'; }
bridge_isolation_can_sudo_to_agent() { return 2; }
bridge_isolation_run_as_agent_user_via_bash() { return 2; }
HOME="$TMP_HOME/u6-home"
awk '/^bridge_usage_read_claude_cache_for_agent\(\) \{/{c=1} c{print} c && /^\}\$/{c=0}' "$ROOT_DIR/bridge-usage.sh" >"$TMP_HOME/u6-extract.sh"
# shellcheck source=/dev/null
source "$TMP_HOME/u6-extract.sh"
# This MUST NOT abort under set -e even though the helper internally
# captures non-zero rc from sub-calls.
bridge_usage_read_claude_cache_for_agent agent-x /nonexistent/path.json >/dev/null 2>&1
echo "survived"
EOF
chmod +x "$SETE_TEST"
U6_OUT="$(bash "$SETE_TEST" 2>&1 || printf 'ABORTED rc=%s' "$?")"
if [[ "$U6_OUT" == "survived" ]]; then
  ok
else
  err "set -e wrapper output: '$U6_OUT'"
fi

# --- U7: rotation candidate row includes worst-case agent attribution -------
step "U7: rotation candidate carries agent identity for audit attribution"
U7_AGENT_FIELD="$(printf '%s' "$OUT_U1" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); rc=d.get("rotation_candidates") or []; print(rc[0].get("agent") or rc[0].get("worst_case_agent") or "" if rc else "")')"
# Also exercise the daemon-helpers tabular extractor: the agent column must
# be column 7 (0-indexed 6) so the bash loop reads it correctly.
ROT_ROW="$(python3 "$ROOT_DIR/bridge-daemon-helpers.py" usage-rotation-candidates-parse "$OUT_U1")"
ROT_COL7="$(printf '%s' "$ROT_ROW" | awk -F'\t' '{print $7}')"
if [[ "$U7_AGENT_FIELD" == "agent-a" && "$ROT_COL7" == "agent-a" ]]; then
  ok
else
  err "agent_field='$U7_AGENT_FIELD' rot_col7='$ROT_COL7' (expected agent-a / agent-a)"
fi

# --- Summary ----------------------------------------------------------------
TOTAL=$((PASS + FAIL))
printf '\n# Issue #831 usage-monitor per-agent suite: %s/%s passed\n' "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
