#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2067-reminder-unclaimed-exempt.sh
#
# Issue #2067 — daemon blocked-aging REMINDER tasks self-trigger the
# [unclaimed-task] watchdog → N×N admin-queue noise amplification.
#
# Background: post-#1986, process_blocked_task_aging (bridge-queue.py) emits
# informational `[blocked-aging] task #<id> needs status refresh` tasks
# (created_by=daemon, priority=normal) ASSIGNED TO THE OWNING AGENT, so a
# busy agent's own blocked work re-surfaces. Those reminder rows are
# claimable. When the owning agent is legitimately busy they age past the
# unclaimed threshold and the [unclaimed-task] watchdog
# (process_unclaimed_queue_escalation in bridge-daemon.sh) escalated EACH to
# admin (priority high). N blocked tasks → N reminders → N admin escalations,
# all auto-generated, none actionable.
#
# The fix (Option 1, task-class exemption, reuse existing machinery): skip the
# daemon reminder class in lib/daemon-helpers/unclaimed-task-filter.py (the
# helper that feeds the unclaimed scanner), keyed on BOTH created_by=='daemon'
# AND a `[blocked-aging] task #` title prefix. The match is PRECISE: gating on
# created_by as well as the title means a genuine WORK task that merely starts
# with that reserved literal (any other creator) STILL escalates — a title-only
# --exclude-title-prefix on find-open would over-exempt it (this is the codex r1
# P1). [cron-dispatch] stays a title-only find-open exemption because it is
# creator-agnostic by design. The `[blocked-escalation] task #<id> needs admin
# review` class is NOT exempted: it is deliberately admin-actionable (assigned
# TO admin), and an admin-assigned unclaimed row is already audit-only via the
# daemon's admin-self-target guard, so it generates no storm.
#
# This smoke drives process_unclaimed_queue_escalation END-TO-END against a
# REAL queue DB:
#
#   A — an unclaimed daemon blocked-aging REMINDER (created_by=daemon) on the
#       owning agent → the scanner EXCLUDES it: NO task_unclaimed_escalated
#       audit row and NO open [unclaimed-task] admin task; it stays claimable.
#   B — a genuine unclaimed WORK task on the same agent → STILL escalates
#       (the exemption is not over-broad).
#   D — a NON-daemon task whose title STARTS WITH the reserved
#       `[blocked-aging] task #` prefix → STILL escalates (the precision case:
#       the exemption gates on created_by, not the title alone).
#   C — a `[blocked-escalation] task #` row assigned to a NON-admin agent →
#       STILL escalates (only the daemon `[blocked-aging]` reminder is exempt,
#       not `[blocked-escalation]`).
#   M (MUTATION, non-vacuous proof) — re-run test A's scenario against a mutated
#       copy of unclaimed-task-filter.py with the exemption skip block REMOVED
#       (BRIDGE_SCRIPT_DIR re-pointed at the mutated helper tree) → the same
#       reminder NOW re-escalates. Proves test A passes because of the
#       exemption, not by accident.
#   teeth — structural: the helper carries the precise (created_by=='daemon' AND
#       title-prefix) skip, the daemon find-open does NOT title-exempt
#       blocked-aging (over-broad), [cron-dispatch] stays, and
#       [blocked-escalation] is never exempted — so a revert fails this smoke.
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at a python3
# subprocess for queue mutation; the daemon function is sourced via the same
# awk/py extractor the #1944 smoke uses; all queue mutation is via the
# bridge-queue.py CLI.

set -euo pipefail

# Re-exec under Bash 4+ for the bridge libs.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:2067-reminder-unclaimed-exempt] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="2067-reminder-unclaimed-exempt"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"
QUEUE="$REPO_ROOT/bridge-queue.py"

smoke_require_cmd python3
smoke_require_cmd sqlite3

ADMIN="admin-agent"
TARGET="busy-agent"

export BRIDGE_ADMIN_AGENT_ID="$ADMIN"
# Age threshold 1s: we backdate created_ts/updated_ts so a task is "expired"
# deterministically without sleeping.
export BRIDGE_QUEUE_UNCLAIMED_ESCALATE_SECS=1

DB="$BRIDGE_STATE_DIR/tasks.db"
mkdir -p "$BRIDGE_STATE_DIR"
export BRIDGE_TASK_DB="$DB"
python3 "$QUEUE" init >/dev/null

AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$BRIDGE_LOG_DIR"
: >"$AUDIT_LOG"

# --- Boundary stubs (everything except the function under test) -------
bridge_audit_log() {
  local actor="$1" action="$2" target="$3"
  shift 3 || true
  local detail_csv=""
  while (( $# )); do
    case "$1" in
      --detail)
        if [[ -n "$detail_csv" ]]; then detail_csv+=";"; fi
        detail_csv+="$2"
        shift 2 ;;
      *) shift ;;
    esac
  done
  printf '{"actor":"%s","action":"%s","target":"%s","detail":"%s"}\n' \
    "$actor" "$action" "$target" "$detail_csv" >>"$AUDIT_LOG"
}
daemon_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
daemon_info() { printf '[stub-info] %s\n' "$*"; }

bridge_require_python() { command -v python3 >/dev/null 2>&1; }

declare -ga BRIDGE_AGENT_IDS=("$ADMIN" "$TARGET")
bridge_agent_exists() {
  local a="$1"
  [[ "$a" == "$ADMIN" || "$a" == "$TARGET" ]]
}

bridge_queue_cli() {
  python3 "$QUEUE" "$@"
}

export BRIDGE_SCRIPT_DIR="$REPO_ROOT"
bridge_daemon_helper_python() {
  local helper="${1:-}"
  [[ -n "$helper" ]] || return 1
  shift || true
  python3 "$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/$helper.py" "$@"
}

# --- Function extractor (same shape as the #1944 smoke) ---------------
WANTED_HELPERS=(
  bridge_daemon_unclaimed_escalation_state_dir
  bridge_daemon_unclaimed_escalation_marker_file
  process_unclaimed_queue_escalation
  bridge_daemon_sweep_stale_unclaimed_markers
)
IOTA_WANTED_CSV="$(IFS=,; echo "${WANTED_HELPERS[*]}")"
export IOTA_WANTED_CSV

# Extract the WANTED_HELPERS functions from a given bridge-daemon.sh source
# path into the given output file. Used twice: once against the real source
# (tests A/B/C) and once against a mutated copy (test M).
extract_daemon_helpers() {
  local src_path="$1" out_path="$2"
  python3 - "$src_path" >"$out_path" <<'PY'
import os, re, sys
src_path = sys.argv[1]
wanted = set(os.environ.get("IOTA_WANTED_CSV", "").split(","))
with open(src_path, "r", encoding="utf-8") as f:
    lines = f.readlines()
out = []
i = 0
fn_start_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{')
heredoc_re = re.compile(r"<<[-']?([A-Za-z_][A-Za-z0-9_]*)'?")
while i < len(lines):
    line = lines[i]
    m = fn_start_re.match(line)
    if m and m.group(1) in wanted:
        block = [line]
        heredoc_term = None
        j = i + 1
        while j < len(lines):
            cur = lines[j]
            block.append(cur)
            if heredoc_term is None:
                hm = heredoc_re.search(cur)
                if hm:
                    heredoc_term = hm.group(1)
            else:
                if cur.rstrip("\n") == heredoc_term:
                    heredoc_term = None
                j += 1
                continue
            if cur == "}\n" or cur == "}":
                break
            j += 1
        out.extend(block)
        out.append("\n")
        i = j + 1
        continue
    i += 1
sys.stdout.write("".join(out))
PY
}

HELPERS_SUBSET="$SMOKE_TMP_ROOT/daemon-helpers.sh"
extract_daemon_helpers "$REPO_ROOT/bridge-daemon.sh" "$HELPERS_SUBSET"
# shellcheck source=/dev/null
source "$HELPERS_SUBSET"

# --- helpers ----------------------------------------------------------
# Count task_unclaimed_escalated rows whose target_agent detail names the
# given agent. Anchor on the trailing `;` so a prefix agent name cannot
# match a longer one.
escalations_for_target() {
  local who="${1:-$TARGET}" n
  if n="$(grep -c "\"action\":\"task_unclaimed_escalated\".*target_agent=${who};" "$AUDIT_LOG" 2>/dev/null)"; then
    printf '%s' "$n"
  else
    printf '0'
  fi
}

