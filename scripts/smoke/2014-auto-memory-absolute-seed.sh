#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2014-auto-memory-absolute-seed.sh — #2014 absolute auto-memory seed.
#
# Pins the #2014 invariant: bridge_ensure_auto_memory_isolation() seeds an
# ABSOLUTE, fully-resolved autoMemoryDirectory (no leading "~") so the Claude
# CLI has nothing to mis-expand. The tilde form was resolved inconsistently
# per session ($HOME vs CLAUDE_CONFIG_DIR-parent), splitting one agent's
# auto-memory across two trees on a ~20-agent install.
#
# Cases (all in an isolated BRIDGE_HOME — never touches live runtime; reuses
# scripts/smoke/lib.sh). The function is driven via a per-case bash driver
# that sources bridge-agent.sh (the dispatcher's empty-subcommand path just
# prints usage and returns) with BRIDGE_CONTROLLER_HOME pinned so the
# shared-mode resolver returns the operator home, then calls
# bridge_ensure_auto_memory_isolation directly:
#
#   T1. No file        → seed is created, ABSOLUTE (no leading "~"),
#                        rooted at the operator home + the bridge slug.
#   T2. Legacy "~/..." → the bridge's own prior tilde seed is UPGRADED in
#                        place to the absolute form (not refused).
#   T3. User-customized → a genuinely different operator value is PRESERVED
#                        (fail-closed; non-zero exit, value untouched).
#   T4. Valid JSON, no key → the key is upserted with the absolute value,
#                        unrelated keys preserved.
#   T5. Idempotent     → a second run over the absolute value is a no-op
#                        (exit 0, byte-identical file).
#   T6. Create-time iso-v2 → passing the REAL create-time positionals
#                        (isolation_mode=linux-user + os_user) with the
#                        roster NOT populated for the agent roots the seed
#                        under the iso UID home via the new
#                        bridge_agent_linux_user_home branch — NOT the
#                        operator home the roster-driven resolver would
#                        return at create time (#2014 regression guard).
#   T7. Non-string value → a truthy non-string autoMemoryDirectory
#                        (number/bool/list/object) fail-closes cleanly
#                        instead of raising on the str-only `.startswith`
#                        inside _same_absolute_target; value preserved.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:2014-auto-memory-absolute-seed][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="2014-auto-memory-absolute-seed"
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
OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
mkdir -p "$OPERATOR_HOME"

BRIDGE_BASH="${BRIDGE_SMOKE_BASH:-bash}"
if [[ -x /opt/homebrew/bin/bash ]]; then
  BRIDGE_BASH=/opt/homebrew/bin/bash
elif [[ -x /usr/local/bin/bash ]]; then
  BRIDGE_BASH=/usr/local/bin/bash
fi

# Pin the iso UID home root under the temp tree so the create-time iso branch
# (bridge_agent_linux_user_home → $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>)
# resolves to a verifiable path on macOS without a real iso UID. The os_user
# convention is `agent-bridge-<agent>`.
ISO_ROOT="$SMOKE_TMP_ROOT/iso-root"
ISO_OS_USER="agent-bridge-tester"
mkdir -p "$ISO_ROOT/$ISO_OS_USER"

EXPECTED_SLUG="$(python3 - "$BRIDGE_HOME" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]).replace(os.sep, "-").replace(".", "-"))
PY
)"
EXPECTED_ABS="$OPERATOR_HOME/.claude/auto-memory/$EXPECTED_SLUG/tester"
EXPECTED_ISO_ABS="$ISO_ROOT/$ISO_OS_USER/.claude/auto-memory/$EXPECTED_SLUG/tester"
# Intentionally the LITERAL legacy tilde form the bridge used to seed — it
# must stay unexpanded so the upgrade-in-place path (T2) sees the exact
# "~/..." string the fix recognises as upgradeable.
# shellcheck disable=SC2088
LEGACY_TILDE="~/.claude/auto-memory/$EXPECTED_SLUG/tester"

