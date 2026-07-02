#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/token-updater-lease-client.sh — #21895 phase-1, sub-PR 2/4 (HIGH-RISK auth).
#
# Contract A: the token-updater lease HTTP client (checkout/heartbeat/swap/
# checkin), the durable 0600 lease-state file, and the email→local-token
# mapping. This sub-PR is ADDITIVE + default-OFF: NO rotator, NO daemon tick, NO
# caller of the client. The load-bearing invariant this smoke pins: a
# disabled/unconfigured install is a byte-for-byte no-op (every verb reports OFF
# and mutates nothing), and the client never touches the network in CI (all HTTP
# is served from a per-verb JSON fixture dir).
#
# Isolation: a temp BRIDGE_HOME via smoke_setup_bridge_home; the runtime-secrets
# dir + lease-state file are pinned under it. NEVER touches the real ~/.claude or
# ~/.agent-bridge, and NEVER makes a live HTTP request.
#
# Cases:
#   T1  disabled/unconfigured: `lease checkout|swap|checkin` report status=disabled
#       (rc!=0), mutate NO lease-state file (the default-OFF no-op invariant)
#   T2  mapping: unique operator-sourced email -> ok:local_token_id (casefold)
#   T3  mapping fail-closed: missing / probe-sourced-only / >1 match / empty ->
#       structured skip (map_missing|map_ambiguous), NEVER a guess
#   T4  lease-state file: sanctioned writer -> read round-trips EXACT keys, 0600
#   T5  client happy path: checkout|heartbeat|swap|checkin 200 -> status=ok
#   T6  client 404 (heartbeat lease gone) -> status=error, http surfaced
#   T7  client 409 (swap nothing-usable) -> status=conflict, reset fields passthrough
#   T7b non-finite server lease_expires_at (Infinity/1e400) -> ok, expiry None (no crash)
#   T8  client transport error/timeout -> status=error, http=None (never raises)
#   T8b _parse_retry_after robust: neg/inf/-inf/Infinity/1e400/nan/NaN/date/empty -> None
#   T9  enabled client verb happy path end-to-end through the CLI (checkout ok)
#   T9b `lease heartbeat` CLI verb: no-lease noop / with-lease ok (Sub-PR 4 seam)
#   T10 ci-select routing: bridge-auth.py/.sh select this smoke by source mapping

set -uo pipefail

SMOKE_NAME="token-updater-lease-client"
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
HELPER="$SCRIPT_DIR/token-updater-lease-client-helper.py"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing bridge-auth.py: $AUTH_PY"
[[ -f "$AUTH_SH" ]] || smoke_fail "missing bridge-auth.sh: $AUTH_SH"
[[ -f "$HELPER" ]] || smoke_fail "missing helper: $HELPER"

# smoke_setup_bridge_home exports BRIDGE_RUNTIME_ROOT + BRIDGE_RUNTIME_CONFIG_FILE
# but NOT the secrets dir — pin it under the isolated runtime root (mirrors the
# config smoke + bridge-lib.sh's `$BRIDGE_RUNTIME_ROOT/secrets` default).
export BRIDGE_RUNTIME_SECRETS_DIR="$BRIDGE_RUNTIME_ROOT/secrets"
mkdir -p "$BRIDGE_RUNTIME_SECRETS_DIR"
REGISTRY="$BRIDGE_RUNTIME_SECRETS_DIR/registry.json"
LEASE_STATE="$BRIDGE_RUNTIME_SECRETS_DIR/token-updater-lease.json"
FIXTURE_KEY="tu-fixture-secret-0123456789abcdef"

field() { python3 "$HELPER" json-field "$1"; }
file_mode() { python3 "$HELPER" file-mode "$1"; }
lease_py() { python3 "$AUTH_PY" --registry "$REGISTRY" lease "$@"; }

enable_feature() {
  printf '%s' "$FIXTURE_KEY" | lease_py config \
    --api-url "https://lease.example.com" --server-id "srv-1" --enabled --api-key-stdin --json >/dev/null
}

disable_feature() {
  rm -f "$BRIDGE_RUNTIME_CONFIG_FILE" "$BRIDGE_RUNTIME_SECRETS_DIR/token-updater-api-key" "$LEASE_STATE"
}

