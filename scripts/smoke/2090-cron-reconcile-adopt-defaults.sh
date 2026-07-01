#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2090-cron-reconcile-adopt-defaults.sh — Issue #2090.
#
# bootstrap-memory-system.sh normally REFUSES to overwrite a wiki-* or
# memory-daily-<agent> cron whose live schedule/tz has drifted from the
# cadence shipped in the current version — it records `conflict` and notes
# drift so an operator's deliberate schedule is never clobbered silently.
# Before #2090 there was no way to converge an upgraded install onto the
# shipped cadences short of manual delete/recreate per job.
#
# #2090 adds an OPT-IN `--reconcile` (apply-only) flag: for each drifted
# same-family job it adopts the shipped default in place via `agb cron
# update` (verb-atomic) and records a `reconciled` (existing → want) row.
# Default behaviour (no flag) MUST stay non-destructive — the job is left
# untouched and only recorded as `conflict`.
#
# This smoke drives the REAL bootstrap-memory-system.sh against an isolated
# BRIDGE_HOME with a stubbed `agb` that:
#   - reports one static/active claude admin agent (so the memory-daily and
#     wiki-* registration paths both run),
#   - returns a cron inventory in which BOTH a wiki-* job (wiki-mention-scan)
#     and the admin's memory-daily job already exist on a DIFFERENT schedule
#     than the shipped default (drift),
#   - logs every `cron update` / `cron create` / `cron delete` mutation to a
#     file so the test can assert what actually mutated.
#
# Mutation proof (the core of this smoke):
#   T1: WITHOUT --reconcile — the stubbed inventory jobs are recorded as
#       `conflict`, NO `cron update` is issued against them, and the report
#       carries `reconcile_requested=false`. (non-destructive default)
#   T2: WITH --reconcile — the same two drifted jobs are recorded as
#       `reconciled` (existing → want), a `cron update <id> --schedule ...`
#       IS issued for each, and the report carries `reconcile_requested=true`.
#   T3: --reconcile without --apply is rejected (exit 2).
#
# Footgun #11 (heredoc-stdin): the stub `agb` and the report-inspection
# python read their input from files / argv, not a heredoc piped to a
# subprocess. The only heredocs write fixture files to disk via redirection.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:2090-cron-reconcile-adopt-defaults][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="2090-cron-reconcile-adopt-defaults"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd cksum
smoke_require_cmd awk

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"
BOOTSTRAP="$REPO_ROOT/bootstrap-memory-system.sh"
smoke_assert_file_exists "$BOOTSTRAP" "T0: bootstrap-memory-system.sh present in repo root"

BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-$(command -v bash)}"
export BRIDGE_BASH_BIN

ADMIN="patch"
export BRIDGE_ADMIN_AGENT="$ADMIN"
export BRIDGE_ADMIN_AGENT_ID="$ADMIN"
# A prior bootstrap report keeps the wiki-graph stack ON, and the explicit
# opt-in env removes any inference; both drive --apply past the #1263 gate.
export BRIDGE_WIKI_GRAPH_ENABLED=1

# Give the admin a real workdir so list_active_static_claude_agents accepts it.
ADMIN_WORKDIR="$BRIDGE_HOME/agents/$ADMIN"
mkdir -p "$ADMIN_WORKDIR"

# ----------------------------------------------------------------------------
# Compute the shipped default for the admin's memory-daily cron so the test
# can assert the exact adopted schedule. Mirrors the script's own jitter:
#   jitter_min = cksum(agent) % 60 ; schedule = "<jitter_min> 3 * * *"
# ----------------------------------------------------------------------------
JITTER_MIN="$(printf '%s' "$ADMIN" | cksum | awk '{print $1 % 60}')"
MEMDAILY_WANT="$JITTER_MIN 3 * * *"
# Seed an existing memory-daily schedule that is UNAMBIGUOUSLY a different
# cadence (different hour) so it is a generic drift, not the re-jitter
# same-minute collapse signature — proving --reconcile adopts broadly.
MEMDAILY_EXISTING="30 5 * * *"
# wiki-mention-scan shipped default is "17 * * * *"; seed a drifted one.
WIKI_WANT="17 * * * *"
WIKI_EXISTING="41 * * * *"

# ----------------------------------------------------------------------------
# Stub `agb`. Dispatches on the subcommand. Mutations are appended to
# $MUTATION_LOG so the test can assert exactly which jobs were updated.
# ----------------------------------------------------------------------------
MUTATION_LOG="$SMOKE_TMP_ROOT/agb-mutations.log"
: >"$MUTATION_LOG"
export MUTATION_LOG SMOKE_ADMIN="$ADMIN" SMOKE_ADMIN_WORKDIR="$ADMIN_WORKDIR"
export SMOKE_WIKI_EXISTING="$WIKI_EXISTING" SMOKE_MEMDAILY_EXISTING="$MEMDAILY_EXISTING"

