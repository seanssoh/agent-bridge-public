#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/18849-operator-account-email.sh — #18849 Part 1b-v2 (HIGH-RISK auth).
#
# The displayed Claude identity (oauthAccount.emailAddress in ~/.claude.json) is
# sourced from the OPERATOR-PROVIDED account email captured in the token
# registry, NOT a user:profile probe (which 403s on the pool's tokens — #2145).
# The email is BINDING only when account_email_source == "operator". This smoke
# pins the capture paths (add/receive/set), the validation, the operator-source
# gate on the ~/.claude.json write, the replace stale-clear, the optional
# verify-only probe (non-blocking + warn-only), the configured-identity status
# surface, and the dropped user:profile scope. FAKE files only.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home + a FAKE operator home
# under $SMOKE_TMP_ROOT. NEVER touches the real ~/.claude or ~/.agent-bridge.
#
# Cases:
#   C1  add --account-email          -> row records account_email + source=operator
#   C2  add without --account-email  -> no account_email / source on the row
#   C3  set --account-email          -> source=operator, set_at stamped
#   C4  validation (format-only)     -> empty/space/no-@/multi-@/control rejected
#   C5  receive --request            -> non-secret email stored in the request record
#   C6  empty account_email          -> identity-sync unconfigured, NO ~/.claude.json write
#   C7  operator email PATCH         -> only emailAddress; projects/mcp/unknown/mode preserved
#   C8  replace WITHOUT email        -> clears stale account_email/source (no inherit)
#   C9  replace WITH email           -> writes the new operator identity
#   C10 legacy probe-sourced email   -> NOT trusted (source!=operator) -> unconfigured, no write
#   C11 optional probe 403           -> verify_skipped, NON-blocking (operator write still lands)
#   C12 optional probe mismatch      -> WARN only; account_email NOT overwritten, no rollback
#   C13 global-auth-status           -> reports CONFIGURED-identity convergence (not verified-profile)
#   C14 generated scopes             -> no longer require user:profile (gate 7)
#   C15 ci-select routing            -> bridge-auth.py + this smoke selected

set -uo pipefail

SMOKE_NAME="18849-operator-account-email"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"
CI_SELECT="$REPO_ROOT/scripts/ci-select-smoke.sh"
HELPER="$SCRIPT_DIR/18849-operator-account-email-helper.py"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing bridge-auth.py: $AUTH_PY"
[[ -f "$AUTH_SH" ]] || smoke_fail "missing bridge-auth.sh: $AUTH_SH"
[[ -f "$HELPER" ]] || smoke_fail "missing helper: $HELPER"

REGISTRY="$SMOKE_TMP_ROOT/registry.json"
OP_HOME="$SMOKE_TMP_ROOT/op-home"
OP_CRED="$OP_HOME/.claude/.credentials.json"
OP_CFG="$OP_HOME/.claude.json"
DISPLAY_EMAIL="olduser@example.com"
# Benign, non-credential-shaped token (validate_token only requires len>=20 and
# no whitespace/quotes) so nothing here resembles a real Anthropic credential.
ACTIVE_TOKEN="ZZZactive-token-aaaaaaaaaaaaaaaaaaaa"

mkdir -p "$OP_HOME/.claude"
smoke_assert_path_in_temp "$OP_CRED" "fake operator credential path"

field() { python3 "$HELPER" json-field "$1"; }
reg() { python3 "$HELPER" reg-field "$REGISTRY" "$1"; }
add_token() {  # $1=id, rest=flags
  local id="$1"; shift
  printf '%s' "$ACTIVE_TOKEN" | python3 "$AUTH_PY" --registry "$REGISTRY" add --id "$id" --stdin "$@"
}
# Force the keychain-exists guard OFF so the macOS test host's real keychain
# state cannot pre-empt the identity path; verify-probe stays default-OFF.
run_sync() {  # remaining args appended to sync-global / global-auth-status
  env BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT=0 \
    python3 "$AUTH_PY" --registry "$REGISTRY" "$@"
}

seed_runtime() {
  python3 "$HELPER" seed-registry "$REGISTRY" "$ACTIVE_TOKEN" true
  python3 "$HELPER" seed-cred "$OP_CRED"
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
}

# ── C1 ────────────────────────────────────────────────────────────────
test_add_account_email_persists() {
  rm -f "$REGISTRY"
  local out
  out="$(add_token a1 --account-email "real@example.com" --json)"
  smoke_assert_eq "added" "$(printf '%s' "$out" | field status)" "C1 add status=added"
  smoke_assert_eq "real@example.com" "$(reg account_email)" "C1 row account_email captured"
  smoke_assert_eq "operator" "$(reg account_email_source)" "C1 row source=operator"
  [[ -n "$(reg account_email_set_at)" ]] || smoke_fail "C1 account_email_set_at not stamped"
}