# Write a per-verb HTTP fixture into $1 (dir); $2=verb, $3=json spec.
write_fixture() { mkdir -p "$1"; printf '%s' "$3" >"$1/$2.json"; }

# ── T1 ────────────────────────────────────────────────────────────────
# Disabled/unconfigured => every client verb reports status=disabled (rc!=0) and
# writes NO lease-state file. This is the default-OFF no-op invariant.
test_disabled_noop() {
  disable_feature
  local out rc verb
  for verb in checkout heartbeat swap checkin; do
    set +e
    out="$(lease_py "$verb" --json 2>/dev/null)"; rc=$?
    set -e 2>/dev/null || true
    [[ "$rc" -ne 0 ]] || smoke_fail "T1 lease $verb rc=0 while disabled (must be nonzero)"
    smoke_assert_eq "disabled" "$(printf '%s' "$out" | field status)" "T1 lease $verb status=disabled"
    [[ ! -f "$LEASE_STATE" ]] || smoke_fail "T1 lease-state written while disabled: $LEASE_STATE"
  done
}

# ── T2 ────────────────────────────────────────────────────────────────
# Mapping: a UNIQUE operator-sourced email maps (casefold) to its local row id.
test_map_unique() {
  local reg="$SMOKE_TMP_ROOT/reg-unique.json" out
  cat >"$reg" <<'JSON'
{"tokens":[
  {"id":"tok-A","account_email":"Op@example.com","account_email_source":"operator"},
  {"id":"tok-B","account_email":"other@example.com","account_email_source":"operator"}
]}
JSON
  # Query with a DIFFERENT local-part case than the stored row so the assert
  # proves the join is casefold (mixed 'Op' row vs upper 'OP' query -> match).
  out="$(python3 "$HELPER" map "OP@example.com" "$reg")"
  smoke_assert_eq "ok:tok-A:" "$out" "T2 unique casefold map -> ok:tok-A"
}

# ── T3 ────────────────────────────────────────────────────────────────
# Mapping fail-closed: 0/probe-only/>1/empty -> structured skip, never a guess.
test_map_fail_closed() {
  local reg="$SMOKE_TMP_ROOT/reg-fc.json" out
  cat >"$reg" <<'JSON'
{"tokens":[
  {"id":"tok-P","account_email":"probe@example.com","account_email_source":"probe"},
  {"id":"tok-D1","account_email":"dup@example.com","account_email_source":"operator"},
  {"id":"tok-D2","account_email":"DUP@example.com","account_email_source":"operator"}
]}
JSON
  out="$(python3 "$HELPER" map "nobody@example.com" "$reg")"
  smoke_assert_eq "error::map_missing" "$out" "T3 no match -> map_missing"
  out="$(python3 "$HELPER" map "probe@example.com" "$reg")"
  smoke_assert_eq "error::map_missing" "$out" "T3 probe-sourced NOT trusted -> map_missing"
  out="$(python3 "$HELPER" map "dup@example.com" "$reg")"
  smoke_assert_eq "error::map_ambiguous" "$out" "T3 >1 operator match -> map_ambiguous"
  out="$(python3 "$HELPER" map "" "$reg")"
  smoke_assert_eq "error::map_missing" "$out" "T3 empty email -> map_missing"
}

# ── T4 ────────────────────────────────────────────────────────────────
# Durable lease-state: the sanctioned writer round-trips EXACT keys at mode 0600.
test_lease_state_roundtrip() {
  local statefile="$SMOKE_TMP_ROOT/lease-rt.json" out
  out="$(python3 "$HELPER" lease-state-roundtrip "$statefile")"
  smoke_assert_eq "OK:600" "$out" "T4 lease-state round-trips exact keys at 0600"
}

