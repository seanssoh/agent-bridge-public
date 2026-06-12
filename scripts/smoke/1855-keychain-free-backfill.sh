#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1855-keychain-free-backfill.sh — Issue #1855.
#
# Pins the create-if-absent keychain-free apiKeyHelper backfill contract for
# pre-#1520 shared Claude agents.
#
# Root cause (#1855): ensure_claude_settings_file wires apiKeyHelper into a
# Claude agent's per-agent settings.json at provision/sync time — but agents
# provisioned BEFORE #1520 shipped have a settings.json with no apiKeyHelper and
# nothing ever backfilled it. So the #1520 keychain-free gate (Darwin +
# executable helper + settings wired + active registry OAT) can never pass and
# the shared launch silently degrades to the operator keychain: the admin never
# consumes the claude-token OAT pool while every other agent rotates. Same
# create-time-only materialization gap as #1809 (AGENTS.md backfill).
#
# The fix: a `bridge-auth.py backfill-settings` subcommand (driven per-agent by
# the upgrade migrate loop + the daemon process_keychain_free_backfill hygiene
# pass) that REUSES ensure_claude_settings_file — the exact provision-time
# writer — so the backfilled end state is byte-identical to a fresh-install
# scaffold. Plus a read-only `--check` credential-coherence drift report and a
# cred-state-honesty `coherent` field on the sync payload.
#
# Test plan — drive the production bridge-auth.py subcommand directly (the
# byte-exact writer is Python; no live claude binary required), in an isolated
# BRIDGE_HOME, with BRIDGE_HOST_PLATFORM_OVERRIDE / BRIDGE_CLAUDE_KEYCHAIN_FREE_-
# AUTH to drive the Darwin + gate branches deterministically:
#
#   T1. Legacy agent (settings.json without apiKeyHelper) on Darwin + gate-on:
#       backfill reports changed:true and settings.json now carries the
#       managed apiKeyHelper resolved by claude_api_key_helper_path.
#   T2. Idempotency — a second backfill on the already-contracted agent reports
#       changed:false and leaves settings.json byte-identical.
#   T3. Non-Darwin no-op — the same legacy agent on a non-Darwin host is
#       skipped (status:skipped) and settings.json gains NO apiKeyHelper (the
#       controller helper path must never leak into a non-macOS agent).
#   T4. create-if-ABSENT — no settings.json at all on Darwin + gate-on: the
#       file is created with skipDangerousModePermissionPrompt + apiKeyHelper.
#   T5. --check drift report (read-only) — a legacy incoherent agent reports
#       coherent:false / drift:true and the settings.json is NOT mutated.
#   T6. Byte-identical-to-provision teeth — the backfilled settings.json equals
#       what ensure_claude_settings_file writes on a fresh dir (same writer).
#   T7. Bash wrapper path — `bridge-auth.sh claude-token backfill-settings`
#       passes the required --registry through to bridge-auth.py and reports
#       the agent as backfilled.
#
# Footgun #11 (heredoc_write deadlock class): plain `printf` / file-arg writes
# only; no command-substitution feeding a heredoc-stdin into a bridge function.

set -euo pipefail

SMOKE_NAME="1855-keychain-free-backfill"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "1855-keychain-free-backfill"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing bridge-auth.py: $AUTH_PY"
[[ -f "$AUTH_SH" ]] || smoke_fail "missing bridge-auth.sh: $AUTH_SH"

# bridge-auth.py requires a top-level --registry; backfill-settings does not
# read it (it operates on --config-dir), but argparse still demands the flag.
REGISTRY="$SMOKE_TMP_ROOT/registry.json"

# The helper path the writer resolves (and that the gate validates) — the
# in-repo default when no override is set. The smoke asserts the backfilled
# value equals this exact canonical path.
EXPECTED_HELPER="$(cd -P "$REPO_ROOT" && python3 -c 'import pathlib,sys; print(pathlib.Path("scripts/claude-oat-api-key-helper.sh").resolve())')"

