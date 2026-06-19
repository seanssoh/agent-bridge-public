#!/usr/bin/env bash
# scripts/smoke/1983-wiki-ingest-lane-b-liveness.sh — Issue #1983 smoke.
#
# scripts/wiki-daily-ingest.sh Lane B used to select the [librarian-ingest]
# target by agent EXISTENCE (`agb agent show librarian`) rather than LIVENESS.
# When librarian was stopped, `agb task create --to librarian` failed (an
# inactive agent needs --force), `|| true` swallowed the failure, and
# `lane_b_enqueue_status=enqueued-librarian` was set unconditionally — so the
# run + audit log claimed a successful enqueue while Lane B captures were
# SILENTLY DROPPED, and the designed `$BRIDGE_ADMIN_AGENT` fallback never
# engaged.
#
# Fix (#1983): the target is selected by liveness (librarian's `active` flag in
# `agb agent list --json`, the canonical bridge liveness signal), so a stopped
# librarian falls through to the live admin fallback; and the create exit code
# is captured so `lane_b_enqueue_status` reflects the ACTUAL outcome
# (`enqueued-<target>` on success, `enqueue-failed-<target>` on failure) instead
# of an unconditional `enqueued-librarian`.
#
# This smoke is hermetic + Linux-CI portable: it stubs `agb` (BRIDGE_AGB)
# entirely so no real CLI / queue / agent-state is exercised. The stub records
# the actual `task create --to <target>` invocation and refuses (exit 1) a
# create aimed at a stopped librarian without --force — the same shape that
# produced the original false positive.
#
# Assertions:
# T1 (stopped librarian): the run does NOT report `enqueue=enqueued-librarian`;
#     Lane B routes to the live admin fallback and reports
#     `enqueue=enqueued-<admin>`; the stub recorded a create --to <admin>, and
#     recorded NO create --to librarian. The audit log does not claim a
#     librarian success that did not occur.
# T2 (live librarian, no regression): Lane B reports `enqueue=enqueued-librarian`
#     and the stub recorded a create --to librarian.
# T3 (honest failure, no silent drop): when even the chosen target's create
#     fails, the run reports `enqueue=enqueue-failed-<target>` (a visible
#     failure), never a false `enqueued-` success.
# T4 (mutation guard): with the fix reverted, a stopped librarian would yield
#     `enqueue=enqueued-librarian` with no task created — this smoke is
#     non-vacuous because T1 asserts the opposite.

set -euo pipefail

SMOKE_NAME="1983-wiki-ingest-lane-b-liveness"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

ADMIN_AGENT="patch"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Write the hermetic agb stub under $BRIDGE_HOME (so the Lane B same-install
# guard — which requires BRIDGE_AGB to resolve under BRIDGE_HOME — passes).
# Behaviour is controlled by two marker files in the stub's own dir:
#   librarian-active  : present → `agent list --json` reports librarian active
#   create-fail-all   : present → every `task create` exits 1 (force a failure
#                       even for a live/admin target, to test honest reporting)
# The stub appends every `task create --to <target>` to created-targets.log.
write_agb_stub() {
  local stub="$BRIDGE_HOME/agent-bridge"
  smoke_assert_path_in_temp "$stub" "agb stub write"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
# Hermetic agb stub for the #1983 Lane B liveness smoke. Not a real CLI.
set -u
_stub_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_admin="${STUB_ADMIN_AGENT:-patch}"

_librarian_active=false
[[ -f "$_stub_dir/librarian-active" ]] && _librarian_active=true

case "${1:-}" in
  agent)
    case "${2:-}" in
      list)
        # `agent list --json` — librarian active flag is the only thing the
        # Lane B liveness gate reads. The admin is always active.
        printf '[{"agent":"%s","engine":"claude","active":true,"workdir":"%s"},' \
          "$_admin" "$_stub_dir"
        printf '{"agent":"librarian","engine":"claude","active":%s,"workdir":"%s"}]\n' \
          "$_librarian_active" "$_stub_dir"
        exit 0
        ;;
      show)
        # `agent show <name>` — proves existence (exit 0). The OLD buggy gate
        # keyed on THIS, which is why a stopped-but-present librarian was
        # wrongly chosen. The librarian record exists regardless of liveness.
        exit 0
        ;;
    esac
    ;;
  cron)
    if [[ "${2:-}" == "list" ]]; then
      # Empty inventory → Lane B Gate 1 cron check is permissive.
      printf '{"jobs":[]}\n'
      exit 0
    fi
    ;;
  task)
    if [[ "${2:-}" == "create" ]]; then
      # Parse --to and detect --force.
      _to=""
      _force=false
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --to) _to="${2:-}"; shift 2 ;;
          --force) _force=true; shift ;;
          --body-file|--title|--from|--priority) shift 2 ;;
          *) shift ;;
        esac
      done
      printf '%s\n' "$_to" >>"$_stub_dir/created-targets.log"
      # Force-fail mode: every create fails (honest-reporting test).
      if [[ -f "$_stub_dir/create-fail-all" ]]; then
        echo "stub: forced create failure" >&2
        exit 1
      fi
      # Real-CLI shape: creating a task for a stopped (inactive) librarian
      # without --force fails. The admin is always live, so admin succeeds.
      if [[ "$_to" == "librarian" && "$_librarian_active" != true && "$_force" != true ]]; then
        echo "stub: librarian is inactive — needs --force" >&2
        exit 1
      fi
      exit 0
    fi
    ;;
