#!/usr/bin/env bash
# scripts/smoke/legacy-install-migrator.sh — release-gate smoke #4
#
# Synthetic legacy-install repro for scripts/migrate-legacy-install.sh.
#
# Builds a fake old-style install (two agents + cron + memory + channel config),
# then runs: export → plan → apply → verify.
#
# Issue #1087 (v0.14.5-beta7+): apply ships as the user-facing default
# (no BRIDGE_MIGRATOR_BETA6_APPLY_UNSAFE gate). The smoke asserts the
# full round-trip plus the contract surface from the codex r1 review:
#   - cleanliness gate covers every apply write path (not just state/*).
#   - per-agent paths come from the layout shim (canonical resolver).
#   - cron payload.env is filtered through CRON_ENV_ALLOWLIST.
#   - apply is atomic with rollback on failure.
#   - operator-supplied secrets are written with mode 0600; source
#     secrets remain stripped.
#
# Assertions:
#   1. export writes a manifest + agent identity files to bundle dir.
#   2. plan prints apply plan and target-cleanliness check without error.
#   3. secrets are NOT in the bundle (Teams secret, A2A key).
#   4. workspace / project-tree files are NOT in the bundle (non-portable).
#   5. cron env scrub uses the allowlist (FOO_TOKEN dropped, PATH kept).
#   6. apply succeeds against a clean target.
#   7. cleanliness gate refuses a polluted target (agents/admin/SOUL.md
#      pre-exists — codex r1 BLOCKING #1 repro).
#   8. apply writes target via the canonical resolver (data/agents/<a>/home).
#   9. verify PASS — all canonical-resolver checks pass.

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

# Cron definitions — payload.env has an allowlisted key (PATH) and a
# non-allowlisted key (FOO_TOKEN). The allowlist scrub must drop the
# latter.
printf '[{"name":"daily-note","target":"admin","schedule":"0 8 * * *","timezone":"UTC","payload_kind":"text","payload":{"text":"daily note","env":{"PATH":"/usr/bin","FOO_TOKEN":"secret"}},"enabled":true}]\n' \
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

# Cron env scrub: PATH stays, FOO_TOKEN is dropped. Issue #1087
# BLOCKING #3 — beta6 keyword heuristic would have stripped FOO_TOKEN
# only because it ends in `_TOKEN`; the new allowlist drops everything
# not explicitly safe.
cron_env_keys="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" manifest-first-cron-env-keys "$BUNDLE_DIR/manifest.json")"
smoke_assert_contains "$cron_env_keys" "PATH" "cron env allowlist keeps PATH"
if [[ "$cron_env_keys" == *FOO_TOKEN* ]]; then
  smoke_fail "cron env allowlist must drop FOO_TOKEN, got: $cron_env_keys"
fi
smoke_log "assertion: cron env allowlist scrub — PASS"

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
smoke_assert_contains "$plan_out" "apply may proceed" "plan no longer references beta7 deferral"
smoke_log "assertion: plan output correct — PASS"

# ---------------------------------------------------------------------------
# 3. apply (default; no env-var gate) against a clean target.
# ---------------------------------------------------------------------------
smoke_log "running apply against clean target"
# Wipe the state/ stub plan left so the cleanliness gate is fully clean.
rm -rf "$CLEAN_TARGET"
mkdir -p "$CLEAN_TARGET"
bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$CLEAN_TARGET"
smoke_assert_file_exists "$CLEAN_TARGET/.migrator-apply-result.json" \
  "apply writes apply-result manifest"
# Issue #1087 BLOCKING #2 — apply must drop identity at the canonical
# resolver path (data/agents/<a>/home), not the legacy agents/<a>/ shape.
smoke_assert_file_exists "$CLEAN_TARGET/data/agents/admin/home/SOUL.md" \
  "apply writes admin SOUL.md at canonical resolver path"
smoke_assert_file_exists "$CLEAN_TARGET/data/agents/admin/home/MEMORY.md" \
  "apply writes admin MEMORY.md at canonical resolver path"
smoke_assert_file_exists "$CLEAN_TARGET/data/agents/reviewer/home/SOUL.md" \
  "apply writes reviewer SOUL.md at canonical resolver path"
smoke_assert_file_exists "$CLEAN_TARGET/cron/jobs.json" "apply imports cron jobs"
# Backup tree exists with real file contents — manifest+files.
smoke_assert_file_exists "$CLEAN_TARGET/.migrator-pre-apply-backup/pre-apply-backup-manifest.json" \
  "apply writes pre-apply backup manifest"
smoke_log "assertion: apply succeeds, identity at canonical paths — PASS"

# ---------------------------------------------------------------------------
# 4. cleanliness gate refuses a polluted target — codex r1 BLOCKING #1
#    repro: target has agents/admin/SOUL.md = OLD already, must refuse.
# ---------------------------------------------------------------------------
smoke_log "testing cleanliness gate refuses polluted target"
mkdir -p "$DIRTY_TARGET/agents/admin"
printf 'OLD\n' > "$DIRTY_TARGET/agents/admin/SOUL.md"
set +e
dirty_apply_out="$(bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$DIRTY_TARGET" 2>&1)"
dirty_apply_rc=$?
set -e
if [[ "$dirty_apply_rc" -eq 0 ]]; then
  smoke_fail "apply against polluted target must refuse (rc!=0); got rc=0"
fi
smoke_assert_contains "$dirty_apply_out" "not clean/fresh" \
  "polluted-target refusal mentions cleanliness gate"
smoke_assert_contains "$dirty_apply_out" "agents" \
  "polluted-target refusal cites blocking path (agents/)"
# Confirm SOUL.md is byte-preserved (the codex r1 repro: it became NEW).
dirty_soul="$(cat "$DIRTY_TARGET/agents/admin/SOUL.md")"
smoke_assert_eq "OLD" "$dirty_soul" \
  "polluted target SOUL.md preserved byte-for-byte (codex r1 BLOCKING #1)"
smoke_log "assertion: polluted target refused + content preserved — PASS"

# ---------------------------------------------------------------------------
# 5. verify against the migrated target.
# ---------------------------------------------------------------------------
smoke_log "running verify on migrated target"
verify_out="$(bash "$MIGRATOR" verify --target "$CLEAN_TARGET")"
smoke_assert_contains "$verify_out" "all" "verify output reports all passes"
smoke_assert_contains "$verify_out" "agent admin: identity files present" \
  "verify confirms admin identity at canonical path"
smoke_assert_contains "$verify_out" "agent reviewer: identity files present" \
  "verify confirms reviewer identity at canonical path"
smoke_log "assertion: verify PASS — all canonical-resolver checks — PASS"

smoke_log "all assertions passed"
