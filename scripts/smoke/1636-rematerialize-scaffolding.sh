#!/usr/bin/env bash
# 1636-rematerialize-scaffolding.sh -- Issue #1636 add-missing-only propagation
# of the non-identity _template scaffolding (slash commands, capture/session
# scaffolds, codex extras) from the controller-owned profile source to the agent
# workdir during upgrade-time rematerialize.
#
# The helper is invoked DIRECTLY with the resolved bash 5.x binary (mirroring
# `upgrade-migrate-rematerialize-workdir.sh`'s `test_iso_writer_stub`) so the
# Bash-3.2->4+ re-exec in bridge-lib.sh (#1454) never enters the picture — that
# re-exec only triggers when the helper is reached through a shebang resolving
# to /bin/bash 3.2 on macOS, which is a separate environment concern.

set -euo pipefail

SMOKE_NAME="1636-rematerialize-scaffolding"
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

HELPER="$REPO_ROOT/lib/upgrade-helpers/rematerialize-agent-identity.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

setup_bridge_fixture() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  # Issue #1636: model the REAL v2 layer split. The controller-owned profile
  # source lives under $BRIDGE_HOME/agents/<agent> (= $BRIDGE_AGENT_HOME_ROOT,
  # where migrate_agent_home writes the _template scaffolding). The agent's
  # identity home + workdir live under the v2 data root, which in production is
  # $BRIDGE_HOME/data (under target_root, see bridge-layout-resolver.sh
  # BRIDGE_DEFAULT_DATA_ROOT) — so home is $BRIDGE_HOME/data/agents/<agent>/home,
  # a DIFFERENT tree from the profile source. Keeping these two roots distinct
  # (NOT collapsing BRIDGE_AGENT_ROOT_V2 onto $BRIDGE_HOME/agents) is what proves
  # the scaffolding is read from the profile source, not the identity home, while
  # the workdir stays under target_root so the containment guard does not skip.
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME/data"
  export BRIDGE_AGENT_ROOT_V2="$BRIDGE_DATA_ROOT/agents"
  {
    printf '%s\n' 'BRIDGE_LAYOUT=v2'
    printf 'BRIDGE_DATA_ROOT=%q\n' "$BRIDGE_DATA_ROOT"
  } >"$BRIDGE_STATE_DIR/layout-marker.sh"
  mkdir -p "$BRIDGE_AGENT_ROOT_V2"
}

write_roster() {
  local agent="$1"
  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
}

write_identity_file_set() {
  local dir="$1"
  local marker="$2"
  mkdir -p "$dir"
  {
    printf '# %s\n' "$marker"
    printf '\n'
    printf '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->\n'
    printf 'managed block %s\n' "$marker"
    printf '<!-- END AGENT BRIDGE DOC MIGRATION -->\n'
  } >"$dir/CLAUDE.md"
  printf '# soul %s\n' "$marker" >"$dir/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$dir/SESSION-TYPE.md"
  printf 'memory %s\n' "$marker" >"$dir/MEMORY.md"
  printf 'schema %s\n' "$marker" >"$dir/MEMORY-SCHEMA.md"
  printf 'heartbeat %s\n' "$marker" >"$dir/HEARTBEAT.md"
  printf 'change %s\n' "$marker" >"$dir/CHANGE-POLICY.md"
  printf 'tools %s\n' "$marker" >"$dir/TOOLS.md"
}

