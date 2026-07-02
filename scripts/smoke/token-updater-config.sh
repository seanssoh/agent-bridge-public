#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/token-updater-config.sh — #21895 phase-1, sub-PR 1/4 (HIGH-RISK auth).
#
# The token-updater lease CONFIG surface + setup wizard, default-OFF. This
# sub-PR ships ONLY persistence + the `lease status`/`--check` probe — NO lease
# HTTP client, NO rotator wiring, NO daemon tick (later sub-PRs). The load-
# bearing invariant this smoke pins: disabled/unconfigured == byte-for-byte no
# behavior change.
#
# Isolation: a temp BRIDGE_HOME via smoke_setup_bridge_home; the runtime-secrets
# dir is pinned under it. NEVER touches the real ~/.claude or ~/.agent-bridge.
#
# Cases:
#   T1  unconfigured: `lease status --check` -> OFF (rc=1); NO runtime-config /
#       secret file written; the config surfaces are untouched
#   T2  `lease config` persists URL/SERVER_ID/ENABLED to runtime-config JSON and
#       the API KEY to a 0600 secret file; the secret is NOT in runtime-config
#   T3  `--check` gate exit codes: fully enabled -> 0, disabled -> nonzero
#   T4  the `set-env` config verb still DENIES TOKEN_UPDATER_API_KEY (deny
#       intact), and the other TOKEN_UPDATER_* names too (TOKEN substring)
#   T5  conjunctive gate: ENABLED persisted but NOT fully configured -> OFF
#   T6  the secret NEVER comes through argv (stdin/file only) and round-trips
#   T7  bash wrapper plumbing: bridge-auth.sh claude-token lease -> bridge-auth.py;
#       unknown flag fails closed (rc=2)
#   T8  setup wizard delegates to the sanctioned writer (dry-run writes nothing;
#       real run persists via bridge-auth.py; secret 0600, not in config JSON)
#   T9  an explicit-but-empty/whitespace key source is REFUSED fail-closed (CLI
#       + wizard, stdin + file); the existing secret survives the refusal intact
#   T10 ci-select routing: bridge-auth.py / bridge-config.py / bridge-setup.py
#       and the smoke file all select this smoke

set -uo pipefail

SMOKE_NAME="token-updater-config"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"
SETUP_PY="$REPO_ROOT/bridge-setup.py"
CI_SELECT="$REPO_ROOT/scripts/ci-select-smoke.sh"
HELPER="$SCRIPT_DIR/token-updater-config-helper.py"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing bridge-auth.py: $AUTH_PY"
[[ -f "$AUTH_SH" ]] || smoke_fail "missing bridge-auth.sh: $AUTH_SH"
[[ -f "$SETUP_PY" ]] || smoke_fail "missing bridge-setup.py: $SETUP_PY"
[[ -f "$HELPER" ]] || smoke_fail "missing helper: $HELPER"

# smoke_setup_bridge_home exports BRIDGE_RUNTIME_ROOT + BRIDGE_RUNTIME_CONFIG_FILE
# but NOT the secrets dir — pin it under the isolated runtime root (mirrors
# bridge-lib.sh's `$BRIDGE_RUNTIME_ROOT/secrets` default).
export BRIDGE_RUNTIME_SECRETS_DIR="$BRIDGE_RUNTIME_ROOT/secrets"
mkdir -p "$BRIDGE_RUNTIME_SECRETS_DIR"
# A dummy registry path (the lease verb never reads it, but --registry is
# mandatory on bridge-auth.py). Do NOT seed it — a bare path is fine.
REGISTRY="$BRIDGE_RUNTIME_SECRETS_DIR/registry.json"
CFG="$BRIDGE_RUNTIME_CONFIG_FILE"
SECRET="$BRIDGE_RUNTIME_SECRETS_DIR/token-updater-api-key"
# A benign, non-credential-shaped fixture secret (nothing resembling a real key).
FIXTURE_KEY="tu-fixture-secret-0123456789abcdef"

field() { python3 "$HELPER" json-field "$1"; }
file_mode() { python3 "$HELPER" file-mode "$1"; }

# bridge-auth.py lease <args...>
lease_py() { python3 "$AUTH_PY" --registry "$REGISTRY" lease "$@"; }

reset_surfaces() {
  rm -f "$CFG" "$SECRET"
}

