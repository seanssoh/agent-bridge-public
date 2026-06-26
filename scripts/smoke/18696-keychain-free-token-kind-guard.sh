#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/18696-keychain-free-token-kind-guard.sh — Issue #18696.
#
# Follow-up to #2137. The keychain-free `apiKeyHelper` implements Claude Code's
# x-api-key contract, but the keychain-free path wired the active OAuth token
# (sk-ant-oat…, the .credentials.json `claudeAiOauth` root) into it. An OAT is a
# Bearer credential — valid via the native .credentials.json sync (200) but
# x-api-key-invalid (401 "Invalid API key") — so every wired agent 401'd. The
# fix adds a fail-closed TOKEN-KIND gate to the predicate: the managed
# apiKeyHelper is wired ONLY for a confirmed `api_key` (sk-ant-api…) active
# token; OAuth/OAT/unknown fail closed and route through the native sync.
#
# Drives the production bridge-auth.sh wrapper + bridge-auth.py directly in an
# isolated BRIDGE_HOME with BRIDGE_HOST_PLATFORM_OVERRIDE / the keychain-free
# gate to exercise the Darwin branch deterministically. Two static Claude agents
# are seeded: `patch` (the configured admin / interactive agent) and `librarian`
# (a non-admin static agent). The x-api-key probe is mocked via
# BRIDGE_CLAUDE_TOKEN_CHECK_BIN (no real network / API key).
#
# Acceptance tests (issue #18696):
#   B1. OAT active + `keychain-free enable` -> refused (kind gate), gate stays
#       OFF, actionable error, helper scan 0.
#   B2. OAT active + broad `backfill-settings` / `sync` -> NO apiKeyHelper for
#       ANY agent (incl. non-admin), helper scan 0, actionable skipped status;
#       the native .credentials.json is still delivered by sync.
#   B3. `api-key-helper` with an OAT -> nonzero, emits NOTHING to stdout (incl.
#       the bare emit AND the --check / --check --json follow-ups). The OAT
#       never reaches stdout.
#   B4. native `sync --agents <agent>` for an OAT -> writes .credentials.json,
#       helper scan 0 (native path unaffected).
#   B5. confirmed `api_key` token -> helper path allowed: `keychain-free enable`
#       passes the (mocked) x-api-key preflight, and a broad backfill wires the
#       managed apiKeyHelper for the non-admin agent.
#   B6. #2137 admin-exclusion + #1444 Darwin gate still intact under the kind
#       gate: a broad backfill with an api_key token excludes the admin and
#       skips entirely on a non-Darwin host (no controller-helper-path leak).
#   B7. classify_token_kind unit cases: api_key / oauth_oat / unknown / empty.
#
# Footgun #11 (heredoc_write deadlock class): plain `printf` / file-arg writes
# only; no command-substitution feeding a heredoc-stdin into a bridge function.

set -euo pipefail

SMOKE_NAME="18696-keychain-free-token-kind-guard"
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

ADMIN_AGENT="patch"
USER_AGENT="librarian"
REGISTRY="$SMOKE_TMP_ROOT/registry.json"
CONFIG_FILE="$BRIDGE_RUNTIME_CONFIG_FILE"

EXPECTED_HELPER="$(cd -P "$REPO_ROOT" && python3 -c 'import pathlib; print(pathlib.Path("scripts/claude-oat-api-key-helper.sh").resolve())')"

# Clearly-mock tokens (>=20 chars, no quote/whitespace). The PREFIX is what
# classify_token_kind keys on: sk-ant-api… = api_key, sk-ant-oat… = oauth_oat.
OAT_TOKEN="sk-ant-oat01-MOCK-not-a-real-token-AAAAAAAAAAAAAAAA"
API_TOKEN="sk-ant-api03-MOCK-not-a-real-token-BBBBBBBBBBBBBBBB"
UNKNOWN_TOKEN="totally-unprefixed-mock-token-CCCCCCCCCCCCCCCC"

