#!/usr/bin/env bash
# scripts/smoke/1106-nudge-shell-recheck.sh — regression for issue #1106
# (beta7 follow-up from PR #1103).
#
# PR #1103 (closing #1099) added a task-level age gate to
# `bridge-queue.py::cmd_daemon_step` that suppresses ACTION REQUIRED
# nudge candidates when no queued task has aged past
# `BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS`. The Python gate is
# authoritative for WHICH candidates are emitted, but the shell-side
# `bridge-daemon.sh::nudge_agent_session` then re-queries the live
# queue state via `cmd_nudge_live_state` to compute `live_nudge_key`
# and decide whether to dispatch. Between the Python step and the
# shell fanout, the aged task that triggered emission may be
# claimed/done by another worker AND a fresh queued task remains, in
# which case the live queue is fresh-only and the ACTION REQUIRED
# nudge no longer matches the Python eligibility decision.
#
# The #1106 fix re-applies the task-level age gate at shell dispatch
# time via a new `bridge-daemon-helpers.py nudge-eligibility-recheck`
# helper. On a fresh-only live queue the shell emits
# `session_nudge_dropped_stale` with
# `reason=live_recheck_no_eligible_tasks` and returns 0 without
# dispatching.
#
# This smoke covers three layers:
#   H1 — helper unit: the new `nudge-eligibility-recheck` subcommand
#        returns the right shape and obeys the age gate (aged+fresh
#        coexist → only aged is eligible; aged claimed mid-tick →
#        zero eligible; gate disabled → all queued eligible).
#   H2 — race window: aged task → claimed mid-tick + fresh task
#        remains → helper returns 0 eligible (the input to the
#        shell's skip decision).
#   S1 — in-source wiring: `nudge_agent_session` calls the helper and
#        emits the documented audit + skip-reason on zero eligible.
#        Static grep — the integration is too tightly coupled to the
#        daemon main loop to source in isolation, but the wiring is
#        small and grep-verifiable.
#
# Footgun #11: no python3 heredoc-stdin, no `<<<` here-string at the
# point of a python3 subprocess. DB seeding uses the standalone
# helpers under `scripts/smoke/nudge-task-age-gate-helpers/`.

set -euo pipefail

SMOKE_NAME="1106-nudge-shell-recheck"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
HELPER_DIR="$SCRIPT_DIR/nudge-task-age-gate-helpers"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1106-recheck.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
export BRIDGE_TASK_DB="$DB"

AGENT="recheck-agent"
NOW="$(date +%s)"
REDELIVERY=60

failed=0

# Initialize the queue DB schema by creating+canceling a throwaway
# task (matches the pattern from the sibling
# nudge-redundant-active-agent smoke).
python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$AGENT" \
  --from requester \
  --title "schema init" \
  --body "init" \
  --format shell >"$TMP_DIR/init.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/init.sh"
python3 "$REPO_ROOT/bridge-queue.py" cancel "$TASK_ID" --actor requester >/dev/null
unset TASK_ID

# ============================================================
# H1 — helper unit: aged+fresh coexist
# ============================================================
# An aged task (created_ts backdated to NOW-600s) and a fresh task
# (created_ts ≈ NOW) are both queued. With redelivery_seconds=60, only
# the aged task should pass the age gate.

python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$AGENT" \
  --from requester \
  --title "aged task" \
  --body "aged body" \
  --format shell >"$TMP_DIR/create-aged.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-aged.sh"
aged_task_id="$TASK_ID"
unset TASK_ID
python3 "$HELPER_DIR/backdate-task-created-ts.py" "$DB" "$(( NOW - 600 ))" "$aged_task_id"

python3 "$REPO_ROOT/bridge-queue.py" create \
  --to "$AGENT" \
  --from requester \
  --title "fresh task" \
  --body "fresh body" \
  --format shell >"$TMP_DIR/create-fresh.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/create-fresh.sh"
fresh_task_id="$TASK_ID"
unset TASK_ID

helper_output="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" nudge-eligibility-recheck "$DB" "$AGENT" "$REDELIVERY")"
helper_count="${helper_output%$'\t'*}"
helper_ids="${helper_output##*$'\t'}"

if [[ "$helper_count" == "1" && "$helper_ids" == "$aged_task_id" ]]; then
  echo "  PASS  H1: helper returns aged task only when both aged+fresh queued (count=${helper_count}, ids=${helper_ids})"
