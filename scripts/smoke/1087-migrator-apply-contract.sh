#!/usr/bin/env bash
# scripts/smoke/1087-migrator-apply-contract.sh
#
# Dedicated smoke for issue #1087 — close the codex r1 contract gaps in
# scripts/migrate-legacy-install.sh:apply. Each section below maps to
# one contract gap so a regression points directly at the closed gap.
#
# Gap 1 (BLOCKING) — clean-target gate insufficient.
# Gap 2 (BLOCKING) — layout-resolver bypass.
# Gap 3 (BLOCKING) — operator-supplied secrets accepted but never written;
#                    cron payload.env scrubbed by keyword heuristic.
# Should-fix      — apply is not atomic; partial failure leaves the
#                    target in a half-migrated state.
#
# This smoke is complementary to legacy-install-migrator.sh (which
# covers the full export → plan → apply → verify round-trip). The two
# smoke files share no state; each one builds and tears down its own
# synthetic install under SMOKE_TMP_ROOT.

set -euo pipefail

SMOKE_NAME="1087-migrator-apply-contract"
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

OLD_HOME="$SMOKE_TMP_ROOT/old"
BUNDLE_DIR="$SMOKE_TMP_ROOT/bundle"
SECRETS_DIR="$SMOKE_TMP_ROOT/secrets"

# ---------------------------------------------------------------------------
# Synthetic legacy install + bundle (shared for every gap section)
# ---------------------------------------------------------------------------
smoke_log "building synthetic legacy install"

mkdir -p \
  "$OLD_HOME/state" \
  "$OLD_HOME/agents/admin/memory" \
  "$OLD_HOME/agents/reviewer" \
  "$OLD_HOME/cron" \
  "$SECRETS_DIR"

printf 'BRIDGE_LAYOUT=legacy\n' >"$OLD_HOME/state/layout-marker.sh"
printf '# Admin soul\n'                >"$OLD_HOME/agents/admin/SOUL.md"
printf '# Admin memory file\n'         >"$OLD_HOME/agents/admin/MEMORY.md"
printf 'session-type: admin\n'         >"$OLD_HOME/agents/admin/SESSION-TYPE.md"
printf '# admin memory note\n'         >"$OLD_HOME/agents/admin/memory/notes.md"
printf '# Reviewer soul\n'             >"$OLD_HOME/agents/reviewer/SOUL.md"

# Cron with payload.env carrying both a safe (PATH) and an unsafe
# (AUTHORIZATION) key. The beta6 keyword heuristic would have let
# AUTHORIZATION through because none of TOKEN/SECRET/PASSWORD/KEY/PASS
# match it; the new allowlist must drop it.
printf '[{"name":"daily","target":"admin","schedule":"0 8 * * *","timezone":"UTC","payload_kind":"text","payload":{"text":"note","env":{"PATH":"/usr/bin","AUTHORIZATION":"Bearer xxx","COOKIE":"sid=zzz"}},"enabled":true}]\n' \
  >"$OLD_HOME/cron/jobs.json"

printf '' >"$OLD_HOME/agent-roster.sh"
printf '' >"$OLD_HOME/agent-roster.local.sh"

# Build bundle.
bash "$MIGRATOR" export --source "$OLD_HOME" --bundle "$BUNDLE_DIR" >/dev/null
smoke_assert_file_exists "$BUNDLE_DIR/manifest.json" "bundle manifest exists"
smoke_log "synthetic legacy install + bundle ready"

# ---------------------------------------------------------------------------
# Gap 1 — clean-target gate insufficient.
#
# Repro from codex r1: a target with `agents/admin/SOUL.md = OLD`
# pre-existing was marked `cleanliness: PASS` and apply overwrote it.
# The new inclusive list must refuse, and the pre-existing content must
# survive byte-for-byte (no mutation during refusal).
# ---------------------------------------------------------------------------
smoke_log "Gap 1: cleanliness gate covers every apply write path"

# Case 1a: legacy-shape agents/<a>/ pre-exists.
TARGET_1A="$SMOKE_TMP_ROOT/gap1a"
mkdir -p "$TARGET_1A/agents/admin"
printf 'OLD-BYTES\n' >"$TARGET_1A/agents/admin/SOUL.md"
set +e
out_1a="$(bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$TARGET_1A" 2>&1)"
rc_1a=$?
set -e
if [[ "$rc_1a" -eq 0 ]]; then
  smoke_fail "Gap 1a: apply against agents/admin/ polluted target must refuse"