# ── T1 ────────────────────────────────────────────────────────────────
# Unconfigured => `status --check` OFF (rc=1), NO files written, surfaces
# byte-for-byte untouched. This is the default-OFF no-op invariant.
test_unconfigured_noop() {
  reset_surfaces
  local rc out
  set +e
  lease_py status --check >/dev/null 2>&1
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T1 status --check returned 0 while unconfigured (must be OFF)"
  [[ ! -f "$CFG" ]] || smoke_fail "T1 runtime-config was written while unconfigured: $CFG"
  [[ ! -f "$SECRET" ]] || smoke_fail "T1 secret file was written while unconfigured: $SECRET"
  out="$(lease_py status --json)"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field enabled)" "T1 enabled=False unconfigured"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field persisted_enabled)" "T1 persisted_enabled=False"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field configured)" "T1 configured=False"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field api_key_present)" "T1 api_key_present=False"
}

# ── T2 ────────────────────────────────────────────────────────────────
# `config` persists URL/SERVER_ID/ENABLED to runtime-config JSON and the API KEY
# to a 0600 secret file; the secret is NOT in the runtime-config JSON.
test_config_persist_split() {
  reset_surfaces
  local out
  out="$(printf '%s' "$FIXTURE_KEY" | lease_py config \
    --api-url "https://lease.example.com" --server-id "srv-1" --enabled --api-key-stdin --json)"
  smoke_assert_eq "ok" "$(printf '%s' "$out" | field status)" "T2 config status=ok"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field secret_written)" "T2 secret_written=True"
  [[ -f "$CFG" ]] || smoke_fail "T2 runtime-config not written: $CFG"
  [[ -f "$SECRET" ]] || smoke_fail "T2 secret file not written: $SECRET"
  # Non-secret keys landed in runtime-config JSON.
  local cfg_json; cfg_json="$(cat "$CFG")"
  smoke_assert_eq "https://lease.example.com" \
    "$(printf '%s' "$cfg_json" | field token_updater_api_url)" "T2 url in runtime-config"
  smoke_assert_eq "srv-1" \
    "$(printf '%s' "$cfg_json" | field token_updater_server_id)" "T2 server_id in runtime-config"
  smoke_assert_eq "True" \
    "$(printf '%s' "$cfg_json" | field token_updater_enabled)" "T2 enabled in runtime-config"
  # Secret is 0600 and NOT present in runtime-config JSON.
  smoke_assert_eq "600" "$(file_mode "$SECRET")" "T2 secret file mode 0600 (owner-only)"
  smoke_assert_eq "$FIXTURE_KEY" "$(cat "$SECRET")" "T2 secret round-trips verbatim"
  smoke_assert_not_contains "$cfg_json" "$FIXTURE_KEY" "T2 secret NOT in runtime-config JSON"
  smoke_assert_not_contains "$cfg_json" "token_updater_api_key" "T2 no api_key key in runtime-config JSON"
}

# ── T3 ────────────────────────────────────────────────────────────────
# `--check` gate exit codes: fully enabled -> 0, disabled -> nonzero.
test_check_gate_exit_codes() {
  reset_surfaces
  printf '%s' "$FIXTURE_KEY" | lease_py config \
    --api-url "https://lease.example.com" --server-id "srv-1" --enabled --api-key-stdin --json >/dev/null
  local rc
  set +e
  lease_py status --check >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 0 ]] || smoke_fail "T3 status --check rc=$rc for fully enabled (want 0)"
  lease_py config --disabled --json >/dev/null
  set +e
  lease_py status --check >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T3 status --check rc=0 after --disabled (want nonzero)"
}

# ── T4 ────────────────────────────────────────────────────────────────
# The `set-env` config verb still DENIES TOKEN_UPDATER_API_KEY (the deny at
# bridge-config.py ENV_KEY_DENY_SUBSTRINGS stays intact). The other TOKEN_UPDATER_*
# names also carry the TOKEN substring and are denied too — proving none of them
# can be smuggled through the durable env-override path.
test_setenv_deny_intact() {
  local reason
  reason="$(python3 "$HELPER" deny-reason TOKEN_UPDATER_API_KEY)"
  smoke_assert_contains "$reason" "forbidden" "T4 TOKEN_UPDATER_API_KEY denied by set-env"
  smoke_assert_contains "$reason" "TOKEN" "T4 deny cites the TOKEN substring screen"
  reason="$(python3 "$HELPER" deny-reason TOKEN_UPDATER_API_URL)"
  smoke_assert_contains "$reason" "forbidden" "T4 TOKEN_UPDATER_API_URL denied by set-env"
  reason="$(python3 "$HELPER" deny-reason TOKEN_UPDATER_ENABLED)"
  smoke_assert_contains "$reason" "forbidden" "T4 TOKEN_UPDATER_ENABLED denied by set-env"
}

