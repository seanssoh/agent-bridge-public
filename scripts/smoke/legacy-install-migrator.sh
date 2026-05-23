#!/usr/bin/env bash
# scripts/smoke/legacy-install-migrator.sh — release-gate smoke #4
#
# Synthetic legacy-install repro for scripts/migrate-legacy-install.sh.
#
# Builds a fake old-style install (two agents + cron + memory + channel config),
# then runs: export → plan → apply-to-clean → verify.
#
# Assertions:
#   1. export writes a manifest + agent identity files to bundle dir.
#   2. plan prints apply plan and target-cleanliness check without error.
#   3. apply REFUSES a non-empty target (safety gate).
#   4. apply SUCCEEDS into a clean target; identity lands in agent_home.
#   5. workspace / project-tree files are NOT copied (non-portable).
#   6. secrets are NOT in the bundle (Teams secret, A2A key).
#   7. verify PASSES on the migrated target.
#   8. apply writes .migrator-apply-result.json with correct agent list.

set -euo pipefail

SMOKE_NAME="legacy-install-migrator"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

MIGRATOR="$SMOKE_REPO_ROOT/scripts/migrate-legacy-install.sh"
HELPER_DIR="$SMOKE_REPO_ROOT/scripts/python-helpers"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

OLD_HOME="$SMOKE_TMP_ROOT/old-bridge-home"
BUNDLE_DIR="$SMOKE_TMP_ROOT/bundle"
CLEAN_TARGET="$SMOKE_TMP_ROOT/clean-bridge-home"
DIRTY_TARGET="$SMOKE_TMP_ROOT/dirty-bridge-home"

# ---------------------------------------------------------------------------
# Build synthetic legacy install
# ---------------------------------------------------------------------------
smoke_log "building synthetic legacy install at $OLD_HOME"

mkdir -p \
  "$OLD_HOME/state" \
  "$OLD_HOME/logs" \
  "$OLD_HOME/agents/admin/memory" \
  "$OLD_HOME/agents/admin/users/alice" \
  "$OLD_HOME/agents/reviewer" \
  "$OLD_HOME/cron"

# Layout marker (v2 not set → legacy layout)
printf 'BRIDGE_LAYOUT=legacy\n' >"$OLD_HOME/state/layout-marker.sh"

# Agent 1: admin — with identity files, memory, users
printf '# Admin soul\n' >"$OLD_HOME/agents/admin/SOUL.md"
printf '# Admin memory\n' >"$OLD_HOME/agents/admin/MEMORY.md"
printf 'session-type: admin\n' >"$OLD_HOME/agents/admin/SESSION-TYPE.md"
printf '# Admin memory note\n' >"$OLD_HOME/agents/admin/memory/notes.md"
printf '# Alice USER\n' >"$OLD_HOME/agents/admin/users/alice/USER.md"

# Non-portable file that must NOT be copied.
printf 'tmux-session-123\n' >"$OLD_HOME/agents/admin/session_id"
printf '12345\n' >"$OLD_HOME/agents/admin/pid"

# Agent 2: reviewer — minimal
printf '# Reviewer soul\n' >"$OLD_HOME/agents/reviewer/SOUL.md"

# Cron definitions (portable, no secrets).
printf '[{"name":"daily-note","target":"admin","schedule":"0 8 * * *","timezone":"UTC","payload_kind":"text","payload":{"text":"daily note"},"enabled":true}]\n' \
  >"$OLD_HOME/cron/jobs.json"

# Host profile.
printf '{"os":"linux","sudo_available":true,"bridge_version":"0.14.0"}\n' \
  >"$OLD_HOME/state/host-profile.json"

# Secret files — must NOT appear in bundle.
printf '{"bridge_id":"old-bridge","peers":[],"hmac_secret":"TOPSECRET"}\n' \
  >"$OLD_HOME/handoff.local.json"
printf 'TEAMS_APP_PASSWORD=super-secret-pass\n' >"$OLD_HOME/.env"