# ── T5 ────────────────────────────────────────────────────────────────
# Client happy path: every verb served a 200 fixture -> status=ok (no network).
test_client_happy() {
  local fix="$SMOKE_TMP_ROOT/fix-happy" out
  write_fixture "$fix" checkout '{"http_status":200,"body":{"service_token_id":"svc-9","account_email":"op@example.com","lease_expires_at":1751000000}}'
  write_fixture "$fix" heartbeat '{"http_status":200,"body":{"lease_expires_at":1751000600}}'
  write_fixture "$fix" swap '{"http_status":200,"body":{"service_token_id":"svc-10","account_email":"op@example.com","lease_expires_at":1751000900}}'
  write_fixture "$fix" checkin '{"http_status":200,"body":{}}'
  local verb
  for verb in checkout heartbeat swap checkin; do
    out="$(python3 "$HELPER" client "$verb" "$fix")"
    smoke_assert_eq "ok:200" "$out" "T5 client $verb 200 -> ok"
  done
}

# ── T6 ────────────────────────────────────────────────────────────────
# Client 404 (heartbeat lease gone) -> status=error, http surfaced.
test_client_404() {
  local fix="$SMOKE_TMP_ROOT/fix-404" out
  write_fixture "$fix" heartbeat '{"http_status":404,"body":{}}'
  out="$(python3 "$HELPER" client heartbeat "$fix")"
  smoke_assert_eq "error:404" "$out" "T6 heartbeat 404 -> error, http=404"
}

# ── T7 ────────────────────────────────────────────────────────────────
# Client 409 (swap nothing-usable) -> status=conflict, http=409.
test_client_409_conflict() {
  local fix="$SMOKE_TMP_ROOT/fix-409" out
  write_fixture "$fix" swap '{"http_status":409,"body":{"reset_at":"2099-01-01T00:00:00Z"}}'
  out="$(python3 "$HELPER" client swap "$fix")"
  smoke_assert_eq "conflict:409" "$out" "T7 swap 409 -> conflict, http=409"
}

# ── T7b ───────────────────────────────────────────────────────────────
# Malformed 200: a SERVER-CONTROLLED non-finite `lease_expires_at` (json.loads
# accepts Infinity / 1e400 -> float('inf')) must NOT crash the caller with an
# OverflowError from int(inf). checkout/heartbeat/swap each degrade to a
# structured status=ok with lease_expires_at=None. The helper propagates any
# raise, so a passing assertion here IS the no-crash proof.
test_client_nonfinite_expiry() {
  local fix="$SMOKE_TMP_ROOT/fix-nonfinite" out
  write_fixture "$fix" checkout '{"http_status":200,"body":{"service_token_id":"svc-x","account_email":"op@example.com","lease_expires_at":Infinity}}'
  write_fixture "$fix" heartbeat '{"http_status":200,"body":{"lease_expires_at":1e400}}'
  write_fixture "$fix" swap '{"http_status":200,"body":{"service_token_id":"svc-y","account_email":"op@example.com","lease_expires_at":Infinity}}'
  out="$(python3 "$HELPER" client-expiry checkout "$fix")"
  smoke_assert_eq "ok:200:None" "$out" "T7b checkout Infinity expiry -> ok, expiry None (no OverflowError)"
  out="$(python3 "$HELPER" client-expiry heartbeat "$fix")"
  smoke_assert_eq "ok:200:None" "$out" "T7b heartbeat 1e400 expiry -> ok, expiry None"
  out="$(python3 "$HELPER" client-expiry swap "$fix")"
  smoke_assert_eq "ok:200:None" "$out" "T7b swap Infinity expiry -> ok, expiry None"
}

# ── T8 ────────────────────────────────────────────────────────────────
# Client transport error/timeout -> status=error, http=None (never raises out).
test_client_transport_error() {
  local fix="$SMOKE_TMP_ROOT/fix-transport" out
  write_fixture "$fix" checkout '{"transport_error":true}'
  out="$(python3 "$HELPER" client checkout "$fix")"
  smoke_assert_eq "error:None" "$out" "T8 transport error -> error, http=None"
}