fi
smoke_assert_contains "$out_1a" "agents" \
  "Gap 1a: refusal cites 'agents' blocking path"
preserved="$(cat "$TARGET_1A/agents/admin/SOUL.md")"
smoke_assert_eq "OLD-BYTES" "$preserved" \
  "Gap 1a: pre-existing SOUL.md preserved byte-for-byte"

# Case 1b: agent-roster.sh pre-exists. The beta6 list did not check this.
TARGET_1B="$SMOKE_TMP_ROOT/gap1b"
mkdir -p "$TARGET_1B"
printf 'OPERATOR-OWNED-ROSTER\n' >"$TARGET_1B/agent-roster.sh"
set +e
out_1b="$(bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$TARGET_1B" 2>&1)"
rc_1b=$?
set -e
if [[ "$rc_1b" -eq 0 ]]; then
  smoke_fail "Gap 1b: apply against pre-existing agent-roster.sh must refuse"
fi
smoke_assert_contains "$out_1b" "agent-roster.sh" \
  "Gap 1b: refusal cites agent-roster.sh blocking path"

# Case 1c: cron/jobs.json pre-exists.
TARGET_1C="$SMOKE_TMP_ROOT/gap1c"
mkdir -p "$TARGET_1C/cron"
printf '[{"name":"operator-job"}]\n' >"$TARGET_1C/cron/jobs.json"
set +e
out_1c="$(bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$TARGET_1C" 2>&1)"
rc_1c=$?
set -e
if [[ "$rc_1c" -eq 0 ]]; then
  smoke_fail "Gap 1c: apply against pre-existing cron/jobs.json must refuse"
fi
smoke_assert_contains "$out_1c" "cron/jobs.json" \
  "Gap 1c: refusal cites cron/jobs.json blocking path"

smoke_log "Gap 1: cleanliness gate inclusive list — PASS"

# ---------------------------------------------------------------------------
# Gap 2 — layout-resolver bypass.
#
# Apply must derive per-agent paths from the canonical resolver via the
# layout shim, NOT from hardcoded `data/agents/<a>/home` math. We assert
# the shim is invoked and that apply / verify both consume the same
# canonical paths.
# ---------------------------------------------------------------------------
smoke_log "Gap 2: apply + verify consume the canonical layout resolver"

# The shim is a separate script — confirm it exists and runs standalone.
smoke_assert_file_exists "$HELPER_DIR/migrate-layout-shim.sh" \
  "Gap 2: migrate-layout-shim.sh shipped"

SHIM_TARGET="$SMOKE_TMP_ROOT/gap2-shim"
mkdir -p "$SHIM_TARGET"
# Pick the same bash the helper picks (Bash 4+). On macOS /bin/bash is
# 3.2; on Linux CI it's usually 5.x, so just exec the shim directly.
SHIM_BIN="/opt/homebrew/bin/bash"
if [[ ! -x "$SHIM_BIN" ]]; then
  SHIM_BIN="/usr/local/bin/bash"
fi
if [[ ! -x "$SHIM_BIN" ]]; then
  SHIM_BIN="$(command -v bash)"
fi
shim_out="$("$SHIM_BIN" "$HELPER_DIR/migrate-layout-shim.sh" "$SHIM_TARGET" admin reviewer)"
smoke_assert_contains "$shim_out" "type=top" "Gap 2: shim emits top record"
smoke_assert_contains "$shim_out" "type=agent" "Gap 2: shim emits agent records"
smoke_assert_contains "$shim_out" "id=admin" "Gap 2: shim covers admin"
smoke_assert_contains "$shim_out" "id=reviewer" "Gap 2: shim covers reviewer"
smoke_assert_contains "$shim_out" "home_dir=$SHIM_TARGET/data/agents/admin/home" \
  "Gap 2: shim emits canonical v2 home for admin"

# Apply through the migrator and confirm the apply-result captures the
# canonical layout (NOT a hardcoded path). The same paths must be on disk.
TARGET_2="$SMOKE_TMP_ROOT/gap2-apply"
mkdir -p "$TARGET_2"
bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$TARGET_2" >/dev/null
layout_in_result="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" \
  apply-result-field "$TARGET_2/.migrator-apply-result.json" layout)"
smoke_assert_eq "v2" "$layout_in_result" \
  "Gap 2: apply-result.json captures canonical layout"
smoke_assert_file_exists "$TARGET_2/data/agents/admin/home/SOUL.md" \
  "Gap 2: apply writes admin SOUL.md at canonical path"
smoke_assert_file_exists "$TARGET_2/data/agents/reviewer/home/SOUL.md" \
  "Gap 2: apply writes reviewer SOUL.md at canonical path"
