#!/usr/bin/env bash
# scripts/smoke/1628-a2a-deliver-per-row-guard.sh — the A2A sender deliver loop
# isolates a poisoned row so one unreadable body can't abort/delay the batch
# (#1628, audit R1, HIGH).
#
# Root cause: the per-candidate `_deliver_one` call ran with NO per-row
# try/except. `_deliver_one` does `body_path.read_bytes()` outside any local
# catch, so an unreadable body (an iso-owned 0660 envelope the runner cannot
# read -> PermissionError) or a transient OSError unwound the WHOLE batch. The
# poisoned row was left leased as 'sending' and every other healthy DUE row on
# that tick was skipped (never even claimed). The fix wraps `_deliver_one` in a
# per-row guard that demotes the bad row to the existing transient `retry` path
# (lease cleared, backoff ladder walked, max-attempts ceiling still eventually
# dead-letters) and CONTINUES the batch.
#
# This smoke drives the REAL bridge-a2a.py:cmd_deliver loop against a 2-row
# outbox — one unreadable-body row ordered FIRST + one healthy row ordered
# SECOND — and pins:
#   #1 the deliver tick returns cleanly (rc=0); it does NOT unwind on the bad row.
#   #2 TOOTH: the HEALTHY row is still REACHED (status='retry', attempts>=1).
#      Without the guard the loop aborts on the bad row before the good row is
#      claimed, leaving it 'pending' with attempts=0.
#   #3 the bad row is demoted to the transient 'retry' path (NOT left wedged as
#      'sending') and its lease is cleared.
#   #4 the bad row's last_error records the per-row guard ("deliver error: ...").

set -euo pipefail

SMOKE_NAME="1628-a2a-deliver-per-row-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/1628-a2a-deliver-per-row-guard-helper.py"
WORK=""

cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

smoke_require_cmd python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${SMOKE_NAME}.XXXXXX")"

field() {
  printf '%s' "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)[sys.argv[1]])" "$2"
}

out="$(python3 "$HELPER" run "$WORK/outbox.db")"

# The 0o000-chmod trigger only raises PermissionError for a non-root reader.
# Under an euid=0 runner the read would succeed and the #1628 scenario cannot be
# reproduced this way, so skip rather than emit a misleading pass.
euid="$(field "$out" euid)"
if [[ "$euid" == "0" ]]; then
  smoke_log "skip: running as root (euid=0); chmod 000 does not block read_bytes"
  exit 0
fi

smoke_log "check #1: the deliver tick does NOT unwind on the poisoned row"
smoke_assert_eq "$(field "$out" rc)" "0" "#1 cmd_deliver returns 0 (no batch abort)"
smoke_assert_eq "$(field "$out" raised)" "" "#1 no exception propagated out of the loop"

smoke_log "check #2: the HEALTHY row is still reached despite the bad row"
smoke_assert_eq "$(field "$out" good_status)" "retry" \
  "#2 TOOTH: healthy row reached -> retry (un-guarded loop leaves it 'pending')"
good_attempts="$(field "$out" good_attempts)"
[[ "$good_attempts" -ge 1 ]] \
  || smoke_fail "#2 TOOTH: healthy row never attempted (attempts=$good_attempts) — batch aborted on the bad row?"

smoke_log "check #3: the bad row is demoted to the transient retry path, lease cleared"
smoke_assert_eq "$(field "$out" bad_status)" "retry" \
  "#3 bad row demoted to retry (not left wedged as 'sending')"
smoke_assert_eq "$(field "$out" bad_lease_owner)" "None" "#3 bad row lease cleared"

smoke_log "check #4: the bad row's last_error records the per-row guard"
smoke_assert_contains "$(field "$out" bad_last_error)" "deliver error" \
  "#4 last_error names the guarded deliver failure"
smoke_assert_contains "$(field "$out" bad_last_error)" "PermissionError" \
  "#4 last_error preserves the underlying error type"

smoke_log "check #5: an all-poisoned batch still logs 'processed', not 'no due'"
ab="$(python3 "$HELPER" all-bad "$WORK/all-bad.db")"
smoke_assert_eq "$(field "$ab" bad_status)" "retry" "#5 only-bad row demoted to retry"
smoke_assert_eq "$(field "$ab" logged_processed)" "True" \
  "#5 TOOTH: demoted row counts toward the processed total (review finding 2)"
smoke_assert_eq "$(field "$ab" logged_no_due)" "False" \
  "#5 TOOTH: a processed-but-poisoned batch is NOT logged as 'no due outbox entries'"

smoke_log "all #1628 per-row-guard teeth passed"
