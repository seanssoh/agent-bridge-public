#!/usr/bin/env bash
# scripts/smoke/1468-usage-429-positive-signal.sh — regression for issue #1468.
#
# #1437 follow-up: the native Anthropic OAuth usage probe (the PRIMARY proactive
# OAT-rotation path) gets HTTP 429 `rate_limit_error` from the oauth/usage
# endpoint with a long Retry-After. The shipped probe's
# DEFAULT_RETRY_AFTER_CAP_SECONDS = 5 made it bail and write NOTHING → no usage
# cache → proactive rotation never fired → the account hard-limited and only the
# reactive 429-on-cron fallback rotated, ~15–20 min late. The catch-22: the
# usage endpoint is rate-limited exactly when the account is near its limit.
#
# Fix (#1468): treat a GENUINE usage-endpoint 429 `rate_limit_error` (valid
# request, UA present) as a near-limit signal — PERSIST a near-limit usage cache
# (used_percent >= rotation threshold, reset_at from Retry-After,
# _source=native-oauth-probe) so proactive rotation fires; idempotent per
# rate-limit window (rotate at most once per token per window, never loop the
# pool); emit an audit row on probe 429/failure (was silent).
#
# Coverage:
#   PY  — scripts/smoke/1468-usage-429-positive-signal-helper.py drives every
#         scenario against the REAL run_probe + the REAL monitor with an INJECTED
#         mock HTTP seam (NO live network, MOCK tokens only): near-limit cache
#         persisted, monitor surfaces a rotation candidate, idempotence (2nd 429
#         same window = suppressed), failure-class teeth (non-rate-limit 429 /
#         empty-body 429 / 401 / network error = NO signal), reset_at stability,
#         whole-pool bound, dedupe-clear-on-clean-reading, helper classification,
#         credential safety.
#   S1  — in-source wiring: bridge-usage-probe.py treats a genuine 429
#         rate_limit_error as a near-limit signal (is_rate_limit_429 +
#         build_rate_limit_signal_cache + the per-window idempotence helpers).
#   S2  — in-source wiring: bridge-usage.sh captures the probe --json result and
#         emits a `usage_probe` audit row (bridge_usage_probe_audit).
#   S3  — in-source wiring: bridge-daemon-helpers.py exposes
#         usage-probe-result-parse classifying noteworthy outcomes.
#   E1  — end-to-end: the REAL `bridge-usage.sh probe` emits a `usage_probe`
#         audit row (observability §5) on a noteworthy outcome.
#   E2  — end-to-end: the REAL `bridge-usage.sh monitor --agents static`
#         surfaces a seeded 429-signal cache as a rotation candidate at the
#         threshold (the probe→cache→monitor→rotation flow).
#   S4  — footgun #11: no heredoc-stdin / here-string into a python3 subprocess
#         in the new bridge-usage.sh audit path.

set -euo pipefail

SMOKE_NAME="1468-usage-429-positive-signal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

PROBE="$REPO_ROOT/bridge-usage-probe.py"
USAGE_SH="$REPO_ROOT/bridge-usage.sh"
HELPERS_PY="$REPO_ROOT/bridge-daemon-helpers.py"
HELPER="$SCRIPT_DIR/1468-usage-429-positive-signal-helper.py"

failed=0
fail() {
  echo "  FAIL  $1" >&2
  failed=1
}
ok() { echo "  PASS  $1"; }

# --- PY: the mock-only python harness (the bulk of behavioral coverage) ------
echo "[PY] mock-only 429-signal scenarios (no live network)"
if python3 "$HELPER"; then
  ok "python harness: all 429-signal scenarios pass"
else
  fail "python harness: one or more 429-signal scenarios failed"
fi

# --- S1: bridge-usage-probe.py treats a genuine 429 as a near-limit signal ---
echo "[S1] bridge-usage-probe.py: genuine 429 rate_limit_error → near-limit signal"
if grep -q 'def is_rate_limit_429' "$PROBE"; then
  ok "probe classifies a genuine rate_limit_error 429 (is_rate_limit_429)"