count_open_with_prefix() {
  local agent="$1" prefix="$2" json
  # `find-open --all --format json` prints `[]` AND exits 1 when the set is
  # empty (bridge-queue.py: `return 0 if payload else 1`). Capture stdout
  # regardless of exit code and read only the first JSON line so a trailing
  # `|| fallback` can't append a second `[]` (extra-data parse error).
  json="$(python3 "$QUEUE" find-open --agent "$agent" --title-prefix "$prefix" --all --format json 2>/dev/null | head -n1)"
  [[ -n "$json" ]] || json="[]"
  python3 -c 'import json,sys; print(len(json.loads(sys.argv[1] or "[]")))' "$json"
}

backdate_task() {
  local task_id="$1" seconds_ago="${2:-600}" cutoff
  cutoff="$(( $(date +%s) - seconds_ago ))"
  sqlite3 "$DB" "UPDATE tasks SET created_ts=${cutoff}, updated_ts=${cutoff} WHERE id=${task_id};"
}

# Queue a task with an explicit title/assignee/creator and backdate it so it
# is an "old unclaimed" task. Mirrors the real daemon-created reminder shape
# (created_by=daemon) when --from daemon is passed.
queue_aged_task() {
  local to="$1" from="$2" title="$3" out id
  out="$(python3 "$QUEUE" create --to "$to" --from "$from" --priority normal \
           --title "$title" --body "body" --format shell)"
  id="$(printf '%s\n' "$out" | sed -n 's/^TASK_ID=//p' | tr -d "'")"
  backdate_task "$id" 600
  printf '%s' "$id"
}

UNCLAIMED_PREFIX="[unclaimed-task] #"
REMINDER_TITLE_PREFIX="[blocked-aging] task #"
ESCALATION_TITLE_PREFIX="[blocked-escalation] task #"

# Cross-check the title prefixes against bridge-queue.py's source-of-truth
# constants so a constant rename can't silently desync this smoke from the
# emit path.
# grep/sed (NOT a python-heredoc-in-capture: footgun #11 deadlock class) —
# extract the BLOCKED_REMINDER_TITLE_PREFIX literal straight from the source.
src_reminder_prefix="$(grep -oE 'BLOCKED_REMINDER_TITLE_PREFIX[[:space:]]*=[[:space:]]*"[^"]*"' "$QUEUE" | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')"
[[ "$src_reminder_prefix" == "$REMINDER_TITLE_PREFIX" ]] \
  || smoke_fail "precondition: BLOCKED_REMINDER_TITLE_PREFIX desynced: got '$src_reminder_prefix' want '$REMINDER_TITLE_PREFIX'"

# ======================================================================
# A — an unclaimed daemon blocked-aging REMINDER is EXEMPT (no escalation)
# ======================================================================
smoke_run "A daemon blocked-aging reminder is exempt from [unclaimed-task]" : ; {
  : >"$AUDIT_LOG"
  # Real reminder title shape: "[blocked-aging] task #<orig> needs status refresh".
  reminder_id="$(queue_aged_task "$TARGET" daemon "${REMINDER_TITLE_PREFIX}9001 needs status refresh")"

  process_unclaimed_queue_escalation || true
  process_unclaimed_queue_escalation || true

  esc_count="$(escalations_for_target "$TARGET")"
  smoke_assert_eq 0 "$esc_count" "A reminder generates NO task_unclaimed_escalated"

  open_count="$(count_open_with_prefix "$ADMIN" "$UNCLAIMED_PREFIX")"
  smoke_assert_eq 0 "$open_count" "A reminder generates NO open [unclaimed-task] admin task"

  # The reminder itself stays a claimable queued task (not deleted/closed) —
  # it just never admin-escalates.
  status_after="$(python3 "$QUEUE" show "$reminder_id" --format shell | sed -n 's/^TASK_STATUS=//p' | tr -d "'")"
  smoke_assert_eq queued "$status_after" "A reminder remains a claimable queued task"
}

# ======================================================================
# B — a genuine unclaimed WORK task on the SAME agent STILL escalates
# ======================================================================
smoke_run "B genuine unclaimed work task still escalates (not over-exempted)" : ; {
  : >"$AUDIT_LOG"
  work_id="$(queue_aged_task "$TARGET" someone "ship the real feature")"

  process_unclaimed_queue_escalation || true

  esc_count="$(escalations_for_target "$TARGET")"
  smoke_assert_eq 1 "$esc_count" "B genuine work task escalates exactly once"

  open_count="$(count_open_with_prefix "$ADMIN" "$UNCLAIMED_PREFIX")"
  smoke_assert_eq 1 "$open_count" "B genuine work task yields one open [unclaimed-task] admin task"
  [[ -n "$work_id" ]] || smoke_fail "B sanity: work task id should be set"
}

