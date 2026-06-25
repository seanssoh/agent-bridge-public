#!/usr/bin/env bash
# scripts/smoke/2109-rooms-admin-migration.sh — #2109 (the durable half of #2079):
# robust room_members.admin migration + local-admin backfill + leader-only roster
# re-broadcast.
#
# Two gaps the field report (a patch/admin on the sean-mac rc3 install) hit:
#   GAP 1 — _migrate_schema swallowed EVERY sqlite3.OperationalError, so a
#     `database is locked` during the upgrade window left room_members.admin
#     UNADDED → the next `room show` SELECT crashed with `no such column: admin`.
#   GAP 2 — a migrated row defaults to -1 (unknown) and fail-closes admin-involved
#     cross-node delivery until the leader rebroadcasts a v2 roster — but the
#     migration NEVER triggered that rebroadcast, so on a STABLE room (no
#     join/leave to bump the epoch) admin members stayed unknown FOREVER.
#
# THE MAKE-OR-BREAK TEETH (each mutation-proven in the helper — widening the
# narrowed except, inferring a remote admin from local config, writing 0 instead
# of -1 on an empty admin config, or letting a non-leader bump make a test FAIL):
#   migrate_adds_admin_column            the column is present after migrate.
#   migrate_duplicate_rerun_noop         a re-run (column present) is a no-op.
#   migrate_nonduplicate_error_reraises  a NON-duplicate OperationalError (a real
#                                        `database is locked`) RE-RAISES, never
#                                        silently swallowed (GAP 1).
#   backfill_local_admin_and_nonadmin    local admin -> 1, other local -> 0.
#   backfill_leaves_remote_rows_untouched a remote row (even one whose agent name
#                                        equals the local admin id) stays -1 —
#                                        local config never classifies a remote
#                                        endpoint.
#   backfill_empty_config_leaves_unknown an empty/unresolved admin id leaves every
#                                        local row at -1 (NOT 0).
#   backfill_corrects_stale_classification a stale local bit self-corrects (the
#                                        recompute is over ALL local rows).
#   backfill_singlenode_empty_node       single-node (node='' / local_node='')
#                                        local rows classify correctly.
#   leader_bumps_and_enqueues            the LEADER bumps the epoch + enqueues a
#                                        durable room_roster_outbox row for the
#                                        remote member (via bump_epoch +
#                                        enqueue_roster_broadcast — no new sender).
#   nonleader_does_not_bump              a NON-leader backfills its own local bit
#                                        but does NOT bump/enqueue (no forging).
#   no_change_no_bump                    a second idempotent call bumps nothing.
#   enqueue_failure_rolls_back_bit_and_retries
#                                        codex r1: if enqueue_roster_broadcast
#                                        raises, the admin-bit UPDATE ROLLS BACK
#                                        (stays -1, epoch un-bumped, no outbox
#                                        row) so the NEXT tick re-detects + retries
#                                        — the corrected bit + broadcast are never
#                                        lost on a transient enqueue failure.
#
# ISOLATION: the helper runs fully in-process against the real
# bridge_rooms_common module, with every rooms.db under a TemporaryDirectory it
# pins as BRIDGE_HOME (so the #1728 test-bind guard accepts the path). NEVER
# ticks the live runtime; NEVER spawns a listener; NEVER sets
# BRIDGE_ALLOW_FOREIGN_CHECKOUT.

set -euo pipefail

SMOKE_NAME="2109-rooms-admin-migration"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/2109-rooms-admin-migration-helper.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

smoke_log "setup/act/assert: the migration/backfill/rebroadcast teeth (in-process, mutation-proven)"
OUT="$(BRIDGE_A2A_ALLOW_TEST_BIND=1 python3 "$HELPER" 2>&1)" || true
printf '%s\n' "$OUT"
smoke_assert_contains "$OUT" "OVERALL PASS" \
  "the in-process migration/backfill/rebroadcast teeth all pass"
for t in migrate_adds_admin_column \
         migrate_duplicate_rerun_noop \
         migrate_nonduplicate_error_reraises \
         backfill_local_admin_and_nonadmin \
         backfill_leaves_remote_rows_untouched \
         backfill_empty_config_leaves_unknown \
         backfill_corrects_stale_classification \
         backfill_singlenode_empty_node \
         leader_bumps_and_enqueues \
         nonleader_does_not_bump \
         no_change_no_bump \
         enqueue_failure_rolls_back_bit_and_retries; do
  smoke_assert_contains "$OUT" "RESULT $t PASS" "tooth $t green"
done

smoke_log "ALL 2109 rooms-admin-migration teeth PASS"
