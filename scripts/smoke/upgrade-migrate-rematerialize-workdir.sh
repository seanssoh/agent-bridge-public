#!/usr/bin/env bash
# upgrade-migrate-rematerialize-workdir.sh -- migrate-agents workdir copy smoke.

set -euo pipefail

SMOKE_NAME="upgrade-migrate-rematerialize-workdir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

setup_bridge_fixture() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME"
  export BRIDGE_AGENT_ROOT_V2="$BRIDGE_HOME/agents"
  {
    printf '%s\n' 'BRIDGE_LAYOUT=v2'
    printf 'BRIDGE_DATA_ROOT=%q\n' "$BRIDGE_DATA_ROOT"
  } >"$BRIDGE_STATE_DIR/layout-marker.sh"
  mkdir -p "$BRIDGE_AGENT_ROOT_V2"
}

write_roster() {
  local agent=""
  {
    printf 'BRIDGE_AGENT_IDS=('
    for agent in "$@"; do
      printf '"%s" ' "$agent"
    done
    printf ')\n'
    for agent in "$@"; do
      printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
      printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
      printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
      printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
      printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
    done
  } >"$BRIDGE_ROSTER_FILE"
}

set_roster_workdir() {
  local agent="$1"
  local workdir="$2"
  printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$workdir" >>"$BRIDGE_ROSTER_FILE"
}

write_identity_file_set() {
  local dir="$1"
  local agent="$2"
  local marker="$3"
  mkdir -p "$dir"
  {
    printf '# %s %s\n' "$agent" "$marker"
    printf '\n'
    printf '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->\n'
    printf 'old managed block for %s\n' "$agent"
    printf '<!-- END AGENT BRIDGE DOC MIGRATION -->\n'
  } >"$dir/CLAUDE.md"
  printf '# %s soul %s\n' "$agent" "$marker" >"$dir/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$dir/SESSION-TYPE.md"
  printf 'memory %s\n' "$marker" >"$dir/MEMORY.md"
  printf 'schema %s\n' "$marker" >"$dir/MEMORY-SCHEMA.md"
  printf 'heartbeat %s\n' "$marker" >"$dir/HEARTBEAT.md"
  printf 'change %s\n' "$marker" >"$dir/CHANGE-POLICY.md"
  printf 'tools %s\n' "$marker" >"$dir/TOOLS.md"
}

seed_agent() {
  local agent="$1"
  local source_marker="$2"
  local workdir_marker="$3"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$BRIDGE_AGENT_ROOT_V2/$agent/home"
  write_identity_file_set "$profile" "$agent" "$source_marker"
  write_identity_file_set "$workdir" "$agent" "$workdir_marker"
}

run_migrate() {
  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" \
    --target-root "$BRIDGE_HOME" \
    --admin-agent owner "$@"
}

json_agent_remat_field() {
  local json="$1"
  local agent="$2"
  local field="$3"
  printf '%s' "$json" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
agent = sys.argv[1]
field = sys.argv[2]
for item in payload.get("agents", []):
    if item.get("agent") == agent:
        value = (item.get("rematerialize") or {}).get(field, "")
        if isinstance(value, list):
            print("\n".join(str(v) for v in value))
        else:
            print(value)
        break
' "$agent" "$field"
}

json_top_field() {
  local json="$1"
  local field="$2"
  printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$field"
}

json_manifest_entry_paths() {
  local manifest="$1"
  python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
for item in payload.get("entries", []):
    print(item.get("path", ""))
' "$manifest"
}

portable_mode() {
  local path="$1"
  stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path"
}

test_split_apply() {
  setup_bridge_fixture
  write_roster split
  seed_agent split source-old workdir-stale

  local out="$SMOKE_TMP_ROOT/split.out"
  run_migrate >"$out"
  cmp -s "$BRIDGE_AGENT_HOME_ROOT/split/CLAUDE.md" "$BRIDGE_AGENT_ROOT_V2/split/workdir/CLAUDE.md" \
    || smoke_fail "split apply: workdir CLAUDE.md is not byte-identical to migrated source"
  smoke_assert_contains "$(json_agent_remat_field "$(cat "$out")" split updated_paths)" \
    "agents/split/workdir/CLAUDE.md" \
    "split apply: JSON did not report workdir CLAUDE.md update"

  local backup_root="$SMOKE_TMP_ROOT/split-backup"
  python3 "$REPO_ROOT/bridge-upgrade.py" backup-live \
    --target-root "$BRIDGE_HOME" \
    --backup-root "$backup_root" \
    --source-root "$REPO_ROOT" \
    --migration-json-file "$out" >"$SMOKE_TMP_ROOT/split-backup.out"
  smoke_assert_contains "$(json_manifest_entry_paths "$backup_root/manifest.json")" \
    "agents/split/workdir/CLAUDE.md" \
    "split apply: backup planner did not include rematerialized workdir path"
}

test_dry_run_no_write() {
  setup_bridge_fixture
  write_roster dry
  seed_agent dry source-new workdir-stale
  local before=""
  before="$(cat "$BRIDGE_AGENT_ROOT_V2/dry/workdir/CLAUDE.md")"

  local out="$SMOKE_TMP_ROOT/dry.out"
  run_migrate --dry-run >"$out"
  smoke_assert_eq "$before" "$(cat "$BRIDGE_AGENT_ROOT_V2/dry/workdir/CLAUDE.md")" \
    "dry-run: workdir CLAUDE.md changed"
  smoke_assert_eq "planned" "$(json_agent_remat_field "$(cat "$out")" dry status)" \
    "dry-run: rematerialize status"
  smoke_assert_contains "$(json_agent_remat_field "$(cat "$out")" dry updated_paths)" \
    "agents/dry/workdir/CLAUDE.md" \
    "dry-run: planned updated path missing"
}