# ── T8b ───────────────────────────────────────────────────────────────
# _parse_retry_after robustness: delta-seconds parse, and a hostile / malformed
# value (negative, non-finite inf/Infinity/nan, HTTP-date, empty) degrades to
# None WITHOUT raising (a server-controlled `Retry-After: inf` must not escape
# int(float("inf")) as an OverflowError).
test_retry_after_robust() {
  smoke_assert_eq "30" "$(python3 "$HELPER" retry-after "30")" "T8b Retry-After 30 -> 30"
  smoke_assert_eq "12" "$(python3 "$HELPER" retry-after " 12 ")" "T8b whitespace ' 12 ' -> 12 (float strips)"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "-5")" "T8b negative -> None"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "inf")" "T8b inf -> None (no OverflowError)"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "-inf")" "T8b -inf -> None (isfinite rejects)"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "Infinity")" "T8b Infinity -> None"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "1e400")" "T8b 1e400 (-> float inf) -> None"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "nan")" "T8b nan -> None"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "NaN")" "T8b NaN (capital) -> None"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "Wed, 21 Oct 2099 07:28:00 GMT")" "T8b HTTP-date -> None"
  smoke_assert_eq "None" "$(python3 "$HELPER" retry-after "")" "T8b empty -> None"
}

# ── T9 ────────────────────────────────────────────────────────────────
# Enabled client verb through the CLI end-to-end: checkout 200 -> ok (rc=0),
# JSON carries the passed-through service_token_id/account_email/lease_expires_at.
test_cli_enabled_checkout() {
  disable_feature
  enable_feature
  local fix="$SMOKE_TMP_ROOT/fix-cli" out rc
  write_fixture "$fix" checkout '{"http_status":200,"body":{"service_token_id":"svc-cli","account_email":"op@example.com","lease_expires_at":1751111111}}'
  set +e
  out="$(BRIDGE_TOKEN_UPDATER_LEASE_FIXTURE_DIR="$fix" lease_py checkout --json 2>/dev/null)"; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 0 ]] || smoke_fail "T9 CLI checkout rc=$rc (want 0 for ok)"
  smoke_assert_eq "ok" "$(printf '%s' "$out" | field status)" "T9 CLI checkout status=ok"
  smoke_assert_eq "svc-cli" "$(printf '%s' "$out" | field service_token_id)" "T9 service_token_id passthrough"
  smoke_assert_eq "op@example.com" "$(printf '%s' "$out" | field account_email)" "T9 account_email passthrough"
  smoke_assert_eq "1751111111" "$(printf '%s' "$out" | field lease_expires_at)" "T9 lease_expires_at passthrough"
  disable_feature
}

# ── T9b ───────────────────────────────────────────────────────────────
# `lease heartbeat` CLI verb (Sub-PR 4's daemon tick reaches the client ONLY via
# this CLI): enabled + no lease-state -> structured noop (rc!=0), no HTTP; with a
# durable lease-state + 200 fixture -> ok (rc=0), lease_expires_at passthrough.
test_cli_heartbeat() {
  disable_feature
  enable_feature
  local fix="$SMOKE_TMP_ROOT/fix-hb" out rc
  write_fixture "$fix" heartbeat '{"http_status":200,"body":{"lease_expires_at":1751000600}}'
  # No lease-state yet -> heartbeat is a structured no-op (the daemon's cue to
  # checkout instead), NOT an HTTP call.
  set +e
  out="$(BRIDGE_TOKEN_UPDATER_LEASE_FIXTURE_DIR="$fix" lease_py heartbeat --json 2>/dev/null)"; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T9b heartbeat rc=0 with no lease held (want nonzero)"
  smoke_assert_eq "noop" "$(printf '%s' "$out" | field status)" "T9b heartbeat no-lease -> noop"
  # Seed a durable lease-state, then heartbeat -> ok with the renewed TTL.
  printf '%s' '{"service_token_id":"svc-hb","account_email":"op@example.com","local_token_id":"tok-1","lease_expires_at":1,"last_heartbeat_at":1}' >"$LEASE_STATE"
  chmod 600 "$LEASE_STATE"
  set +e
  out="$(BRIDGE_TOKEN_UPDATER_LEASE_FIXTURE_DIR="$fix" lease_py heartbeat --json 2>/dev/null)"; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 0 ]] || smoke_fail "T9b heartbeat rc=$rc with lease held (want 0)"
  smoke_assert_eq "ok" "$(printf '%s' "$out" | field status)" "T9b heartbeat with lease -> ok"
  smoke_assert_eq "1751000600" "$(printf '%s' "$out" | field lease_expires_at)" "T9b heartbeat lease_expires_at passthrough"
  disable_feature
}