# Mock `claude` for the x-api-key probe: returns a clean success result so the
# enable preflight's x-api-key probe passes for an api_key token (B5).
FAKE_BIN="$SMOKE_TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '{\"type\":\"result\",\"is_error\":false,\"result\":\"OK\"}'" >"$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"

# --- roster + per-agent settings fixtures -----------------------------------

seed_agent_lines() {
  local name="$1"
  printf 'bridge_add_agent_id_if_missing %s\n' "$name"
  printf 'BRIDGE_AGENT_DESC["%s"]="18696 smoke"\n' "$name"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$name"
  printf 'BRIDGE_AGENT_SESSION["%s"]="%s"\n' "$name" "$name"
  printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$name" "$BRIDGE_AGENT_ROOT_V2/$name/workdir"
  printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$name"
  printf 'BRIDGE_AGENT_CONTINUE["%s"]="1"\n' "$name"
}

write_roster() {
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck shell=bash disable=SC2034\n'
    printf 'BRIDGE_ADMIN_AGENT_ID="%s"\n' "$ADMIN_AGENT"
    seed_agent_lines "$ADMIN_AGENT"
    seed_agent_lines "$USER_AGENT"
  } >"$BRIDGE_ROSTER_LOCAL_FILE"
}

cfg_dir_for() { printf '%s' "$BRIDGE_AGENT_ROOT_V2/$1/home/.claude"; }

seed_legacy_settings() {
  local cfg
  cfg="$(cfg_dir_for "$1")"
  mkdir -p "$cfg"
  printf '{"skipDangerousModePermissionPrompt": true}\n' >"$cfg/settings.json"
}

helper_in() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("apiKeyHelper",""))' "$(cfg_dir_for "$1")/settings.json"
}

# Simulate a PRIOR provision that already wired our managed apiKeyHelper, so a
# later OAT-active backfill must clean it up (#18696 r2 / patch-dev #18722).
seed_managed_helper_settings() {
  local cfg
  cfg="$(cfg_dir_for "$1")"
  mkdir -p "$cfg"
  python3 -c 'import json,sys; json.dump({"skipDangerousModePermissionPrompt": True, "apiKeyHelper": sys.argv[2]}, open(sys.argv[1],"w"), indent=2)' \
    "$cfg/settings.json" "$EXPECTED_HELPER"
}

reseed_all_settings() {
  seed_legacy_settings "$ADMIN_AGENT"
  seed_legacy_settings "$USER_AGENT"
}

write_roster
reseed_all_settings

# Run the wrapper. Honors PLATFORM (default Darwin), GATE (env gate override),
# always points the registry at our crafted file, and mocks the x-api-key probe.
run_auth() {
  set +e
  BRIDGE_HOST_PLATFORM_OVERRIDE="${PLATFORM:-Darwin}" \
  BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH="${GATE:-}" \
  BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
  BRIDGE_CLAUDE_TOKEN_CHECK_BIN="$FAKE_BIN/claude" \
    bash "$AUTH_SH" "$@" >"$SMOKE_TMP_ROOT/auth.out" 2>"$SMOKE_TMP_ROOT/auth.err"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# Write a single-token registry. $1 token value (kind keyed off its prefix).
write_registry() {
  local token="$1"
  printf '{"version":1,"active_token_id":"primary","auto_rotate_enabled":false,"rotation_threshold":99.0,"weekly_warn_threshold":95.0,"tokens":[{"id":"primary","token":"%s","enabled":true,"last_check_status":"available"}],"last_rotation":{}}\n' \
    "$token" >"$REGISTRY"
}

gate_enabled_in_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf 'false'
    return 0
  fi
  python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1])).get("claude_keychain_free_auth") is True else "false")' "$CONFIG_FILE"
}