else
  fail "probe missing is_rate_limit_429 classifier"
fi
if grep -q 'def build_rate_limit_signal_cache' "$PROBE"; then
  ok "probe builds a near-limit signal cache (build_rate_limit_signal_cache)"
else
  fail "probe missing build_rate_limit_signal_cache"
fi
if grep -q 'rate-limited-signal' "$PROBE" && grep -q 'rate-limited-suppressed' "$PROBE"; then
  ok "probe distinguishes signal vs idempotent-suppressed status"
else
  fail "probe missing rate-limited-signal / rate-limited-suppressed statuses"
fi
if grep -q 'def signal_already_emitted' "$PROBE" && grep -q 'def record_signal_emitted' "$PROBE"; then
  ok "probe has the per-window idempotence guard (signal_already_emitted / record_signal_emitted)"
else
  fail "probe missing the per-window idempotence guard"
fi
# The synthetic signal cache must carry the source marker the monitor consumes.
if grep -q 'CACHE_SOURCE' "$PROBE" && grep -q '"_signal": SIGNAL_MARKER' "$PROBE"; then
  ok "signal cache carries _source (native-oauth-probe) + a 429-signal marker"
else
  fail "signal cache does not carry the native source marker / 429-signal marker"
fi

# --- S2: bridge-usage.sh emits a usage_probe audit row -----------------------
echo "[S2] bridge-usage.sh emits a usage_probe audit row on a noteworthy probe outcome"
if grep -q 'bridge_usage_probe_audit' "$USAGE_SH"; then
  ok "bridge-usage.sh defines/calls bridge_usage_probe_audit"
else
  fail "bridge-usage.sh missing bridge_usage_probe_audit wiring"
fi
if grep -q 'usage_probe' "$USAGE_SH" && grep -q 'usage-probe-result-parse' "$USAGE_SH"; then
  ok "audit path routes through usage-probe-result-parse + emits action=usage_probe"
else
  fail "bridge-usage.sh audit path not wired to usage-probe-result-parse / usage_probe"
fi

# --- S3: bridge-daemon-helpers.py exposes the result parser ------------------
echo "[S3] bridge-daemon-helpers.py exposes usage-probe-result-parse"
if grep -q 'usage-probe-result-parse' "$HELPERS_PY" && grep -q 'def cmd_usage_probe_result_parse' "$HELPERS_PY"; then
  ok "daemon-helpers registers usage-probe-result-parse"
else
  fail "daemon-helpers missing usage-probe-result-parse subcommand"
fi

# --- E1: end-to-end audit emit through the REAL wrapper ----------------------
# Drive `bridge-usage.sh probe` OFFLINE (no token resolves → status=no-token,
# a noteworthy outcome) in a hermetic home with the admin set in the roster +
# a writable audit log; assert a `usage_probe` audit row lands. No network call
# is made (no token → the probe never reaches the HTTP layer). This exercises
# the real bridge_usage_probe_audit → usage-probe-result-parse → bridge_audit_log
# chain end-to-end (§5 observability).
echo "[E1] REAL bridge-usage.sh probe emits a usage_probe audit row (offline, no-token)"
E1_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agb-1468-e1.XXXXXX")"
mkdir -p "$E1_HOME/.agent-bridge/logs" "$E1_HOME/.agent-bridge/state"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'declare -ag BRIDGE_AGENT_IDS=("admin1")'
  printf '%s\n' 'declare -Ag BRIDGE_AGENT_ENGINE=(["admin1"]="claude")'
  printf '%s\n' 'declare -Ag BRIDGE_AGENT_SOURCE=(["admin1"]="static")'
  printf '%s\n' 'BRIDGE_ADMIN_AGENT_ID="admin1"'
} >"$E1_HOME/roster.sh"
env \
  HOME="$E1_HOME" \
  BRIDGE_HOME="$E1_HOME/.agent-bridge" \
  BRIDGE_LAYOUT="v2" \
  BRIDGE_DATA_ROOT="$E1_HOME/.agent-bridge" \
  BRIDGE_STATE_DIR="$E1_HOME/.agent-bridge/state" \
  BRIDGE_ROSTER_FILE="$E1_HOME/roster.sh" \
  BRIDGE_ROSTER_LOCAL_FILE="$E1_HOME/none-local.sh" \
  BRIDGE_AUDIT_LOG="$E1_HOME/.agent-bridge/logs/audit.jsonl" \
  BRIDGE_CLAUDE_USAGE_CACHE="$E1_HOME/.usage-cache.json" \
  BRIDGE_CLAUDE_TOKEN_REGISTRY="$E1_HOME/no-registry.json" \
  BRIDGE_USAGE_PROBE_ENABLED=1 \
  BRIDGE_USAGE_PROBE_MAX_AGE=0 \
  bash "$USAGE_SH" probe --credentials-path "$E1_HOME/no-cred.json" >/dev/null 2>&1 || true
