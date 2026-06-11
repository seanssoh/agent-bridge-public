#!/usr/bin/env bash
# 1781-doc-migration-memory-preserve.sh -- DATA-LOSS guard for issue #1781.
#
# The upgrade-time HOME -> workdir identity sync
# (lib/upgrade-helpers/rematerialize-agent-identity.sh, invoked by
# bridge-upgrade.py migrate-agents) used to copy the agent-home MEMORY.md over
# the live workdir MEMORY.md like a managed doc. MEMORY.md is AGENT-WRITTEN
# state (memory-daily crons + live sessions append to the workdir copy), so on
# layouts where home is the stale copy this silently rolled live memory back on
# every upgrade (13/22 agents on one host, byte-identical to the older home
# copy). This smoke pins the fix:
#
#   (a) a NEWER + DIVERGENT workdir/MEMORY.md is left byte-unchanged
#   (b) the memory/ tree is never touched (it was never in the sync set)
#   (c) users/<id>/MEMORY.md is left byte-unchanged
#   (d) the marker block in CLAUDE.md still updates correctly (the migration's
#       real job — sync managed docs home->workdir — keeps working)
#   (e) one named audit line is emitted for each managed-doc write AND each
#       preserved state file
#   (f) workdir/MEMORY.md + users/<id>/MEMORY.md stay in the migrate-agents
#       JSON `preserved_paths` AND in the backup-live manifest (the recovery
#       anchor the issue credits — must not regress)
#   (g) teeth: a source-token pin so a refactor cannot silently re-add
#       MEMORY.md to the copy set (remat_names) or strip the state guard.
#
# Footgun #11: no heredoc-stdin to any subprocess. Sidecar python is invoked
# via `python3 -c` (no stdin) or by the helper's own argv path.

set -euo pipefail

SMOKE_NAME="1781-doc-migration-memory-preserve"
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

write_identity_doc_set() {
  # Managed DOCS the migration owns — distinct content per dir so a successful
  # home->workdir sync is observable.
  local dir="$1"
  local agent="$2"
  local marker="$3"
  mkdir -p "$dir"
  {
    printf '# %s %s\n' "$agent" "$marker"
    printf '\n'
    printf '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->\n'
    printf 'managed block for %s (%s)\n' "$agent" "$marker"
    printf '<!-- END AGENT BRIDGE DOC MIGRATION -->\n'
  } >"$dir/CLAUDE.md"
  printf '# %s soul %s\n' "$agent" "$marker" >"$dir/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$dir/SESSION-TYPE.md"
  printf 'schema %s\n' "$marker" >"$dir/MEMORY-SCHEMA.md"
  printf 'heartbeat %s\n' "$marker" >"$dir/HEARTBEAT.md"
  printf 'change %s\n' "$marker" >"$dir/CHANGE-POLICY.md"
  printf 'tools %s\n' "$marker" >"$dir/TOOLS.md"
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

# The helper writes its named audit lines to stderr; migrate-agents
# (bridge-upgrade.py) captures that stderr into the per-agent rematerialize
# `warnings` list, which is where it surfaces in the upgrade output/JSON.
json_agent_remat_warnings() {
  local json="$1"
  local agent="$2"
  printf '%s' "$json" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
agent = sys.argv[1]
for item in payload.get("agents", []):
    if item.get("agent") == agent:
        for line in (item.get("rematerialize") or {}).get("warnings") or []:
            print(line)
        break
' "$agent"
}

# Seed an agent with a STALE home copy and a NEWER + DIVERGENT workdir copy of
# every agent-written state surface (top-level MEMORY.md, memory/ tree,
# users/<id>/MEMORY.md), plus managed docs that DO differ home<->workdir so the
# real sync job is observable.
seed_agent() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$BRIDGE_AGENT_ROOT_V2/$agent/home"

  # Managed docs: home is the canonical NEW render; workdir is the OLD copy.
  write_identity_doc_set "$profile" "$agent" "home-new"
  write_identity_doc_set "$workdir" "$agent" "workdir-old"

  # State: home is the STALE copy, workdir is the LIVE divergent copy.
  printf 'memory STALE-HOME\nLast updated: 2026-05-29 (cron)\n' >"$profile/MEMORY.md"
  printf 'memory LIVE-WORKDIR\nLast updated: 2026-06-11 (cron)\n06-10/06-11 work state\n' >"$workdir/MEMORY.md"

  # memory/ tree (never in the sync set at all) — only the workdir has it.
  mkdir -p "$workdir/memory/projects"
  printf 'project note LIVE 06-11\n' >"$workdir/memory/projects/p1.md"
  printf 'memory index LIVE\n' >"$workdir/memory/index.md"

  # users/<id>/MEMORY.md is per-user STATE; USER.md is per-user identity (doc).
  mkdir -p "$profile/users/u1" "$workdir/users/u1"
  printf 'user identity home-new\n' >"$profile/users/u1/USER.md"
  printf 'user identity workdir-old\n' >"$workdir/users/u1/USER.md"
  printf 'user memory STALE-HOME\n' >"$profile/users/u1/MEMORY.md"
  printf 'user memory LIVE-WORKDIR 06-11\n' >"$workdir/users/u1/MEMORY.md"
}