# ===========================================================================
# B1 — OAT active + keychain-free enable -> refused, gate stays off.
# ===========================================================================
test_oat_enable_refused() {
  reseed_all_settings
  write_registry "$OAT_TOKEN"
  rm -f "$CONFIG_FILE"
  local rc out
  rc="$(run_auth claude-token keychain-free enable --json)"
  out="$(cat "$SMOKE_TMP_ROOT/auth.out")"
  [[ "$rc" != "0" ]] || smoke_fail "B1 OAT enable returned rc=0 (expected fail-closed)"
  smoke_assert_contains "$out" '"status": "refused"' "B1 OAT enable is refused"
  smoke_assert_contains "$out" '"active_token_kind"' "B1 refusal surfaces the token-kind check"
  smoke_assert_contains "$out" 'oauth_oat' "B1 refusal identifies the active token as oauth_oat"
  smoke_assert_eq "false" "$(gate_enabled_in_config)" "B1 gate stays OFF after the refused enable"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" "B1 refused enable wrote no admin apiKeyHelper"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "B1 refused enable wrote no user apiKeyHelper"
}

# ===========================================================================
# B2 — OAT active + broad backfill/sync -> no helper anywhere; native cred
#      still delivered by sync; actionable skipped status.
# ===========================================================================
test_oat_broad_backfill_and_sync_no_helper() {
  reseed_all_settings
  write_registry "$OAT_TOKEN"
  # Broad backfill: refused for the OAT pool, no helper for anyone.
  local rc out direct
  rc="$(GATE=1 run_auth claude-token backfill-settings --json)"
  smoke_assert_eq "0" "$rc" "B2 broad backfill rc 0 (skipped, not error)"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "B2 OAT broad backfill writes NO non-admin apiKeyHelper"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" "B2 OAT broad backfill writes NO admin apiKeyHelper"

  # The per-agent verb carries the ACTIONABLE kind reason (the broad aggregate
  # buckets it as `unchanged` — the operator-facing detail lives in the verb).
  direct="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    python3 "$AUTH_PY" --registry "$REGISTRY" backfill-settings \
      --config-dir "$(cfg_dir_for "$USER_AGENT")" --agent "$USER_AGENT" --json 2>&1)"
  smoke_assert_contains "$direct" 'active_token_not_api_key' "B2 backfill verb reports the actionable kind reason"
  smoke_assert_contains "$direct" 'native' "B2 backfill verb points the operator at the native sync path"

  # Broad sync: still delivers the native .credentials.json, but no helper.
  reseed_all_settings
  rc="$(GATE=1 run_auth claude-token sync --json)"
  smoke_assert_eq "0" "$rc" "B2 broad sync rc 0"
  smoke_assert_file_exists "$(cfg_dir_for "$USER_AGENT")/.credentials.json" \
    "B2 OAT sync still delivers the native .credentials.json (Bearer path unaffected)"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" \
    "B2 OAT sync does NOT wire the apiKeyHelper for the non-admin agent (helper scan 0)"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" \
    "B2 OAT sync does NOT wire the apiKeyHelper for the admin agent"
}