e1_audit="$E1_HOME/.agent-bridge/logs/audit.jsonl"
if [[ -f "$e1_audit" ]] && grep -q '"action": "usage_probe"' "$e1_audit" \
   && grep -q '"source": "native-oauth-probe"' "$e1_audit"; then
  ok "real probe wrote a usage_probe audit row tagged source=native-oauth-probe"
else
  fail "real probe did NOT write a usage_probe audit row (audit=$(cat "$e1_audit" 2>/dev/null))"
fi
rm -rf "$E1_HOME"

# --- E2: end-to-end monitor surfaces a seeded 429-signal as a candidate ------
# Seed the EXACT synthetic cache the probe writes on a genuine 429 (at-limit,
# _source native-oauth-probe, _signal rate_limit_429) and drive the REAL
# `bridge-usage.sh monitor --agents static` — the probe→cache→monitor→rotation
# flow. Assert the account surfaces as a rotation candidate at a 99% threshold.
# (The probe-gets-429 behavior itself is covered by the PY harness, which injects
#  the HTTP seam; the CLI has no network-injection hook, so E2 seeds the cache.)
echo "[E2] REAL bridge-usage.sh monitor surfaces a seeded 429-signal cache as a rotation candidate"
E2_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agb-1468-e2.XXXXXX")"
mkdir -p "$E2_HOME/.agent-bridge/state/usage" "$E2_HOME/.claude/plugins/claude-hud"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'declare -ag BRIDGE_AGENT_IDS=("probeacc")'
  printf '%s\n' 'declare -Ag BRIDGE_AGENT_ENGINE=(["probeacc"]="claude")'
  printf '%s\n' 'declare -Ag BRIDGE_AGENT_SOURCE=(["probeacc"]="static")'
} >"$E2_HOME/roster.sh"
e2_cache="$E2_HOME/.claude/plugins/claude-hud/.usage-cache.json"
printf '%s' '{"data":{"planName":"subscription","fiveHour":100.0,"sevenDay":100.0,"fiveHourResetAt":"2026-06-03T18:00:00+00:00","sevenDayResetAt":"2026-06-03T18:00:00+00:00"},"_source":"native-oauth-probe","_signal":"rate_limit_429"}' >"$e2_cache"
e2_out="$(env \
  HOME="$E2_HOME" \
  BRIDGE_HOME="$E2_HOME/.agent-bridge" \
  BRIDGE_LAYOUT="v2" \
  BRIDGE_DATA_ROOT="$E2_HOME/.agent-bridge" \
  BRIDGE_STATE_DIR="$E2_HOME/.agent-bridge/state" \
  BRIDGE_USAGE_MONITOR_STATE_FILE="$E2_HOME/.agent-bridge/state/usage/monitor-state.json" \
  BRIDGE_CLAUDE_TOKEN_REGISTRY="$E2_HOME/no-registry.json" \
  BRIDGE_ROSTER_FILE="$E2_HOME/roster.sh" \
  BRIDGE_ROSTER_LOCAL_FILE="$E2_HOME/none-local.sh" \
  BRIDGE_CLAUDE_USAGE_CACHE="$e2_cache" \
  BRIDGE_USAGE_PROBE_ENABLED=1 \
  BRIDGE_USAGE_PROBE_MAX_AGE=999999 \
  BRIDGE_CLAUDE_TOKEN_ROTATION_PERCENT=99 \
  bash "$USAGE_SH" monitor --agents static --json 2>/dev/null || true)"
