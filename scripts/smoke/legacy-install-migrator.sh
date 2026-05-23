#!/usr/bin/env bash
# scripts/smoke/legacy-install-migrator.sh — release-gate smoke #4
#
# Synthetic legacy-install repro for scripts/migrate-legacy-install.sh.
#
# Builds a fake old-style install (two agents + cron + memory + channel config),
# then runs: export → plan → confirm-apply-deferred.
#
# beta6 fold-back per codex r1 review: apply is DEFERRED to beta7 (three
# contract gaps — clean-target gate, layout-resolver bypass, secret re-entry).
# The smoke now asserts the user-facing apply default is refused with a clear
# beta7 deferral message and does NOT mutate the target. The full apply +
# post-apply verify smoke moves to beta7 alongside the apply rework.
#
# Assertions (beta6):
#   1. export writes a manifest + agent identity files to bundle dir.
#   2. plan prints apply plan and target-cleanliness check without error.
#   3. secrets are NOT in the bundle (Teams secret, A2A key).
#   4. workspace / project-tree files are NOT in the bundle (non-portable).
#   5. apply default invocation is REFUSED (beta7 deferral message).
#   6. deferred apply does NOT mutate the target (no apply-result manifest,
#      no target/agents/ created).

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
# 3. apply is deferred to beta7 — confirm default invocation refuses to run.
# ---------------------------------------------------------------------------
# beta6 fold-back per codex r1 review: apply has three open contract gaps
# (clean-target gate insufficient, layout-resolver bypass, supplied secrets
# never written) and is gated behind BRIDGE_MIGRATOR_BETA6_APPLY_UNSAFE=1
# for follow-up dev only. The user-facing default refuses with a clear
# message. Verify regression (post-apply) moves to beta7 alongside the
# apply rework.
smoke_log "testing apply default invocation is deferred (beta7 contract gate)"
rm -rf "$CLEAN_TARGET"
mkdir -p "$CLEAN_TARGET"
set +e
apply_deferred_out="$(bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$CLEAN_TARGET" 2>&1)"
apply_deferred_rc=$?
set -e
if [[ "$apply_deferred_rc" -eq 0 ]]; then
  smoke_fail "apply default invocation must refuse (beta7 deferral); rc=0 instead"
fi
smoke_assert_contains "$apply_deferred_out" "deferred to beta7" \
  "apply refusal mentions beta7 deferral"
# Confirm the unsafe env var is the documented dev escape hatch.
smoke_assert_contains "$apply_deferred_out" "BRIDGE_MIGRATOR_BETA6_APPLY_UNSAFE" \
  "apply refusal documents the dev opt-in env var"
smoke_log "assertion: apply deferred to beta7 (default invocation refused) — PASS"

# Confirm the target was NOT mutated by the deferred apply.
if [[ -f "$CLEAN_TARGET/.migrator-apply-result.json" ]]; then
  smoke_fail "deferred apply must not write any apply-result manifest"
fi
if [[ -d "$CLEAN_TARGET/agents" ]]; then
  smoke_fail "deferred apply must not create target/agents/"
fi
smoke_log "assertion: deferred apply did NOT mutate target — PASS"

smoke_log "all assertions passed"