# ===========================================================================
# B2b — OAT active + a STALE managed apiKeyHelper already in settings.json:
#       a mutating backfill must REMOVE it (route through ensure_claude_settings_file
#       so the launch falls back to native .credentials.json), and `--check` must
#       stay read-only and report drift. Without this, the helper floor blocks the
#       token leak but the launched Claude still sees settings.json pointing at the
#       (now-refusing) helper — the auth-death shape. (#18696 r2 / patch-dev #18722)
# ===========================================================================
test_oat_backfill_removes_stale_managed_helper() {
  write_registry "$OAT_TOKEN"

  # Precondition: a prior provision left our managed helper wired.
  seed_managed_helper_settings "$USER_AGENT"
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$USER_AGENT")" \
    "B2b precondition: a stale managed apiKeyHelper is present"

  # --check is read-only: reports drift, removes nothing.
  local out
  out="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    python3 "$AUTH_PY" --registry "$REGISTRY" backfill-settings \
      --config-dir "$(cfg_dir_for "$USER_AGENT")" --agent "$USER_AGENT" --check --json 2>&1)"
  smoke_assert_contains "$out" '"drift": true' "B2b --check reports drift for a stale helper on an OAT agent"
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$USER_AGENT")" \
    "B2b --check is read-only: the stale helper is NOT removed"

  # Mutating backfill: REMOVES the stale managed helper.
  out="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    python3 "$AUTH_PY" --registry "$REGISTRY" backfill-settings \
      --config-dir "$(cfg_dir_for "$USER_AGENT")" --agent "$USER_AGENT" --json 2>&1)"
  smoke_assert_contains "$out" '"helper_removed": true' "B2b mutating backfill reports helper_removed"
  smoke_assert_contains "$out" '"coherent": true' "B2b reports coherent:true after cleanup"
  smoke_assert_not_contains "$out" "$OAT_TOKEN" "B2b the OAT never reaches stdout"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" \
    "B2b mutating backfill REMOVED the stale managed apiKeyHelper (launch falls back to native)"

  # Idempotent: a second mutating backfill is a true no-op (nothing to clean).
  out="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    python3 "$AUTH_PY" --registry "$REGISTRY" backfill-settings \
      --config-dir "$(cfg_dir_for "$USER_AGENT")" --agent "$USER_AGENT" --json 2>&1)"
  smoke_assert_contains "$out" '"helper_removed": false' "B2b re-run is a no-op (already coherent)"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "B2b re-run keeps the helper absent"

  # managed-but-not-current (override) case (#18696 r3 / patch-dev #18731): a
  # stale in-repo DEFAULT managed helper while BRIDGE_CLAUDE_API_KEY_HELPER points
  # elsewhere. settings_apikeyhelper_coherent() would MISS it (value != current
  # override path), but apikeyhelper_value_is_bridge_managed() treats the default
  # as ours — so the cleanup MUST still remove it (was the r2 gap).
  seed_managed_helper_settings "$USER_AGENT"   # seeds the in-repo DEFAULT helper path
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$USER_AGENT")" \
    "B2b(override) precondition: the default managed helper is present"
  out="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    BRIDGE_CLAUDE_API_KEY_HELPER="$SMOKE_TMP_ROOT/custom-operator-helper.sh" \
    python3 "$AUTH_PY" --registry "$REGISTRY" backfill-settings \
      --config-dir "$(cfg_dir_for "$USER_AGENT")" --agent "$USER_AGENT" --json 2>&1)"
  smoke_assert_contains "$out" '"helper_removed": true' \
    "B2b(override) removes a stale managed-DEFAULT helper even under a custom override"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" \
    "B2b(override) the default managed helper is gone (broad managed predicate)"

  # And `--check` reports drift for the same managed-but-not-current case.
  seed_managed_helper_settings "$USER_AGENT"
  out="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    BRIDGE_CLAUDE_API_KEY_HELPER="$SMOKE_TMP_ROOT/custom-operator-helper.sh" \
    python3 "$AUTH_PY" --registry "$REGISTRY" backfill-settings \
      --config-dir "$(cfg_dir_for "$USER_AGENT")" --agent "$USER_AGENT" --check --json 2>&1)"
  smoke_assert_contains "$out" '"drift": true' \
    "B2b(override) --check reports drift for a managed-default helper under override"
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$USER_AGENT")" \
    "B2b(override) --check stays read-only (helper not removed)"
}

