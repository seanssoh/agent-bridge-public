#!/usr/bin/env bash
#
# Issue #1973 Track A — queue-gateway drain containment + degraded claim/done.
#
# On a v0.16.15 install the queue-gateway DRAIN stalled for ~1.5h while the
# daemon process stayed alive (NRestarts=0): every agent's `agb claim`/`agb done`
# timed out, a `[cron-followup]` re-nudge stormed every 5 minutes, and iso agents
# could not self-recover (containment forbids them writing tasks.db/daemon.pid).
# The 0-byte daemon log made the root cause unprovable, so Track A bounds the
# blast radius and makes the next event diagnosable — it does NOT claim a
# root-cause fix.
#
# This smoke proves the three acceptance teeth against the REAL gateway code:
#   A1  a HUNG queue request cannot block a later claim/done beyond the bounded
#       per-request timeout (the batch finishes in ~N ceilings, not 60s+, and the
#       later control request is still reached).
#   A2  a timed-out claim/done NEVER returns success and prints actionable
#       retry/status guidance (EX_TEMPFAIL 75 preserved, no fabricated 0).
#   A3  a stale `.working.json` is retired with an error response AND retained
#       evidence (renamed `.timeout`, out of the drain) — not re-run every tick.
# Plus two non-vacuous priority checks: control-priority-sort (a newer control op
# drains ahead of an older create) AND fairness (control priority does not starve
# cron/followup creates — the per-cycle budget reserves a slice for non-control).
#
# Every Python step is driven through the file-as-argv sidecar
# scripts/smoke/1973a-gateway-drain-containment-helper.py (footgun #11 / C1: NO
# `python3 - <<'PY'` heredoc-stdin to a subprocess anywhere in this smoke).

set -euo pipefail

SMOKE_NAME="1973a-gateway-drain-containment"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/${SMOKE_NAME}-helper.py"

trap smoke_cleanup_temp_root EXIT

run_step() {
  # Each step gets its OWN gateway root so the cases do not cross-contaminate.
  local step="$1"
  local root="$SMOKE_TMP_ROOT/$step"
  mkdir -p "$root"
  python3 "$HELPER" "$step" "$root" 2>&1 || true
}

main() {
  local out

  smoke_make_temp_root

  out="$(run_step a1)"
  case $'\n'"$out"$'\n' in
    *$'\nok-a1 '*) smoke_log "$SMOKE_NAME: A1 hung request bounded; later control request still reached" ;;
    *) smoke_fail "$SMOKE_NAME: A1 failed (hung request not bounded / later request starved): $out" ;;
  esac

  out="$(run_step a2)"
  case $'\n'"$out"$'\n' in
    *$'\nok-a2 '*) smoke_log "$SMOKE_NAME: A2 degraded claim/done never faked success + printed retry guidance" ;;
    *) smoke_fail "$SMOKE_NAME: A2 failed (fabricated success or missing guidance): $out" ;;
  esac

  out="$(run_step a3)"
  case $'\n'"$out"$'\n' in
    *$'\nok-a3 '*) smoke_log "$SMOKE_NAME: A3 stale .working.json retired with evidence + tempfail response" ;;
    *) smoke_fail "$SMOKE_NAME: A3 failed (stale working not retired / no evidence): $out" ;;
  esac

  out="$(run_step priority-sort)"
  case $'\n'"$out"$'\n' in
    *$'\nok-priority-sort '*) smoke_log "$SMOKE_NAME: control op drains ahead of an older create (non-vacuous)" ;;
    *) smoke_fail "$SMOKE_NAME: priority-sort failed (control op not prioritized): $out" ;;
  esac

  out="$(run_step fairness)"
  case $'\n'"$out"$'\n' in
    *$'\nok-fairness '*) smoke_log "$SMOKE_NAME: control priority does NOT starve cron/followup creates under the cap" ;;
    *) smoke_fail "$SMOKE_NAME: fairness failed (creates starved by control traffic): $out" ;;
  esac

  smoke_log "$SMOKE_NAME: passed"
}

main "$@"