# Seed the real v2 three-layer state for an EXISTING agent that just migrated:
#   - profile source ($BRIDGE_HOME/agents/<agent>): identity files + the
#     non-identity _template scaffolding (this is where migrate_agent_home put it)
#   - identity home ($BRIDGE_AGENT_ROOT_V2/<agent>/home): identity files only,
#     WITH the engine entry (CLAUDE.md) so source_dir resolves to home and does
#     NOT fall back to the profile source — and CRITICALLY no scaffolding, which
#     is exactly why the scaffold pass must read the profile source, not home
#   - workdir ($BRIDGE_AGENT_ROOT_V2/<agent>/workdir): identity files (stale),
#     scaffolding "missing" (the gap #1636 closes)
seed_agent() {
  local agent="$1"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local home="$BRIDGE_AGENT_ROOT_V2/$agent/home"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"

  write_identity_file_set "$profile" "$agent source"
  write_identity_file_set "$home" "$agent home"
  write_identity_file_set "$workdir" "$agent stale"

  # Scaffolding lives ONLY in the profile source (mirrors the migrated _template
  # tree). The identity home deliberately has none — proving the scaffold pass
  # does not read from source_dir/home.
  mkdir -p \
    "$profile/.claude/commands" \
    "$profile/raw/captures/inbox" \
    "$profile/raw/captures/ingested" \
    "$profile/session-type-files/admin/references" \
    "$profile/codex"
  printf '# wrap-up command (upstream)\n' >"$profile/.claude/commands/wrap-up.md"
  : >"$profile/raw/captures/inbox/.gitkeep"
  : >"$profile/raw/captures/ingested/.gitkeep"
  printf 'admin playbook\n' >"$profile/session-type-files/admin/references/admin-playbook.md"
  printf '# codex AGENTS engine entry\n' >"$profile/codex/AGENTS.md"
  printf '# codex extra helper\n' >"$profile/codex/extra.md"
}

run_helper() {
  local agent="$1"
  local dry="$2"
  shift 2 || true
  env "$@" "$BRIDGE_BASH" "$HELPER" "$REPO_ROOT" "$BRIDGE_HOME" "$agent" claude "$dry"
}

json_field() {
  local json="$1"
  local field="$2"
  printf '%s' "$json" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
value = payload.get(sys.argv[1], "")
if isinstance(value, list):
    print("\n".join(str(v) for v in value))
else:
    print(value)
' "$field"
}

# T1: a shared-mode agent missing scaffolding gets the missing files added.
test_adds_missing_scaffolding() {
  setup_bridge_fixture
  write_roster t1
  seed_agent t1
  local wd="$BRIDGE_AGENT_ROOT_V2/t1/workdir"

  local out=""
  out="$(run_helper t1 0)"

  smoke_assert_eq "applied" "$(json_field "$out" status)" "T1: status"
  smoke_assert_file_exists "$wd/.claude/commands/wrap-up.md" "T1: slash command not added"
  smoke_assert_file_exists "$wd/raw/captures/inbox/.gitkeep" "T1: inbox .gitkeep not added"
  smoke_assert_file_exists "$wd/raw/captures/ingested/.gitkeep" "T1: ingested .gitkeep not added"
  smoke_assert_file_exists "$wd/session-type-files/admin/references/admin-playbook.md" \
    "T1: session-type-files not added"
  smoke_assert_file_exists "$wd/codex/extra.md" "T1: codex extra not added"

  local scaffold=""
  scaffold="$(json_field "$out" scaffold_paths)"
  smoke_assert_contains "$scaffold" "agents/t1/workdir/.claude/commands/wrap-up.md" \
    "T1: scaffold_paths missing slash command"
  smoke_assert_contains "$scaffold" "agents/t1/workdir/raw/captures/inbox/.gitkeep" \
    "T1: scaffold_paths missing inbox .gitkeep"
  smoke_assert_eq "5" "$(json_field "$out" scaffold_added)" "T1: scaffold_added count"

  # The slash command content matches the upstream source (it was absent).
  cmp -s "$BRIDGE_AGENT_HOME_ROOT/t1/.claude/commands/wrap-up.md" \
    "$wd/.claude/commands/wrap-up.md" \
    || smoke_fail "T1: added slash command is not byte-identical to source"
}