# ======================================================================
# D — PRECISION: a NON-daemon work task that merely STARTS WITH the reserved
#     "[blocked-aging] task #" prefix MUST still escalate
# ======================================================================
# The exemption is keyed on BOTH the title prefix AND created_by=='daemon'
# (the daemon-helper filter), not the title alone. A title-only exemption
# would over-exempt a genuine work task that happened to start with the
# reserved literal — exactly the codex r1 P1. This asserts the created_by
# half of the match: same title prefix, a non-daemon creator → STILL escalates.
smoke_run "D non-daemon [blocked-aging]-prefixed work task still escalates (precision)" : ; {
  : >"$AUDIT_LOG"
  spoof_id="$(queue_aged_task "$TARGET" someone "${REMINDER_TITLE_PREFIX}fake but real work")"

  process_unclaimed_queue_escalation || true

  esc_count="$(escalations_for_target "$TARGET")"
  smoke_assert_eq 1 "$esc_count" "D a non-daemon task with the reserved prefix STILL escalates (created_by gate)"
  [[ -n "$spoof_id" ]] || smoke_fail "D sanity: spoof task id should be set"
}

# ======================================================================
# C — a `[blocked-escalation] task #` row is NOT exempted (still escalates)
# ======================================================================
# Only the daemon `[blocked-aging]` reminder is exempt;
# `[blocked-escalation]` is admin-actionable. The real emit path assigns it
# TO admin (where the admin-self-target guard makes it audit-only). To prove
# the exemption does NOT catch `[blocked-escalation]` we assign it to a
# NON-admin agent and assert it STILL escalates — i.e. the scanner does not
# filter it out (even with created_by=daemon, the title prefix differs).
smoke_run "C [blocked-escalation] is not exempt — still escalates" : ; {
  : >"$AUDIT_LOG"
  esc_row_id="$(queue_aged_task "$TARGET" daemon "${ESCALATION_TITLE_PREFIX}7002 needs admin review")"

  process_unclaimed_queue_escalation || true

  esc_count="$(escalations_for_target "$TARGET")"
  smoke_assert_eq 1 "$esc_count" "C [blocked-escalation] row still escalates (only [blocked-aging] is exempt)"
  [[ -n "$esc_row_id" ]] || smoke_fail "C sanity: escalation row id should be set"
}

