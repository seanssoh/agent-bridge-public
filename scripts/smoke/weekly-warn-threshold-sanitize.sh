#!/usr/bin/env bash
# Regression smoke for #1725 — weekly-warn / rotation threshold fail-safe.
#
# A malformed BRIDGE_CLAUDE_WEEKLY_WARN_PERCENT (or the 5h rotation env) must
# never reach the Python monitor's argparse float: an invalid value there exits
# the whole `usage monitor` run before any snapshot, which would suppress the
# valid 5h hard-threshold rotation candidate too (the #1725 review blocker).
# bridge-usage.sh sanitizes both thresholds to their safe default at the single
# chokepoint before invoking Python; this proves that, plus the Python contract
# that makes the sanitize necessary.

set -euo pipefail

SMOKE_NAME="weekly-warn-threshold-sanitize"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd awk
smoke_setup_bridge_home "$SMOKE_NAME"

# --- Unit: the sanitize helper extracted from bridge-usage.sh ----------------
FN_FILE="$SMOKE_TMP_ROOT/usage-sanitize-fn.sh"
python3 "$SMOKE_REPO_ROOT/scripts/smoke/helpers/extract-shell-fn.py" \
  "$SMOKE_REPO_ROOT/bridge-usage.sh" \
  _bridge_usage_sanitize_percent \
  >"$FN_FILE"
# shellcheck source=/dev/null
source "$FN_FILE"

smoke_log "U1: valid values pass through unchanged"
smoke_assert_eq "$(_bridge_usage_sanitize_percent 95 95)" "95" "U1 valid int passthrough"
smoke_assert_eq "$(_bridge_usage_sanitize_percent 95.5 95)" "95.5" "U1 valid float passthrough"

smoke_log "U2: a malformed weekly value falls back to the default (the #1725 bug)"
smoke_assert_eq "$(_bridge_usage_sanitize_percent not-a-number 95)" "95" "U2 non-numeric -> weekly default"

smoke_log "U3: out-of-range values fall back (mirrors the registry 0<v<=100 check)"
smoke_assert_eq "$(_bridge_usage_sanitize_percent 150 95)" "95" "U3 >100 -> default"
smoke_assert_eq "$(_bridge_usage_sanitize_percent 0 95)" "95" "U3 0 -> default"
smoke_assert_eq "$(_bridge_usage_sanitize_percent '' 95)" "95" "U3 empty -> default"

smoke_log "U4: a bad weekly value does not disturb the independent 5h default"
smoke_assert_eq "$(_bridge_usage_sanitize_percent not-a-number 99)" "99" "U4 5h fallback independent of weekly"

# --- Contract + end-to-end: the Python monitor the sanitize protects ---------
CACHE="$SMOKE_TMP_ROOT/usage-cache.json"
# Static 99% 5h-window cache. Written with printf (not a python here-document
# piped to a subprocess) to keep the lint-heredoc-ban baseline ratchet flat
# (Bash 5.3.9 read_comsub deadlock surface — footgun #11).
printf '%s\n' \
  '{"data":{"planName":"account-a","fiveHour":99.9,"fiveHourResetAt":"2026-06-09T20:00:00+00:00","sevenDay":10.0,"sevenDayResetAt":"2026-06-15T00:00:00+00:00"}}' \
  >"$CACHE"

run_monitor() {  # $1 = --weekly-warn-threshold value, $2 = state file
  python3 "$SMOKE_REPO_ROOT/bridge-usage.py" monitor \
    --claude-usage-cache "$CACHE" \
    --codex-sessions-dir "$SMOKE_TMP_ROOT/nonexistent-codex" \
    --state-file "$2" \
    --rotation-threshold 99 \
    --weekly-warn-threshold "$1" \
    --json
}

smoke_log "C1: a RAW malformed weekly value crashes the monitor (why the sanitize exists)"
if run_monitor not-a-number "$SMOKE_TMP_ROOT/state-bad.json" >/dev/null 2>&1; then
  smoke_fail "C1 monitor should exit non-zero on a malformed --weekly-warn-threshold (raw)"
fi

smoke_log "C2: the sanitized default still emits the 5h rotation candidate"
OUT="$(run_monitor 95 "$SMOKE_TMP_ROOT/state-ok.json")"
HAS_5H="$(printf '%s' "$OUT" | python3 -c 'import sys, json; d = json.loads(sys.stdin.read()); print(any(c.get("window") == "5h" for c in d.get("rotation_candidates", [])))')"
smoke_assert_eq "$HAS_5H" "True" "C2 5h rotation candidate emitted with the safe weekly default"

smoke_log "ok"
