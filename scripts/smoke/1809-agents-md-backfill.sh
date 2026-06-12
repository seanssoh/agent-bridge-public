#!/usr/bin/env bash
# 1809-agents-md-backfill.sh -- Issue #1809 codex AGENTS.md backfill (upgrade
# migration + doctor remediation + daemon hygiene pass).
#
# Codex agents created before the entrypoint-materialization existed have NO
# AGENTS.md identity contract and nothing in the runtime ever backfilled it
# (the watchdog flagged `missing_files: AGENTS.md` forever). This smoke pins the
# four contract halves the fix delivers:
#   T1  upgrade migrate-agents backfills a missing codex AGENTS.md (home), and
#       the workdir entrypoint mirror create-if-absents it.
#   T2  an existing AGENTS.md with a hand-written custom contract BELOW the
#       managed marker is REFRESHED (managed header re-rendered) with the custom
#       tail preserved BYTE-FOR-BYTE — never a whole-file clobber (the live
#       hand-backfill protection).
#   T3  a CLAUDE agent NEVER receives a root AGENTS.md (codex-only).
#   T4  a codex PAIR sharing the admin's workdir does NOT clobber the admin's
#       workdir entrypoint (the shared-workspace guard holds in the
#       entrypoint-backfill-only mirror too); AGENTS.md (codex) + CLAUDE.md
#       (claude) coexist in the shared workdir without clobber.
#   T5  bridge-doctor flags a missing codex AGENTS.md (missing-agent-entrypoint),
#       the focused backfill remediation create-if-absents it, and the daemon
#       hygiene helpers report non-clean + render the [hygiene] task body — only
#       when something was backfilled (clean pass = no task).
#
# The rematerialize helper is invoked DIRECTLY with the resolved bash 5.x binary
# (mirroring 1636-rematerialize-scaffolding.sh) so the Bash-3.2->4+ re-exec in
# bridge-lib.sh (#1454) never enters the picture. The python surfaces
# (migrate-agents, backfill-codex-entrypoints, doctor, daemon-helpers) are
# driven via their CLIs with a temp BRIDGE_HOME — the operator's live tree is
# never touched.

set -euo pipefail

SMOKE_NAME="1809-agents-md-backfill"
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
TEMPLATE_AGENTS_MD="$REPO_ROOT/agents/_template/codex/AGENTS.md"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

setup_bridge_fixture() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME/data"
  export BRIDGE_AGENT_ROOT_V2="$BRIDGE_DATA_ROOT/agents"
  {
    printf '%s\n' 'BRIDGE_LAYOUT=v2'
    printf 'BRIDGE_DATA_ROOT=%q\n' "$BRIDGE_DATA_ROOT"
  } >"$BRIDGE_STATE_DIR/layout-marker.sh"
  mkdir -p "$BRIDGE_AGENT_ROOT_V2"
}

# A codex roster agent in the v2 split layout: profile source under
# $BRIDGE_AGENT_HOME_ROOT/<agent>, identity home + workdir under
# $BRIDGE_AGENT_ROOT_V2/<agent>/{home,workdir}.
write_codex_roster() {
  local agent="$1"
  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="codex"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
}

write_codex_identity_home() {
  local dir="$1"
  mkdir -p "$dir"
  # The home identity AUTHORITY carries the codex AGENTS.md (rendered from the
  # template, with the managed block) + the rest of the canonical fileset.
  cp "$TEMPLATE_AGENTS_MD" "$dir/AGENTS.md"
  printf '# soul\n' >"$dir/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-codex\n- Engine: codex\n' >"$dir/SESSION-TYPE.md"
  printf 'memory\n' >"$dir/MEMORY.md"
  printf 'schema\n' >"$dir/MEMORY-SCHEMA.md"
  printf 'tools\n' >"$dir/TOOLS.md"
}