# Roster files (minimal).
printf '' >"$OLD_HOME/agent-roster.sh"
printf 'BRIDGE_AGENT_DESC["admin"]="Main admin agent"\n' >"$OLD_HOME/agent-roster.local.sh"
printf 'BRIDGE_AGENT_ENGINE["admin"]="claude"\n' >>"$OLD_HOME/agent-roster.local.sh"

smoke_log "synthetic legacy install ready"

# ---------------------------------------------------------------------------
# 1. export
# ---------------------------------------------------------------------------
smoke_log "running export"
bash "$MIGRATOR" export --source "$OLD_HOME" --bundle "$BUNDLE_DIR"

smoke_assert_file_exists "$BUNDLE_DIR/manifest.json" "manifest written by export"
smoke_assert_file_exists "$BUNDLE_DIR/agents/admin/SOUL.md" "admin SOUL.md in bundle"
smoke_assert_file_exists "$BUNDLE_DIR/agents/admin/MEMORY.md" "admin MEMORY.md in bundle"
smoke_assert_file_exists "$BUNDLE_DIR/agents/admin/SESSION-TYPE.md" "admin SESSION-TYPE.md in bundle"
smoke_assert_file_exists "$BUNDLE_DIR/agents/admin/memory/notes.md" "admin memory/notes.md in bundle"
smoke_assert_file_exists "$BUNDLE_DIR/agents/admin/users/alice/USER.md" "admin users/alice/USER.md in bundle"
smoke_assert_file_exists "$BUNDLE_DIR/agents/reviewer/SOUL.md" "reviewer SOUL.md in bundle"
smoke_log "assertion: identity files present in bundle — PASS"

# Non-portable files must NOT be in bundle.
if [[ -f "$BUNDLE_DIR/agents/admin/session_id" ]]; then
  smoke_fail "session_id must not be in bundle (non-portable)"
fi
if [[ -f "$BUNDLE_DIR/agents/admin/pid" ]]; then
  smoke_fail "pid must not be in bundle (non-portable)"
fi
smoke_log "assertion: non-portable files absent from bundle — PASS"

# Secrets must NOT be in bundle.
if [[ -f "$BUNDLE_DIR/handoff.local.json" ]]; then
  smoke_fail "handoff.local.json (A2A secret) must not be in bundle"
fi
if [[ -f "$BUNDLE_DIR/.env" ]]; then
  smoke_fail ".env (Teams secret) must not be in bundle"
fi
smoke_log "assertion: secret files absent from bundle — PASS"

# Verify manifest lists agents.
agent_count="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" manifest-agent-count "$BUNDLE_DIR/manifest.json")"
if [[ "$agent_count" -lt 2 ]]; then
  smoke_fail "manifest should list >=2 agents, got $agent_count"
fi
smoke_log "assertion: manifest agent count=$agent_count — PASS"

# Verify cron definitions exported.
cron_count="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" manifest-cron-count "$BUNDLE_DIR/manifest.json")"
if [[ "$cron_count" -lt 1 ]]; then
  smoke_fail "manifest should list >=1 cron job, got $cron_count"
fi
smoke_log "assertion: cron count=$cron_count — PASS"

# ---------------------------------------------------------------------------
# 2. plan
# ---------------------------------------------------------------------------
smoke_log "running plan"
mkdir -p "$CLEAN_TARGET/state"
# Fresh target — no layout marker yet, no agents.
plan_out="$(bash "$MIGRATOR" plan --bundle "$BUNDLE_DIR" --target "$CLEAN_TARGET")"
smoke_assert_contains "$plan_out" "admin" "plan output lists admin agent"
smoke_assert_contains "$plan_out" "reviewer" "plan output lists reviewer agent"
smoke_assert_contains "$plan_out" "daily-note" "plan output lists cron job"
smoke_assert_contains "$plan_out" "clean/fresh" "plan detects clean target"
smoke_log "assertion: plan output correct — PASS"

