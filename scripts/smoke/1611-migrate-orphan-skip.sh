#!/usr/bin/env bash
# scripts/smoke/1611-migrate-orphan-skip.sh
#
# Issue #1611 regression smoke — `bridge-upgrade.py migrate-agents` must
# roster-restrict its loop so orphan / non-roster agent homes under
# `agents/` are NOT migrated, while real roster agents ARE.
#
# Pre-#1611 behavior: cmd_migrate_agents iterated discover_agent_dirs()
# with no roster filter, so every dir under agents/ (including ~97 orphan
# test-agent homes on one live host) got migrated. That write-surface
# noise is why operators reached for `--no-migrate-agents`.
#
# Post-#1611 behavior:
#   T1 — a roster agent dir is migrated (NOT in skipped_orphans).
#   T2 — an orphan (non-roster) dir is skipped (in skipped_orphans,
#        roster_filtering=active).
#   T3 — admin agent is always included even if no source named it.
#   T4 — SAFE FALLBACK: with no parseable roster source, ALL dirs are
#        migrated (roster_filtering=unavailable, nothing skipped).
#   T5 — `--migrate-all-agents` force-includes orphans
#        (roster_filtering=disabled, nothing skipped).
#
# All runs use --dry-run: the skipped_orphans / roster_filtering payload
# fields are computed before any on-disk migration, so dry-run exercises
# the #1611 logic without depending on a full v2 runtime layout.
#
# Footgun #11: NO heredoc-stdin to any subprocess — fixtures are written
# with printf. Run under Bash 5.x (macOS system bash is 3.2).

set -euo pipefail

SMOKE_NAME="1611-migrate-orphan-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_make_temp_root "$SMOKE_NAME"

MIGRATOR="$REPO_ROOT/bridge-upgrade.py"
HELPER="$REPO_ROOT/scripts/smoke/1611-migrate-orphan-skip-helper.py"

# Build a synthetic target install tree. The source-root is the real repo
# (so agents/_template and the rematerialize helper exist); the target is
# the fixture whose agents/ dirs the migrator walks.
build_target() {
  # $1 = target dir; remaining args = agent-dir names to create under agents/
  local target="$1"
  shift
  local name
  mkdir -p "$target/state" "$target/agents"
  for name in "$@"; do
    mkdir -p "$target/agents/$name"
    # Minimal identity files so detect_display_name / detect_role_text have
    # something to read; the migrator copies template files in around them.
    printf '%s\n' "# $name — synthetic test agent" >"$target/agents/$name/CLAUDE.md"
  done
}

# Write a roster shell file naming exactly the given agent ids via the
# scaffolder's `bridge_add_agent_id_if_missing` shape.
write_roster_shell() {
  local path="$1"
  shift
  local name
  : >"$path"
  for name in "$@"; do
    printf 'bridge_add_agent_id_if_missing %q\n' "$name" >>"$path"
    printf 'BRIDGE_AGENT_DESC[%q]="Synthetic role"\n' "$name" >>"$path"
  done
}