test_memory_preserved_docs_synced() {
  setup_bridge_fixture
  write_roster keep
  seed_agent keep
  local profile="$BRIDGE_AGENT_HOME_ROOT/keep"
  local workdir="$BRIDGE_AGENT_ROOT_V2/keep/workdir"

  # Snapshot every agent-written state surface BEFORE the migration.
  local mem_before="" user_mem_before="" mem_tree_before="" mem_index_before=""
  mem_before="$(cat "$workdir/MEMORY.md")"
  user_mem_before="$(cat "$workdir/users/u1/MEMORY.md")"
  mem_tree_before="$(cat "$workdir/memory/projects/p1.md")"
  mem_index_before="$(cat "$workdir/memory/index.md")"

  local out="$SMOKE_TMP_ROOT/keep.out"
  local stderr="$SMOKE_TMP_ROOT/keep.stderr"
  run_migrate >"$out" 2>"$stderr"

  # (a) workdir/MEMORY.md byte-unchanged.
  smoke_assert_eq "$mem_before" "$(cat "$workdir/MEMORY.md")" \
    "workdir MEMORY.md was clobbered by doc-migration"
  if cmp -s "$profile/MEMORY.md" "$workdir/MEMORY.md"; then
    smoke_fail "workdir MEMORY.md was rolled back to the stale home copy"
  fi

  # (b) memory/ tree untouched.
  smoke_assert_eq "$mem_tree_before" "$(cat "$workdir/memory/projects/p1.md")" \
    "workdir memory/ tree file was modified"
  smoke_assert_eq "$mem_index_before" "$(cat "$workdir/memory/index.md")" \
    "workdir memory/index.md was modified"

  # (c) users/<id>/MEMORY.md untouched.
  smoke_assert_eq "$user_mem_before" "$(cat "$workdir/users/u1/MEMORY.md")" \
    "workdir users/u1/MEMORY.md was clobbered"

  # (d) marker block in CLAUDE.md still updates from the home copy (real job).
  cmp -s "$profile/CLAUDE.md" "$workdir/CLAUDE.md" \
    || smoke_fail "CLAUDE.md was not synced home->workdir (migration job regressed)"
  smoke_assert_contains "$(cat "$workdir/CLAUDE.md")" "home-new" \
    "CLAUDE.md did not receive the new managed-doc content"
  # And other managed docs likewise refresh (USER.md is per-user identity doc).
  smoke_assert_contains "$(cat "$workdir/SOUL.md")" "home-new" \
    "SOUL.md was not synced home->workdir"
  smoke_assert_contains "$(cat "$workdir/users/u1/USER.md")" "home-new" \
    "users/u1/USER.md (identity doc) was not synced home->workdir"

  # (e) named audit line per managed-doc write and per preserved state file.
  # migrate-agents folds the helper stderr into rematerialize.warnings.
  local audit=""
  audit="$(json_agent_remat_warnings "$(cat "$out")" keep)"
  smoke_assert_contains "$audit" \
    "[rematerialize] agent=keep preserve agents/keep/workdir/MEMORY.md" \
    "missing preserve audit line for workdir MEMORY.md"
  smoke_assert_contains "$audit" \
    "[rematerialize] agent=keep preserve agents/keep/workdir/users/u1/MEMORY.md" \
    "missing preserve audit line for users MEMORY.md"
  smoke_assert_contains "$audit" \
    "[rematerialize] agent=keep rematerialize agents/keep/workdir/CLAUDE.md" \
    "missing rematerialize audit line for CLAUDE.md"
  # The stderr capture file should exist but is empty (audit lines flow through
  # warnings, not the terminal) — touch it so the unused-var check is moot.
  : "$stderr"

  # (f1) preserved_paths reported in migrate-agents JSON.
  local preserved=""
  preserved="$(json_agent_remat_field "$(cat "$out")" keep preserved_paths)"
  smoke_assert_contains "$preserved" "agents/keep/workdir/MEMORY.md" \
    "JSON preserved_paths missing workdir MEMORY.md"
  smoke_assert_contains "$preserved" "agents/keep/workdir/users/u1/MEMORY.md" \
    "JSON preserved_paths missing users MEMORY.md"
  # MEMORY.md must NOT appear in updated_paths (it was not copied).
  smoke_assert_not_contains "$(json_agent_remat_field "$(cat "$out")" keep updated_paths)" \
    "workdir/MEMORY.md" \
    "MEMORY.md leaked into updated_paths (was copied home->workdir)"
}