esac
# Unhandled verbs are a no-op success — the smoke only drives the paths above.
exit 0
STUB
  chmod +x "$stub"
  printf '%s' "$stub"
}

# Run wiki-daily-ingest.sh against an isolated fixture and echo the stdout
# summary line. Lane B routing is what we assert; the legacy enumeration path
# (no BRIDGE_LAYOUT=v2) keeps the non-daily fixture deterministic.
run_ingest() {
  local agents_root="$BRIDGE_HOME/agents"
  local wiki_root="$BRIDGE_HOME/shared/wiki"
  local research_dir="$agents_root/alpha/memory/research"
  mkdir -p "$research_dir" "$wiki_root/_audit" "$BRIDGE_STATE_DIR/wiki"

  # One non-daily capture modified now → Lane B has work (non_daily_total>0).
  : >"$research_dir/note-$(date +%Y-%m-%d).md"
  printf 'fixture research note\n' >"$research_dir/note-$(date +%Y-%m-%d).md"

  local stub
  stub="$write_agb_stub_path"

  env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_SHARED_ROOT="$BRIDGE_HOME/shared" \
    BRIDGE_WIKI_ROOT="$wiki_root" \
    BRIDGE_AGENTS_ROOT="$agents_root" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db" \
    BRIDGE_SCRIPTS_ROOT="$SMOKE_REPO_ROOT/scripts" \
    BRIDGE_AGB="$stub" \
    BRIDGE_ADMIN_AGENT="$ADMIN_AGENT" \
    BRIDGE_HOST_PROFILE=server \
    STUB_ADMIN_AGENT="$ADMIN_AGENT" \
    bash "$SMOKE_REPO_ROOT/scripts/wiki-daily-ingest.sh" 2>/dev/null \
    | grep '^wiki-daily-ingest:' || true
}

audit_log() {
  cat "$BRIDGE_HOME/shared/wiki/_audit/ingest-$(date +%Y-%m-%d).md" 2>/dev/null || true
}

created_targets() {
  cat "$write_agb_stub_dir/created-targets.log" 2>/dev/null || true
}

reset_stub_state() {
  rm -f "$write_agb_stub_dir/created-targets.log" \
        "$write_agb_stub_dir/librarian-active" \
        "$write_agb_stub_dir/create-fail-all"
}

assert_stopped_librarian_falls_back() {
  reset_stub_state
  # librarian-active marker ABSENT → librarian is stopped/inactive.
  local summary targets log
  summary="$(run_ingest)"
  targets="$(created_targets)"
  log="$(audit_log)"

  smoke_assert_not_contains "$summary" "enqueue=enqueued-librarian" \
    "T1: stopped librarian does NOT false-report enqueue=enqueued-librarian"
  smoke_assert_contains "$summary" "enqueue=enqueued-$ADMIN_AGENT" \
    "T1: stopped librarian routes to the live admin fallback ($ADMIN_AGENT)"
  smoke_assert_contains "$targets" "$ADMIN_AGENT" \
    "T1: a real create --to $ADMIN_AGENT was issued (not a silent drop)"
  smoke_assert_not_contains "$targets" "librarian" \
    "T1: no create --to librarian was attempted at a stopped librarian"
  smoke_assert_not_contains "$log" "enqueued-librarian" \
    "T1: audit log does not claim a librarian success that did not occur"
}

assert_live_librarian_enqueues() {
  reset_stub_state
  : >"$write_agb_stub_dir/librarian-active"  # librarian is LIVE
  local summary targets
  summary="$(run_ingest)"
  targets="$(created_targets)"

  smoke_assert_contains "$summary" "enqueue=enqueued-librarian" \
    "T2: live librarian still enqueues to librarian (no regression)"
  smoke_assert_contains "$targets" "librarian" \
    "T2: a real create --to librarian was issued"
}

assert_failed_create_is_visible() {
  reset_stub_state
  : >"$write_agb_stub_dir/librarian-active"   # librarian live → chosen target
  : >"$write_agb_stub_dir/create-fail-all"    # but the create itself fails
  local summary
  summary="$(run_ingest)"

  smoke_assert_contains "$summary" "enqueue=enqueue-failed-librarian" \
    "T3: a failed create is reported as enqueue-failed-<target>, not a false success"
  smoke_assert_not_contains "$summary" "enqueue=enqueued-librarian" \
    "T3: a failed create never reads as enqueued-librarian"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  write_agb_stub_path="$(write_agb_stub)"
  write_agb_stub_dir="$(cd -P "$(dirname "$write_agb_stub_path")" && pwd -P)"

  smoke_run "T1: stopped librarian → live admin fallback + honest status" \
    assert_stopped_librarian_falls_back
  smoke_run "T2: live librarian → enqueued-librarian (no regression)" \
    assert_live_librarian_enqueues
  smoke_run "T3: failed create → visible enqueue-failed, no silent false success" \
    assert_failed_create_is_visible

  smoke_log "PASS"
}

main "$@"