STUB_AGB="$BRIDGE_HOME/agent-bridge"
smoke_assert_path_in_temp "$STUB_AGB" "stub agb"
cat >"$STUB_AGB" <<'STUB'
#!/usr/bin/env bash
# Minimal `agb` stub for the #2090 reconcile smoke. Handles only the verbs
# bootstrap-memory-system.sh issues on the cron-conflict/reconcile path.
set -uo pipefail

sub="${1:-}"; shift || true

emit_agent_list() {
  # One static/active claude admin agent with a workdir.
  printf '[{"agent":"%s","engine":"claude","active":true,"source":"static","workdir":"%s"}]\n' \
    "$SMOKE_ADMIN" "$SMOKE_ADMIN_WORKDIR"
}

emit_cron_list() {
  # Args may include: --agent <name> --json. The wiki-* lookups pass the
  # admin; the memory-daily lookup passes the admin too (single-agent run).
  # Return BOTH the drifted wiki-mention-scan job and the drifted
  # memory-daily-<admin> job. `title` + `schedule` + `id` are the fields
  # cron_lookup / memory_daily_cron_lookup read.
  cat <<JSON
{"jobs":[
  {"id":"job-wiki-mention","title":"wiki-mention-scan","schedule":"$SMOKE_WIKI_EXISTING","tz":"Asia/Seoul","payload_preview":"bash wiki-mention-scan.sh"},
  {"id":"job-memdaily-admin","title":"memory-daily-$SMOKE_ADMIN","schedule":"$SMOKE_MEMDAILY_EXISTING","tz":"Asia/Seoul","payload_preview":"bash memory-daily-harvest.sh"}
]}
JSON
}

case "$sub" in
  agent)
    # `agent list --json`
    if [[ "${1:-}" == "list" ]]; then emit_agent_list; fi
    exit 0
    ;;
  cron)
    verb="${1:-}"; shift || true
    case "$verb" in
      list) emit_cron_list; exit 0 ;;
      update|create|delete)
        printf 'cron %s %s\n' "$verb" "$*" >>"$MUTATION_LOG"
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  task)
    # first-run signal — accept and succeed.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_AGB"
export BRIDGE_AGB="$STUB_AGB"

run_bootstrap() {
  # run_bootstrap <extra-args...> — prints combined stdout+stderr; sets RC.
  local _out _rc=0
  _out="$(
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_AGB="$STUB_AGB" \
    BRIDGE_ADMIN_AGENT="$ADMIN" \
    BRIDGE_ADMIN_AGENT_ID="$ADMIN" \
    BRIDGE_WIKI_GRAPH_ENABLED=1 \
      "$BRIDGE_BASH_BIN" "$BOOTSTRAP" "$@" 2>&1
  )" || _rc=$?
  RUN_OUT="$_out"
  RUN_RC="$_rc"
}

# latest_report — path of the most recent report-*.json under bootstrap-memory.
# Report basenames are `report-<YYYYMMDD-HHMMSS>.json` (alphanumeric + dash +
# dot only), so mtime-sorted `ls -1t` is safe here.
latest_report() {
  # shellcheck disable=SC2012  # report-*.json names are stamp-only, no globs
  ls -1t "$BRIDGE_STATE_DIR/bootstrap-memory"/report-*.json 2>/dev/null | head -n1
}

# report_status <report> <step-substr> — prints the `status` for the record
# whose `step` contains <step-substr>. Reads the JSON via python (argv, no
# heredoc-stdin).
report_status() {
  python3 - "$1" "$2" <<'PY'
import json, sys
report, step_sub = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(report, encoding="utf-8"))
except Exception:
    sys.exit(0)
for r in data.get("records", []):
    if step_sub in (r.get("step") or ""):
        print(r.get("status") or "")
        break
PY
}

# report_note <report> <step-substr> — prints the `note` for the matching record.
report_note() {
  python3 - "$1" "$2" <<'PY'
import json, sys
report, step_sub = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(report, encoding="utf-8"))
except Exception:
    sys.exit(0)
for r in data.get("records", []):
    if step_sub in (r.get("step") or ""):
        print(r.get("note") or "")
        break
PY
}

report_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
report, field = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(report, encoding="utf-8"))
except Exception:
    sys.exit(0)
val = data.get(field)
print("true" if val is True else "false" if val is False else ("" if val is None else val))
PY
}

# ============================================================================
# T1 — WITHOUT --reconcile: drifted same-family jobs are recorded as
# `conflict`, NOT mutated. Non-destructive default.
# ============================================================================
smoke_log "T1: --apply (no --reconcile) leaves drifted crons untouched (conflict, no update)"
: >"$MUTATION_LOG"
run_bootstrap --apply
[[ "$RUN_RC" -eq 0 || "$RUN_RC" -eq 2 ]] \
  || smoke_fail "T1: bootstrap exited unexpectedly rc=$RUN_RC; out:\n$RUN_OUT"

