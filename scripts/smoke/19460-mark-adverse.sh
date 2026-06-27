#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/19460-mark-adverse.sh — #19460 Fix 1 PR-A: the deterministic
# `claude-token mark-adverse` registry primitive (no network probe).
#
# Proves the active-dead recovery primitive stamps a real observed failure onto
# the token row so the cascade (`rotation_candidate_availability`) skips a
# known-dead token BEFORE the next selection — the M4 fleet-down root shape
# (rotation re-picking a dead token / blind nudge). Pure registry/JSON work in an
# isolated BRIDGE_HOME; NEVER touches the real ~/.agent-bridge and makes NO
# network call (benign non-credential token strings only).
#
# Cases:
#   T1 quota_limited + reset -> token DISABLED, limited_until/disabled_until/
#      next_check_at == reset, last_check_status=quota_limited            (mark-quota parity)
#   T2 auth_failed            -> token STAYS ENABLED (no permanent disable),
#      last_check_status=auth_failed + last_checked_at + bounded next_check_at,
#      source recorded                                                    (gap 1 auth shape)
#   T3 stale fingerprint      -> mismatch SKIPS the write (token_replaced), row
#      untouched                                                          (fp guard)
#   T4 no fingerprint         -> applies (guard only fires when fp supplied)
#   T5 cascade skip           -> a rotate from t1 SKIPS an auth_failed-fresh t2
#      and selects the available t3                                       (selection integration)

set -uo pipefail

SMOKE_NAME="19460-mark-adverse"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing bridge-auth.py: $AUTH_PY"
[[ -f "$AUTH_SH" ]] || smoke_fail "missing bridge-auth.sh: $AUTH_SH"

REGISTRY="$SMOKE_TMP_ROOT/registry.json"
# Benign, non-credential token strings (validate_token wants len>=20, no
# whitespace/quotes). A FUTURE reset window keeps the quota block "active".
FUTURE="2999-01-01T00:00:00+00:00"

seed() {
  python3 - "$REGISTRY" <<'PY'
import json, sys
reg = {
    "version": 1,
    "active_token_id": "t1",
    "auto_rotate_enabled": True,
    "rotation_threshold": 99.0,
    "weekly_warn_threshold": 95.0,
    "tokens": [
        {"id": "t1", "token": "ZZZmarkadv-tok1-aaaaaaaaaaaa", "enabled": True},
        {"id": "t2", "token": "ZZZmarkadv-tok2-bbbbbbbbbbbb", "enabled": True},
        {"id": "t3", "token": "ZZZmarkadv-tok3-cccccccccccc", "enabled": True},
    ],
    "last_rotation": {},
}
json.dump(reg, open(sys.argv[1], "w"))
PY
}

# reg_field <id> <field>  — print a token row field ('' if absent)
reg_field() {
  python3 - "$REGISTRY" "$1" "$2" <<'PY'
import json, sys
reg = json.load(open(sys.argv[1]))
row = next((t for t in reg["tokens"] if t["id"] == sys.argv[2]), {})
v = row.get(sys.argv[3], "")
print("true" if v is True else "false" if v is False else v)
PY
}
reg_active() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['active_token_id'])" "$REGISTRY"; }
out_field() { python3 -c "import json,sys;print(json.load(sys.stdin).get(sys.argv[1],''))" "$1"; }
run_py() { python3 "$AUTH_PY" --registry "$REGISTRY" "$@"; }

# ── T1 ────────────────────────────────────────────────────────────────
test_quota_disables_and_windows() {
  seed
  local out
  out="$(run_py mark-adverse t2 --status quota_limited --reset-at "$FUTURE" --source usage:weekly --json)"
  smoke_assert_eq "quota_limited" "$(printf '%s' "$out" | out_field status)" "T1 status=quota_limited"
  smoke_assert_eq "false" "$(reg_field t2 enabled)" "T1 quota token DISABLED"
  smoke_assert_eq "quota_limited" "$(reg_field t2 last_check_status)" "T1 last_check_status=quota_limited"
  smoke_assert_eq "$FUTURE" "$(reg_field t2 disabled_until)" "T1 disabled_until==reset"
  smoke_assert_eq "$FUTURE" "$(reg_field t2 limited_until)" "T1 limited_until==reset (#1789 window)"
  smoke_assert_eq "$FUTURE" "$(reg_field t2 next_check_at)" "T1 next_check_at==reset"
}