# Codex r2 finding 1: apply must author state/layout-marker.sh, otherwise
# the migrated target is markerless and bridge-layout-resolver dies on
# next startup.
smoke_assert_file_exists "$TARGET_2/state/layout-marker.sh" \
  "Gap 2 + finding 1: apply writes layout-marker.sh (target startable)"
marker_body="$(cat "$TARGET_2/state/layout-marker.sh")"
smoke_assert_contains "$marker_body" "BRIDGE_LAYOUT=v2" \
  "Gap 2 + finding 1: marker pins BRIDGE_LAYOUT=v2"

# Verify drives the SAME shim; assert it agrees with apply.
verify_out_2="$(bash "$MIGRATOR" verify --target "$TARGET_2")"
smoke_assert_contains "$verify_out_2" "via resolver" \
  "Gap 2: verify resolves agent homes through the shim"
smoke_assert_contains "$verify_out_2" "agent admin: identity files present" \
  "Gap 2: verify confirms admin identity at canonical path"
smoke_log "Gap 2: apply + verify ↔ shim coupling — PASS"

# ---------------------------------------------------------------------------
# Gap 3 — operator-supplied secrets written, cron env allowlist.
# ---------------------------------------------------------------------------
smoke_log "Gap 3: operator-supplied secrets written with mode 0600; cron env allowlist"

# Cron env: AUTHORIZATION / COOKIE must NOT survive (beta6 heuristic
# would have let them through). PATH must survive (allowlisted).
cron_env_keys="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" \
  manifest-first-cron-env-keys "$BUNDLE_DIR/manifest.json")"
smoke_assert_contains "$cron_env_keys" "PATH" "Gap 3 cron: PATH kept"
if [[ "$cron_env_keys" == *AUTHORIZATION* ]]; then
  smoke_fail "Gap 3 cron: AUTHORIZATION must be dropped by allowlist, got: $cron_env_keys"
fi
if [[ "$cron_env_keys" == *COOKIE* ]]; then
  smoke_fail "Gap 3 cron: COOKIE must be dropped by allowlist, got: $cron_env_keys"
fi