REPORT_T1="$(latest_report)"
[[ -n "$REPORT_T1" ]] || smoke_fail "T1: no report emitted; out:\n$RUN_OUT"

WIKI_STATUS_T1="$(report_status "$REPORT_T1" "cron:wiki-mention-scan")"
MEM_STATUS_T1="$(report_status "$REPORT_T1" "cron:memory-daily-$ADMIN")"
smoke_assert_eq "conflict" "$WIKI_STATUS_T1" \
  "T1: wiki-mention-scan drift must be a conflict (no adoption) without --reconcile"
smoke_assert_eq "conflict" "$MEM_STATUS_T1" \
  "T1: memory-daily-$ADMIN drift must be a conflict (no adoption) without --reconcile"

# No `cron update` was issued against the two drifted jobs.
smoke_assert_not_contains "$(cat "$MUTATION_LOG")" "cron update job-wiki-mention" \
  "T1: wiki-mention-scan must NOT be updated without --reconcile (non-destructive default)"
smoke_assert_not_contains "$(cat "$MUTATION_LOG")" "cron update job-memdaily-admin" \
  "T1: memory-daily-$ADMIN must NOT be updated without --reconcile (non-destructive default)"

RECON_REQ_T1="$(report_field "$REPORT_T1" "reconcile_requested")"
smoke_assert_eq "false" "$RECON_REQ_T1" "T1: reconcile_requested must be false when the flag is absent"

# The conflict rows must still surface the adopt-path hint (in the recorded
# note, so the operator can discover --reconcile) — proving the diff is not
# lost even on the non-destructive path.
WIKI_NOTE_T1="$(report_note "$REPORT_T1" "cron:wiki-mention-scan")"
smoke_assert_contains "$WIKI_NOTE_T1" "run-with---reconcile-to-adopt-shipped-default" \
  "T1: the conflict note must surface the --reconcile adopt-path hint"

# ============================================================================
# T2 — WITH --reconcile: the same two drifted jobs are adopted to the shipped
# default (reconciled), and a `cron update <id> --schedule <want>` IS issued.
# ============================================================================
smoke_log "T2: --apply --reconcile adopts the shipped default for the drifted crons (mutation-proven)"
: >"$MUTATION_LOG"
run_bootstrap --apply --reconcile
[[ "$RUN_RC" -eq 0 || "$RUN_RC" -eq 2 ]] \
  || smoke_fail "T2: bootstrap exited unexpectedly rc=$RUN_RC; out:\n$RUN_OUT"

REPORT_T2="$(latest_report)"
[[ -n "$REPORT_T2" && "$REPORT_T2" != "$REPORT_T1" ]] \
  || smoke_fail "T2: no fresh report emitted (T1=$REPORT_T1 T2=$REPORT_T2); out:\n$RUN_OUT"

WIKI_STATUS_T2="$(report_status "$REPORT_T2" "cron:wiki-mention-scan")"
MEM_STATUS_T2="$(report_status "$REPORT_T2" "cron:memory-daily-$ADMIN")"
smoke_assert_eq "reconciled" "$WIKI_STATUS_T2" \
  "T2: wiki-mention-scan drift must be reconciled with --reconcile"
smoke_assert_eq "reconciled" "$MEM_STATUS_T2" \
  "T2: memory-daily-$ADMIN drift must be reconciled with --reconcile"

# Mutation proof: the exact `cron update <id> --schedule <want> --tz <tz>`
# was issued for each drifted job.
MUT="$(cat "$MUTATION_LOG")"
smoke_assert_contains "$MUT" "cron update job-wiki-mention --schedule $WIKI_WANT" \
  "T2: wiki-mention-scan must be updated to the shipped default schedule ($WIKI_WANT)"
smoke_assert_contains "$MUT" "cron update job-memdaily-admin --schedule $MEMDAILY_WANT" \
  "T2: memory-daily-$ADMIN must be updated to the shipped default schedule ($MEMDAILY_WANT)"

RECON_REQ_T2="$(report_field "$REPORT_T2" "reconcile_requested")"
smoke_assert_eq "true" "$RECON_REQ_T2" "T2: reconcile_requested must be true when --reconcile is passed"

# The run prints an operator-visible `existing → want` diff.
smoke_assert_contains "$RUN_OUT" "adopted shipped default" \
  "T2: run must print an operator-visible existing→want reconcile diff"

# ============================================================================
# T3 — misuse guard: --reconcile without --apply is rejected (exit 2).
# ============================================================================
smoke_log "T3: --reconcile requires --apply (dry-run/check rejected, exit 2)"
run_bootstrap --dry-run --reconcile
smoke_assert_eq "2" "$RUN_RC" "T3: --reconcile --dry-run must exit 2"
smoke_assert_contains "$RUN_OUT" "--reconcile requires --apply" \
  "T3: the misuse error must name the --apply requirement"

smoke_log "PASS: #2090 opt-in --reconcile adopts shipped cadence over same-family drift; default stays non-destructive"