# ===========================================================================
# B3 — api-key-helper with an OAT: nonzero, NOTHING to stdout (the OAT must
#      never reach stdout), on the emit path AND the --check / --check --json
#      follow-ups.
# ===========================================================================
test_api_key_helper_oat_emits_nothing() {
  write_registry "$OAT_TOKEN"
  local rc out
  # Bare emit (the production helper path).
  set +e
  out="$(BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
    python3 "$AUTH_PY" --registry "$REGISTRY" api-key-helper 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || smoke_fail "B3 api-key-helper emit returned rc=0 for an OAT (expected refusal)"
  smoke_assert_eq "" "$out" "B3 api-key-helper emit wrote NOTHING to stdout for an OAT"
  smoke_assert_not_contains "$out" "$OAT_TOKEN" "B3 the OAT never reached stdout (emit)"

  # --check (non-json): refusal to stderr, empty stdout.
  set +e
  out="$(BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
    python3 "$AUTH_PY" --registry "$REGISTRY" api-key-helper --check 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || smoke_fail "B3 api-key-helper --check returned rc=0 for an OAT"
  smoke_assert_eq "" "$out" "B3 api-key-helper --check wrote NOTHING to stdout for an OAT"

  # --check --json: structured refusal carries the KIND but never the token.
  set +e
  out="$(BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
    python3 "$AUTH_PY" --registry "$REGISTRY" api-key-helper --check --json 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || smoke_fail "B3 api-key-helper --check --json returned rc=0 for an OAT"
  smoke_assert_contains "$out" '"status": "refused"' "B3 --check --json reports refused for an OAT"
  smoke_assert_contains "$out" '"helper_eligible": false' "B3 --check --json reports helper_eligible:false"
  smoke_assert_not_contains "$out" "$OAT_TOKEN" "B3 the OAT never reached stdout (--check --json)"
}

# ===========================================================================
# B4 — native sync for an OAT writes .credentials.json, helper scan 0.
# ===========================================================================
test_native_sync_oat_writes_credentials() {
  reseed_all_settings
  write_registry "$OAT_TOKEN"
  local rc
  rc="$(GATE=1 run_auth claude-token sync --agents "$USER_AGENT" --json)"
  smoke_assert_eq "0" "$rc" "B4 native sync rc 0"
  smoke_assert_file_exists "$(cfg_dir_for "$USER_AGENT")/.credentials.json" \
    "B4 native sync writes the per-agent .credentials.json (Bearer path)"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "B4 native sync wires NO apiKeyHelper (helper scan 0)"
}

# ===========================================================================
# B5 — confirmed api_key token: helper path allowed (enable passes the mocked
#      x-api-key preflight; broad backfill wires the non-admin helper).
# ===========================================================================
test_api_key_helper_path_allowed() {
  reseed_all_settings
  write_registry "$API_TOKEN"
  rm -f "$CONFIG_FILE"
  local rc out
  rc="$(run_auth claude-token keychain-free enable --json)"
  out="$(cat "$SMOKE_TMP_ROOT/auth.out")"
  smoke_assert_eq "0" "$rc" "B5 api_key keychain-free enable succeeds (mocked x-api-key preflight passes)"
  smoke_assert_eq "true" "$(gate_enabled_in_config)" "B5 gate flipped ON for an api_key token"
  smoke_assert_contains "$out" 'x_api_key_probe' "B5 preflight exercised the real x-api-key probe path"

  # A broad backfill wires the managed helper for the non-admin agent.
  rc="$(GATE=1 run_auth claude-token backfill-settings --json)"
  smoke_assert_eq "0" "$rc" "B5 api_key broad backfill rc 0"
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$USER_AGENT")" \
    "B5 api_key broad backfill wires the managed apiKeyHelper for the non-admin agent"
}

# ===========================================================================
# B6 — #2137 admin-exclusion + #1444 Darwin gate intact under the kind gate.
# ===========================================================================
test_2137_and_1444_intact_under_kind_gate() {
  reseed_all_settings
  write_registry "$API_TOKEN"
  # Admin-exclusion: broad backfill never touches the admin even for api_key.
  local rc
  rc="$(GATE=1 run_auth claude-token backfill-settings --json)"
  smoke_assert_eq "0" "$rc" "B6 broad backfill rc 0"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" \
    "B6 #2137 admin-exclusion holds under the kind gate (admin not backfilled broadly)"
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$USER_AGENT")" \
    "B6 non-admin api_key agent still backfilled under broad scope"

  # #1444 Darwin gate: non-Darwin is a no-op (no controller-helper-path leak).
  reseed_all_settings
  rc="$(PLATFORM=Linux GATE=1 run_auth claude-token backfill-settings --json)"
  smoke_assert_eq "0" "$rc" "B6 non-Darwin backfill rc 0 (skipped)"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" \
    "B6 #1444 Darwin gate holds: non-Darwin writes NO apiKeyHelper even for an api_key token"
}