# ── C2 ────────────────────────────────────────────────────────────────
test_add_without_email_no_source() {
  rm -f "$REGISTRY"
  add_token a1 --json >/dev/null
  smoke_assert_eq "" "$(reg account_email)" "C2 no account_email when not provided"
  smoke_assert_eq "" "$(reg account_email_source)" "C2 no source when not provided"
}

# ── C3 ────────────────────────────────────────────────────────────────
test_set_account_email() {
  rm -f "$REGISTRY"
  add_token a1 --json >/dev/null
  local out
  out="$(python3 "$AUTH_PY" --registry "$REGISTRY" set --id a1 --account-email "new@example.com" --json)"
  smoke_assert_eq "set" "$(printf '%s' "$out" | field status)" "C3 set status=set"
  smoke_assert_eq "new@example.com" "$(reg account_email)" "C3 set captured account_email"
  smoke_assert_eq "operator" "$(reg account_email_source)" "C3 set source=operator"
  [[ -n "$(reg account_email_set_at)" ]] || smoke_fail "C3 set_at not stamped"
}

# ── C4 ────────────────────────────────────────────────────────────────
test_validation_rejects_bad() {
  rm -f "$REGISTRY"
  add_token a1 --json >/dev/null
  local bad rc
  for bad in "" "  " "noatsign.example.com" "two@@example.com" "a b@example.com" "@example.com" "user@"; do
    set +e
    python3 "$AUTH_PY" --registry "$REGISTRY" set --id a1 --account-email "$bad" --json >/dev/null 2>&1
    rc=$?
    set -e 2>/dev/null || true
    [[ "$rc" -ne 0 ]] || smoke_fail "C4 invalid account email accepted: '${bad}'"
  done
  # control char (embedded newline) must be rejected
  set +e
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id a1 --account-email "$(printf 'a\nb@example.com')" --json >/dev/null 2>&1
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "C4 control char in account email accepted"
  # a valid address still works after the rejections
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id a1 --account-email "ok@example.com" --json >/dev/null \
    || smoke_fail "C4 a valid account email was rejected"
}

# ── C5 ────────────────────────────────────────────────────────────────
test_receive_request_carries_email() {
  rm -f "$REGISTRY"
  python3 "$HELPER" seed-registry "$REGISTRY" "$ACTIVE_TOKEN" true
  local out record
  out="$(python3 "$AUTH_PY" --registry "$REGISTRY" receive --request --id a2 \
        --account-email "req@example.com" --json)"
  smoke_assert_eq "req@example.com" "$(printf '%s' "$out" | field account_email)" \
    "C5 receive --request echoes the non-secret account_email"
  record="$(printf '%s' "$out" | field record)"
  [[ -f "$record" ]] || smoke_fail "C5 request record file missing: $record"
  smoke_assert_eq "req@example.com" "$(python3 "$HELPER" json-field account_email <"$record")" \
    "C5 request record stores the non-secret account_email"
  # a malformed email is rejected at request time too
  local rc
  set +e
  python3 "$AUTH_PY" --registry "$REGISTRY" receive --request --id a2 --account-email "bad" --json >/dev/null 2>&1
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "C5 receive --request accepted a malformed account_email"
}

# ── C6 ────────────────────────────────────────────────────────────────
test_empty_email_no_write() {
  seed_runtime  # seed-registry: no operator account_email
  local before out
  before="$(cksum <"$OP_CFG")"
  out="$(run_sync sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "unconfigured" "$(printf '%s' "$out" | field identity_shadow.status)" \
    "C6 identity unconfigured with no operator account_email"
  smoke_assert_eq "$before" "$(cksum <"$OP_CFG")" "C6 ~/.claude.json byte-identical (NO identity write)"
}

# ── C7 ────────────────────────────────────────────────────────────────
test_operator_email_patches_only_email() {
  seed_runtime
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id t1 --account-email "configured@example.com" --json >/dev/null
  local out
  out="$(run_sync sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "synced" "$(printf '%s' "$out" | field identity_shadow.status)" "C7 identity status=synced"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field identity_shadow.converged)" "C7 identity converged"
  python3 "$HELPER" assert-identity-patched "$OP_CFG" "configured@example.com" >/dev/null \
    || smoke_fail "C7 identity PATCH altered emailAddress-only contract or lost load-bearing keys"
}