test_shared_pair_guard() {
  setup_bridge_fixture
  write_roster owner guest
  seed_agent owner owner-source owner-workdir
  seed_agent guest guest-source guest-workdir
  set_roster_workdir guest "$BRIDGE_AGENT_ROOT_V2/owner/workdir"

  local out="$SMOKE_TMP_ROOT/shared.out"
  run_migrate >"$out"
  smoke_assert_contains "$(head -n 1 "$BRIDGE_AGENT_ROOT_V2/owner/workdir/CLAUDE.md")" "# owner" \
    "shared pair: owner identity was not preserved in shared workdir"
  smoke_assert_eq "skipped" "$(json_agent_remat_field "$(cat "$out")" guest status)" \
    "shared pair: guest status"
  smoke_assert_eq "shared_workspace" "$(json_agent_remat_field "$(cat "$out")" guest skipped_reason)" \
    "shared pair: guest skip reason"
}

test_source_equals_target() {
  setup_bridge_fixture
  write_roster legacy
  seed_agent legacy source same
  set_roster_workdir legacy "$BRIDGE_AGENT_ROOT_V2/legacy/home"
  rm -rf -- "$BRIDGE_AGENT_ROOT_V2/legacy/workdir"
  write_identity_file_set "$BRIDGE_AGENT_ROOT_V2/legacy/home" legacy source

  local out="$SMOKE_TMP_ROOT/legacy.out"
  run_migrate >"$out"
  smoke_assert_eq "skipped" "$(json_agent_remat_field "$(cat "$out")" legacy status)" \
    "source==target: status"
  smoke_assert_eq "source_equals_target" "$(json_agent_remat_field "$(cat "$out")" legacy skipped_reason)" \
    "source==target: skip reason"
}

test_iso_writer_stub() {
  setup_bridge_fixture
  write_roster iso
  seed_agent iso iso-source iso-stale
  local stub_log="$SMOKE_TMP_ROOT/iso-writer.log"
  local out="$SMOKE_TMP_ROOT/iso.out"
  BRIDGE_REMATERIALIZE_TEST_STUB_ISO=1 \
  BRIDGE_REMATERIALIZE_TEST_STUB_LOG="$stub_log" \
    "$BRIDGE_BASH" "$REPO_ROOT/lib/upgrade-helpers/rematerialize-agent-identity.sh" \
      "$REPO_ROOT" "$BRIDGE_HOME" iso claude 0 >"$out"

  cmp -s "$BRIDGE_AGENT_HOME_ROOT/iso/CLAUDE.md" "$BRIDGE_AGENT_ROOT_V2/iso/workdir/CLAUDE.md" \
    || smoke_fail "iso stub: workdir CLAUDE.md was not written from source"
  smoke_assert_eq "660" "$(portable_mode "$BRIDGE_AGENT_ROOT_V2/iso/workdir/CLAUDE.md")" \
    "iso stub: CLAUDE.md mode"
  smoke_assert_contains "$(cat "$stub_log")" "write:$BRIDGE_AGENT_ROOT_V2/iso/workdir/CLAUDE.md:0660" \
    "iso stub: writer helper was not used"
  smoke_assert_contains "$(cat "$stub_log")" "chgrp:$BRIDGE_AGENT_ROOT_V2/iso/workdir/CLAUDE.md:0660" \
    "iso stub: chgrp helper was not used"
  smoke_assert_eq "applied" "$(json_top_field "$(cat "$out")" status)" \
    "iso stub: status"
}

test_target_outside_root_skips() {
  setup_bridge_fixture
  write_roster outside
  seed_agent outside source-new external-stale
  local external_workdir="$SMOKE_TMP_ROOT/external-workdir"
  write_identity_file_set "$external_workdir" outside external-stale
  set_roster_workdir outside "$external_workdir"
  local before=""
  before="$(cat "$external_workdir/CLAUDE.md")"

  local out="$SMOKE_TMP_ROOT/outside.out"
  run_migrate >"$out"
  smoke_assert_eq "$before" "$(cat "$external_workdir/CLAUDE.md")" \
    "outside-root: external workdir changed"
  smoke_assert_eq "skipped" "$(json_agent_remat_field "$(cat "$out")" outside status)" \
    "outside-root: status"
  smoke_assert_eq "target_outside_root" "$(json_agent_remat_field "$(cat "$out")" outside skipped_reason)" \
    "outside-root: skip reason"
}

smoke_run "split stale workdir rematerializes on apply" test_split_apply
smoke_run "dry-run plans but writes nothing" test_dry_run_no_write
smoke_run "shared-cwd pair skips non-owner identity" test_shared_pair_guard
smoke_run "source equals target is a no-op" test_source_equals_target
smoke_run "iso path uses writer stub and lands 0660" test_iso_writer_stub
smoke_run "outside-root workdir is skipped without write" test_target_outside_root_skips
smoke_log "PASS: $SMOKE_NAME"