# ===========================================================================
# B7 — classify_token_kind direct unit cases.
# ===========================================================================
test_classify_token_kind_units() {
  python3 - "$AUTH_PY" "$API_TOKEN" "$OAT_TOKEN" "$UNKNOWN_TOKEN" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("bridge_auth", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
classify = mod.classify_token_kind

cases = [
    (sys.argv[2], "api_key"),
    (sys.argv[3], "oauth_oat"),
    (sys.argv[4], "unknown"),
    ("", "unknown"),
    ("   ", "unknown"),
]
for token, expected in cases:
    got = classify(token)
    if got != expected:
        raise SystemExit(f"classify_token_kind({token[:12]!r}...) = {got!r}, expected {expected!r}")
# A None / non-str is fail-closed unknown, never api_key.
if classify(None) != "unknown":  # type: ignore[arg-type]
    raise SystemExit("classify_token_kind(None) must be 'unknown' (fail-closed)")
print("classify_token_kind units OK")
PY
  smoke_assert_eq "0" "$?" "B7 classify_token_kind unit cases pass"
}

# ===========================================================================
# B8 — bridge-cron-runner.py keychain-free preflight falls back to native for an
#      OAT/unknown active token (mirror of the bridge-run.sh kind gate): the
#      cron launch must NOT raise/fail-before-launch for the OAT pool — it routes
#      through the native .credentials.json instead.
# ===========================================================================
test_cron_runner_oat_native_fallback() {
  reseed_all_settings
  write_registry "$OAT_TOKEN"
  local cfg out rc
  cfg="$(cfg_dir_for "$USER_AGENT")"   # legacy settings.json, NO apiKeyHelper
  set +e
  out="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
    python3 - "$REPO_ROOT/bridge-cron-runner.py" "$cfg" <<'PY' 2>&1
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("bridge_cron_runner", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
# An OAT active token must take the native-credential fallback (no exception),
# not the old helper-required preflight that raised before launch.
mod.validate_claude_keychain_free_auth(Path(sys.argv[2]))
print("cron keychain-free preflight: native fallback (no raise) for OAT")
PY
)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" "B8 cron keychain-free preflight does NOT raise for an OAT (native fallback)"
  smoke_assert_contains "$out" "native fallback" "B8 cron preflight reports the OAT native fallback"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "B8 cron OAT path leaves settings.json helper-free (scan 0)"
}

smoke_run "B1 OAT keychain-free enable is refused (kind gate), gate stays off"  test_oat_enable_refused
smoke_run "B2 OAT broad backfill/sync wire no helper; native cred delivered"    test_oat_broad_backfill_and_sync_no_helper
smoke_run "B2b OAT backfill REMOVES a stale managed helper; --check read-only"   test_oat_backfill_removes_stale_managed_helper
smoke_run "B3 api-key-helper refuses an OAT, emits nothing to stdout"           test_api_key_helper_oat_emits_nothing
smoke_run "B4 native sync for an OAT writes .credentials.json, helper scan 0"   test_native_sync_oat_writes_credentials
smoke_run "B5 confirmed api_key token: helper path allowed (mocked preflight)"  test_api_key_helper_path_allowed
smoke_run "B6 #2137 admin-exclusion + #1444 Darwin gate intact under kind gate" test_2137_and_1444_intact_under_kind_gate
smoke_run "B7 classify_token_kind unit cases (api_key/oauth_oat/unknown/empty)" test_classify_token_kind_units
smoke_run "B8 cron-runner keychain-free preflight native-fallback for an OAT"   test_cron_runner_oat_native_fallback

smoke_log "all checks passed"