# ── T5 ────────────────────────────────────────────────────────────────
# Conjunctive gate: ENABLED persisted but the triple is NOT complete (no secret)
# => effective OFF. An operator who flips ENABLED before finishing the wizard
# stays OFF rather than half-activating a lease path that would fail every call.
test_conjunctive_gate() {
  reset_surfaces
  # Persist url + server + ENABLED but NO secret.
  lease_py config --api-url "https://lease.example.com" --server-id "srv-1" --enabled --json >/dev/null
  local out rc
  out="$(lease_py status --json)"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field persisted_enabled)" "T5 persisted_enabled=True"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field configured)" "T5 configured=False (no secret)"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field enabled)" "T5 effective enabled=False (conjunctive)"
  set +e
  lease_py status --check >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T5 status --check rc=0 with ENABLED-but-unconfigured (want nonzero)"
}

# ── T6 ────────────────────────────────────────────────────────────────
# The secret NEVER comes through argv: --api-key-file / --api-key-stdin only.
# Round-trip a key via a file and confirm the 0600 write + verbatim read.
test_secret_from_file() {
  reset_surfaces
  local keyfile="$SMOKE_TMP_ROOT/key.txt"
  printf '%s\n' "$FIXTURE_KEY" >"$keyfile"
  lease_py config --api-url "https://lease.example.com" --server-id "srv-1" \
    --enabled --api-key-file "$keyfile" --json >/dev/null
  [[ -f "$SECRET" ]] || smoke_fail "T6 secret not written from --api-key-file"
  smoke_assert_eq "600" "$(file_mode "$SECRET")" "T6 file-sourced secret is 0600"
  smoke_assert_eq "$FIXTURE_KEY" "$(cat "$SECRET")" "T6 file-sourced secret round-trips (trailing NL stripped)"
}

# ── T7 ────────────────────────────────────────────────────────────────
# bash wrapper plumbing: bridge-auth.sh claude-token lease -> bridge-auth.py.
# An unknown flag fails closed (rc=2); the happy path persists end-to-end.
test_bash_wrapper_plumbing() {
  reset_surfaces
  local rc out
  set +e
  bash "$AUTH_SH" claude-token lease status --bogus-flag >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 2 ]] || smoke_fail "T7 wrapper unknown flag rc=$rc (must fail closed rc=2)"
  out="$(printf '%s' "$FIXTURE_KEY" | bash "$AUTH_SH" claude-token lease config \
    --api-url "https://lease.example.com" --server-id "srv-1" --enabled --api-key-stdin --json)"
  smoke_assert_eq "ok" "$(printf '%s' "$out" | field status)" "T7 wrapper config status=ok"
  set +e
  bash "$AUTH_SH" claude-token lease status --check >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 0 ]] || smoke_fail "T7 wrapper status --check rc=$rc after enable (want 0)"
}

# ── T8 ────────────────────────────────────────────────────────────────
# setup wizard delegates to the sanctioned writer. Dry-run writes NOTHING; a
# real run persists via bridge-auth.py (secret 0600, not in config JSON).
test_setup_wizard_delegates() {
  reset_surfaces
  # Dry-run: no files written.
  printf '%s' "$FIXTURE_KEY" | python3 "$SETUP_PY" token-updater \
    --api-url "https://lease.example.com" --server-id "srv-w" \
    --api-key-stdin --enable --dry-run --yes >/dev/null
  [[ ! -f "$CFG" ]] || smoke_fail "T8 wizard --dry-run wrote runtime-config"
  [[ ! -f "$SECRET" ]] || smoke_fail "T8 wizard --dry-run wrote the secret"
  # Real run: persists via the delegated writer.
  local out
  out="$(printf '%s' "$FIXTURE_KEY" | python3 "$SETUP_PY" token-updater \
    --api-url "https://lease.example.com" --server-id "srv-w" \
    --api-key-stdin --enable --yes)"
  smoke_assert_contains "$out" "write_status: ok" "T8 wizard real run write_status: ok"
  [[ -f "$CFG" ]] || smoke_fail "T8 wizard did not persist runtime-config"
  [[ -f "$SECRET" ]] || smoke_fail "T8 wizard did not persist the secret"
  smoke_assert_eq "600" "$(file_mode "$SECRET")" "T8 wizard secret is 0600"
  smoke_assert_not_contains "$(cat "$CFG")" "$FIXTURE_KEY" "T8 wizard secret NOT in runtime-config JSON"
  # And the effective gate is now ON.
  local rc
  set +e
  lease_py status --check >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 0 ]] || smoke_fail "T8 status --check rc=$rc after wizard enable (want 0)"
}