# Per-case driver. Sources bridge-agent.sh (empty-subcommand → usage, which
# returns) then calls bridge_ensure_auto_memory_isolation for agent "tester"
# against $WORKDIR. The optional 2nd/3rd args are the CREATE-TIME isolation
# context (isolation_mode, os_user) — the real positional args the create flow
# threads (#2014), exercising bridge_agent_linux_user_home directly rather than
# stubbing the resolver. Operator home is pinned via BRIDGE_CONTROLLER_HOME so
# shared-mode resolution is deterministic + offline; the iso UID home root is
# pinned via BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT.
run_seed() {
  local workdir="$1"
  local iso_mode="${2:-}"
  local iso_os_user="${3:-}"
  local rc=0
  BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  HOME="$OPERATOR_HOME" \
  BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$ISO_ROOT" \
  _SMOKE_REPO_ROOT="$REPO_ROOT" \
  _SMOKE_WORKDIR="$workdir" \
  _SMOKE_ISO_MODE="$iso_mode" \
  _SMOKE_ISO_OS_USER="$iso_os_user" \
  "$BRIDGE_BASH" -c '
    set -euo pipefail
    set -- ""    # empty subcommand → dispatcher prints usage and returns
    source "${_SMOKE_REPO_ROOT}/bridge-agent.sh" >/dev/null 2>&1
    bridge_ensure_auto_memory_isolation tester "${_SMOKE_WORKDIR}" \
      "${_SMOKE_ISO_MODE}" "${_SMOKE_ISO_OS_USER}"
  ' || rc=$?
  return "$rc"
}

read_seed() {
  python3 - "$1" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("autoMemoryDirectory", "<MISSING>"))
except Exception as exc:  # noqa: BLE001
    print(f"<ERR:{exc}>")
PY
}

# --- T1: no file → absolute seed created ------------------------------------
WT1="$SMOKE_TMP_ROOT/wt1"
mkdir -p "$WT1/.claude"
run_seed "$WT1" || smoke_fail "T1: seed returned non-zero on fresh workdir"
S1="$WT1/.claude/settings.local.json"
smoke_assert_file_exists "$S1" "T1: settings.local.json not created"
V1="$(read_seed "$S1")"
smoke_assert_eq "$V1" "$EXPECTED_ABS" "T1: seeded value is not the absolute operator-home path"
case "$V1" in
  "~"*) smoke_fail "T1: seeded value still starts with '~' ($V1)";;
esac
smoke_log "T1 OK — fresh seed is absolute: $V1"

# --- T2: legacy "~/..." form → upgraded in place ----------------------------
WT2="$SMOKE_TMP_ROOT/wt2"
mkdir -p "$WT2/.claude"
S2="$WT2/.claude/settings.local.json"
printf '{\n  "autoMemoryDirectory": "%s"\n}\n' "$LEGACY_TILDE" >"$S2"
run_seed "$WT2" || smoke_fail "T2: seed refused to upgrade the legacy tilde form (non-zero exit)"
V2="$(read_seed "$S2")"
smoke_assert_eq "$V2" "$EXPECTED_ABS" "T2: legacy tilde was not upgraded in place to the absolute form"
case "$V2" in
  "~"*) smoke_fail "T2: value still tilde-prefixed after upgrade ($V2)";;
esac
smoke_log "T2 OK — legacy tilde upgraded in place: $V2"

# --- T3: user-customized value → preserved (fail-closed) --------------------
WT3="$SMOKE_TMP_ROOT/wt3"
mkdir -p "$WT3/.claude"
S3="$WT3/.claude/settings.local.json"
CUSTOM="$SMOKE_TMP_ROOT/operator-chosen/auto-memory/tester"
printf '{\n  "autoMemoryDirectory": "%s"\n}\n' "$CUSTOM" >"$S3"
T3_RC=0
run_seed "$WT3" || T3_RC=$?
[[ "$T3_RC" -ne 0 ]] || smoke_fail "T3: seed silently overwrote a user-customized value (expected fail-closed non-zero)"
V3="$(read_seed "$S3")"
smoke_assert_eq "$V3" "$CUSTOM" "T3: user-customized autoMemoryDirectory was clobbered"
smoke_log "T3 OK — user-customized value preserved (rc=$T3_RC): $V3"

