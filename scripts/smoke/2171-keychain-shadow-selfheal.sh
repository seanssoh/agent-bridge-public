#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2171-keychain-shadow-selfheal.sh — Issue #2171 (incident
# #19460 M4 fleet-down) PR-D.
#
# Pins the Claude Code keychain-shadow self-heal contract for bridge-auth.py's
# `reconcile-keychain` verb.
#
# Root cause (confirmed on sean-m4, Claude Code v2.1.195): Claude Code stores its
# OAuth credential in the login keychain under a HASHED service name
# ("Claude Code-credentials-<hash>") alongside / instead of the base
# "Claude Code-credentials". When that keychain entry's token DIVERGES from the
# agent's active pool token it SHADOWS the per-agent .credentials.json — the
# session authenticates with the stale keychain token (a personal "Claude Max"
# subscription that hit a weekly limit → 429) even though .credentials.json holds
# the correct rotating pool token. The base-only `find-generic-password -s
# 'Claude Code-credentials'` MISSES the hashed variant, so reconcile must
# FULL-ENUMERATE via `dump-keychain`.
#
# Safety: the real login keychain is NEVER touched. A mock `security` binary
# (scripts/smoke/2171-keychain-shadow-selfheal-mock-security.py) is injected via
# the BRIDGE_SECURITY_BIN seam; it reads/writes only files under $MOCK_KC_DIR.
#
# Test plan — drive the production bridge-auth.py verb directly in an isolated
# BRIDGE_HOME, with BRIDGE_HOST_PLATFORM_OVERRIDE driving the Darwin/non-Darwin
# branches and the mock keychain driving the match/stale fixtures:
#
#   T1. Matching fingerprint — the base entry holds the active pool token:
#       status clean, no stale, deletes 0, rc 0.
#   T2. Hashed-variant stale shadow — default FAIL-CLOSED: shadow_detected,
#       deletes NOTHING, rc 3 (the health signal). This is the M4 case.
#   T3. Base + hashed BOTH present — both are enumerated (base-only is
#       insufficient); only the divergent hashed entry is flagged stale.
#   T4. --apply (operator-approved cleanup) — deletes ONLY the stale hashed
#       entry (mock deleted.log records exactly that service); the matching base
#       entry is untouched; status cleaned, rc 0.
#   T5. Non-Darwin no-op — status skipped_non_darwin, rc 0, security(1) is never
#       invoked (the guard short-circuits before any keychain call).
#   T6. Raw-token guard — the diagnostic prints FINGERPRINTS only; neither the
#       active pool token nor the shadow token appears in the JSON output.
#   T7. Bash wrapper path — `bridge-auth.sh claude-token reconcile-keychain`
#       passes --registry + --apply through to bridge-auth.py, and an unknown
#       flag fails closed (rc 2) before any keychain call.
#   T8. --expected-credentials — a per-agent .credentials.json is the EXPECTED
#       fingerprint source; an entry matching it is clean even when the registry
#       active token differs.
#
# Footgun #11 (heredoc_write deadlock class): plain `printf` / file-arg /
# `python3 -c` only; no command-substitution feeding a heredoc-stdin.

set -euo pipefail

SMOKE_NAME="2171-keychain-shadow-selfheal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "2171-keychain-shadow-selfheal"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"
MOCK_SRC="$SCRIPT_DIR/2171-keychain-shadow-selfheal-mock-security.py"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing bridge-auth.py: $AUTH_PY"
[[ -f "$AUTH_SH" ]] || smoke_fail "missing bridge-auth.sh: $AUTH_SH"
[[ -f "$MOCK_SRC" ]] || smoke_fail "missing mock security helper: $MOCK_SRC"

# Service names Claude Code uses (base + the hashed variant from the sean-m4 RCA).
SVC_BASE="Claude Code-credentials"
SVC_HASH="Claude Code-credentials-73a6604c"

