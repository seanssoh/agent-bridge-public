#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2137-keychain-free-scope-guard.sh — Issue #2137.
#
# Pins the keychain-free auth hardening after a live macOS incident where the
# keychain-free apiKeyHelper backfill silently moved the interactive admin
# (`patch`) from Claude.ai/keychain auth onto apiKeyHelper / API-key billing —
# producing `Invalid API key` — without an explicit `--agents patch`, and where
# a diagnostic `backfill-settings --help` executed the mutating path.
#
# Drives the production bridge-auth.sh wrapper + bridge-auth.py directly in an
# isolated BRIDGE_HOME with BRIDGE_HOST_PLATFORM_OVERRIDE / the keychain-free
# gate to exercise the Darwin branch deterministically. Two static Claude agents
# are seeded: `patch` (the configured admin / interactive agent) and `librarian`
# (a non-admin static agent).
#
# Acceptance tests (issue #2137):
#   A1. `backfill-settings --help` -> usage text, rc 0, NO per-agent iteration.
#   A2. `backfill-settings --bogus` -> nonzero, no writes.
#   A3. gate ON, no `--agents` (broad default static) -> admin (`patch`) NOT
#       mutated; the non-admin static agent (`librarian`) IS backfilled.
#   A4. gate ON, `--agents librarian` -> only librarian gets the managed helper.
#   A4b. gate ON, `--agents patch` (explicit opt-in) -> the admin DOES get it.
#   A5. gate OFF -> backfill does not resurrect a helper, and the settings writer
#       removes a bridge-managed helper.
#   A6. `keychain-free enable` fails closed when the active OAT is unhealthy:
#       gate stays off, no managed helper written into the interactive admin.
#   A6b/c. `keychain-free enable` with a healthy OAT flips the gate; `disable`
#       flips it back; unknown flag fails closed.
#
# Footgun #11 (heredoc_write deadlock class): plain `printf` / file-arg writes
# only; no command-substitution feeding a heredoc-stdin into a bridge function.

set -euo pipefail

SMOKE_NAME="2137-keychain-free-scope-guard"
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

# --- roster + per-agent settings fixtures -----------------------------------

seed_agent_lines() {
  local name="$1"
  printf 'bridge_add_agent_id_if_missing %s\n' "$name"
  printf 'BRIDGE_AGENT_DESC["%s"]="2137 smoke"\n' "$name"
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

# (re)seed a legacy settings.json (present, valid, NO apiKeyHelper) for an agent.
seed_legacy_settings() {
  local cfg
  cfg="$(cfg_dir_for "$1")"
  mkdir -p "$cfg"
  printf '{"skipDangerousModePermissionPrompt": true}\n' >"$cfg/settings.json"
}

helper_in() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("apiKeyHelper",""))' "$(cfg_dir_for "$1")/settings.json"
}

reseed_all_settings() {
  seed_legacy_settings "$ADMIN_AGENT"
  seed_legacy_settings "$USER_AGENT"
}

write_roster
reseed_all_settings

# Run the wrapper. Honors PLATFORM (default Darwin), GATE (env gate override),
# and always points the registry at our crafted file. Echoes rc; stdout/stderr
# captured into auth.out / auth.err.
run_auth() {
  set +e
  BRIDGE_HOST_PLATFORM_OVERRIDE="${PLATFORM:-Darwin}" \
  BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH="${GATE:-}" \
  BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
    bash "$AUTH_SH" "$@" >"$SMOKE_TMP_ROOT/auth.out" 2>"$SMOKE_TMP_ROOT/auth.err"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# Write a single-line claude-token registry. $1 active_id ("" for none),
# $2 enabled (true|false), $3 last_check_status.
TOKEN_40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
write_registry() {
  local active="$1" enabled="$2" status="$3"
  printf '{"version":1,"active_token_id":"%s","auto_rotate_enabled":false,"rotation_threshold":99.0,"weekly_warn_threshold":95.0,"tokens":[{"id":"primary","token":"%s","enabled":%s,"last_check_status":"%s"}],"last_rotation":{}}\n' \
    "$active" "$TOKEN_40" "$enabled" "$status" >"$REGISTRY"
}

gate_enabled_in_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf 'false'
    return 0
  fi
  python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1])).get("claude_keychain_free_auth") is True else "false")' "$CONFIG_FILE"
}