run_migrate() {
  # Emits the JSON payload (last stdout line) for a migrate-agents dry-run.
  # Extra args after the fixed three are passed through (e.g. admin/all).
  local target="$1"
  shift
  python3 "$MIGRATOR" migrate-agents \
    --source-root "$REPO_ROOT" \
    --target-root "$target" \
    --dry-run \
    "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# T1 + T2 — roster dir migrated, orphan dir skipped.
# ---------------------------------------------------------------------------
smoke_log "T1/T2: roster dir migrated, orphan dir skipped"

TARGET_A="$SMOKE_TMP_ROOT/case-a"
build_target "$TARGET_A" "real-agent" "orphan-test-agent"
write_roster_shell "$TARGET_A/agent-roster.sh" "real-agent"
: >"$TARGET_A/agent-roster.local.sh"

OUT_A="$(run_migrate "$TARGET_A")"

filtering_a="$(printf '%s' "$OUT_A" | python3 "$HELPER" field roster_filtering)"
smoke_assert_eq "active" "$filtering_a" "T2: roster_filtering=active when roster parseable"

if python3 "$HELPER" list-has "$OUT_A" skipped_orphans "real-agent"; then
  smoke_fail "T1 FAIL: real-agent must NOT be in skipped_orphans"
fi
smoke_log "T1 PASS: real-agent not skipped"

if ! python3 "$HELPER" list-has "$OUT_A" skipped_orphans "orphan-test-agent"; then
  smoke_fail "T2 FAIL: orphan-test-agent must be in skipped_orphans"
fi
orphans_count_a="$(printf '%s' "$OUT_A" | python3 "$HELPER" field skipped_orphans_count)"
smoke_assert_eq "1" "$orphans_count_a" "T2: exactly one orphan skipped"
migrated_a="$(printf '%s' "$OUT_A" | python3 "$HELPER" field migrated_count)"
smoke_assert_eq "1" "$migrated_a" "T2: exactly one (roster) agent migrated"
smoke_log "T2 PASS: orphan-test-agent skipped, real-agent migrated"

# ---------------------------------------------------------------------------
# T3 — admin agent always included, even if no source names it.
# ---------------------------------------------------------------------------
smoke_log "T3: admin agent always folded into the roster set"

TARGET_B="$SMOKE_TMP_ROOT/case-b"
build_target "$TARGET_B" "boss" "orphan-x"
# Roster shell names ONLY orphan-x; admin (boss) arrives via --admin-agent.
write_roster_shell "$TARGET_B/agent-roster.sh" "orphan-x"
: >"$TARGET_B/agent-roster.local.sh"

OUT_B="$(run_migrate "$TARGET_B" --admin-agent boss)"

if python3 "$HELPER" list-has "$OUT_B" skipped_orphans "boss"; then
  smoke_fail "T3 FAIL: admin agent 'boss' must never be skipped as an orphan"
fi
# orphan-x IS in the roster shell, so it is migrated, not skipped. The point
# of T3 is purely that boss (only reachable via --admin-agent) is migrated.
migrated_b="$(printf '%s' "$OUT_B" | python3 "$HELPER" field migrated_count)"
smoke_assert_eq "2" "$migrated_b" "T3: admin + roster agent both migrated"
smoke_log "T3 PASS: admin agent migrated via --admin-agent"

# ---------------------------------------------------------------------------
# T4 — SAFE FALLBACK: no parseable roster source → migrate ALL dirs.
# ---------------------------------------------------------------------------
smoke_log "T4: safe fallback migrates all dirs when roster unknown"

TARGET_C="$SMOKE_TMP_ROOT/case-c"
build_target "$TARGET_C" "alpha" "beta" "gamma"
# Empty roster files, no state TSVs, no --admin-agent → no source found.
: >"$TARGET_C/agent-roster.sh"
: >"$TARGET_C/agent-roster.local.sh"

OUT_C="$(run_migrate "$TARGET_C")"

filtering_c="$(printf '%s' "$OUT_C" | python3 "$HELPER" field roster_filtering)"
smoke_assert_eq "unavailable" "$filtering_c" "T4: roster_filtering=unavailable on empty roster"
orphans_count_c="$(printf '%s' "$OUT_C" | python3 "$HELPER" field skipped_orphans_count)"
smoke_assert_eq "0" "$orphans_count_c" "T4: nothing skipped under fallback"
migrated_c="$(printf '%s' "$OUT_C" | python3 "$HELPER" field migrated_count)"
smoke_assert_eq "3" "$migrated_c" "T4: all three dirs migrated under fallback"
smoke_log "T4 PASS: safe fallback migrated all dirs"

# ---------------------------------------------------------------------------
# T5 — --migrate-all-agents force-includes orphans.
# ---------------------------------------------------------------------------
smoke_log "T5: --migrate-all-agents force-includes orphans"

TARGET_D="$SMOKE_TMP_ROOT/case-d"
build_target "$TARGET_D" "real-agent" "orphan-test-agent"
write_roster_shell "$TARGET_D/agent-roster.sh" "real-agent"
: >"$TARGET_D/agent-roster.local.sh"

OUT_D="$(run_migrate "$TARGET_D" --migrate-all-agents)"

filtering_d="$(printf '%s' "$OUT_D" | python3 "$HELPER" field roster_filtering)"
smoke_assert_eq "disabled" "$filtering_d" "T5: roster_filtering=disabled under --migrate-all-agents"
orphans_count_d="$(printf '%s' "$OUT_D" | python3 "$HELPER" field skipped_orphans_count)"
smoke_assert_eq "0" "$orphans_count_d" "T5: nothing skipped under --migrate-all-agents"
migrated_d="$(printf '%s' "$OUT_D" | python3 "$HELPER" field migrated_count)"
smoke_assert_eq "2" "$migrated_d" "T5: both dirs migrated under --migrate-all-agents"
smoke_log "T5 PASS: --migrate-all-agents migrated the orphan too"

# ---------------------------------------------------------------------------
# T6 — state/agents-aggregate.tsv is honored as a roster source (covers a
#      stopped-but-real agent that the shell roster did not name).
# ---------------------------------------------------------------------------
smoke_log "T6: agents-aggregate.tsv counts as a roster source"

TARGET_E="$SMOKE_TMP_ROOT/case-e"
build_target "$TARGET_E" "stopped-real" "orphan-y"
: >"$TARGET_E/agent-roster.sh"
: >"$TARGET_E/agent-roster.local.sh"
# Aggregate TSV header + one stopped real agent. No shell-roster mention.
printf 'agent\tactive\tactivity_state\tupdated_at\n' >"$TARGET_E/state/agents-aggregate.tsv"
printf 'stopped-real\t0\tstopped\t2026-06-07T00:00:00+00:00\n' >>"$TARGET_E/state/agents-aggregate.tsv"

OUT_E="$(run_migrate "$TARGET_E")"

filtering_e="$(printf '%s' "$OUT_E" | python3 "$HELPER" field roster_filtering)"
smoke_assert_eq "active" "$filtering_e" "T6: aggregate.tsv yields roster_filtering=active"
if python3 "$HELPER" list-has "$OUT_E" skipped_orphans "stopped-real"; then
  smoke_fail "T6 FAIL: stopped-real (from aggregate.tsv) must NOT be skipped"
fi
if ! python3 "$HELPER" list-has "$OUT_E" skipped_orphans "orphan-y"; then
  smoke_fail "T6 FAIL: orphan-y must be skipped"
fi
sources_has_aggregate="$(printf '%s' "$OUT_E" | python3 "$HELPER" sources-has state/agents-aggregate.tsv)"
smoke_assert_eq "yes" "$sources_has_aggregate" "T6: roster_sources lists state/agents-aggregate.tsv"
smoke_log "T6 PASS: aggregate.tsv honored as roster source"

smoke_log "all assertions passed (#1611)"