# Redacted mock tokens (validate_token-clean: >=20 chars, no whitespace/quotes/
# control chars). POOL = the active rotating pool token; SHADOW = the stale
# keychain token that shadows it.
POOL_TOKEN="MOCKpoolTOKENvalueAAAAAAAAAAAA-pool0001"
SHADOW_TOKEN="MOCKshadowTOKENvalueBBBBBBBBBB-shadow001"

# Install the mock `security` binary under the smoke temp root (#1860 guard:
# never resolve a runtime stub onto the live install / source checkout).
SECURITY_BIN="$SMOKE_TMP_ROOT/security"
smoke_write_runtime_stub "$SECURITY_BIN" "$(cat "$MOCK_SRC")"

KC_DIR="$SMOKE_TMP_ROOT/keychain"

# Seed a registry whose ACTIVE token is the pool token.
REGISTRY="$SMOKE_TMP_ROOT/registry.json"
printf '{"version":1,"active_token_id":"primary","auto_rotate_enabled":false,"rotation_threshold":99.0,"weekly_warn_threshold":95.0,"tokens":[{"id":"primary","token":"%s","enabled":true,"last_check_status":"available"}],"last_rotation":{}}\n' \
  "$POOL_TOKEN" >"$REGISTRY"
export BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY"

# kc_reset — clear the mock keychain to an empty state.
kc_reset() {
  rm -rf "$KC_DIR"
  mkdir -p "$KC_DIR"
  : >"$KC_DIR/services"
}

# kc_add <service> <token> — register a generic-password entry whose secret is
# the Claude Code credential JSON wrapping <token> as the OAuth access token.
kc_add() {
  local service="$1" token="$2"
  printf '%s\n' "$service" >>"$KC_DIR/services"
  printf '{"claudeAiOauth":{"accessToken":"%s"}}' "$token" >"$KC_DIR/tok-$service"
}

# reconcile [args...] — run the production verb against the mock keychain. Echoes
# stdout; returns the verb's exit code (captured by the caller).
reconcile() {
  BRIDGE_SECURITY_BIN="$SECURITY_BIN" \
  MOCK_KC_DIR="$KC_DIR" \
  BRIDGE_HOST_PLATFORM_OVERRIDE="${PLATFORM:-Darwin}" \
    python3 "$AUTH_PY" --registry "$REGISTRY" reconcile-keychain "$@"
}

# T1 — matching fingerprint: clean no-op, deletes 0.
test_match_is_clean_noop() {
  kc_reset
  kc_add "$SVC_BASE" "$POOL_TOKEN"
  local out rc=0
  out="$(reconcile --json)" || rc=$?
  smoke_assert_eq "0" "$rc" "T1 matching entry exits 0"
  smoke_assert_contains "$out" '"status": "clean"' "T1 status clean"
  smoke_assert_contains "$out" '"stale_count": 0' "T1 no stale entries"
  smoke_assert_contains "$out" '"match": "match"' "T1 entry classified match"
  smoke_assert_file_exists "$KC_DIR/tok-$SVC_BASE" "T1 matching entry left in place"
  [[ ! -f "$KC_DIR/deleted.log" ]] || smoke_fail "T1 no delete must have been issued"
}

# T2 — hashed-variant stale shadow: default FAIL-CLOSED diagnostic, rc 3, deletes
# nothing. This is the confirmed M4 fleet-down case.
test_hashed_stale_is_failclosed() {
  kc_reset
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  local out rc=0
  out="$(reconcile --json)" || rc=$?
  smoke_assert_eq "3" "$rc" "T2 detected shadow exits 3 (fail-closed signal)"
  smoke_assert_contains "$out" '"status": "shadow_detected"' "T2 status shadow_detected"
  smoke_assert_contains "$out" '"stale_count": 1' "T2 one stale entry"
  smoke_assert_contains "$out" "$SVC_HASH" "T2 reports the hashed service name"
  smoke_assert_contains "$out" '"match": "stale"' "T2 entry classified stale"
  [[ ! -f "$KC_DIR/deleted.log" ]] || smoke_fail "T2 default mode must delete NOTHING"
  smoke_assert_file_exists "$KC_DIR/tok-$SVC_HASH" "T2 stale entry left in place (diagnostic only)"
}