# ===========================================================================
# A1 — `backfill-settings --help` prints usage, rc 0, no per-agent iteration.
# ===========================================================================
test_help_prints_usage_no_iteration() {
  reseed_all_settings
  local rc out
  rc="$(GATE=1 run_auth claude-token backfill-settings --help)"
  out="$(cat "$SMOKE_TMP_ROOT/auth.out")"
  smoke_assert_eq "0" "$rc" "A1 --help exits 0"
  smoke_assert_contains "$out" "Usage:" "A1 --help prints usage text"
  smoke_assert_not_contains "$out" '"backfilled"' "A1 --help does not iterate agents (no aggregate)"
  smoke_assert_not_contains "$out" '"status": "skipped"' "A1 --help does not emit per-agent skip rows"
  # No write happened to either agent.
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" "A1 --help wrote no admin apiKeyHelper"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "A1 --help wrote no user apiKeyHelper"
}

# ===========================================================================
# A2 — unknown flag fails closed (nonzero), no writes.
# ===========================================================================
test_unknown_flag_fails_closed() {
  reseed_all_settings
  local rc err
  rc="$(GATE=1 run_auth claude-token backfill-settings --definitely-not-a-real-flag --json)"
  err="$(cat "$SMOKE_TMP_ROOT/auth.err")"
  [[ "$rc" != "0" ]] || smoke_fail "A2 unknown flag returned rc=0 (expected nonzero)"
  smoke_assert_contains "$err" "unknown flag" "A2 unknown flag emits a deny reason"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" "A2 unknown flag wrote no admin apiKeyHelper"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "A2 unknown flag wrote no user apiKeyHelper"
}

# ===========================================================================
# A3 — gate ON, broad default scope: admin NOT mutated, non-admin backfilled.
# ===========================================================================
test_broad_scope_excludes_admin() {
  reseed_all_settings
  local rc out
  rc="$(GATE=1 run_auth claude-token backfill-settings --json)"
  out="$(cat "$SMOKE_TMP_ROOT/auth.out")"
  smoke_assert_eq "0" "$rc" "A3 broad-scope backfill rc 0"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" \
    "A3 admin/interactive agent NOT moved onto apiKeyHelper under broad scope"
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$USER_AGENT")" \
    "A3 non-admin static agent IS backfilled under broad scope"
  smoke_assert_contains "$out" "\"$USER_AGENT\"" "A3 aggregate lists the non-admin agent"
  smoke_assert_not_contains "$out" "\"$ADMIN_AGENT\"" "A3 aggregate never lists the admin agent"
}

# ===========================================================================
# A4 — gate ON, explicit `--agents librarian`: only librarian touched.
# ===========================================================================
test_explicit_csv_scopes_to_named() {
  reseed_all_settings
  local rc
  rc="$(GATE=1 run_auth claude-token backfill-settings --agents "$USER_AGENT" --json)"
  smoke_assert_eq "0" "$rc" "A4 explicit-csv backfill rc 0"
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$USER_AGENT")" "A4 named agent backfilled"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" "A4 admin untouched by a non-admin csv"
}

# ===========================================================================
# A4b — gate ON, explicit `--agents patch`: the admin IS backfilled when named.
# ===========================================================================
test_explicit_admin_optin() {
  reseed_all_settings
  local rc
  rc="$(GATE=1 run_auth claude-token backfill-settings --agents "$ADMIN_AGENT" --json)"
  smoke_assert_eq "0" "$rc" "A4b explicit-admin backfill rc 0"
  smoke_assert_eq "$EXPECTED_HELPER" "$(helper_in "$ADMIN_AGENT")" \
    "A4b admin IS backfilled when an explicit --agents names it (opt-in)"
}