# T2: an EXISTING/customized workdir file is NOT overwritten (skip-existing).
test_skip_existing_customized() {
  setup_bridge_fixture
  write_roster t2
  seed_agent t2
  local wd="$BRIDGE_AGENT_ROOT_V2/t2/workdir"

  mkdir -p "$wd/.claude/commands"
  printf 'USER CUSTOMIZED WRAP-UP\n' >"$wd/.claude/commands/wrap-up.md"
  local before=""
  before="$(cat "$wd/.claude/commands/wrap-up.md")"

  local out=""
  out="$(run_helper t2 0)"

  smoke_assert_eq "$before" "$(cat "$wd/.claude/commands/wrap-up.md")" \
    "T2: customized slash command was overwritten"
  local scaffold=""
  scaffold="$(json_field "$out" scaffold_paths)"
  smoke_assert_not_contains "$scaffold" "agents/t2/workdir/.claude/commands/wrap-up.md" \
    "T2: skip-existing file was reported in scaffold_paths"
  # The other (genuinely missing) scaffolding files are still added.
  smoke_assert_file_exists "$wd/codex/extra.md" "T2: missing scaffolding was not added"
}

# T3: a re-run is idempotent (no-op once everything is present).
test_idempotent_rerun() {
  setup_bridge_fixture
  write_roster t3
  seed_agent t3

  run_helper t3 0 >/dev/null
  local out=""
  out="$(run_helper t3 0)"

  smoke_assert_eq "0" "$(json_field "$out" scaffold_added)" "T3: re-run scaffold_added not zero"
  smoke_assert_eq "" "$(json_field "$out" scaffold_paths)" "T3: re-run reported scaffold paths"
}

# T4: codex/AGENTS.md is never double-handled here (it is the engine entry).
test_codex_agents_not_double_handled() {
  setup_bridge_fixture
  write_roster t4
  seed_agent t4
  local wd="$BRIDGE_AGENT_ROOT_V2/t4/workdir"

  local out=""
  out="$(run_helper t4 0)"

  local scaffold=""
  scaffold="$(json_field "$out" scaffold_paths)"
  smoke_assert_not_contains "$scaffold" "codex/AGENTS.md" \
    "T4: codex/AGENTS.md leaked into scaffold_paths"
  # codex/extra.md IS propagated, proving the codex/ subtree is walked but the
  # AGENTS.md member is excluded (rather than the whole subtree being skipped).
  smoke_assert_contains "$scaffold" "agents/t4/workdir/codex/extra.md" \
    "T4: codex/ subtree was not walked"
}

# T4b: dry-run plans the scaffolding but writes nothing.
test_dry_run_plans_only() {
  setup_bridge_fixture
  write_roster t4b
  seed_agent t4b
  local wd="$BRIDGE_AGENT_ROOT_V2/t4b/workdir"

  local out=""
  out="$(run_helper t4b 1)"

  smoke_assert_eq "planned" "$(json_field "$out" status)" "T4b: dry-run status"
  smoke_assert_eq "5" "$(json_field "$out" scaffold_added)" "T4b: dry-run scaffold_added count"
  [[ ! -e "$wd/codex/extra.md" ]] || smoke_fail "T4b: dry-run wrote codex/extra.md"
  [[ ! -e "$wd/.claude/commands/wrap-up.md" ]] \
    || smoke_fail "T4b: dry-run wrote slash command"
}