# ---------------------------------------------------------------------------
# 3. apply REFUSES non-empty target
# ---------------------------------------------------------------------------
smoke_log "testing apply refuses dirty target"
mkdir -p "$DIRTY_TARGET/state/agents/admin"
printf '{}' >"$DIRTY_TARGET/state/tasks.db"
set +e
apply_refuse_out="$(bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$DIRTY_TARGET" 2>&1)"
apply_refuse_rc=$?
set -e
if [[ "$apply_refuse_rc" -eq 0 ]]; then
  smoke_fail "apply must refuse a non-empty target (returned 0 on dirty target)"
fi
smoke_assert_contains "$apply_refuse_out" "not clean" "apply refuse message mentions not clean"
smoke_log "assertion: apply refused dirty target — PASS"

# ---------------------------------------------------------------------------
# 4. apply to clean target
# ---------------------------------------------------------------------------
smoke_log "running apply to clean target"
rm -rf "$CLEAN_TARGET"
mkdir -p "$CLEAN_TARGET"
bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$CLEAN_TARGET"

# Verify apply result manifest exists.
smoke_assert_file_exists "$CLEAN_TARGET/.migrator-apply-result.json" "apply-result manifest"

# Check applied_agents list in result.
applied_agents="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" apply-result-agents "$CLEAN_TARGET/.migrator-apply-result.json")"
smoke_assert_contains "$applied_agents" "admin" "apply result lists admin agent"
smoke_assert_contains "$applied_agents" "reviewer" "apply result lists reviewer agent"
smoke_log "assertion: apply result applied_agents correct — PASS"

# Identity files land in legacy-layout agent homes (legacy source → legacy target).
smoke_assert_file_exists "$CLEAN_TARGET/agents/admin/SOUL.md" "admin SOUL.md in target agent home"
smoke_assert_file_exists "$CLEAN_TARGET/agents/admin/MEMORY.md" "admin MEMORY.md in target agent home"
smoke_assert_file_exists "$CLEAN_TARGET/agents/admin/memory/notes.md" "admin memory/notes.md in target"
smoke_assert_file_exists "$CLEAN_TARGET/agents/admin/users/alice/USER.md" "admin users/alice/USER.md in target"
smoke_assert_file_exists "$CLEAN_TARGET/agents/reviewer/SOUL.md" "reviewer SOUL.md in target"
smoke_log "assertion: identity files in correct agent_home paths — PASS"

# Non-portable files must NOT be in target.
if [[ -f "$CLEAN_TARGET/agents/admin/session_id" ]]; then
  smoke_fail "session_id must not be in applied target (non-portable)"
fi
if [[ -f "$CLEAN_TARGET/agents/admin/pid" ]]; then
  smoke_fail "pid must not be in applied target (non-portable)"
fi
smoke_log "assertion: non-portable files absent from target — PASS"

# Secrets must NOT be in target.
if [[ -f "$CLEAN_TARGET/handoff.local.json" ]]; then
  smoke_fail "handoff.local.json (A2A secret) must not be in applied target"
fi
if [[ -f "$CLEAN_TARGET/.env" ]]; then
  smoke_fail ".env (Teams secret) must not be in applied target"
fi
smoke_log "assertion: secrets absent from applied target — PASS"

# Cron definitions imported.
smoke_assert_file_exists "$CLEAN_TARGET/cron/jobs.json" "cron jobs.json in target"
cron_target_count="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" cron-job-count "$CLEAN_TARGET/cron/jobs.json")"
if [[ "$cron_target_count" -lt 1 ]]; then
  smoke_fail "cron jobs.json in target should have >=1 entry, got $cron_target_count"
fi
smoke_log "assertion: cron definitions in target count=$cron_target_count — PASS"

# ---------------------------------------------------------------------------
# 5. verify
# ---------------------------------------------------------------------------
smoke_log "running verify on migrated target"
verify_out="$(bash "$MIGRATOR" verify --target "$CLEAN_TARGET")"
smoke_assert_contains "$verify_out" "PASS" "verify reports PASSes"
if echo "$verify_out" | grep -q "FAIL"; then
  smoke_fail "verify reported FAIL on correctly migrated target"
fi
smoke_log "assertion: verify PASS — PASS"

smoke_log "all assertions passed"