# Count the at-limit (100%) rotation candidates the monitor surfaced FROM the
# seeded 429-signal cache, via the real daemon-helpers parser
# (usage-rotation-candidates-parse), invoked by file path with the monitor JSON
# passed as ARGV — NOT via a heredoc / here-string into the subprocess (footgun
# #11). The parser emits one tab row per candidate:
# provider/account/window/used_percent/reset_at/source/agent/message. In the
# `--agents static` non-isolated path the `source` column is the cache file path
# (it IS the 429-signal cache), so we key on used_percent==100 + the seeded
# cache path. We loop the rows via a TEMP FILE + `while read` (no procsub /
# here-string, per the #1468 brief).
e2_rows="$(python3 "$HELPERS_PY" usage-rotation-candidates-parse "$e2_out" 2>/dev/null || true)"
e2_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-1468-e2-rows.XXXXXX")"
printf '%s\n' "$e2_rows" >"$e2_tmp"
e2_count=0
while IFS=$'\t' read -r e2_provider e2_account e2_window e2_used e2_reset e2_source e2_agent e2_msg; do
  [[ -n "$e2_provider" ]] || continue
  [[ "$e2_provider" == "claude" && "$e2_used" == "100.0" && "$e2_source" == "$e2_cache" ]] && e2_count=$((e2_count + 1))
done <"$e2_tmp"
rm -f -- "$e2_tmp"
if [[ "${e2_count:-0}" -ge 1 ]]; then
  ok "monitor surfaced the seeded 429-signal cache as a 100% rotation candidate (count=$e2_count)"
else
  fail "monitor did NOT surface the 429-signal cache as a rotation candidate (count=$e2_count rows=[$e2_rows])"
fi
rm -rf "$E2_HOME"

# --- S4: footgun #11 — no heredoc-stdin into a python3 subprocess ------------
echo "[S4] footgun #11: the new audit path invokes python3 by file path (no heredoc-stdin)"
# Build the redirect tokens at runtime (lt="<") so this scanner line itself does
# not contain the literal redirect operators the sister heredoc-ban lint matches.
lt='<'
redir_pattern="python3[^|]*${lt}${lt}|python3.*${lt}${lt}${lt}"
audit_block="$(awk '/^bridge_usage_probe_audit\(\)/{f=1} f{print} /^}/{if(f)exit}' "$USAGE_SH")"
if printf '%s\n' "$audit_block" | grep -qE "$redir_pattern"; then
  fail "bridge_usage_probe_audit uses heredoc/here-string into python3"
else
  ok "bridge_usage_probe_audit invokes python3 by file path (no heredoc-stdin)"
fi
if printf '%s\n' "$audit_block" | grep -qE 'python3[[:space:]].*bridge-daemon-helpers\.py'; then
  ok "bridge_usage_probe_audit runs bridge-daemon-helpers.py by file path"
else
  fail "bridge_usage_probe_audit does not invoke bridge-daemon-helpers.py by file path"
fi

if [[ "$failed" -ne 0 ]]; then
  echo "[smoke:${SMOKE_NAME}] FAILED"
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] PASS"