# ===========================================================================
# A5 — gate OFF: backfill never resurrects, and the writer removes a managed
#      helper (rollback cleanup path).
# ===========================================================================
test_gate_off_no_resurrect_and_removes() {
  reseed_all_settings
  # Backfill with gate OFF -> skipped, never resurrects a helper on a clean agent.
  local rc
  rc="$(GATE=0 run_auth claude-token backfill-settings --json)"
  smoke_assert_eq "0" "$rc" "A5 gate-off backfill rc 0"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "A5 gate-off backfill does not resurrect a helper"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" "A5 gate-off backfill leaves the admin clean"

  # The settings writer REMOVES a bridge-managed helper when the gate is off.
  local cfg
  cfg="$(cfg_dir_for "$USER_AGENT")"
  printf '{"skipDangerousModePermissionPrompt": true, "apiKeyHelper": "%s"}\n' "$EXPECTED_HELPER" >"$cfg/settings.json"
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=0 \
    python3 -c 'import importlib.util,sys; from pathlib import Path; spec=importlib.util.spec_from_file_location("ba",sys.argv[2]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); m.ensure_claude_settings_file(Path(sys.argv[1]))' \
    "$cfg" "$AUTH_PY"
  smoke_assert_eq "" "$(helper_in "$USER_AGENT")" "A5 gate-off settings writer removes the managed helper"
}

# ===========================================================================
# A6 — `keychain-free enable` fails closed on an unhealthy active OAT.
# ===========================================================================
test_keychain_free_enable_fail_closed() {
  reseed_all_settings
  # Active token disabled + auth_failed -> unhealthy.
  write_registry "primary" "false" "auth_failed"
  rm -f "$CONFIG_FILE"
  local rc out
  rc="$(run_auth claude-token keychain-free enable --json)"
  out="$(cat "$SMOKE_TMP_ROOT/auth.out")"
  [[ "$rc" != "0" ]] || smoke_fail "A6 enable with unhealthy OAT returned rc=0 (expected fail-closed)"
  smoke_assert_contains "$out" '"status": "refused"' "A6 enable is refused on unhealthy OAT"
  smoke_assert_eq "false" "$(gate_enabled_in_config)" "A6 gate stays OFF after a refused enable"
  smoke_assert_eq "" "$(helper_in "$ADMIN_AGENT")" \
    "A6 refused enable writes no managed helper into the interactive admin"
}

# ===========================================================================
# A6b/c — healthy OAT enables; disable flips back; unknown flag fails closed.
# ===========================================================================
test_keychain_free_enable_disable_cycle() {
  write_registry "primary" "true" "available"
  rm -f "$CONFIG_FILE"
  local rc
  rc="$(run_auth claude-token keychain-free enable --json)"
  smoke_assert_eq "0" "$rc" "A6b enable with a healthy OAT rc 0"
  smoke_assert_eq "true" "$(gate_enabled_in_config)" "A6b gate flipped ON in bridge-config.json"

  rc="$(run_auth claude-token keychain-free disable --json)"
  smoke_assert_eq "0" "$rc" "A6c disable rc 0"
  smoke_assert_eq "false" "$(gate_enabled_in_config)" "A6c gate flipped OFF in bridge-config.json"

  rc="$(run_auth claude-token keychain-free enable --bogus)"
  [[ "$rc" != "0" ]] || smoke_fail "A6c keychain-free unknown flag returned rc=0 (expected nonzero)"
}

smoke_run "A1 backfill-settings --help prints usage, no agent iteration"   test_help_prints_usage_no_iteration
smoke_run "A2 backfill-settings unknown flag fails closed (no writes)"      test_unknown_flag_fails_closed
smoke_run "A3 broad-scope WRITE excludes the admin/interactive agent"       test_broad_scope_excludes_admin
smoke_run "A4 explicit --agents csv scopes to the named agent only"         test_explicit_csv_scopes_to_named
smoke_run "A4b explicit --agents <admin> opt-in backfills the admin"        test_explicit_admin_optin
smoke_run "A5 gate-off: no resurrect + writer removes managed helper"       test_gate_off_no_resurrect_and_removes
smoke_run "A6 keychain-free enable fails closed on an unhealthy OAT"        test_keychain_free_enable_fail_closed
smoke_run "A6b/c keychain-free enable/disable cycle + unknown-flag guard"   test_keychain_free_enable_disable_cycle

smoke_log "all checks passed"