# ── T2 ────────────────────────────────────────────────────────────────
test_auth_failed_no_permanent_disable() {
  seed
  local out
  out="$(run_py mark-adverse t3 --status auth_failed --api-error-status 401 --source nudge --json)"
  smoke_assert_eq "auth_failed" "$(printf '%s' "$out" | out_field status)" "T2 status=auth_failed"
  smoke_assert_eq "true" "$(reg_field t3 enabled)" "T2 auth_failed token STAYS ENABLED (no permanent disable)"
  smoke_assert_eq "auth_failed" "$(reg_field t3 last_check_status)" "T2 last_check_status=auth_failed"
  smoke_assert_eq "401" "$(reg_field t3 last_check_api_error_status)" "T2 api_error_status recorded"
  smoke_assert_eq "nudge" "$(reg_field t3 last_check_source)" "T2 source recorded"
  [[ -n "$(reg_field t3 last_checked_at)" ]] || smoke_fail "T2 last_checked_at must be stamped (cascade freshness)"
  [[ -n "$(reg_field t3 next_check_at)" ]] || smoke_fail "T2 bounded next_check_at must be scheduled"
  [[ -z "$(reg_field t3 disabled_until)" ]] || smoke_fail "T2 auth_failed must NOT stamp a disable window"
}

# ── T3 ────────────────────────────────────────────────────────────────
test_stale_fingerprint_skips() {
  seed
  local out
  out="$(run_py mark-adverse t2 --status quota_limited --reset-at "$FUTURE" --fingerprint deadbeefwrongfp --json)"
  smoke_assert_eq "skipped" "$(printf '%s' "$out" | out_field status)" "T3 status=skipped on fp mismatch"
  smoke_assert_eq "token_replaced" "$(printf '%s' "$out" | out_field reason)" "T3 reason=token_replaced"
  smoke_assert_eq "true" "$(reg_field t2 enabled)" "T3 row UNTOUCHED on stale fingerprint (still enabled)"
  smoke_assert_eq "" "$(reg_field t2 last_check_status)" "T3 no adverse stamp written on stale fingerprint"
}

# ── T4 ────────────────────────────────────────────────────────────────
test_no_fingerprint_applies() {
  seed
  run_py mark-adverse t2 --status auth_failed --json >/dev/null
  smoke_assert_eq "auth_failed" "$(reg_field t2 last_check_status)" "T4 applies when no --fingerprint supplied (guard opt-in)"
}

# ── T5 ────────────────────────────────────────────────────────────────
test_cascade_skips_marked() {
  seed
  # t2 is the next ring candidate after t1; mark it auth_failed-fresh so the
  # cascade must skip it and select the still-available t3.
  run_py mark-adverse t2 --status auth_failed --json >/dev/null
  local out
  out="$(run_py rotate --json)"
  smoke_assert_eq "rotated" "$(printf '%s' "$out" | out_field status)" "T5 rotate succeeds"
  smoke_assert_eq "t3" "$(printf '%s' "$out" | out_field active_token_id)" \
    "T5 cascade SKIPS the auth_failed-fresh t2 and selects the available t3"
  smoke_assert_eq "t3" "$(reg_active)" "T5 registry active advanced to t3"
}

# ── T6 ────────────────────────────────────────────────────────────────
# The daemon + auth automation call `bridge-auth.sh claude-token ...`, never
# bridge-auth.py directly, so the wrapper MUST route mark-adverse or PR-B (the
# daemon active-dead recovery) fails at runtime. Prove the bash->python plumbing
# reaches the new handler end to end (the python-direct cases above cannot).
test_wrapper_plumbing() {
  seed
  local out
  out="$(BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" bash "$AUTH_SH" claude-token mark-adverse t2 --status auth_failed --source nudge --json)"
  smoke_assert_eq "auth_failed" "$(printf '%s' "$out" | out_field status)" \
    "T6 wrapper: bash bridge-auth.sh -> python mark-adverse reaches the handler"
  smoke_assert_eq "auth_failed" "$(reg_field t2 last_check_status)" \
    "T6 wrapper: the registry row was actually stamped through the wrapper"
  smoke_assert_eq "true" "$(reg_field t2 enabled)" "T6 wrapper: auth_failed still no permanent disable"
}

smoke_run "T1 quota_limited -> disabled + reset windows (mark-quota parity)"       test_quota_disables_and_windows
smoke_run "T2 auth_failed -> stays enabled, adverse-stamp only (no disable)"        test_auth_failed_no_permanent_disable
smoke_run "T3 stale fingerprint -> SKIP write (token_replaced), row untouched"      test_stale_fingerprint_skips
smoke_run "T4 no fingerprint -> applies (guard fires only when fp supplied)"        test_no_fingerprint_applies
smoke_run "T5 cascade skips an auth_failed-fresh candidate, selects available"      test_cascade_skips_marked
smoke_run "T6 wrapper routes mark-adverse (bash->python handler reached)"           test_wrapper_plumbing

smoke_log "all checks passed"