# T5: iso path -- a PermissionError on the iso write graceful-skips (no abort).
test_iso_write_permission_error_graceful_skip() {
  setup_bridge_fixture
  write_roster t5
  seed_agent t5
  local wd="$BRIDGE_AGENT_ROOT_V2/t5/workdir"

  local out=""
  local rc=0
  out="$(run_helper t5 0 \
    BRIDGE_REMATERIALIZE_TEST_STUB_ISO=1 \
    BRIDGE_REMATERIALIZE_TEST_STUB_WRITE_FAIL_GLOB="codex/extra.md")" || rc=$?

  smoke_assert_eq "0" "$rc" "T5: helper aborted instead of graceful-skip (rc=$rc)"
  smoke_assert_eq "error" "$(json_field "$out" status)" "T5: status should record the iso failure"
  smoke_assert_contains "$(json_field "$out" errors)" "iso scaffold write failed" \
    "T5: structured iso-skip error missing"
  # The failing scaffold file is not present (write was skipped, not aborted).
  [[ ! -e "$wd/codex/extra.md" ]] || smoke_fail "T5: failed iso write left a file behind"
  # A sibling scaffold file that did NOT fail was still written via the iso path.
  smoke_assert_file_exists "$wd/.claude/commands/wrap-up.md" \
    "T5: non-failing scaffolding was not written via iso path"
}

# T6: identity-file propagation is unchanged (the existing 7-file + CLAUDE.md
# behavior must not regress when scaffolding is added alongside it). Identity
# propagates from the identity HOME (source_dir), so the workdir must end up
# byte-identical to the home copy.
test_identity_propagation_unchanged() {
  setup_bridge_fixture
  write_roster t6
  seed_agent t6
  local home="$BRIDGE_AGENT_ROOT_V2/t6/home"
  local wd="$BRIDGE_AGENT_ROOT_V2/t6/workdir"

  local out=""
  out="$(run_helper t6 0)"

  cmp -s "$home/SOUL.md" "$wd/SOUL.md" \
    || smoke_fail "T6: SOUL.md identity propagation regressed (workdir != home)"
  smoke_assert_contains "$(json_field "$out" updated_paths)" "agents/t6/workdir/SOUL.md" \
    "T6: updated_paths missing SOUL.md"
  smoke_assert_contains "$(json_field "$out" updated_paths)" "agents/t6/workdir/CLAUDE.md" \
    "T6: updated_paths missing CLAUDE.md"
}

# T7: scaffolding is read from the PROFILE SOURCE, not the identity home (the
# #1636 codex r1 [P1] regression lock). The identity home deliberately has NO
# scaffolding, yet the workdir gets it — proving the scaffold pass does not read
# source_dir/home. If a future refactor reverts the scaffold source back to
# source_dir, the home has no codex/extra.md and this test fails.
test_scaffold_source_is_profile_not_home() {
  setup_bridge_fixture
  write_roster t7
  seed_agent t7
  local home="$BRIDGE_AGENT_ROOT_V2/t7/home"
  local wd="$BRIDGE_AGENT_ROOT_V2/t7/workdir"

  # Precondition: the identity home has no scaffolding (only the profile does).
  [[ ! -e "$home/codex/extra.md" ]] \
    || smoke_fail "T7 precondition: identity home unexpectedly has scaffolding"

  local out=""
  out="$(run_helper t7 0)"

  smoke_assert_eq "5" "$(json_field "$out" scaffold_added)" \
    "T7: scaffolding not propagated from profile source (home-only read would be 0)"
  smoke_assert_file_exists "$wd/codex/extra.md" \
    "T7: codex/extra.md (profile-source only) not propagated to workdir"
  cmp -s "$BRIDGE_AGENT_HOME_ROOT/t7/codex/extra.md" "$wd/codex/extra.md" \
    || smoke_fail "T7: workdir codex/extra.md not byte-identical to the profile source"
}

