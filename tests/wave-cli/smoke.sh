#!/usr/bin/env bash
# tests/wave-cli/smoke.sh — `agent-bridge wave` Phase 1.1 + 1.2 acceptance.
#
# Phase 1.1 covers: dispatch (state JSON + briefs + README), list, show,
# templates, close-issue placeholder.
# Phase 1.2 adds: per-member state mutators (state-list-members,
# state-mark-running) and the dispatch-loop guardrail (when --repo-root is
# not a git project, the spawn loop is skipped and members stay pending).
# Live worker spawn + queue task creation are gated behind
# BRIDGE_WAVE_PHASE_1_2_LIVE_TEST=1 because they require a real agent-bridge
# runtime (tmux + Claude/Codex CLI + roster) to be reproducible.
#
# Codex adapter, PR automation, and close-issue validation belong to Phases
# 1.3-1.6 and are out of scope for this smoke.
#
# Runs with an isolated BRIDGE_HOME under TMPDIR. No live state touched.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log()  { printf '[wave-cli] %s\n' "$*"; }
ok()   { printf '[wave-cli] ok: %s\n' "$*"; }
die()  { printf '[wave-cli][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[wave-cli][skip] %s\n' "$*"; exit 0; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required (have ${BASH_VERSION})"
fi

if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 missing"
fi

TMP_ROOT="$(mktemp -d -t agb-wave-cli.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

export BRIDGE_HOME="$TMP_ROOT/bridge-home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
# Re-anchor worktree metadata + worktree roots into the isolated tree so
# Phase 1.2 dispatch can never touch the operator's live runtime even when
# the surrounding shell exports these (issue #276 Phase 1.2 — `agent-bridge
# --prefer new` walks BRIDGE_WORKTREE_META_DIR and BRIDGE_WORKTREE_ROOT).
export BRIDGE_WORKTREE_META_DIR="$BRIDGE_STATE_DIR/worktrees"
export BRIDGE_WORKTREE_ROOT="$TMP_ROOT/worktrees"
mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_SHARED_DIR" \
  "$BRIDGE_WORKTREE_META_DIR" "$BRIDGE_WORKTREE_ROOT"

# Pin a deterministic main agent so dispatch doesn't try to read
# BRIDGE_AGENT_ID from the live process env.
export BRIDGE_AGENT_ID="wave-smoke-runner"

AB="$REPO_ROOT/agent-bridge"
WAVE_SH="$REPO_ROOT/bridge-wave.sh"
WAVE_PY="$REPO_ROOT/bridge-wave.py"

[[ -x "$AB" ]] || die "agent-bridge missing or not executable at $AB"
[[ -r "$WAVE_SH" ]] || die "bridge-wave.sh missing at $WAVE_SH"
[[ -r "$WAVE_PY" ]] || die "bridge-wave.py missing at $WAVE_PY"

# ---------------------------------------------------------------------------
# 1. python helper smokes
# ---------------------------------------------------------------------------

wave_id="$(python3 "$WAVE_PY" wave-id-generate 276)"
[[ "$wave_id" =~ ^wave-276-[0-9]{8}-[0-9]{4}-[0-9a-f]{8}$ ]] \
  || die "wave-id-generate shape unexpected: $wave_id"
ok "wave-id-generate composes wave-<issue>-<stamp>-<sha8>"

member_id="$(python3 "$WAVE_PY" member-id-generate "$wave_id" A)"
[[ "$member_id" == "$wave_id"-A-* && "${#member_id}" -gt "${#wave_id}" ]] \
  || die "member-id-generate shape unexpected: $member_id"
ok "member-id-generate appends -<track>-<sha8>"

# Close-keyword scanner positive: a brief with `closes #276`
positive="$TMP_ROOT/positive.md"
cat >"$positive" <<'BAD'
This PR closes #276 and fixes #999.
BAD
if python3 "$WAVE_PY" close-keyword-scan "$positive" >/dev/null; then
  die "close-keyword-scan should have flagged $positive"
fi
ok "close-keyword-scan flags closes/fixes/resolves"

negative="$TMP_ROOT/negative.md"
cat >"$negative" <<'OK'
Reference: (#276 Track A). See also: #999 for the related work.
OK
python3 "$WAVE_PY" close-keyword-scan "$negative" >/dev/null \
  || die "close-keyword-scan flagged a clean reference"
ok "close-keyword-scan accepts (#N) reference style"

# ---------------------------------------------------------------------------
# 2. wave dispatch --dry-run
# ---------------------------------------------------------------------------

dry_out="$("$AB" wave dispatch 276 --tracks A,B --main-agent ws-smoke --repo-root "$TMP_ROOT" --dry-run 2>&1)"
[[ "$dry_out" == *"would create wave: wave-276-"* ]] \
  || die "dispatch --dry-run output unexpected: $dry_out"
[[ "$dry_out" == *"tracks:     A,B"* ]] \
  || die "dispatch --dry-run did not echo tracks: $dry_out"

# Confirm dry-run wrote nothing.
[[ "$(find "$BRIDGE_STATE_DIR" -name '*.json' 2>/dev/null | wc -l)" -eq 0 ]] \
  || die "dispatch --dry-run wrote state: $(find "$BRIDGE_STATE_DIR" -name '*.json')"
ok "wave dispatch --dry-run echoes plan + writes nothing"

# ---------------------------------------------------------------------------
# 3. wave dispatch (real)
# ---------------------------------------------------------------------------

dispatch_out="$("$AB" wave dispatch 276 --tracks A,B --main-agent ws-smoke --repo-root "$TMP_ROOT" 2>&1)"
real_wave_id="$(printf '%s\n' "$dispatch_out" | awk '/^wave dispatched: /{print $3}')"
[[ -n "$real_wave_id" ]] || die "could not parse wave id from dispatch output: $dispatch_out"
ok "wave dispatch returns wave id ($real_wave_id)"

state_file="$BRIDGE_STATE_DIR/waves/${real_wave_id}.json"
[[ -r "$state_file" ]] || die "state file missing: $state_file"
ok "wave dispatch writes state JSON"

shared_dir="$BRIDGE_SHARED_DIR/waves/$real_wave_id"
[[ -d "$shared_dir" ]] || die "shared wave dir missing: $shared_dir"
[[ -r "$shared_dir/README.md" ]] || die "README mirror missing: $shared_dir/README.md"
brief_count="$(find "$shared_dir" -name brief.md | wc -l | tr -d ' ')"
[[ "$brief_count" == 2 ]] || die "expected 2 briefs (A,B), got $brief_count"
ok "wave dispatch writes README + 2 member briefs"

# Each brief must NOT contain a close-keyword (Phase 1.1 emits the
# 11-section template — verify the close-keyword footgun warning is in
# place but no actual `closes #N` line).
for b in "$shared_dir"/*/brief.md; do
  # close-keyword-scan returns rc=0 when clean, rc=1 when a hit is found.
  # The brief MUST be clean.
  if ! python3 "$WAVE_PY" close-keyword-scan "$b" >/dev/null; then
    grep -nE "closes\s+#[0-9]+|fixes\s+#[0-9]+|resolves\s+#[0-9]+" "$b" || true
    die "generated brief contains a close-keyword: $b"
  fi
done
ok "generated briefs are close-keyword-clean"

# State JSON shape sanity.
python3 - "$state_file" <<'PY' || die "state JSON sanity check failed"
import json, sys
s = json.loads(open(sys.argv[1]).read())
assert s["wave_id"], "wave_id missing"
assert s["issue"] == "276", f"issue mismatch: {s['issue']!r}"
assert s["main_agent"] == "ws-smoke", f"main_agent mismatch: {s['main_agent']!r}"
assert s["worker_engine"] == "claude", f"default worker engine mismatch: {s['worker_engine']!r}"
assert s["reviewer_policy"] == "codex-rescue", f"default reviewer mismatch: {s['reviewer_policy']!r}"
assert sorted(s["tracks"]) == ["A", "B"], f"tracks mismatch: {s['tracks']!r}"
assert len(s["members"]) == 2, f"members count mismatch: {len(s['members'])}"
for m in s["members"]:
    assert m["state"] == "pending", f"member state should be pending: {m}"
    assert m["task_id"] is None, "phase 1.1 must not set task_id"
    assert m["pr_url"] is None, "phase 1.1 must not set pr_url"
    assert m["worktree_root"] is None, "phase 1.1 must not set worktree_root"
    # Codex r1 finding on PR #373: the member_id in state and the path
    # used by the bash brief writer must agree. Verify brief_path
    # contains the same member_id.
    expected_path_suffix = f"/{m['member_id']}/brief.md"
    assert m["brief_path"].endswith(expected_path_suffix), (
        f"brief_path ({m['brief_path']!r}) does not match member_id ({m['member_id']!r})"
    )
PY
ok "state JSON shape and pending-state invariants hold (incl. member_id consistency)"

# Cross-check: every member's brief_path resolves to an existing brief file.
# This catches the codex r1 regression where state and writer disagreed.
python3 - "$state_file" "$BRIDGE_SHARED_DIR" <<'PY' || die "brief_path actually-on-disk check failed"
import json, sys, os
s = json.loads(open(sys.argv[1]).read())
shared = sys.argv[2]
for m in s["members"]:
    full = os.path.join(shared, m["brief_path"])
    assert os.path.isfile(full), f"member {m['member_id']}: brief not at {full}"
PY
ok "every member's brief_path resolves to an existing brief on disk"

# ---------------------------------------------------------------------------
# 4. wave list / show
# ---------------------------------------------------------------------------

list_json="$("$AB" wave list --json)"
echo "$list_json" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
n = len(data["waves"])
assert n == 1, f"expected 1 wave, got {n}"
w = data["waves"][0]
assert w["issue"] == "276"
assert w["member_states"]["pending"] == 2
' || die "wave list --json shape mismatch"
ok "wave list --json reports 1 wave with 2 pending members"

show_json="$("$AB" wave show "$real_wave_id" --json)"
echo "$show_json" | python3 -c '
import json, sys
s = json.loads(sys.stdin.read())
assert s["wave_id"], "wave show: wave_id missing"
assert sorted(s["tracks"]) == ["A", "B"]
' || die "wave show --json shape mismatch"
ok "wave show --json round-trips state"

show_human="$("$AB" wave show "$real_wave_id")"
[[ "$show_human" == *"wave: $real_wave_id"* ]] || die "wave show (human) header mismatch"
[[ "$show_human" == *"main agent:   ws-smoke"* ]] || die "wave show (human) main_agent missing"
ok "wave show prints human-readable summary"

# ---------------------------------------------------------------------------
# 5. wave templates + close-issue placeholder
# ---------------------------------------------------------------------------

templates_out="$("$AB" wave templates 2>&1)"
[[ "$templates_out" == *"default"* ]] || die "wave templates should mention default"
ok "wave templates lists at least the default template"

# close-issue is a placeholder that exits 64 (operator must do it manually
# for now). Catch the rc explicitly.
set +e
"$AB" wave close-issue 276 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 64 ]] || die "wave close-issue placeholder should exit 64, got $rc"
ok "wave close-issue is placeholder until Phase 1.6 (rc=64)"

# ---------------------------------------------------------------------------
# 6. dispatch with brief-file (no issue number) writes source-brief.md
# ---------------------------------------------------------------------------

brief="$TMP_ROOT/some-brief.md"
cat >"$brief" <<'EOF'
# Some brief
This is a non-issue-numbered brief used to dispatch a wave.
EOF
brief_dispatch="$("$AB" wave dispatch "$brief" --tracks main --main-agent ws-smoke --repo-root "$TMP_ROOT" 2>&1)"
brief_wave_id="$(printf '%s\n' "$brief_dispatch" | awk '/^wave dispatched: /{print $3}')"
[[ -n "$brief_wave_id" ]] || die "brief-file dispatch did not return wave id"
[[ -r "$BRIDGE_SHARED_DIR/waves/$brief_wave_id/source-brief.md" ]] \
  || die "brief-file dispatch did not copy source-brief.md"
ok "wave dispatch <brief-file> mirrors the brief into shared/waves/<id>/source-brief.md"

# ---------------------------------------------------------------------------
# 7. --reviewer override is plumbed through (codex r1 finding on PR #373)
# ---------------------------------------------------------------------------

reviewer_dispatch="$("$AB" wave dispatch 999 --tracks A --main-agent ws-smoke --reviewer custom-reviewer --repo-root "$TMP_ROOT" 2>&1)"
reviewer_wave_id="$(printf '%s\n' "$reviewer_dispatch" | awk '/^wave dispatched: /{print $3}')"
reviewer_state="$BRIDGE_STATE_DIR/waves/${reviewer_wave_id}.json"
python3 - "$reviewer_state" <<'PY' || die "--reviewer override not plumbed to state JSON"
import json, sys
s = json.loads(open(sys.argv[1]).read())
assert s["reviewer_policy"] == "custom-reviewer", (
    f"reviewer_policy override lost: {s['reviewer_policy']!r}"
)
PY
ok "--reviewer override is plumbed to state JSON"

log "all Phase 1.1 acceptance checks passed"

# ---------------------------------------------------------------------------
# 8. Phase 1.2 — state-list-members + state-mark-running unit tests
# ---------------------------------------------------------------------------
#
# These exercise the new Python helpers directly without spawning workers.
# The dispatch shell loop is also tested via the non-git --repo-root guard
# (it must skip the spawn block, leaving members pending).

# 8a. state-list-members emits one row per pending member (TSV).
list_members_state="$BRIDGE_STATE_DIR/waves/${real_wave_id}.json"
list_out="$(python3 "$WAVE_PY" state-list-members "$list_members_state" "$BRIDGE_SHARED_DIR")"
list_count="$(printf '%s\n' "$list_out" | grep -c $'\t' || true)"
[[ "$list_count" == 2 ]] || die "state-list-members expected 2 rows, got $list_count: $list_out"
# Each row: <member_id>\t<track>\t<absolute_brief_path>
# codex r1 item 11: brief paths must be absolute and exist on disk
# regardless of caller CWD or whether shared_dir was passed as a
# relative path.
while IFS=$'\t' read -r m_id m_track m_brief; do
  [[ -n "$m_id" ]] || die "state-list-members row missing member_id"
  [[ -n "$m_track" ]] || die "state-list-members row missing track for $m_id"
  [[ -f "$m_brief" ]] || die "state-list-members brief path not on disk: $m_brief"
  [[ "$m_brief" = /* ]] || die "state-list-members brief path is not absolute: $m_brief"
done <<<"$list_out"
ok "state-list-members emits TSV rows with absolute brief paths"

# 8a'. Run state-list-members from a CWD other than the state dir with a
# relative shared-dir path; the emitted brief paths must still be
# absolute (codex r1 item 11 — `.resolve()` not `.absolute()` so the
# resolution doesn't depend on the caller's CWD).
shared_rel="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], "/tmp"))' "$BRIDGE_SHARED_DIR")"
state_rel="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], "/tmp"))' "$list_members_state")"
list_out_rel="$(cd /tmp && python3 "$WAVE_PY" state-list-members "$state_rel" "$shared_rel")"
[[ -n "$list_out_rel" ]] || die "state-list-members from /tmp produced no rows"
while IFS=$'\t' read -r _m_id _m_track m_brief_rel; do
  [[ -n "$m_brief_rel" ]] || continue
  [[ "$m_brief_rel" = /* ]] || die "state-list-members from other CWD emitted non-absolute path: $m_brief_rel"
  [[ -f "$m_brief_rel" ]] || die "state-list-members from other CWD: brief not on disk: $m_brief_rel"
done <<<"$list_out_rel"
ok "state-list-members produces absolute paths even when invoked from a different CWD"

# 8b. state-list-members --state running on a fresh wave returns empty.
running_out="$(python3 "$WAVE_PY" state-list-members "$list_members_state" "$BRIDGE_SHARED_DIR" --state running)"
[[ -z "$running_out" ]] || die "state-list-members --state running should be empty on fresh wave: $running_out"
ok "state-list-members --state running filters correctly"

# 8c. state-mark-running transitions a member pending -> running with all
# four wiring fields and appends a wave_member_queued audit row.
target_member="$(printf '%s\n' "$list_out" | head -n 1 | cut -f1)"
[[ -n "$target_member" ]] || die "could not pick a member to mark running"
python3 "$WAVE_PY" state-mark-running "$list_members_state" \
  --member-id "$target_member" \
  --worker "$target_member" \
  --worktree-root "$TMP_ROOT/worktrees/test-repo/$target_member" \
  --branch "agent-bridge/$target_member" \
  --task-id 12345 >/dev/null \
  || die "state-mark-running failed for $target_member"

python3 - "$list_members_state" "$target_member" <<'PY' || die "state-mark-running invariants violated"
import json, sys
state_file, target = sys.argv[1], sys.argv[2]
s = json.loads(open(state_file).read())
hit = next(m for m in s["members"] if m["member_id"] == target)
assert hit["state"] == "running", f"state not running: {hit['state']!r}"
assert hit["task_id"] == 12345, f"task_id mismatch: {hit['task_id']!r}"
assert hit["worker"] == target, f"worker mismatch: {hit['worker']!r}"
assert hit["worktree_root"].endswith(target), f"worktree_root mismatch: {hit['worktree_root']!r}"
assert hit["branch"] == f"agent-bridge/{target}", f"branch mismatch: {hit['branch']!r}"
# The other member must still be pending.
others = [m for m in s["members"] if m["member_id"] != target]
assert all(m["state"] == "pending" for m in others), "non-target members should remain pending"
# Audit row must be appended (Phase 1.1 wrote `wave_dispatched`; Phase 1.2
# appends `wave_member_queued:<member-id> worker=… task_id=… worktree_root=…
# branch=…` so a state-only inspection can see the full wiring without
# having to cross-reference bridge_audit_log).
prefix = f"wave_member_queued:{target}"
matching = [a for a in s.get("audit", []) if a.startswith(prefix + " ") or a == prefix]
assert matching, (
    f"audit row {prefix} missing; got: {s.get('audit')!r}"
)
assert any("worker=" in a and "task_id=12345" in a for a in matching), (
    f"audit row missing worker/task wiring; got: {matching!r}"
)
PY
ok "state-mark-running transitions one member pending -> running and audits"

# 8d. After step 8c, state-list-members default (--state pending) should
# return only the OTHER member.
remaining="$(python3 "$WAVE_PY" state-list-members "$list_members_state" "$BRIDGE_SHARED_DIR")"
remaining_count="$(printf '%s\n' "$remaining" | grep -c $'\t' || true)"
[[ "$remaining_count" == 1 ]] || die "after mark-running, expected 1 pending row, got $remaining_count"
ok "state-list-members reflects the pending -> running transition"

# 8e. state-mark-running with a missing required arg returns rc=2.
set +e
python3 "$WAVE_PY" state-mark-running "$list_members_state" --member-id "$target_member" >/dev/null 2>&1
mr_rc=$?
set -e
[[ "$mr_rc" == 2 ]] || die "state-mark-running missing-args expected rc=2, got $mr_rc"
ok "state-mark-running validates required args (rc=2)"

# 8f. Dispatch loop guardrail: --repo-root is not a git project => spawn
# loop skips, members stay pending. Already exercised by 8a + state JSON
# invariants above (tasks_id was None at the time of state-list-members in
# step 8a, and the new wave used --repo-root "$TMP_ROOT" which is not a
# git checkout). Make the invariant explicit:
fresh_state="$BRIDGE_STATE_DIR/waves/${reviewer_wave_id}.json"
python3 - "$fresh_state" <<'PY' || die "non-git --repo-root should leave members pending"
import json, sys
s = json.loads(open(sys.argv[1]).read())
for m in s["members"]:
    assert m["state"] == "pending", f"non-git repo-root should keep state pending: {m}"
    assert m["task_id"] is None, f"non-git repo-root should not assign task_id: {m}"
    assert m.get("worker") in (None,), f"non-git repo-root should not set worker: {m}"
PY
ok "non-git --repo-root short-circuits the Phase 1.2 spawn loop"

log "all Phase 1.1 + 1.2 acceptance checks passed"

# ---------------------------------------------------------------------------
# 9. Phase 1.2 LIVE — gated; opt-in via BRIDGE_WAVE_PHASE_1_2_LIVE_TEST=1.
# Validates the full dispatch-to-running handoff against a real
# `agent-bridge --<engine>` invocation in an isolated BRIDGE_HOME.
# Requires: tmux, claude or codex CLI on PATH, a writable git working dir.
# ---------------------------------------------------------------------------
if [[ "${BRIDGE_WAVE_PHASE_1_2_LIVE_TEST:-0}" == "1" ]]; then
  log "BRIDGE_WAVE_PHASE_1_2_LIVE_TEST=1 — running live dispatch test (may launch tmux sessions)"

  # codex r1 item 12: live workers + queue tasks must be torn down on
  # exit (success OR failure) so the smoke is rerunnable. The cleanup
  # uses a randomized title/session prefix so concurrent invocations
  # never collide, and is idempotent — the trap may fire twice (once
  # from EXIT, once if we re-arm the trap) and must not error.
  LIVE_PREFIX="wave-p12-livetest-${RANDOM}-$$"
  LIVE_TITLE_PREFIX="[livetest ${LIVE_PREFIX}]"
  export BRIDGE_WAVE_LIVETEST_PREFIX="$LIVE_PREFIX"

  _wave_livetest_cleanup() {
    # Idempotent — every command swallows its own errors so re-running
    # the trap (or running it after a partial setup) is safe.
    if command -v tmux >/dev/null 2>&1; then
      # Find sessions whose name contains our prefix and kill them.
      tmux list-sessions -F '#S' 2>/dev/null \
        | grep -F "$LIVE_PREFIX" 2>/dev/null \
        | while IFS= read -r _sess; do
            [[ -n "$_sess" ]] || continue
            tmux kill-session -t "$_sess" 2>/dev/null || true
          done
    fi
    # Cancel any queue tasks created by this run. Best-effort: list,
    # match by title prefix, mark done. The queue tooling tolerates
    # repeat `done` calls on a closed task without erroring.
    if [[ -x "$AB" ]]; then
      "$AB" inbox --json 2>/dev/null \
        | python3 -c '
import json, os, sys
prefix = os.environ.get("BRIDGE_WAVE_LIVETEST_PREFIX", "")
if not prefix:
    sys.exit(0)
try:
    data = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)
tasks = data if isinstance(data, list) else data.get("tasks", [])
for t in tasks:
    title = t.get("title", "") or ""
    tid = t.get("id") or t.get("task_id")
    if prefix in title and tid is not None:
        print(tid)
' 2>/dev/null \
        | while IFS= read -r _tid; do
            [[ -n "$_tid" ]] || continue
            "$BRIDGE_BASH_BIN" "$REPO_ROOT/bridge-task.sh" done "$_tid" \
              --agent ws-smoke \
              --note "livetest cleanup ($LIVE_PREFIX)" >/dev/null 2>&1 || true
          done
    fi
    # TMP_ROOT is already covered by the outer `trap … EXIT` (line ~37);
    # this no-op is here as documentation / belt-and-braces in case the
    # outer trap is replaced.
    [[ -d "${TMP_ROOT:-}" ]] && rm -rf "$TMP_ROOT"/livetest-* 2>/dev/null || true
  }
  # Compose a trap that runs both the existing TMP_ROOT cleanup and the
  # livetest teardown. The EXIT trap is rebound here (not added) so we
  # have to keep the original rm -rf call too.
  trap '_wave_livetest_cleanup; rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

  live_out="$("$AB" wave dispatch 276 --tracks "${LIVE_PREFIX}" --main-agent ws-smoke --repo-root "$REPO_ROOT" 2>&1)" \
    || die "live dispatch failed: $live_out"
  live_wave_id="$(printf '%s\n' "$live_out" | awk '/^wave dispatched: /{print $3}')"
  [[ -n "$live_wave_id" ]] || die "live dispatch did not return wave id: $live_out"
  python3 - "$BRIDGE_STATE_DIR/waves/${live_wave_id}.json" <<'PY' || die "live dispatch did not transition member to running"
import json, sys
s = json.loads(open(sys.argv[1]).read())
running = [m for m in s["members"] if m["state"] == "running"]
assert running, f"expected at least one running member; got: {s['members']}"
for m in running:
    assert m["task_id"] is not None, f"running member missing task_id: {m}"
    assert m["worker"], f"running member missing worker: {m}"
    assert m["worktree_root"], f"running member missing worktree_root: {m}"
    assert m["branch"], f"running member missing branch: {m}"
PY
  ok "live dispatch transitions a member to running with full wiring"

  # Verify cleanup is idempotent: invoking it again must not error.
  _wave_livetest_cleanup
  _wave_livetest_cleanup
  ok "live dispatch cleanup is idempotent"
fi