backfill() {
  # backfill <config-dir> <agent> [extra-args...]
  local cfg="$1" agent="$2"; shift 2
  BRIDGE_HOST_PLATFORM_OVERRIDE="${PLATFORM:-Darwin}" \
  BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH="${GATE:-1}" \
    python3 "$AUTH_PY" --registry "$REGISTRY" backfill-settings \
      --config-dir "$cfg" --agent "$agent" --json "$@"
}

LEGACY_CFG="$SMOKE_TMP_ROOT/legacy/.claude"
mkdir -p "$LEGACY_CFG"
# A pre-#1520 settings.json: present, valid, but NO apiKeyHelper.
printf '{"skipDangerousModePermissionPrompt": true}\n' >"$LEGACY_CFG/settings.json"

# T1 — legacy agent gains the managed apiKeyHelper.
test_legacy_gains_helper() {
  local out
  out="$(backfill "$LEGACY_CFG" legacy)"
  smoke_assert_contains "$out" '"changed": true' "T1 backfill reports changed:true"
  smoke_assert_contains "$out" '"backfilled": true' "T1 backfill reports backfilled:true"
  local helper
  helper="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("apiKeyHelper",""))' "$LEGACY_CFG/settings.json")"
  smoke_assert_eq "$EXPECTED_HELPER" "$helper" \
    "T1 settings.json now points at the canonical managed apiKeyHelper"
  # The pre-existing user key must survive (create-if-absent, not clobber).
  local keep
  keep="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("skipDangerousModePermissionPrompt"))' "$LEGACY_CFG/settings.json")"
  smoke_assert_eq "True" "$keep" "T1 existing settings keys are preserved"
}

# T2 — idempotency: a second run is a no-op (changed:false), file unchanged.
test_idempotent_rerun() {
  local before after out
  before="$(cat "$LEGACY_CFG/settings.json")"
  out="$(backfill "$LEGACY_CFG" legacy)"
  smoke_assert_contains "$out" '"changed": false' "T2 re-run reports changed:false"
  after="$(cat "$LEGACY_CFG/settings.json")"
  smoke_assert_eq "$before" "$after" "T2 re-run leaves settings.json byte-identical"
}

# T3 — non-Darwin no-op: skipped, no apiKeyHelper written.
test_non_darwin_noop() {
  local cfg out helper
  cfg="$SMOKE_TMP_ROOT/linux/.claude"
  mkdir -p "$cfg"
  printf '{"skipDangerousModePermissionPrompt": true}\n' >"$cfg/settings.json"
  out="$(PLATFORM=Linux backfill "$cfg" linux-agent)"
  smoke_assert_contains "$out" '"status": "skipped"' "T3 non-Darwin reports status:skipped"
  helper="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("apiKeyHelper",""))' "$cfg/settings.json")"
  smoke_assert_eq "" "$helper" "T3 non-Darwin writes NO apiKeyHelper (no controller-path leak)"
}

# T4 — create-if-absent: no settings.json at all → it is created with the
# managed apiKeyHelper.
test_create_if_absent() {
  local cfg out helper
  cfg="$SMOKE_TMP_ROOT/fresh/.claude"
  mkdir -p "$cfg"
  [[ ! -f "$cfg/settings.json" ]] || smoke_fail "T4 precondition: settings.json must be absent"
  out="$(backfill "$cfg" fresh)"
  smoke_assert_contains "$out" '"changed": true' "T4 create-if-absent reports changed:true"
  smoke_assert_file_exists "$cfg/settings.json" "T4 settings.json is created"
  helper="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("apiKeyHelper",""))' "$cfg/settings.json")"
  smoke_assert_eq "$EXPECTED_HELPER" "$helper" "T4 created settings.json carries the managed apiKeyHelper"
}