# T3 — base + hashed BOTH present: full enumeration (base-only is insufficient);
# only the divergent hashed entry is flagged.
test_full_enumeration_base_plus_hashed() {
  kc_reset
  kc_add "$SVC_BASE" "$POOL_TOKEN"
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  local out rc=0
  out="$(reconcile --json)" || rc=$?
  smoke_assert_eq "3" "$rc" "T3 mixed pool exits 3 (one shadow)"
  smoke_assert_contains "$out" "$SVC_BASE" "T3 base entry enumerated"
  smoke_assert_contains "$out" "$SVC_HASH" "T3 hashed entry enumerated (base-only would miss it)"
  smoke_assert_contains "$out" '"stale_count": 1' "T3 exactly one stale (the hashed variant)"
  local stale
  stale="$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["stale_services"]))')"
  smoke_assert_eq "$SVC_HASH" "$stale" "T3 only the hashed variant is stale; base matches"
}

# T4 — --apply: operator-approved cleanup deletes ONLY the stale hashed entry.
test_apply_deletes_only_stale() {
  kc_reset
  kc_add "$SVC_BASE" "$POOL_TOKEN"
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  local out rc=0
  out="$(reconcile --apply --json)" || rc=$?
  smoke_assert_eq "0" "$rc" "T4 --apply cleanup exits 0"
  smoke_assert_contains "$out" '"status": "cleaned"' "T4 status cleaned"
  smoke_assert_contains "$out" "$SVC_HASH" "T4 deleted list names the hashed service"
  local deleted
  deleted="$(tr -d '\r' <"$KC_DIR/deleted.log")"
  smoke_assert_eq "$SVC_HASH" "$deleted" "T4 mock recorded exactly one delete (the hashed variant)"
  [[ ! -f "$KC_DIR/tok-$SVC_HASH" ]] || smoke_fail "T4 stale entry must be removed"
  smoke_assert_file_exists "$KC_DIR/tok-$SVC_BASE" "T4 matching base entry must be preserved"
}

# T5 — non-Darwin no-op: security(1) is never invoked.
test_non_darwin_noop() {
  kc_reset
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  local out rc=0
  out="$(PLATFORM=Linux reconcile --json)" || rc=$?
  smoke_assert_eq "0" "$rc" "T5 non-Darwin exits 0"
  smoke_assert_contains "$out" '"status": "skipped_non_darwin"' "T5 status skipped_non_darwin"
  smoke_assert_contains "$out" '"stale_count": 0' "T5 no enumeration on a non-Darwin host"
  # The guard short-circuits BEFORE any security call → no delete log, even
  # though a stale entry exists in the fixture.
  [[ ! -f "$KC_DIR/deleted.log" ]] || smoke_fail "T5 must not call security(1) on a non-Darwin host"
}

# T6 — raw-token guard: only fingerprints are emitted, never the secrets.
test_no_raw_token_in_output() {
  kc_reset
  kc_add "$SVC_BASE" "$POOL_TOKEN"
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  local out rc=0
  out="$(reconcile --json)" || rc=$?
  smoke_assert_not_contains "$out" "$POOL_TOKEN" "T6 active pool token never printed"
  smoke_assert_not_contains "$out" "$SHADOW_TOKEN" "T6 shadow token never printed"
  smoke_assert_contains "$out" '"fingerprint": "sha256:' "T6 only sha256 fingerprints are emitted"
}