# Operator-supplied secrets via --a2a-secret-file / --app-password-file.
printf '%s' '{"shared_secret_hex":"DEADBEEF"}' >"$SECRETS_DIR/a2a.json"
printf '%s' 'super-secret-pass' >"$SECRETS_DIR/teams.txt"
chmod 0600 "$SECRETS_DIR"/*

TARGET_3="$SMOKE_TMP_ROOT/gap3-secrets"
mkdir -p "$TARGET_3"
bash "$MIGRATOR" apply \
  --bundle "$BUNDLE_DIR" \
  --target "$TARGET_3" \
  --a2a-secret-file "$SECRETS_DIR/a2a.json" \
  --app-password-file "$SECRETS_DIR/teams.txt" \
  >/dev/null

smoke_assert_file_exists "$TARGET_3/handoff.local.json" \
  "Gap 3: handoff.local.json written"
smoke_assert_file_exists "$TARGET_3/.env" \
  "Gap 3: .env written"

handoff_mode="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" \
  file-octal-mode "$TARGET_3/handoff.local.json")"
env_mode="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" \
  file-octal-mode "$TARGET_3/.env")"
smoke_assert_eq "0600" "$handoff_mode" "Gap 3: handoff.local.json mode 0600"
smoke_assert_eq "0600" "$env_mode" "Gap 3: .env mode 0600"

# Body sanity: the operator-supplied secret made it into the file.
if ! grep -q "DEADBEEF" "$TARGET_3/handoff.local.json"; then
  smoke_fail "Gap 3: handoff.local.json missing operator-supplied A2A secret"
fi
if ! grep -q "super-secret-pass" "$TARGET_3/.env"; then
  smoke_fail "Gap 3: .env missing operator-supplied Teams password"
fi

# Result manifest reflects the writes.
a2a_written="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" \
  apply-result-field "$TARGET_3/.migrator-apply-result.json" a2a_secret_written)"
teams_written="$(python3 "$HELPER_DIR/migrator-smoke-helpers.py" \
  apply-result-field "$TARGET_3/.migrator-apply-result.json" teams_secret_written)"
smoke_assert_eq "True" "$a2a_written" "Gap 3: apply-result a2a_secret_written=true"
smoke_assert_eq "True" "$teams_written" "Gap 3: apply-result teams_secret_written=true"

smoke_log "Gap 3: secrets written + cron env allowlist — PASS"

# ---------------------------------------------------------------------------
# Should-fix — atomic apply with rollback.
#
# Force a mid-apply failure via BRIDGE_MIGRATOR_TEST_FAIL_BEFORE_PUBLISH
# and assert:
#   - rc != 0
#   - the pre-existing file content survives byte-for-byte
#   - no staged data leaks into the canonical layout
# ---------------------------------------------------------------------------
smoke_log "should-fix: atomic apply + rollback"

TARGET_R="$SMOKE_TMP_ROOT/rollback"
mkdir -p "$TARGET_R"
# A pre-existing file NOT covered by the cleanliness gate; apply
# cleanliness passes, backup picks this up, rollback must preserve it.
printf 'OPERATOR-NOTES\n' >"$TARGET_R/operator-notes.md"

set +e
BRIDGE_MIGRATOR_TEST_FAIL_BEFORE_PUBLISH=1 \
  bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$TARGET_R" >/dev/null 2>&1
rc_rb=$?
set -e
if [[ "$rc_rb" -eq 0 ]]; then
  smoke_fail "rollback: apply must fail when test-hook env is set; got rc=0"
fi

# Pre-existing file survives.
preserved_notes="$(cat "$TARGET_R/operator-notes.md")"
smoke_assert_eq "OPERATOR-NOTES" "$preserved_notes" \
  "rollback: pre-existing operator-notes.md preserved byte-for-byte"

# No leaked staged content in canonical layout.
if [[ -d "$TARGET_R/data/agents/admin/home" ]] && \
   [[ -n "$(ls -A "$TARGET_R/data/agents/admin/home" 2>/dev/null)" ]]; then
  smoke_fail "rollback: data/agents/admin/home/ must be empty after failed apply"
fi
# No leftover staging tree.
if [[ -d "$TARGET_R/.migrator-apply-staging" ]]; then
  smoke_fail "rollback: .migrator-apply-staging/ must be removed after failed apply"
fi
# Apply-result must NOT have been written (apply did not complete).
if [[ -f "$TARGET_R/.migrator-apply-result.json" ]]; then
  smoke_fail "rollback: .migrator-apply-result.json must NOT exist after failed apply"
fi
# Codex r2 finding 2: pre-apply-backup must NOT remain at its blocking
# name, but the rollback evidence must survive as a failed-backup dir
# so a retry can proceed.
if [[ -d "$TARGET_R/.migrator-pre-apply-backup" ]]; then
  smoke_fail "rollback: .migrator-pre-apply-backup must be renamed (clean gate would block retry)"
fi
failed_count="$(find "$TARGET_R" -maxdepth 1 -type d -name '.migrator-failed-backup-*' | wc -l | tr -d ' ')"
if [[ "$failed_count" -lt 1 ]]; then
  smoke_fail "rollback: expected .migrator-failed-backup-<ts>/ for audit trail"
fi

# Retry after rollback must succeed — cleanliness gate no longer blocks.
bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$TARGET_R" >/dev/null
smoke_assert_file_exists "$TARGET_R/.migrator-apply-result.json" \
  "rollback retry: apply succeeds after rollback (clean gate accepts failed-backup leftover)"

smoke_log "should-fix: atomic apply + rollback + retry — PASS"

# ---------------------------------------------------------------------------
# Footnote — BRIDGE_MIGRATOR_BETA6_APPLY_UNSAFE gate is removed.
# ---------------------------------------------------------------------------
smoke_log "BETA6_APPLY_UNSAFE gate removed (apply is the user-facing default)"
TARGET_NG="$SMOKE_TMP_ROOT/no-gate"
mkdir -p "$TARGET_NG"
# Sanity: apply succeeds with NO env-var set.
bash "$MIGRATOR" apply --bundle "$BUNDLE_DIR" --target "$TARGET_NG" >/dev/null
smoke_assert_file_exists "$TARGET_NG/.migrator-apply-result.json" \
  "no-gate: apply succeeded without BRIDGE_MIGRATOR_BETA6_APPLY_UNSAFE"
# And the helper source must NOT mention the gate variable anymore.
if grep -q "BRIDGE_MIGRATOR_BETA6_APPLY_UNSAFE" "$SMOKE_REPO_ROOT/scripts/python-helpers/migrate-legacy-install-helper.py"; then
  smoke_fail "no-gate: BRIDGE_MIGRATOR_BETA6_APPLY_UNSAFE still referenced in helper"
fi
smoke_log "BETA6_APPLY_UNSAFE gate removed — PASS"

smoke_log "all assertions passed"