# ── T9c ───────────────────────────────────────────────────────────────
# Contract A ↔ Contract C binding (codex #2248 finding 1): a CLI `lease checkout`
# must PERSIST the durable lease-state so the daemon tick's `lease status` sees a
# held lease (else it checkout-thrashes every poll). The mapped local_token_id is
# recorded from the account email. The checkout envelope carries secret_material
# — it must NEVER land in the durable lease-state file (allowlist excludes it).
test_cli_checkout_persists_lease_state() {
  disable_feature
  enable_feature
  # Registry so account_email → local_token_id resolves (the drift-check input).
  cat >"$REGISTRY" <<'JSON'
{"active_token_id":"tok-active","tokens":[
  {"id":"tok-lease","account_email":"op@example.com","account_email_source":"operator"},
  {"id":"tok-active","account_email":"other@example.com","account_email_source":"operator"}
]}
JSON
  local fix="$SMOKE_TMP_ROOT/fix-persist" out rc
  write_fixture "$fix" checkout '{"http_status":200,"body":{"service_token_id":"svc-persist","account_email":"op@example.com","lease_expires_at":1751222222,"secret_material":"SEKRIT-STATE-MUST-NOT-PERSIST"}}'
  [[ ! -f "$LEASE_STATE" ]] || smoke_fail "T9c precondition: lease-state exists before checkout"
  set +e
  out="$(BRIDGE_TOKEN_UPDATER_LEASE_FIXTURE_DIR="$fix" lease_py checkout --json 2>/dev/null)"; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 0 ]] || smoke_fail "T9c CLI checkout rc=$rc (want 0 for ok)"
  # THE BINDING: checkout persisted the durable lease-state (else the tick thrashes).
  [[ -f "$LEASE_STATE" ]] || smoke_fail "T9c checkout did NOT persist lease-state ($LEASE_STATE) — daemon tick would checkout-thrash (finding 1)"
  smoke_assert_eq "600" "$(file_mode "$LEASE_STATE")" "T9c lease-state persisted at 0600"
  smoke_assert_eq "svc-persist" "$(field service_token_id <"$LEASE_STATE")" "T9c persisted service_token_id"
  smoke_assert_eq "tok-lease" "$(field local_token_id <"$LEASE_STATE")" "T9c persisted the mapped local_token_id"
  smoke_assert_eq "op@example.com" "$(field account_email <"$LEASE_STATE")" "T9c persisted account_email"
  # SECRET NEVER PERSISTED: secret_material must be absent from the state file.
  if grep -q "SEKRIT-STATE-MUST-NOT-PERSIST" "$LEASE_STATE" 2>/dev/null; then
    smoke_fail "T9c secret_material LEAKED into the durable lease-state file: $LEASE_STATE"
  fi
  smoke_assert_eq "" "$(field secret_material <"$LEASE_STATE")" "T9c no secret_material key in lease-state"
  disable_feature
}

# ── T9d ───────────────────────────────────────────────────────────────
# Contract A ↔ Contract C binding (status side, codex #2248 finding 1): `lease
# status --json` must surface lease.{service_token_id, local_token_id,
# lease_expires_at} + the registry active_token_id — the exact inputs the daemon
# tick's lease-status-parse reads to decide re-checkout / drift. Without them the
# tick sees "no lease held" every poll.
test_cli_status_surfaces_lease() {
  disable_feature
  enable_feature
  cat >"$REGISTRY" <<'JSON'
{"active_token_id":"tok-active","tokens":[
  {"id":"tok-active","account_email":"other@example.com","account_email_source":"operator"}
]}
JSON
  printf '%s' '{"service_token_id":"svc-status","account_email":"op@example.com","local_token_id":"tok-lease","lease_expires_at":1751333333,"last_heartbeat_at":1}' >"$LEASE_STATE"
  chmod 600 "$LEASE_STATE"
  local out
  out="$(lease_py status --json 2>/dev/null)"
  smoke_assert_eq "svc-status" "$(printf '%s' "$out" | field lease.service_token_id)" "T9d status surfaces lease.service_token_id"
  smoke_assert_eq "tok-lease" "$(printf '%s' "$out" | field lease.local_token_id)" "T9d status surfaces lease.local_token_id"
  smoke_assert_eq "1751333333" "$(printf '%s' "$out" | field lease.lease_expires_at)" "T9d status surfaces lease.lease_expires_at"
  smoke_assert_eq "tok-active" "$(printf '%s' "$out" | field active_token_id)" "T9d status surfaces registry active_token_id (drift input)"
  # Secret hygiene: the status payload must never carry the secret value.
  smoke_assert_eq "" "$(printf '%s' "$out" | field secret_material)" "T9d status payload carries no secret_material"
  disable_feature
}