# T7 — bash wrapper passes --registry + --apply through; unknown flag fails closed.
test_bash_wrapper() {
  kc_reset
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  local out rc=0
  out="$(BRIDGE_SECURITY_BIN="$SECURITY_BIN" MOCK_KC_DIR="$KC_DIR" \
    BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
    bash "$AUTH_SH" claude-token reconcile-keychain --apply --json)" || rc=$?
  smoke_assert_eq "0" "$rc" "T7 wrapper --apply exits 0"
  smoke_assert_contains "$out" '"status": "cleaned"' "T7 wrapper resolves the registry and cleans"
  local deleted
  deleted="$(tr -d '\r' <"$KC_DIR/deleted.log")"
  smoke_assert_eq "$SVC_HASH" "$deleted" "T7 wrapper passed --apply through to the deleter"
  # Unknown flag must fail closed (rc 2) BEFORE any keychain call.
  kc_reset
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  rc=0
  BRIDGE_SECURITY_BIN="$SECURITY_BIN" MOCK_KC_DIR="$KC_DIR" \
    BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
    bash "$AUTH_SH" claude-token reconcile-keychain --bogus >/dev/null 2>&1 || rc=$?
  smoke_assert_eq "2" "$rc" "T7 wrapper fails closed (rc 2) on an unknown flag"
  [[ ! -f "$KC_DIR/deleted.log" ]] || smoke_fail "T7 unknown-flag path must not call security(1)"
}

# T8 — --expected-credentials: a per-agent .credentials.json is the expected
# fingerprint source (independent of the registry active token).
test_expected_credentials_source() {
  kc_reset
  # The keychain entry carries the SHADOW token; the registry active is POOL.
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  # A per-agent .credentials.json that matches the SHADOW token → that entry is
  # the expected one for THIS agent, so reconcile reports it clean.
  local creds="$SMOKE_TMP_ROOT/agent/.credentials.json"
  mkdir -p "$(dirname "$creds")"
  printf '{"claudeAiOauth":{"accessToken":"%s"}}' "$SHADOW_TOKEN" >"$creds"
  local out rc=0
  out="$(reconcile --expected-credentials "$creds" --json)" || rc=$?
  smoke_assert_eq "0" "$rc" "T8 entry matching --expected-credentials exits 0"
  smoke_assert_contains "$out" '"status": "clean"' "T8 status clean against the per-agent credential"
  smoke_assert_contains "$out" '"expected_source": "credentials:' "T8 expected_source is the credentials file"
}

# T9 — enumeration FAILURE must fail closed (#2171 PR-D review F1). A security(1)
# that cannot read the keychain (here: a non-zero stub) must NOT be reported as a
# vacuous "clean"; the verb returns keychain_enumeration_failed, deletes nothing
# even under --apply, and exits non-zero so a health gate notices the gap.
test_enumeration_failure_failclosed() {
  kc_reset
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"
  local fail_bin="$SMOKE_TMP_ROOT/security-fail"
  smoke_write_runtime_stub "$fail_bin" '#!/usr/bin/env python3
import sys
sys.exit(1)
'
  local out rc=0
  out="$(BRIDGE_SECURITY_BIN="$fail_bin" MOCK_KC_DIR="$KC_DIR" \
    BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
    python3 "$AUTH_PY" --registry "$REGISTRY" reconcile-keychain --apply --json)" || rc=$?
  smoke_assert_eq "2" "$rc" "T9 enumeration failure exits non-zero (fail-closed, not a vacuous clean)"
  smoke_assert_contains "$out" '"status": "keychain_enumeration_failed"' "T9 status keychain_enumeration_failed"
  smoke_assert_contains "$out" '"applied": false' "T9 applied=false even though --apply was passed"
  [[ ! -f "$KC_DIR/deleted.log" ]] || smoke_fail "T9 enumeration failure must delete NOTHING, even under --apply"
}