# T5 — --check is a read-only coherence drift report (no write).
test_check_drift_readonly() {
  local cfg out before after
  cfg="$SMOKE_TMP_ROOT/drift/.claude"
  mkdir -p "$cfg"
  printf '{"skipDangerousModePermissionPrompt": true}\n' >"$cfg/settings.json"
  before="$(cat "$cfg/settings.json")"
  out="$(backfill "$cfg" drift-agent --check)"
  smoke_assert_contains "$out" '"coherent": false' "T5 --check reports coherent:false on a legacy agent"
  smoke_assert_contains "$out" '"drift": true' "T5 --check reports drift:true"
  smoke_assert_contains "$out" '"changed": false' "T5 --check never reports a change"
  after="$(cat "$cfg/settings.json")"
  smoke_assert_eq "$before" "$after" "T5 --check leaves settings.json untouched (read-only)"
  # A coherent agent reports coherent:true with no drift.
  backfill "$cfg" drift-agent >/dev/null
  out="$(backfill "$cfg" drift-agent --check)"
  smoke_assert_contains "$out" '"coherent": true' "T5 --check reports coherent:true after backfill"
  smoke_assert_contains "$out" '"drift": false' "T5 --check reports drift:false after backfill"
}

# T6 — byte-identical-to-provision teeth: the backfilled settings.json equals
# what ensure_claude_settings_file writes on a fresh dir (same writer, so the
# backfilled end state is indistinguishable from a fresh-install scaffold).
test_byte_identical_to_provision() {
  local backfilled provisioned cfg2
  backfilled="$(cat "$LEGACY_CFG/settings.json")"
  cfg2="$SMOKE_TMP_ROOT/provision/.claude"
  mkdir -p "$cfg2"
  # Call the provision-time writer directly (the same function cmd_sync_agent
  # uses) against an empty dir; compare with the backfilled file.
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    python3 - "$cfg2" "$AUTH_PY" <<'PY'
import importlib.util, sys
from pathlib import Path
cfg = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("bridge_auth", sys.argv[2])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.ensure_claude_settings_file(cfg)
PY
  provisioned="$(cat "$cfg2/settings.json")"
  # Note: the legacy file also carried skipDangerousModePermissionPrompt, which
  # the provision writer setdefaults too — so both files have the same keys.
  smoke_assert_eq "$provisioned" "$backfilled" \
    "T6 backfilled settings.json is byte-identical to the provision-time writer output"
}

test_bash_wrapper_passes_registry() {
  local agent cfg out helper
  agent="wrapper-agent"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck shell=bash disable=SC2034\n'
    printf 'bridge_add_agent_id_if_missing %s\n' "$agent"
    printf 'BRIDGE_AGENT_DESC["%s"]="wrapper smoke"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]="%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_CONTINUE["%s"]="1"\n' "$agent"
  } >"$BRIDGE_ROSTER_LOCAL_FILE"

  cfg="$BRIDGE_AGENT_ROOT_V2/$agent/home/.claude"
  mkdir -p "$cfg"
  printf '{"skipDangerousModePermissionPrompt": true}\n' >"$cfg/settings.json"

  out="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 \
    bash "$AUTH_SH" claude-token backfill-settings --agents "$agent" --json)"
  smoke_assert_contains "$out" '"status": "ok"' "T7 wrapper returns aggregate ok"
  smoke_assert_contains "$out" '"backfilled": [' "T7 wrapper reports a backfilled list"
  smoke_assert_contains "$out" "\"$agent\"" "T7 wrapper reports the selected agent"
  helper="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("apiKeyHelper",""))' "$cfg/settings.json")"
  smoke_assert_eq "$EXPECTED_HELPER" "$helper" \
    "T7 wrapper writes the managed apiKeyHelper through bridge-auth.py"
}

smoke_run "T1 legacy agent gains the managed apiKeyHelper"                test_legacy_gains_helper
smoke_run "T2 backfill is idempotent (already-contracted untouched)"      test_idempotent_rerun
smoke_run "T3 non-Darwin is a no-op (no controller-helper-path leak)"     test_non_darwin_noop
smoke_run "T4 create-if-absent materializes a missing settings.json"      test_create_if_absent
smoke_run "T5 --check is a read-only credential-coherence drift report"   test_check_drift_readonly
smoke_run "T6 backfilled end-state is byte-identical to provision writer"  test_byte_identical_to_provision
smoke_run "T7 bridge-auth.sh wrapper passes --registry to bridge-auth.py"  test_bash_wrapper_passes_registry

smoke_log "all checks passed"