# ── T9e ───────────────────────────────────────────────────────────────
# Contract A ↔ Contract C binding (release side): a CLI `lease checkin` (the
# daemon exit-trap path) clears the durable lease-state so the next boot does not
# resurrect a stale lease — `has_lease` reads 0 afterward (empty service_token_id).
test_cli_checkin_clears_lease_state() {
  disable_feature
  enable_feature
  printf '%s' '{"service_token_id":"svc-gone","account_email":"op@example.com","local_token_id":"tok-lease","lease_expires_at":1751444444,"last_heartbeat_at":1}' >"$LEASE_STATE"
  chmod 600 "$LEASE_STATE"
  local fix="$SMOKE_TMP_ROOT/fix-checkin" rc
  write_fixture "$fix" checkin '{"http_status":200,"body":{}}'
  set +e
  BRIDGE_TOKEN_UPDATER_LEASE_FIXTURE_DIR="$fix" lease_py checkin --json >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 0 ]] || smoke_fail "T9e CLI checkin rc=$rc (want 0 for ok)"
  smoke_assert_eq "" "$(field service_token_id <"$LEASE_STATE")" "T9e checkin cleared service_token_id (no stale lease)"
  disable_feature
}

# ── T10 ───────────────────────────────────────────────────────────────
# ci-select routes bridge-auth.py / bridge-auth.sh to this smoke by source-file
# mapping (else CI silently skips it on a source change).
test_ci_select_routing() {
  [[ -f "$CI_SELECT" ]] || smoke_fail "T10 missing ci-select-smoke.sh: $CI_SELECT"
  local f out
  for f in bridge-auth.py bridge-auth.sh; do
    out="$(bash "$CI_SELECT" --changed-file "$f" 2>/dev/null || true)"
    smoke_assert_contains "$out" "$SMOKE_NAME" "T10 ci-select routes $f -> $SMOKE_NAME"
  done
}

smoke_run "T1 disabled/unconfigured -> every client verb OFF, NO lease-state write" test_disabled_noop
smoke_run "T2 mapping unique operator email -> ok:local_token_id (casefold)"        test_map_unique
smoke_run "T3 mapping fail-closed (missing/probe-only/ambiguous/empty)"             test_map_fail_closed
smoke_run "T4 durable lease-state round-trips exact keys at 0600"                   test_lease_state_roundtrip
smoke_run "T5 client happy path checkout/heartbeat/swap/checkin 200 -> ok"          test_client_happy
smoke_run "T6 client heartbeat 404 -> error, http surfaced"                        test_client_404
smoke_run "T7 client swap 409 nothing-usable -> conflict, http=409"                test_client_409_conflict
smoke_run "T7b non-finite server lease_expires_at -> ok, expiry None (no crash)"   test_client_nonfinite_expiry
smoke_run "T8 client transport error -> error, http=None (never raises)"           test_client_transport_error
smoke_run "T8b _parse_retry_after robust (neg/inf/Infinity/nan/date/empty -> None)" test_retry_after_robust
smoke_run "T9 CLI enabled checkout 200 -> ok + field passthrough"                  test_cli_enabled_checkout
smoke_run "T9b CLI lease heartbeat: no-lease noop / with-lease ok (Sub-PR 4 seam)"  test_cli_heartbeat
smoke_run "T9c CLI checkout PERSISTS lease-state (A↔C bind), secret NOT persisted"  test_cli_checkout_persists_lease_state
smoke_run "T9d CLI status surfaces lease + active_token_id (A↔C bind, tick inputs)" test_cli_status_surfaces_lease
smoke_run "T9e CLI checkin CLEARS lease-state (no stale lease resurrection)"        test_cli_checkin_clears_lease_state
smoke_run "T10 ci-select routing -> bridge-auth.py/.sh select this smoke"          test_ci_select_routing

smoke_log "all checks passed"