# T10 — the operator-keychain-present guard (the sync-global divergence gate) must
# see the HASHED-only service, not just the base name (#2171 PR-D review F2). The
# base-only find-generic-password returned False on the exact M4 setup, letting
# sync-global diverge ~/.claude.json from the keychain-owned identity.
test_present_guard_sees_hashed() {
  kc_reset
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"   # hashed-only, NO base entry
  local res
  res="$(BRIDGE_SECURITY_BIN="$SECURITY_BIN" MOCK_KC_DIR="$KC_DIR" \
    BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
    python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("ba",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print("PRESENT" if m.operator_keychain_credentials_present() else "ABSENT")' "$AUTH_PY")"
  smoke_assert_eq "PRESENT" "$res" "T10 present-guard detects the hashed-only keychain entry (base-only would miss it)"
}

# T11 — an enumerated entry whose SECRET cannot be read must fail closed (#2171
# PR-D review r2). The service name enumerates but find-generic-password -w
# fails, so we cannot tell if it is the active token or a stale shadow: status
# indeterminate_unreadable, rc 2, deletes NOTHING even under --apply. (Same
# fail-closed boundary as enumeration failure, one level deeper.)
test_unreadable_entry_failclosed() {
  kc_reset
  # Service name is enumerable, but NO secret file → mock -w read returns nonzero.
  printf '%s\n' "$SVC_HASH" >>"$KC_DIR/services"
  local out rc=0
  out="$(reconcile --apply --json)" || rc=$?
  smoke_assert_eq "2" "$rc" "T11 unreadable entry exits 2 (fail-closed, not a vacuous clean)"
  smoke_assert_contains "$out" '"status": "indeterminate_unreadable"' "T11 status indeterminate_unreadable"
  smoke_assert_contains "$out" '"match": "unreadable"' "T11 entry classified unreadable"
  smoke_assert_contains "$out" "$SVC_HASH" "T11 the unreadable service is reported"
  [[ ! -f "$KC_DIR/deleted.log" ]] || smoke_fail "T11 must delete NOTHING for an unreadable entry, even under --apply"
}

# T12 — MIXED confirmed-stale + unreadable under --apply must STILL fail closed
# (#2171 PR-D review r3). An unreadable entry dominates: never mutate the keychain
# while an entry is un-inspected (so the confirmed-stale one is NOT deleted), and
# never claim cleaned/rc0 while an unreadable entry remains.
test_mixed_stale_unreadable_failclosed() {
  kc_reset
  kc_add "$SVC_HASH" "$SHADOW_TOKEN"                  # readable, divergent token → stale
  local svc_unread="Claude Code-credentials-unread01"
  printf '%s\n' "$svc_unread" >>"$KC_DIR/services"    # enumerable name, NO secret → unreadable
  local out rc=0
  out="$(reconcile --apply --json)" || rc=$?
  smoke_assert_eq "2" "$rc" "T12 mixed stale+unreadable exits 2 (fail-closed, not cleaned)"
  smoke_assert_contains "$out" '"status": "indeterminate_unreadable"' "T12 unreadable dominates stale in the status"
  smoke_assert_contains "$out" '"deleted": []' "T12 nothing deleted while an entry is unreadable, even under --apply"
  smoke_assert_file_exists "$KC_DIR/tok-$SVC_HASH" "T12 confirmed-stale entry NOT removed while inspection is incomplete"
  [[ ! -f "$KC_DIR/deleted.log" ]] || smoke_fail "T12 must not mutate the keychain in a mixed unreadable set"
}

smoke_run "T1 matching fingerprint is a clean no-op"                  test_match_is_clean_noop
smoke_run "T2 hashed-variant stale shadow is fail-closed (rc 3)"      test_hashed_stale_is_failclosed
smoke_run "T3 base+hashed are both enumerated (base-only insufficient)" test_full_enumeration_base_plus_hashed
smoke_run "T4 --apply deletes only the stale hashed entry"           test_apply_deletes_only_stale
smoke_run "T5 non-Darwin host is a no-op (security never called)"     test_non_darwin_noop
smoke_run "T6 diagnostic emits fingerprints only (no raw token)"     test_no_raw_token_in_output
smoke_run "T7 bash wrapper passthrough + unknown-flag fail-closed"   test_bash_wrapper
smoke_run "T8 --expected-credentials drives the expected fingerprint" test_expected_credentials_source
smoke_run "T9 enumeration failure fails closed (rc 2, deletes nothing)" test_enumeration_failure_failclosed
smoke_run "T10 present-guard sees the hashed-only service (F2)"        test_present_guard_sees_hashed
smoke_run "T11 unreadable entry fails closed (rc 2, deletes nothing)"  test_unreadable_entry_failclosed
smoke_run "T12 mixed stale+unreadable stays fail-closed (no mutation)" test_mixed_stale_unreadable_failclosed

smoke_log "all checks passed"