run_helper_codex() {
  local agent="$1"
  local dry="$2"
  shift 2 || true
  env "$@" "$BRIDGE_BASH" "$HELPER" "$REPO_ROOT" "$BRIDGE_HOME" "$agent" codex "$dry"
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

# ===========================================================================
# T1 — upgrade backfills a missing codex AGENTS.md (home) + workdir mirror.
# ===========================================================================
test_upgrade_backfills_missing_agents_md() {
  setup_bridge_fixture
  local agent=t1
  write_codex_roster "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local home="$BRIDGE_AGENT_ROOT_V2/$agent/home"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  # Pre-materialization agent: home + profile have the identity fileset but NO
  # AGENTS.md anywhere; workdir is bare.
  mkdir -p "$profile" "$home" "$workdir"
  printf '# Session Type\n\n- Session Type: static-codex\n- Engine: codex\n' >"$profile/SESSION-TYPE.md"
  printf '# %s — Monitor (런타임: Codex CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"
  cp "$profile/SESSION-TYPE.md" "$home/SESSION-TYPE.md"
  cp "$profile/CLAUDE.md" "$home/CLAUDE.md"
  cp "$profile/SOUL.md" "$home/SOUL.md"

  [[ ! -f "$profile/AGENTS.md" ]] || smoke_fail "T1 precondition: profile already has AGENTS.md"
  [[ ! -f "$workdir/AGENTS.md" ]] || smoke_fail "T1 precondition: workdir already has AGENTS.md"

  # Drive the real upgrade migrate-agents (home backfill + workdir mirror).
  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$agent" \
    >/dev/null 2>&1

  smoke_assert_file_exists "$profile/AGENTS.md" "T1: home AGENTS.md was not backfilled by upgrade"
  # The backfilled home AGENTS.md carries the managed-block markers + rendered role.
  smoke_assert_contains "$(cat "$profile/AGENTS.md")" "BEGIN AGENT BRIDGE DOC MIGRATION" \
    "T1: backfilled AGENTS.md missing the managed-block START marker"
  smoke_assert_contains "$(cat "$profile/AGENTS.md")" "You are a Codex" \
    "T1: backfilled AGENTS.md missing the template body"
  # The workdir mirror create-if-absented AGENTS.md from the home authority.
  smoke_assert_file_exists "$workdir/AGENTS.md" "T1: workdir AGENTS.md mirror was not created"
}

# ===========================================================================
# T2 — existing AGENTS.md with custom content below the marker is REFRESHED
#      (managed header updated) with the custom tail preserved byte-for-byte.
# ===========================================================================
test_refresh_preserves_custom_content() {
  setup_bridge_fixture
  local agent=t2
  write_codex_roster "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$profile"
  printf '# Session Type\n\n- Session Type: static-codex\n- Engine: codex\n' >"$profile/SESSION-TYPE.md"
  printf '# %s — Monitor (런타임: Codex CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"

  # A hand-backfilled AGENTS.md: a STALE managed block + a hand-written custom
  # contract below the END marker (exactly patch's live-backfill shape).
  local custom_marker="MY-HAND-WRITTEN-CONTRACT-DO-NOT-CLOBBER-1809"
  {
    printf '<!-- Managed by agent-bridge. Regenerated by agent-bridge. -->\n'
    printf '# %s — Monitor (런타임: Codex CLI)\n\n' "$agent"
    printf '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->\n'
    printf 'OLD STALE MANAGED CONTENT THAT MUST BE REPLACED\n'
    printf '<!-- END AGENT BRIDGE DOC MIGRATION -->\n\n'
    printf -- '---\n\n'
    printf '## %s\n' "$custom_marker"
    printf 'patch wrote this custom contract by hand and it MUST survive verbatim.\n'
    printf 'line two of the custom tail.\n'
  } >"$profile/AGENTS.md"
  local custom_tail_before
  custom_tail_before="$(awk '/END AGENT BRIDGE DOC MIGRATION/{f=1;next} f' "$profile/AGENTS.md")"

  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$agent" \
    >/dev/null 2>&1

  # Stale managed content replaced by the fresh template block.
  if grep -q "OLD STALE MANAGED CONTENT" "$profile/AGENTS.md"; then
    smoke_fail "T2: stale managed block was NOT refreshed"
  fi
  smoke_assert_contains "$(cat "$profile/AGENTS.md")" "You are a Codex" \
    "T2: fresh template managed block was not spliced in"
  # Custom tail preserved BYTE-FOR-BYTE.
  local custom_tail_after
  custom_tail_after="$(awk '/END AGENT BRIDGE DOC MIGRATION/{f=1;next} f' "$profile/AGENTS.md")"
  smoke_assert_eq "$custom_tail_before" "$custom_tail_after" \
    "T2: custom content below the managed marker was NOT preserved byte-for-byte"
  smoke_assert_contains "$(cat "$profile/AGENTS.md")" "$custom_marker" \
    "T2: hand-written custom heading was lost"
  smoke_assert_contains "$(cat "$profile/AGENTS.md")" "line two of the custom tail." \
    "T2: hand-written custom body was lost"
}

# ===========================================================================
# T3 — a CLAUDE agent NEVER receives a root AGENTS.md entrypoint (codex-only).
# ===========================================================================
test_claude_agent_never_gets_agents_md() {
  setup_bridge_fixture
  local agent=t3
  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$profile"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$profile/SESSION-TYPE.md"
  printf '# %s — Monitor (런타임: Claude Code CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"

  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$agent" \
    >/dev/null 2>&1

  # The claude agent must NOT get a root AGENTS.md entrypoint. (A template
  # `codex/AGENTS.md` SUBDIR file from the scaffold tree is unrelated and
  # pre-existing — we assert specifically on the root entrypoint.)
  [[ ! -f "$profile/AGENTS.md" ]] \
    || smoke_fail "T3: claude agent received a root AGENTS.md entrypoint (must be codex-only)"

  # And the doctor must NOT flag the claude agent.
  cat >"$SMOKE_TMP_ROOT/reg-t3.json" <<JSON
[{"id":"$agent","engine":"claude","home":"$profile","workdir":"$BRIDGE_AGENT_ROOT_V2/$agent/workdir"}]
JSON
  local out=""
  out="$(python3 "$REPO_ROOT/bridge-doctor.py" --json --detectors missing-agent-entrypoint \
    --agent-registry-json "$SMOKE_TMP_ROOT/reg-t3.json" \
    --agent-list-json "$SMOKE_TMP_ROOT/reg-t3.json" \
    --state-dir "$BRIDGE_STATE_DIR" --agent-home-root "$BRIDGE_AGENT_HOME_ROOT" 2>/dev/null)"
  smoke_assert_not_contains "$out" "missing-agent-entrypoint" \
    "T3: doctor flagged a claude agent for a missing AGENTS.md (must be codex-only)"
}

# ===========================================================================
# T4 — a codex PAIR sharing the admin's workdir does NOT clobber it; AGENTS.md
#      (codex) and CLAUDE.md (claude) coexist in the shared workdir.
# ===========================================================================
test_shared_workdir_pair_no_clobber() {
  setup_bridge_fixture
  local admin=patch
  local pair=patch-dev
  local shared="$BRIDGE_DATA_ROOT/managed-project"
  local pair_home="$BRIDGE_AGENT_ROOT_V2/$pair/home"
  mkdir -p "$shared" "$pair_home"

  # Roster: admin=claude, pair=codex, both resolve to the SAME shared workdir.
  {
    printf 'BRIDGE_AGENT_IDS=("%s" "%s")\n' "$admin" "$pair"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$admin"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$pair"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$admin"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="codex"\n' "$pair"
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$admin" "$admin"
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$pair" "$pair"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$admin"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$pair"
    printf 'BRIDGE_AGENT_ISOLATION_MODE["%s"]="shared"\n' "$admin"
    printf 'BRIDGE_AGENT_ISOLATION_MODE["%s"]="shared"\n' "$pair"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$admin" "$shared"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$pair" "$shared"
  } >"$BRIDGE_ROSTER_FILE"

  # The shared workdir holds the ADMIN's correct claude identity (CLAUDE.md
  # naming the admin). The pair's home has its own codex AGENTS.md template.
  printf '# %s — Manager/admin role  (런타임: Claude Code CLI)\n' "$admin" >"$shared/CLAUDE.md"
  printf '# %s soul\n' "$admin" >"$shared/SOUL.md"
  cp "$TEMPLATE_AGENTS_MD" "$pair_home/AGENTS.md"
  printf '# %s soul\n' "$pair" >"$pair_home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-codex\n- Engine: codex\n' >"$pair_home/SESSION-TYPE.md"

  local admin_claude_before
  admin_claude_before="$(cat "$shared/CLAUDE.md")"

  # Run the codex pair's entrypoint-backfill-only mirror against the shared
  # workdir. The shared-workspace guard must decline (skipped_reason).
  local out=""
  out="$(run_helper_codex "$pair" 0 BRIDGE_REMAT_ENTRYPOINT_BACKFILL_ONLY=1)"

  smoke_assert_eq "shared_workspace" "$(json_field "$out" skipped_reason)" \
    "T4: codex pair entrypoint-backfill was NOT declined on the shared admin workdir"
  # CRITICAL: the admin's workdir CLAUDE.md is untouched (no codex clobber).
  smoke_assert_eq "$admin_claude_before" "$(cat "$shared/CLAUDE.md")" \
    "T4: codex pair backfill mutated the admin's shared workdir CLAUDE.md"
  if grep -q "patch-dev\|You are a Codex" "$shared/CLAUDE.md" 2>/dev/null; then
    smoke_fail "T4: codex pair identity leaked into the admin's shared workdir CLAUDE.md"
  fi
  # The pair did NOT stamp its AGENTS.md into the shared workdir either.
  [[ ! -f "$shared/AGENTS.md" ]] \
    || smoke_fail "T4: codex pair stamped its AGENTS.md into the shared admin workdir"

  # Coexistence: the admin's create-time materialize legitimately keeps the
  # claude CLAUDE.md; a codex AGENTS.md authored alongside it (not by the
  # foreign pair) must not disturb the CLAUDE.md.
  printf '# shared-project codex contract\n' >"$shared/AGENTS.md"
  smoke_assert_eq "$admin_claude_before" "$(cat "$shared/CLAUDE.md")" \
    "T4: an AGENTS.md alongside CLAUDE.md disturbed the CLAUDE.md (coexistence)"
}

# ===========================================================================
# T5 — doctor flags the missing entrypoint; the focused remediation backfills
#      it; the daemon hygiene helpers report non-clean + render the task body
#      ONLY when something was backfilled.
# ===========================================================================
test_doctor_flags_and_remediation_backfills_and_emits_task() {
  setup_bridge_fixture
  local agent=t5
  write_codex_roster "$agent"
  local profile="$BRIDGE_AGENT_HOME_ROOT/$agent"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$profile" "$workdir"
  printf '# Session Type\n\n- Session Type: static-codex\n- Engine: codex\n' >"$profile/SESSION-TYPE.md"
  printf '# %s — Monitor (런타임: Codex CLI)\n' "$agent" >"$profile/CLAUDE.md"
  printf '# soul\n' >"$profile/SOUL.md"

  # (a) doctor FLAGS the missing codex AGENTS.md.
  cat >"$SMOKE_TMP_ROOT/reg-t5.json" <<JSON
[{"id":"$agent","engine":"codex","home":"$profile","workdir":"$workdir"}]
JSON
  local doc=""
  doc="$(python3 "$REPO_ROOT/bridge-doctor.py" --json --detectors missing-agent-entrypoint \
    --agent-registry-json "$SMOKE_TMP_ROOT/reg-t5.json" \
    --agent-list-json "$SMOKE_TMP_ROOT/reg-t5.json" \
    --state-dir "$BRIDGE_STATE_DIR" --agent-home-root "$BRIDGE_AGENT_HOME_ROOT" 2>/dev/null)"
  smoke_assert_contains "$doc" "missing-agent-entrypoint" \
    "T5: doctor did NOT flag the missing codex AGENTS.md"
  smoke_assert_contains "$doc" "\"agent\": \"$agent\"" \
    "T5: doctor finding did not name the codex agent"

  # (b) the focused backfill remediation create-if-absents AGENTS.md (home),
  #     emitting a non-clean summary that names the agent.
  local summary=""
  summary="$(python3 "$REPO_ROOT/bridge-upgrade.py" backfill-codex-entrypoints \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$agent" 2>/dev/null)"
  smoke_assert_file_exists "$profile/AGENTS.md" "T5: remediation did not backfill the home AGENTS.md"
  smoke_assert_contains "$summary" "\"backfilled\"" "T5: backfill summary missing the backfilled list"
  smoke_assert_contains "$summary" "$agent" "T5: backfill summary did not name the codex agent"
  printf '%s' "$summary" >"$SMOKE_TMP_ROOT/backfill-summary.json"

  # (c) the daemon hygiene helpers: non-clean=1 on the backfilled summary, and
  #     the rendered [hygiene] task body names the backfilled agent.
  local nc=""
  nc="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-non-clean \
    "$SMOKE_TMP_ROOT/backfill-summary.json")"
  smoke_assert_eq "1" "$nc" "T5: backfilled pass was not reported non-clean"
  local body=""
  body="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-task-body \
    "$SMOKE_TMP_ROOT/backfill-summary.json" testhost)"
  # The body helper renders the [hygiene] task BODY (the daemon owns the
  # "[hygiene] ..." TITLE); assert on the body subject + the backfilled agent.
  smoke_assert_contains "$body" "codex AGENTS.md backfill" "T5: task body wrong subject"
  smoke_assert_contains "$body" "Backfilled" "T5: task body missing the Backfilled section"
  smoke_assert_contains "$body" "$agent" "T5: task body did not list the backfilled agent"

  # (d) a re-run is a clean no-op: nothing backfilled -> non-clean=0 -> NO task.
  local rerun=""
  rerun="$(python3 "$REPO_ROOT/bridge-upgrade.py" backfill-codex-entrypoints \
    --source-root "$REPO_ROOT" --target-root "$BRIDGE_HOME" --admin-agent "$agent" 2>/dev/null)"
  printf '%s' "$rerun" >"$SMOKE_TMP_ROOT/rerun-summary.json"
  smoke_assert_eq "0" "$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" agent-doc-backfill-non-clean \
    "$SMOKE_TMP_ROOT/rerun-summary.json")" \
    "T5: a clean re-run (nothing backfilled) was reported non-clean (would file a spurious [hygiene] task)"
}

smoke_run "T1 upgrade backfills a missing codex AGENTS.md (home + workdir mirror)" \
  test_upgrade_backfills_missing_agents_md
smoke_run "T2 refresh preserves custom content below the managed marker byte-for-byte" \
  test_refresh_preserves_custom_content
smoke_run "T3 a claude agent never gets a root AGENTS.md (codex-only)" \
  test_claude_agent_never_gets_agents_md
smoke_run "T4 a codex pair does not clobber the shared admin workdir (coexistence)" \
  test_shared_workdir_pair_no_clobber
smoke_run "T5 doctor flags + remediation backfills + emits [hygiene] task (non-clean only)" \
  test_doctor_flags_and_remediation_backfills_and_emits_task
smoke_log "PASS: $SMOKE_NAME"
