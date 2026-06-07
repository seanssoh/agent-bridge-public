#!/usr/bin/env bash
# scripts/smoke/1618-outbox-retry-resets-attempts.sh — A2A outbox `retry`
# resets the attempt counter (#1618).
#
# Root cause: `agb a2a outbox retry <id>` of a DEAD row already set
# next_attempt_ts=0 ("send now"); the footgun was that it PRESERVED `attempts`.
# A dead row sits at delivery_max_attempts (default 12), so the next serve tick
# took it to 13 (>= max) and it re-dead-lettered — or rescheduled a single time
# at the backoff CEILING (12h/1d). Effectively one shot. The fix resets
# `attempts=0` so a manual retry walks the backoff ladder from the base interval
# again. This smoke pins:
#   #1 retry of a dead row -> status='pending', next_attempt_ts=0, attempts=0
#      (and the lease is cleared).
#   #2 retry of a backoff-waiting 'retry' row resets attempts the same way.
#   #3 retry of a non-eligible row (acked) is a no-op (rc!=0, attempts intact).
#   #4 after the reset, one failed serve tick reschedules at the BASE interval
#      (small, <= ceiling+jitter), status='retry', and does NOT re-dead-letter.
#   #5 end-to-end: a REAL max-attempts dead-letter PRESERVES the staged body
#      (it used to be unlinked), so the manual retry leaves a sendable row
#      instead of re-dead-lettering as `dead(nobody)` on the next tick.

set -euo pipefail

SMOKE_NAME="1618-outbox-retry-resets-attempts"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/1618-outbox-retry-resets-attempts-helper.py"
WORK=""

cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

smoke_require_cmd python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${SMOKE_NAME}.XXXXXX")"

field() {
  printf '%s' "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)[sys.argv[1]])" "$2"
}

smoke_log "check #1: retry of a dead row (attempts=12) resets attempts to 0"
out="$(python3 "$HELPER" retry "$WORK/dead.db" --status dead --attempts 12)"
smoke_assert_eq "$(field "$out" rc)" "0" "#1 retry rc==0"
smoke_assert_eq "$(field "$out" status)" "pending" "#1 status -> pending"
smoke_assert_eq "$(field "$out" attempts)" "0" "#1 TOOTH: attempts reset to 0"
smoke_assert_eq "$(field "$out" next_attempt_ts)" "0" "#1 next_attempt_ts -> 0 (send now)"
smoke_assert_eq "$(field "$out" lease_owner)" "None" "#1 lease_owner cleared"
smoke_assert_eq "$(field "$out" lease_expires_ts)" "0" "#1 lease_expires_ts cleared"

smoke_log "check #2: retry of a backoff-waiting 'retry' row also resets attempts"
out="$(python3 "$HELPER" retry "$WORK/retry.db" --status retry --attempts 8)"
smoke_assert_eq "$(field "$out" rc)" "0" "#2 retry rc==0"
smoke_assert_eq "$(field "$out" status)" "pending" "#2 status -> pending"
smoke_assert_eq "$(field "$out" attempts)" "0" "#2 attempts reset to 0"
smoke_assert_eq "$(field "$out" next_attempt_ts)" "0" "#2 next_attempt_ts -> 0"

smoke_log "check #3: retry of a non-eligible (acked) row is a no-op"
out="$(python3 "$HELPER" retry-missing "$WORK/acked.db")"
[[ "$(field "$out" rc)" != "0" ]] \
  || smoke_fail "#3 TOOTH: retry of an acked row should fail (rc!=0), got rc=$(field "$out" rc)"
smoke_assert_eq "$(field "$out" status)" "acked" "#3 status untouched"
smoke_assert_eq "$(field "$out" attempts)" "3" "#3 attempts untouched (filter excludes acked)"

smoke_log "check #4: after the reset, one failed send reschedules at the base interval"
out="$(python3 "$HELPER" reschedule "$WORK/resched.db")"
smoke_assert_eq "$(field "$out" status)" "retry" "#4 reschedule -> retry (not dead)"
smoke_assert_eq "$(field "$out" attempts)" "1" "#4 first new attempt -> 1"
delay="$(field "$out" delay)"
# base step is 15s, with full-jitter half-window the first delay lands in
# [8,15]; the key TOOTH is it is NOT a ceiling-length backoff (12h/1d).
[[ "$delay" -ge 1 && "$delay" -le 15 ]] \
  || smoke_fail "#4 TOOTH: delay $delay not the base interval (one-shot-then-ceiling regressed?)"

smoke_log "check #5: dead-letter preserves the body so a manual retry is sendable"
out="$(python3 "$HELPER" dead-letter-body "$WORK/body.db")"
smoke_assert_eq "$(field "$out" in_managed)" "True" "#5 fixture body is under the managed outgoing root"
smoke_assert_eq "$(field "$out" dead_outcome)" "dead(maxattempts)" "#5 max-attempts dead-letter taken"
smoke_assert_eq "$(field "$out" body_after_dead)" "True" "#5 TOOTH: body survives dead-letter (was unlinked pre-#1618)"
smoke_assert_eq "$(field "$out" retry_rc)" "0" "#5 retry rc==0"
smoke_assert_eq "$(field "$out" status)" "pending" "#5 retry -> pending"
smoke_assert_eq "$(field "$out" attempts)" "0" "#5 retry resets attempts"
smoke_assert_eq "$(field "$out" body_after_retry)" "True" "#5 TOOTH: retried row has a sendable body (no dead(nobody))"

smoke_log "all #1618 retry-reset teeth passed"