# ── T9 (codex r1) ──────────────────────────────────────────────────────
# A key SOURCE that yields an empty/whitespace value is REFUSED fail-closed —
# never a silent skip that could leave a stale secret active. Covers BOTH the
# CLI verb and the wizard, via stdin and file. Also proves the EXISTING secret
# is left byte-for-byte unchanged on the refusal (no partial clobber).
test_empty_key_source_refused() {
  reset_surfaces
  # Seed a good secret first so we can assert it survives a later refusal.
  printf '%s' "$FIXTURE_KEY" | lease_py config \
    --api-url "https://lease.example.com" --server-id "srv-1" --enabled --api-key-stdin --json >/dev/null
  local before_ck; before_ck="$(cksum <"$SECRET")"
  local rc

  # CLI: empty stdin key source => rc!=0, secret unchanged.
  set +e
  printf '' | lease_py config --server-id "srv-2" --api-key-stdin --json >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T9 CLI empty --api-key-stdin returned 0 (must refuse)"
  smoke_assert_eq "$before_ck" "$(cksum <"$SECRET")" "T9 CLI refusal left the existing secret unchanged"

  # CLI: whitespace-only file key source => rc!=0.
  local blankfile="$SMOKE_TMP_ROOT/blank.txt"
  printf '   \n' >"$blankfile"
  set +e
  lease_py config --server-id "srv-3" --api-key-file "$blankfile" --json >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T9 CLI whitespace --api-key-file returned 0 (must refuse)"

  # Wizard: empty stdin key source => rc!=0.
  set +e
  printf '' | python3 "$SETUP_PY" token-updater --server-id "srv-w2" --api-key-stdin --yes >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T9 wizard empty --api-key-stdin returned 0 (must refuse)"

  # Wizard: whitespace-only file key source => rc!=0.
  set +e
  python3 "$SETUP_PY" token-updater --server-id "srv-w3" --api-key-file "$blankfile" --yes >/dev/null 2>&1; rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T9 wizard whitespace --api-key-file returned 0 (must refuse)"
}

# ── T10 ───────────────────────────────────────────────────────────────
# ci-select routes bridge-auth.py / bridge-config.py / bridge-setup.py /
# bridge-setup.sh to this smoke by source-file mapping. (A change to the smoke
# file itself falls under the scripts/smoke/* catch-all that runs the FULL
# static suite — which includes this smoke — so there is no per-file self-map to
# assert; the source-file mappings above are the wiring that keeps this smoke
# from being silently skipped on a source change.)
test_ci_select_routing() {
  [[ -f "$CI_SELECT" ]] || smoke_fail "T10 missing ci-select-smoke.sh: $CI_SELECT"
  local f out
  for f in bridge-auth.py bridge-auth.sh bridge-config.py bridge-setup.py bridge-setup.sh; do
    out="$(bash "$CI_SELECT" --changed-file "$f" 2>/dev/null || true)"
    smoke_assert_contains "$out" "$SMOKE_NAME" "T10 ci-select routes $f -> $SMOKE_NAME"
  done
}

smoke_run "T1 unconfigured -> status --check OFF, NO write, surfaces untouched" test_unconfigured_noop
smoke_run "T2 config persists URL/SERVER_ID/ENABLED + 0600 secret (not in JSON)" test_config_persist_split
smoke_run "T3 --check gate exit codes (enabled 0 / disabled nonzero)"           test_check_gate_exit_codes
smoke_run "T4 set-env verb still DENIES TOKEN_UPDATER_API_KEY (deny intact)"      test_setenv_deny_intact
smoke_run "T5 conjunctive gate: ENABLED-but-unconfigured -> effective OFF"        test_conjunctive_gate
smoke_run "T6 secret from --api-key-file -> 0600, verbatim round-trip"            test_secret_from_file
smoke_run "T7 bash wrapper plumbing + unknown-flag fail-closed (rc=2)"            test_bash_wrapper_plumbing
smoke_run "T8 setup wizard delegates (dry-run no-op; real run persists 0600)"     test_setup_wizard_delegates
smoke_run "T9 empty/whitespace key source refused (CLI+wizard, secret intact)"    test_empty_key_source_refused
smoke_run "T10 ci-select routing -> auth/config/setup + smoke selected"          test_ci_select_routing

smoke_log "all checks passed"