# T8: ancestor-symlink containment (#1636 codex r1 [P2]). If a workdir scaffold
# ancestor is a symlink that escapes the target root, the helper must refuse to
# write through it (record an error, no file created outside the root) rather
# than follow the symlink out of bounds.
test_ancestor_symlink_containment() {
  setup_bridge_fixture
  write_roster t8
  seed_agent t8
  local wd="$BRIDGE_AGENT_ROOT_V2/t8/workdir"
  local escape="$SMOKE_TMP_ROOT/escape-outside-root"
  mkdir -p "$escape"
  # Replace the workdir's .claude with a symlink pointing OUTSIDE target_root.
  rm -rf "$wd/.claude"
  ln -s "$escape" "$wd/.claude"

  local out=""
  local rc=0
  out="$(run_helper t8 0)" || rc=$?

  smoke_assert_eq "0" "$rc" "T8: helper aborted instead of skip-with-error (rc=$rc)"
  smoke_assert_contains "$(json_field "$out" errors)" "outside agent workdir" \
    "T8: containment error not recorded"
  # The escaping write must NOT have landed in the symlink target.
  [[ ! -e "$escape/commands/wrap-up.md" ]] \
    || smoke_fail "T8: scaffold file was written outside the target root via symlink"
  # The refused path must NOT be reported as applied.
  smoke_assert_not_contains "$(json_field "$out" scaffold_paths)" "wrap-up.md" \
    "T8: refused (outside-root) scaffold path was reported as applied"
  # A scaffold root NOT behind the escaping symlink still got its files.
  smoke_assert_file_exists "$wd/codex/extra.md" \
    "T8: unrelated scaffolding regressed while guarding the symlink"
}

# T9: SAME-ROOT cross-agent symlink (codex pair-review BLOCKING). An in-root
# symlink from one agent's workdir into ANOTHER agent's workdir stays under the
# global target_root (BRIDGE_HOME) but escapes THIS agent's own workdir. The
# helper must refuse it (no write into the victim, path not reported as applied)
# — the global-root-only guard from round 1 missed this same-root case.
test_same_root_cross_agent_symlink_refused() {
  setup_bridge_fixture
  write_roster t9
  seed_agent t9
  # A second agent under the SAME data root (same target_root). Its workdir is
  # the symlink target the attacker points t9's .claude at.
  local victim_wd="$BRIDGE_AGENT_ROOT_V2/victim/workdir"
  mkdir -p "$victim_wd/.claude"
  local wd="$BRIDGE_AGENT_ROOT_V2/t9/workdir"
  rm -rf "$wd/.claude"
  ln -s "$victim_wd/.claude" "$wd/.claude"

  local out=""
  local rc=0
  out="$(run_helper t9 0)" || rc=$?

  smoke_assert_eq "0" "$rc" "T9: helper aborted instead of skip-with-error (rc=$rc)"
  smoke_assert_contains "$(json_field "$out" errors)" "outside agent workdir" \
    "T9: cross-agent containment error not recorded"
  # CRITICAL: nothing written into the victim agent's workdir.
  [[ ! -e "$victim_wd/.claude/commands/wrap-up.md" ]] \
    || smoke_fail "T9: scaffold file escaped into another agent's workdir via same-root symlink"
  # The refused path must NOT be reported as applied.
  smoke_assert_not_contains "$(json_field "$out" scaffold_paths)" "wrap-up.md" \
    "T9: refused cross-agent scaffold path was reported as applied"
}

smoke_run "T1 adds missing _template scaffolding to the workdir" test_adds_missing_scaffolding
smoke_run "T2 skip-existing never overwrites a customized file" test_skip_existing_customized
smoke_run "T3 re-run is idempotent" test_idempotent_rerun
smoke_run "T4 codex/AGENTS.md is not double-handled" test_codex_agents_not_double_handled
smoke_run "T4b dry-run plans scaffolding without writing" test_dry_run_plans_only
smoke_run "T5 iso write PermissionError graceful-skips" test_iso_write_permission_error_graceful_skip
smoke_run "T6 identity-file propagation is unchanged" test_identity_propagation_unchanged
smoke_run "T7 scaffold source is the profile, not the identity home" test_scaffold_source_is_profile_not_home
smoke_run "T8 outside-root ancestor-symlink write is contained" test_ancestor_symlink_containment
smoke_run "T9 same-root cross-agent symlink write is refused" test_same_root_cross_agent_symlink_refused
smoke_log "PASS: $SMOKE_NAME"