# ── C8 ────────────────────────────────────────────────────────────────
test_replace_without_email_clears_stale() {
  rm -f "$REGISTRY"
  add_token a1 --account-email "stale@example.com" --json >/dev/null
  smoke_assert_eq "stale@example.com" "$(reg account_email)" "C8 precondition: stale email present"
  # Replace the token VALUE without an explicit --account-email.
  printf '%s' "ZZZreplacement-token-ffffffffffffffff" \
    | python3 "$AUTH_PY" --registry "$REGISTRY" add --id a1 --stdin --replace --json >/dev/null
  smoke_assert_eq "" "$(reg account_email)" "C8 replace WITHOUT --account-email CLEARS the stale email"
  smoke_assert_eq "" "$(reg account_email_source)" "C8 replace clears the stale source"
}

# ── C9 ────────────────────────────────────────────────────────────────
test_replace_with_email_writes_new() {
  rm -f "$REGISTRY"
  add_token a1 --account-email "stale@example.com" --json >/dev/null
  printf '%s' "ZZZreplacement-token-ffffffffffffffff" \
    | python3 "$AUTH_PY" --registry "$REGISTRY" add --id a1 --stdin --replace \
        --account-email "fresh@example.com" --json >/dev/null
  smoke_assert_eq "fresh@example.com" "$(reg account_email)" "C9 replace WITH --account-email writes the new identity"
  smoke_assert_eq "operator" "$(reg account_email_source)" "C9 replace keeps source=operator"
}

# ── C10 ───────────────────────────────────────────────────────────────
test_legacy_probe_email_not_trusted() {
  python3 "$HELPER" seed-registry "$REGISTRY" "$ACTIVE_TOKEN" true "legacy@example.com" "probe"
  python3 "$HELPER" seed-cred "$OP_CRED"
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
  local before out
  before="$(cksum <"$OP_CFG")"
  out="$(run_sync sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "unconfigured" "$(printf '%s' "$out" | field identity_shadow.status)" \
    "C10 probe-sourced legacy account_email is NOT trusted (source!=operator)"
  smoke_assert_eq "$before" "$(cksum <"$OP_CFG")" "C10 no ~/.claude.json write for a non-operator email"
}

# ── C11 ───────────────────────────────────────────────────────────────
test_optional_probe_403_verify_skipped() {
  seed_runtime
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id t1 --account-email "configured@example.com" --json >/dev/null
  local fix="$SMOKE_TMP_ROOT/noscope.json"
  python3 "$HELPER" write-fixture "$fix" no_scope
  local out
  out="$(env BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT=0 \
        BRIDGE_CLAUDE_IDENTITY_VERIFY_PROBE=1 BRIDGE_CLAUDE_PROFILE_PROBE_FIXTURE="$fix" \
        python3 "$AUTH_PY" --registry "$REGISTRY" sync-global \
        --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  # The 403 is NON-blocking: the operator-sourced identity write still lands.
  smoke_assert_eq "synced" "$(printf '%s' "$out" | field identity_shadow.status)" \
    "C11 operator write still lands when the optional probe 403s"
  smoke_assert_eq "verify_skipped" "$(printf '%s' "$out" | field identity_shadow.probe_status)" \
    "C11 probe_status=verify_skipped (403 is benign, not a blocker)"
  smoke_assert_eq "verify_skipped" "$(reg account_email_probe_status)" \
    "C11 registry records verify_skipped separately from the configured source"
  python3 "$HELPER" assert-config-email "$OP_CFG" "configured@example.com" >/dev/null \
    || smoke_fail "C11 displayed identity not converged on the operator email"
}

# ── C12 ───────────────────────────────────────────────────────────────
test_optional_probe_mismatch_warns_only() {
  seed_runtime
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id t1 --account-email "configured@example.com" --json >/dev/null
  local fix="$SMOKE_TMP_ROOT/mismatch.json" err out
  python3 "$HELPER" write-fixture "$fix" verified "different@example.com"
  err="$SMOKE_TMP_ROOT/c12.err"
  out="$(env BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT=0 \
        BRIDGE_CLAUDE_IDENTITY_VERIFY_PROBE=1 BRIDGE_CLAUDE_PROFILE_PROBE_FIXTURE="$fix" \
        python3 "$AUTH_PY" --registry "$REGISTRY" sync-global \
        --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json 2>"$err")"
  smoke_assert_eq "mismatch" "$(printf '%s' "$out" | field identity_shadow.probe_status)" \
    "C12 probe_status=mismatch when the probe email differs from the configured one"
  smoke_assert_contains "$(cat "$err")" "does NOT match" "C12 mismatch emits a WARNING"
  # account_email is the operator value, NOT overwritten by the probe; no rollback.
  smoke_assert_eq "configured@example.com" "$(reg account_email)" \
    "C12 probe NEVER overwrites the operator-configured account_email"
  smoke_assert_eq "different@example.com" "$(reg account_email_probe_observed)" \
    "C12 probe-observed email stored SEPARATELY (diagnostic only)"
  python3 "$HELPER" assert-config-email "$OP_CFG" "configured@example.com" >/dev/null \
    || smoke_fail "C12 displayed identity was rolled back / overwritten by the probe mismatch"
}

