#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1425-cron-dispatch-nudge-scope.sh
#
# Regression coverage for the 2026-06-01 cron-dispatch incident:
#   T1: human inbox scans can exclude [cron-dispatch] rows, matching the
#       daemon live-state helpers that already keep cron worker backlog out of
#       ACTION REQUIRED nudges and unclaimed-task escalation.
#   T2: cron-ready overfetches before memory-daily deferral so one deferred
#       row does not hide later runnable cron-dispatch work when worker
#       parallelism is 1.

set -euo pipefail

SMOKE_NAME="1425-cron-dispatch-nudge-scope"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
QUEUE="$REPO_ROOT/bridge-queue.py"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1425-cron-nudge.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[smoke:${SMOKE_NAME}] FAIL: $*" >&2
  exit 1
}

export BRIDGE_TASK_DB="$TMP_DIR/tasks.db"
python3 "$QUEUE" init >/dev/null

echo "body" >"$TMP_DIR/body.md"
python3 "$QUEUE" create --to agent-a --title "[cron-dispatch] queue-only" --body-file "$TMP_DIR/body.md" --from smoke >/dev/null
normal_id="$(python3 "$QUEUE" create --to agent-a --title "normal queued" --body-file "$TMP_DIR/body.md" --from smoke --format shell | awk -F= '/^TASK_ID=/{print $2}')"

found_id="$(python3 "$QUEUE" find-open --agent agent-a --exclude-title-prefix "[cron-dispatch]" --format id)"
[[ "$found_id" == "$normal_id" ]] || fail "find-open exclude returned $found_id, want $normal_id"

all_json="$(python3 "$QUEUE" find-open --agent agent-a --exclude-title-prefix "[cron-dispatch]" --all --format json)"
all_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$all_json")"
[[ "$all_count" == "1" ]] || fail "find-open --all exclude returned $all_count rows, want 1"

export BRIDGE_TASK_DB="$TMP_DIR/cron-ready.db"
python3 "$QUEUE" init >/dev/null

printf '%s\n' "- family: memory-daily" >"$TMP_DIR/memory.md"
printf '%s\n' "- family: other" >"$TMP_DIR/other.md"
python3 "$QUEUE" create --to agent-a --title "[cron-dispatch] memory-daily busy" --body-file "$TMP_DIR/memory.md" --from smoke >/dev/null
python3 "$QUEUE" create --to agent-a --title "[cron-dispatch] runnable" --body-file "$TMP_DIR/other.md" --from smoke >/dev/null
printf 'agent\tactive\tactivity_state\nagent-a\t1\tworking\n' >"$TMP_DIR/status.tsv"

ready="$(python3 "$QUEUE" cron-ready --limit 1 --scan-limit 2 --format tsv --status-snapshot "$TMP_DIR/status.tsv" --memory-daily-defer-seconds 3600)"
[[ "$ready" == *"[cron-dispatch] runnable"* ]] || fail "cron-ready did not skip deferred memory-daily row: $ready"

echo "[smoke:${SMOKE_NAME}] PASS"