# ======================================================================
# M — MUTATION: remove the exemption → the reminder re-escalates
# ======================================================================
# Non-vacuous proof: the exemption lives in
# lib/daemon-helpers/unclaimed-task-filter.py (the (title AND created_by==daemon)
# skip). Point BRIDGE_SCRIPT_DIR at a temp helper tree whose copy of that helper
# has the skip stripped, then re-run test A's scenario. With the skip gone the
# daemon reminder MUST now escalate — confirming test A's pass is caused by the
# exemption, not by accident.
smoke_run "M removing the exemption re-escalates the reminder (non-vacuous)" : ; {
  real_filter="$REPO_ROOT/lib/daemon-helpers/unclaimed-task-filter.py"
  mut_helper_dir="$SMOKE_TMP_ROOT/mutated-helpers/lib/daemon-helpers"
  mkdir -p "$mut_helper_dir"
  # Mirror every helper the daemon function dispatches to, then mutate just the
  # one under test.
  cp "$REPO_ROOT/lib/daemon-helpers/"*.py "$mut_helper_dir/" 2>/dev/null || true
  mut_filter="$mut_helper_dir/unclaimed-task-filter.py"
  # Strip the created_by/title skip block (the `continue` that exempts the
  # daemon reminder). Anchor on the distinctive `== "daemon"` guard.
  # Standalone fixture (NOT an inline interpreter heredoc — footgun #11):
  if ! python3 "$REPO_ROOT/scripts/smoke/2067-reminder-unclaimed-exempt-mutate.py" \
       "$real_filter" "$mut_filter"; then
    smoke_fail "M precondition: failed to strip the helper exemption block"
  fi
  # Confirm the mutated helper still compiles and no longer skips on daemon-origin.
  python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$mut_filter" \
    || smoke_fail "M precondition: mutated helper does not compile"
  if grep -qF 'startswith(BLOCKED_REMINDER_TITLE_PREFIX)' "$mut_filter"; then
    smoke_fail "M precondition: mutation failed to remove the daemon-reminder skip"
  fi

  # Point the helper dispatcher at the mutated tree for this block only.
  saved_script_dir="$BRIDGE_SCRIPT_DIR"
  export BRIDGE_SCRIPT_DIR="$SMOKE_TMP_ROOT/mutated-helpers"

  # Isolate the count: cancel every still-queued task on TARGET left over from
  # earlier tests (those aged rows would ALSO escalate once the exemption is
  # gone, inflating the count). After this the only aged queued TARGET task is
  # the M reminder we create.
  leftover_json="$(python3 "$QUEUE" find-open --agent "$TARGET" --status-filter queued --all --format json 2>/dev/null | head -n1)"
  [[ -n "$leftover_json" ]] || leftover_json="[]"
  # var-capture (NOT a `< <(procsub)` — lint-heredoc-ban H3); ids are integers
  # so plain word-splitting is safe here.
  leftover_ids="$(python3 -c 'import json,sys
for r in json.loads(sys.argv[1] or "[]"):
    print(r["id"])' "$leftover_json")"
  for lid in $leftover_ids; do
    [[ "$lid" =~ ^[0-9]+$ ]] || continue
    python3 "$QUEUE" cancel "$lid" --actor smoke --note "M isolation" >/dev/null 2>&1 || true
  done

  : >"$AUDIT_LOG"
  mut_reminder_id="$(queue_aged_task "$TARGET" daemon "${REMINDER_TITLE_PREFIX}9003 needs status refresh")"
  process_unclaimed_queue_escalation || true

  esc_count="$(escalations_for_target "$TARGET")"
  smoke_assert_eq 1 "$esc_count" "M without the helper exemption the reminder DOES escalate (proves A is non-vacuous)"
  [[ -n "$mut_reminder_id" ]] || smoke_fail "M sanity: mutated reminder id should be set"

  # Restore the real helper tree for any later block.
  export BRIDGE_SCRIPT_DIR="$saved_script_dir"
}

# ======================================================================
# teeth — structural shape so a revert fails this smoke
# ======================================================================
smoke_run "teeth source carries the precise (title AND created_by) exemption" : ; {
  filter_py="$REPO_ROOT/lib/daemon-helpers/unclaimed-task-filter.py"
  daemon_sh="$REPO_ROOT/bridge-daemon.sh"
  # The exemption must be keyed on created_by=='daemon' AND the reminder
  # prefix — title alone would over-exempt a genuine work task (codex r1 P1).
  grep -qF 'BLOCKED_REMINDER_TITLE_PREFIX = "[blocked-aging] task #"' "$filter_py" \
    || smoke_fail "teeth: helper must define the reminder prefix constant"
  grep -qF '== "daemon"' "$filter_py" \
    || smoke_fail "teeth: exemption must gate on created_by=='daemon' (not title alone)"
  grep -qF 'startswith(BLOCKED_REMINDER_TITLE_PREFIX)' "$filter_py" \
    || smoke_fail "teeth: exemption must match the blocked-aging reminder title prefix"
  # The daemon find-open must NOT title-exempt blocked-aging (that would be the
  # over-broad title-only filter we explicitly moved into the helper).
  if grep -qF -e "--exclude-title-prefix '[blocked-aging]" "$daemon_sh"; then
    smoke_fail "teeth: blocked-aging must NOT be a title-only find-open exemption (over-broad)"
  fi
  # The unrelated cron-dispatch title-only exemption stays (creator-agnostic).
  grep -qF -e "--exclude-title-prefix '[cron-dispatch]'" "$daemon_sh" \
    || smoke_fail "teeth: the existing [cron-dispatch] find-open exemption must remain"
  # Precision guard: the admin-actionable [blocked-escalation] class must NOT
  # be exempted. A mention in an explanatory comment is fine; what must NOT
  # exist is an EXEMPTION CONSTANT or a startswith()/match on that prefix. Check
  # only non-comment lines that reference the escalation prefix literal.
  if grep -nF '[blocked-escalation]' "$filter_py" | grep -vE '^[0-9]+:\s*#' | grep -q .; then
    smoke_fail "teeth: [blocked-escalation] literal must only appear in comments, never in exemption code"
  fi
}

smoke_log "all tests passed: $SMOKE_NAME"