# ── C13 ───────────────────────────────────────────────────────────────
test_status_reports_configured_convergence() {
  seed_runtime
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id t1 --account-email "$DISPLAY_EMAIL" --json >/dev/null
  run_sync sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json >/dev/null
  local out text
  out="$(run_sync global-auth-status --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --json)"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field identity_converged)" "C13 identity_converged=True"
  smoke_assert_eq "$DISPLAY_EMAIL" "$(printf '%s' "$out" | field identity_shadow.configured_email)" \
    "C13 status reports configured_email (not verified-profile)"
  smoke_assert_eq "operator" "$(printf '%s' "$out" | field identity_shadow.source)" "C13 source=operator"
  text="$(run_sync global-auth-status --global-credentials "$OP_CRED" --claude-config "$OP_CFG")"
  smoke_assert_contains "$text" "configured_identity=$DISPLAY_EMAIL" \
    "C13 human status line reports configured_identity (renamed from verified_identity)"
}

# ── C14 ───────────────────────────────────────────────────────────────
test_scopes_drop_user_profile() {
  smoke_assert_eq '["user:inference"]' "$(python3 "$HELPER" scopes-constant)" \
    "C14 CLAUDE_OAUTH_SCOPES no longer declares user:profile"
  # A freshly CREATED operator-global credential carries only the trimmed scopes.
  seed_runtime
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id t1 --account-email "x@example.com" --json >/dev/null
  rm -f "$OP_CRED"
  run_sync sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json >/dev/null
  smoke_assert_eq '["user:inference"]' "$(python3 "$HELPER" cred-scopes "$OP_CRED")" \
    "C14 a freshly created credential seeds scopes without user:profile"
}

# ── C15 ───────────────────────────────────────────────────────────────
test_ci_select_routing() {
  [[ -f "$CI_SELECT" ]] || smoke_fail "C15 missing ci-select-smoke.sh: $CI_SELECT"
  local out_py out_self
  out_py="$(bash "$CI_SELECT" --changed-file bridge-auth.py 2>/dev/null || true)"
  smoke_assert_contains "$out_py" "$SMOKE_NAME" "C15 ci-select routes bridge-auth.py -> $SMOKE_NAME"
  out_self="$(bash "$CI_SELECT" --changed-file "scripts/smoke/$SMOKE_NAME.sh" 2>/dev/null || true)"
  smoke_assert_contains "$out_self" "$SMOKE_NAME" "C15 ci-select routes the smoke file -> itself"
}

smoke_run "C1 add --account-email -> row records source=operator"             test_add_account_email_persists
smoke_run "C2 add without --account-email -> no source"                       test_add_without_email_no_source
smoke_run "C3 set --account-email -> source=operator"                         test_set_account_email
smoke_run "C4 validation rejects malformed account emails"                    test_validation_rejects_bad
smoke_run "C5 receive --request carries the non-secret email"                 test_receive_request_carries_email
smoke_run "C6 empty account_email -> identity-sync no-op"                     test_empty_email_no_write
smoke_run "C7 operator email PATCHes only emailAddress + preserves"           test_operator_email_patches_only_email
smoke_run "C8 replace WITHOUT email clears the stale identity"                test_replace_without_email_clears_stale
smoke_run "C9 replace WITH email writes the new identity"                     test_replace_with_email_writes_new
smoke_run "C10 legacy probe-sourced email NOT trusted"                        test_legacy_probe_email_not_trusted
smoke_run "C11 optional probe 403 -> verify_skipped, non-blocking"           test_optional_probe_403_verify_skipped
smoke_run "C12 optional probe mismatch -> warn-only, no overwrite"           test_optional_probe_mismatch_warns_only
smoke_run "C13 global-auth-status reports configured convergence"            test_status_reports_configured_convergence
smoke_run "C14 generated scopes no longer require user:profile"             test_scopes_drop_user_profile
smoke_run "C15 ci-select routing -> bridge-auth.py + smoke selected"         test_ci_select_routing

smoke_log "all checks passed"