test_backup_keeps_memory() {
  # (f2) backup-live manifest still captures workdir MEMORY.md + users MEMORY.md
  # from the dry-run preview, so a rollback restores the exact pre-upgrade copy.
  setup_bridge_fixture
  write_roster back
  seed_agent back

  local preview="$SMOKE_TMP_ROOT/back-preview.out"
  run_migrate --dry-run >"$preview" 2>/dev/null

  local backup_root="$SMOKE_TMP_ROOT/back-backup"
  python3 "$REPO_ROOT/bridge-upgrade.py" backup-live \
    --target-root "$BRIDGE_HOME" \
    --backup-root "$backup_root" \
    --source-root "$REPO_ROOT" \
    --migration-json-file "$preview" >"$SMOKE_TMP_ROOT/back-backup.out"

  local manifest_paths=""
  manifest_paths="$(json_manifest_entry_paths "$backup_root/manifest.json")"
  smoke_assert_contains "$manifest_paths" "agents/back/workdir/MEMORY.md" \
    "backup manifest dropped workdir MEMORY.md (recovery anchor regressed)"
  smoke_assert_contains "$manifest_paths" "agents/back/workdir/users/u1/MEMORY.md" \
    "backup manifest dropped users MEMORY.md (recovery anchor regressed)"

  # The actual pre-clobber bytes must be in the backup tree.
  smoke_assert_file_exists "$backup_root/live/agents/back/workdir/MEMORY.md" \
    "backup did not capture workdir MEMORY.md content"
  smoke_assert_contains "$(cat "$backup_root/live/agents/back/workdir/MEMORY.md")" \
    "LIVE-WORKDIR" \
    "backed-up MEMORY.md is not the live workdir copy"
}

test_source_token_pin() {
  # (g) teeth: lock the source so a refactor cannot silently re-add MEMORY.md
  # to the copy set or strip the state-file guard.
  local helper="$REPO_ROOT/lib/upgrade-helpers/rematerialize-agent-identity.sh"
  smoke_assert_contains "$(cat "$helper")" "_remat_is_state_file" \
    "state-file guard (_remat_is_state_file) was removed from the helper"
  # The guard must classify MEMORY.md as state, and the copy gate must consult it.
  python3 -c '
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
# The classifier function body (from its def to the next blank line) must map
# MEMORY.md to "return 0" (state). Match the def header then the case arm
# anywhere before the function closes (closing "}" at column 0).
m = re.search(r"^_remat_is_state_file\(\)\s*\{\n(.*?)\n\}", text, re.S | re.M)
if not m or "MEMORY.md) return 0" not in m.group(1):
    sys.exit("FAIL: _remat_is_state_file no longer classifies MEMORY.md as state")
# The copy gate must short-circuit on the classifier.
gate = re.search(r"^_remat_copy_one_file\(\)\s*\{\n(.*?)\n\}", text, re.S | re.M)
if not gate or "_remat_is_state_file" not in gate.group(1):
    sys.exit("FAIL: _remat_copy_one_file no longer consults the state-file guard")
' "$helper" || smoke_fail "source-token pin: MEMORY.md state classification missing"

  # The doc-migration in-place rewrite list (bridge-docs.py) must NOT include
  # MEMORY.md either.
  local docs="$REPO_ROOT/bridge-docs.py"
  python3 -c '
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for line in text.splitlines():
    if line.startswith("AGENT_RUNTIME_REWRITE_FILES"):
        if "MEMORY.md" in line:
            sys.exit("FAIL: bridge-docs.py AGENT_RUNTIME_REWRITE_FILES still rewrites MEMORY.md")
        break
else:
    sys.exit("FAIL: AGENT_RUNTIME_REWRITE_FILES assignment not found in bridge-docs.py")
' "$docs" || smoke_fail "source-token pin: bridge-docs.py still doc-rewrites MEMORY.md"
}

smoke_run "workdir MEMORY.md preserved while managed docs sync" test_memory_preserved_docs_synced
smoke_run "backup manifest keeps workdir MEMORY.md" test_backup_keeps_memory
smoke_run "source tokens pin MEMORY.md out of the copy/rewrite sets" test_source_token_pin
smoke_log "PASS: $SMOKE_NAME"