# --- T4: valid JSON without the key → upsert, unrelated keys preserved -------
WT4="$SMOKE_TMP_ROOT/wt4"
mkdir -p "$WT4/.claude"
S4="$WT4/.claude/settings.local.json"
printf '{\n  "permissions": { "defaultMode": "acceptEdits" }\n}\n' >"$S4"
run_seed "$WT4" || smoke_fail "T4: seed returned non-zero upserting into key-less JSON"
V4="$(read_seed "$S4")"
smoke_assert_eq "$V4" "$EXPECTED_ABS" "T4: absolute value not upserted into existing JSON"
python3 - "$S4" <<'PY' || smoke_fail "T4: unrelated key 'permissions' was dropped on upsert"
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(0 if data.get("permissions", {}).get("defaultMode") == "acceptEdits" else 1)
PY
smoke_log "T4 OK — absolute upsert preserved unrelated keys: $V4"

# --- T5: idempotent re-run over the absolute value → no-op ------------------
BEFORE5="$(cat "$S1")"
run_seed "$WT1" || smoke_fail "T5: idempotent re-run returned non-zero"
AFTER5="$(cat "$S1")"
[[ "$BEFORE5" == "$AFTER5" ]] || smoke_fail "T5: re-run over an absolute seed mutated the file (not idempotent)"
smoke_log "T5 OK — re-run over absolute value is a byte-identical no-op"

# --- T6: create-time iso-v2 context → seed roots under the iso UID home -----
# Drives the REAL create-time path: pass isolation_mode=linux-user + the
# os_user as positionals (exactly what run_create threads at #2014), with the
# roster NOT populated for this agent — so the only way the seed lands under
# the iso UID home is the new bridge_agent_linux_user_home create-time branch
# (NOT a stubbed resolver). Regression guard: if that branch were dropped, the
# resolver would fall through to bridge_agent_claude_home_dir → operator home.
WT6="$SMOKE_TMP_ROOT/wt6"
mkdir -p "$WT6/.claude"
run_seed "$WT6" "linux-user" "$ISO_OS_USER" || smoke_fail "T6: create-time iso seed returned non-zero"
S6="$WT6/.claude/settings.local.json"
V6="$(read_seed "$S6")"
smoke_assert_eq "$V6" "$EXPECTED_ISO_ABS" "T6: create-time iso-v2 seed did not root under the iso UID home"
case "$V6" in
  "$OPERATOR_HOME"/*) smoke_fail "T6: create-time iso-v2 seed leaked into the operator home ($V6) — the create-time iso branch was bypassed";;
  "~"*) smoke_fail "T6: create-time iso-v2 seed still tilde-prefixed ($V6)";;
esac
smoke_log "T6 OK — create-time iso context roots the seed under the iso UID home: $V6"

# --- T7: non-string autoMemoryDirectory → fail-closed, not a crash -----------
# A truthy non-string value (number/bool/list/object an operator set by hand)
# must reach the existing fail-closed refusal — NOT raise on the str-only
# `.startswith` inside _same_absolute_target. Exercises every non-string shape.
for _bad in '123' 'true' '["/x"]' '{"path": "/x"}'; do
  WT7="$SMOKE_TMP_ROOT/wt7"
  rm -rf "$WT7"; mkdir -p "$WT7/.claude"
  S7="$WT7/.claude/settings.local.json"
  printf '{\n  "autoMemoryDirectory": %s\n}\n' "$_bad" >"$S7"
  T7_RC=0
  run_seed "$WT7" || T7_RC=$?
  [[ "$T7_RC" -ne 0 ]] || smoke_fail "T7: non-string autoMemoryDirectory ($_bad) was not refused (rc=0)"
  # The malformed value must be left untouched (no partial/crashed write).
  python3 - "$S7" "$_bad" <<'PY' || smoke_fail "T7: non-string value ($_bad) was mutated instead of preserved"
import json, sys
data = json.load(open(sys.argv[1]))
expected = json.loads(sys.argv[2])
sys.exit(0 if data.get("autoMemoryDirectory") == expected else 1)
PY
  smoke_log "T7 OK — non-string value ($_bad) fail-closed + preserved (rc=$T7_RC)"
done

smoke_log "PASS — #2014 auto-memory absolute-seed invariants hold"