else
  echo "  FAIL  H1: helper output unexpected — got count=${helper_count}, ids=${helper_ids}; expected count=1 ids=${aged_task_id}" >&2
  failed=1
fi

# ============================================================
# H2 — race window: aged claimed mid-tick + fresh remains
# ============================================================
# Simulate the race: aged task is claimed by another worker between
# the Python eligibility decision and the shell live recheck. Only
# the fresh task remains queued → helper returns 0 eligible → shell
# would skip dispatch.

python3 "$REPO_ROOT/bridge-queue.py" claim "$aged_task_id" --agent "$AGENT" >/dev/null

helper_output_post="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" nudge-eligibility-recheck "$DB" "$AGENT" "$REDELIVERY")"
helper_count_post="${helper_output_post%$'\t'*}"
helper_ids_post="${helper_output_post##*$'\t'}"

if [[ "$helper_count_post" == "0" && -z "$helper_ids_post" ]]; then
  echo "  PASS  H2: helper returns 0 eligible once aged task is claimed and only fresh remains (the race the #1106 fix closes)"
else
  echo "  FAIL  H2: helper should return 0 eligible after claim — got count=${helper_count_post}, ids=${helper_ids_post}" >&2
  failed=1
fi

# ============================================================
# H3 — gate disabled (redelivery_seconds=0)
# ============================================================
# With the gate off, the helper reports every queued id as eligible
# (preserves pre-#1019 behavior). The fresh task is still queued — it
# must show up.

helper_output_off="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" nudge-eligibility-recheck "$DB" "$AGENT" 0)"
helper_count_off="${helper_output_off%$'\t'*}"
helper_ids_off="${helper_output_off##*$'\t'}"

if [[ "$helper_count_off" == "1" && "$helper_ids_off" == "$fresh_task_id" ]]; then
  echo "  PASS  H3: gate-off reports all queued tasks eligible (count=${helper_count_off}, ids=${helper_ids_off})"
else
  echo "  FAIL  H3: gate-off output unexpected — got count=${helper_count_off}, ids=${helper_ids_off}; expected count=1 ids=${fresh_task_id}" >&2
  failed=1
fi

# Cleanup test fixtures.
python3 "$REPO_ROOT/bridge-queue.py" done "$aged_task_id" --agent "$AGENT" --note "raced out" >/dev/null
python3 "$REPO_ROOT/bridge-queue.py" cancel "$fresh_task_id" --actor requester >/dev/null

# ============================================================
# S1 — in-source wiring: nudge_agent_session calls the helper
# ============================================================
# The integration is in `nudge_agent_session` (bridge-daemon.sh).
# Sourcing the daemon in isolation triggers `bridge_load_roster` and
# the bottom-of-file CMD dispatch, so we verify the wiring via static
# greps — the same pattern other daemon-targeted smokes use (see
# scripts/smoke/daemon-tick-guards-l2-l4.sh).

daemon_sh="$REPO_ROOT/bridge-daemon.sh"
helpers_py="$REPO_ROOT/bridge-daemon-helpers.py"

if ! grep -q "nudge-eligibility-recheck" "$daemon_sh"; then
  echo "  FAIL  S1: bridge-daemon.sh does not invoke nudge-eligibility-recheck (live recheck not wired)" >&2
  failed=1
else
  echo "  PASS  S1: bridge-daemon.sh invokes nudge-eligibility-recheck"
fi

if ! grep -q "reason=live_recheck_no_eligible_tasks" "$daemon_sh"; then
  echo "  FAIL  S1: bridge-daemon.sh does not emit 'reason=live_recheck_no_eligible_tasks' skip-reason" >&2
  failed=1
else
  echo "  PASS  S1: bridge-daemon.sh emits 'reason=live_recheck_no_eligible_tasks' skip-reason"
fi

if ! grep -q "call_site=nudge_eligibility_recheck" "$daemon_sh"; then
  echo "  FAIL  S1: bridge-daemon.sh does not audit recheck-helper timeouts under its own call_site" >&2
  failed=1
else
  echo "  PASS  S1: bridge-daemon.sh audits recheck-helper timeouts under call_site=nudge_eligibility_recheck"
fi

if ! grep -q "cmd_nudge_eligibility_recheck" "$helpers_py"; then
  echo "  FAIL  S1: bridge-daemon-helpers.py does not define cmd_nudge_eligibility_recheck" >&2
  failed=1
else
  echo "  PASS  S1: bridge-daemon-helpers.py defines cmd_nudge_eligibility_recheck"
fi

if (( failed )); then
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
