#!/usr/bin/env bash
# scripts/smoke/1455-settings-two-tree-doctor.sh — Issue #1455 smoke.
#
# Validates the two settings single-tree invariant detectors in
# bridge-doctor.py PLUS an executable assertion of the invariant itself —
# the check that WOULD have caught #1453 (a channel agent reading a stale
# `enabledPlugins[X]=false` out of a SECOND, drifted settings tree).
#
# The single-tree invariant (docs/settings-single-tree-invariant.md):
#   <home>/.claude/settings.effective.json   = the ONE real effective file
#   <home>/.claude/settings.json             -> settings.effective.json
#   <workdir>/.claude/settings.json          -> (relative)
#                                ../../home/.claude/settings.effective.json
# When it holds, realpath(workdir settings.json) == realpath(home
# settings.json) — same inode, cannot drift. When violated (two real
# files), they drift silently.
#
# Detectors under test (both read `agent registry --json` home + workdir):
#   (a) settings-two-tree-drift : home + workdir settings.json resolve to
#       DIFFERENT real files (workdir copy is a second real file, not a
#       symlink back to home).
#   (b) settings-multi-tree     : a real (non-symlink) settings.effective.json
#       exists under BOTH home/.claude/ and workdir/.claude/.
#
# Test cases:
#   T1. INVARIANT ASSERTION on a correct layout: home effective is the one
#       real file, home + workdir settings.json are symlinks that resolve to
#       it; assert realpath(workdir)==realpath(home)==home effective. This is
#       the executable invariant that would have caught #1453.
#   T2. Correct single-tree+symlink agent → ZERO findings from BOTH detectors
#       (healthy host = empty list).
#   T3. Drift fixture: workdir settings.json is a SECOND real file →
#       detector (a) fires for that agent and ONLY that agent.
#   T4. Multi-tree fixture: a real settings.effective.json under BOTH trees
#       → detector (b) fires; the agent is ALSO (correctly) a (a) two-tree
#       case because its links resolve to different inodes.
#   T5. No false positives: a half-rendered agent (home only, workdir has no
#       .claude/settings.json yet) and a broken/dangling workdir symlink both
#       yield ZERO findings — the detectors must not flag a not-yet-linked
#       tree (settings are read at launch, so an unlinked workdir is benign).
#   T6. Evidence shape + no traceback: drift finding carries the resolved
#       real paths; multi-tree finding lists the >1 real effective files; the
#       raw output never contains a Python Traceback.
#
# Registry is supplied via `--agent-registry-json` so the fixture does NOT
# depend on bridge-agent.sh registry being runnable in the test scope. JSON
# inspection goes through scripts/smoke/1455-settings-doctor-helper.py
# (file-as-argv) — no heredoc-stdin python3 anywhere (footgun #11).

set -euo pipefail

SMOKE_NAME="1455-settings-two-tree-doctor"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "1455-settings-two-tree-doctor"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

DOCTOR="$REPO_ROOT/bridge-doctor.py"
smoke_assert_file_exists "$DOCTOR" "doctor script present"

HELPER="$SCRIPT_DIR/1455-settings-doctor-helper.py"
smoke_assert_file_exists "$HELPER" "1455 helper present"

# Empty agent-list payload — the settings detectors do not consume the
# agent list, but bridge-doctor.py always loads it. Reuse for every run.
EMPTY_AGENT_LIST="$SMOKE_TMP_ROOT/agent-list.empty.json"
printf '%s\n' '[]' >"$EMPTY_AGENT_LIST"

AGENTS_ROOT="$SMOKE_TMP_ROOT/agents"
REGISTRY="$SMOKE_TMP_ROOT/registry.json"
DOCTOR_OUT="$SMOKE_TMP_ROOT/doctor.out.json"

# ---------------------------------------------------------------------------
# Fixture builders.
# ---------------------------------------------------------------------------

# make_healthy <agent> — single real effective under home; home + workdir
# settings.json are symlinks that resolve to it (the invariant holds).
make_healthy() {
  local agent="$1"
  local home="$AGENTS_ROOT/$agent/home"
  local workdir="$AGENTS_ROOT/$agent/workdir"
  mkdir -p "$home/.claude" "$workdir/.claude"
  printf '{"enabledPlugins":{}}\n' >"$home/.claude/settings.effective.json"
  ln -s "settings.effective.json" "$home/.claude/settings.json"
  ln -s "../../home/.claude/settings.effective.json" "$workdir/.claude/settings.json"
}

# make_drift <agent> — workdir settings.json is a SECOND real file (not a
# symlink) → home + workdir resolve to different inodes.
make_drift() {
  local agent="$1"
  local home="$AGENTS_ROOT/$agent/home"
  local workdir="$AGENTS_ROOT/$agent/workdir"
  mkdir -p "$home/.claude" "$workdir/.claude"
  printf '{"enabledPlugins":{"x":true}}\n' >"$home/.claude/settings.effective.json"
  ln -s "settings.effective.json" "$home/.claude/settings.json"
  # The drift: a real file in the workdir, NOT a symlink to home.
  printf '{"enabledPlugins":{"x":false}}\n' >"$workdir/.claude/settings.json"
}

# make_multi <agent> — a real settings.effective.json under BOTH trees.
make_multi() {
  local agent="$1"
  local home="$AGENTS_ROOT/$agent/home"
  local workdir="$AGENTS_ROOT/$agent/workdir"
  mkdir -p "$home/.claude" "$workdir/.claude"
  printf '{"enabledPlugins":{"x":true}}\n' >"$home/.claude/settings.effective.json"
  printf '{"enabledPlugins":{"x":false}}\n' >"$workdir/.claude/settings.effective.json"
  ln -s "settings.effective.json" "$home/.claude/settings.json"
  ln -s "settings.effective.json" "$workdir/.claude/settings.json"
}

# make_half <agent> — home rendered, workdir has NO .claude/settings.json
# yet (not-yet-linked). Must NOT be flagged.
make_half() {
  local agent="$1"
  local home="$AGENTS_ROOT/$agent/home"
  local workdir="$AGENTS_ROOT/$agent/workdir"
  mkdir -p "$home/.claude" "$workdir"
  printf '{"enabledPlugins":{}}\n' >"$home/.claude/settings.effective.json"
  ln -s "settings.effective.json" "$home/.claude/settings.json"
}

# make_broken <agent> — workdir settings.json is a dangling symlink. Must
# NOT be flagged (no real second file; the link just has no target yet).
make_broken() {
  local agent="$1"
  local home="$AGENTS_ROOT/$agent/home"
  local workdir="$AGENTS_ROOT/$agent/workdir"
  mkdir -p "$home/.claude" "$workdir/.claude"
  printf '{"enabledPlugins":{}}\n' >"$home/.claude/settings.effective.json"
  ln -s "settings.effective.json" "$home/.claude/settings.json"
  ln -s "../../home/.claude/DOES-NOT-EXIST.json" "$workdir/.claude/settings.json"
}

# make_same_tree <agent> — registry home + workdir both reach the SAME
# physical tree: the workdir's `.claude` is a symlink to home's `.claude`.
# There is exactly ONE physical settings.effective.json, reachable via both
# bases, so detector (b) must dedupe by realpath and NOT flag it (codex r1).
make_same_tree() {
  local agent="$1"
  local home="$AGENTS_ROOT/$agent/home"
  local workdir="$AGENTS_ROOT/$agent/workdir"
  mkdir -p "$home/.claude" "$workdir"
  printf '{"enabledPlugins":{}}\n' >"$home/.claude/settings.effective.json"
  ln -s "settings.effective.json" "$home/.claude/settings.json"
  # workdir/.claude IS home/.claude (parent-dir symlink) — both registry
  # bases now resolve to the same physical effective file.
  ln -s "../home/.claude" "$workdir/.claude"
}

# write_registry <agent...> — emit `agent registry --json`-shaped rows with
# the home + workdir columns the settings detectors consume.
write_registry() {
  local first=1 agent
  {
    printf '['
    for agent in "$@"; do
      if (( first )); then first=0; else printf ','; fi
      printf '{"id":"%s","class":"dynamic","home":"%s/%s/home","workdir":"%s/%s/workdir","engine":"claude"}' \
        "$agent" "$AGENTS_ROOT" "$agent" "$AGENTS_ROOT" "$agent"
    done
    printf ']\n'
  } >"$REGISTRY"
}

reset_agents_root() {
  rm -rf "$AGENTS_ROOT"
  mkdir -p "$AGENTS_ROOT"
}

run_doctor() {
  # run_doctor <detectors-csv>
  local detectors="$1"
  "$PY_BIN" "$DOCTOR" --json \
    --detectors "$detectors" \
    --agent-registry-json "$REGISTRY" \
    --agent-list-json "$EMPTY_AGENT_LIST" \
    >"$DOCTOR_OUT" 2>&1
}

h_count() { "$PY_BIN" "$HELPER" count "$DOCTOR_OUT" "$1"; }
h_agents() { "$PY_BIN" "$HELPER" agents "$DOCTOR_OUT" "$1"; }
h_field() { "$PY_BIN" "$HELPER" field "$DOCTOR_OUT" "$1" "$2" "$3"; }
h_traceback() { "$PY_BIN" "$HELPER" has-traceback "$DOCTOR_OUT"; }

# ---------------------------------------------------------------------------
# T1 — executable invariant assertion on a correct layout.
# ---------------------------------------------------------------------------
test_invariant_assertion() {
  reset_agents_root
  make_healthy "okagent"
  local home_link="$AGENTS_ROOT/okagent/home/.claude/settings.json"
  local work_link="$AGENTS_ROOT/okagent/workdir/.claude/settings.json"
  local home_eff="$AGENTS_ROOT/okagent/home/.claude/settings.effective.json"

  local home_real work_real eff_real
  home_real="$("$PY_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$home_link")"
  work_real="$("$PY_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$work_link")"
  eff_real="$("$PY_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$home_eff")"

  smoke_assert_eq "$home_real" "$work_real" \
    "T1 invariant: realpath(workdir settings.json) == realpath(home settings.json)"
  smoke_assert_eq "$eff_real" "$work_real" \
    "T1 invariant: both resolve to the single home effective file"
}

# ---------------------------------------------------------------------------
# T2 — correct single-tree+symlink agent → zero findings.
# ---------------------------------------------------------------------------
test_healthy_zero_findings() {
  reset_agents_root
  make_healthy "okagent"
  write_registry "okagent"
  run_doctor "settings-two-tree-drift,settings-multi-tree"

  smoke_assert_eq "0" "$(h_count settings-two-tree-drift)" \
    "T2 healthy: zero two-tree-drift findings"
  smoke_assert_eq "0" "$(h_count settings-multi-tree)" \
    "T2 healthy: zero multi-tree findings"
}

# ---------------------------------------------------------------------------
# T3 — drift fixture fires detector (a) for that agent only.
# ---------------------------------------------------------------------------
test_drift_fires_two_tree() {
  reset_agents_root
  make_healthy "okagent"
  make_drift "draftee"
  write_registry "okagent" "draftee"
  run_doctor "settings-two-tree-drift"

  smoke_assert_eq "1" "$(h_count settings-two-tree-drift)" \
    "T3 drift: exactly one two-tree-drift finding"
  smoke_assert_eq "draftee" "$(h_agents settings-two-tree-drift)" \
    "T3 drift: only the drifted agent fires"
}

# ---------------------------------------------------------------------------
# T4 — multi-tree fixture fires detector (b) (and is also a (a) case).
# ---------------------------------------------------------------------------
test_multi_fires_multi_tree() {
  reset_agents_root
  make_healthy "okagent"
  make_multi "twins"
  write_registry "okagent" "twins"
  run_doctor "settings-two-tree-drift,settings-multi-tree"

  smoke_assert_eq "1" "$(h_count settings-multi-tree)" \
    "T4 multi: exactly one multi-tree finding"
  smoke_assert_eq "twins" "$(h_agents settings-multi-tree)" \
    "T4 multi: only the two-physical-copy agent fires (b)"
  # A multi-tree agent's links resolve to different inodes, so it is also a
  # legitimate two-tree-drift case — assert that overlap is intentional.
  smoke_assert_eq "twins" "$(h_agents settings-two-tree-drift)" \
    "T4 multi: same agent is also flagged by (a) two-tree-drift"
}

# ---------------------------------------------------------------------------
# T5 — half-rendered + broken-symlink agents are NOT flagged.
# ---------------------------------------------------------------------------
test_no_false_positives() {
  reset_agents_root
  make_healthy "okagent"
  make_half "halfway"
  make_broken "dangling"
  write_registry "okagent" "halfway" "dangling"
  run_doctor "settings-two-tree-drift,settings-multi-tree"

  smoke_assert_eq "0" "$(h_count settings-two-tree-drift)" \
    "T5 no-FP: not-yet-linked / dangling workdir does not trip (a)"
  smoke_assert_eq "0" "$(h_count settings-multi-tree)" \
    "T5 no-FP: not-yet-linked / dangling workdir does not trip (b)"
}

# ---------------------------------------------------------------------------
# T6 — evidence shape + no traceback.
# ---------------------------------------------------------------------------
test_evidence_shape() {
  reset_agents_root
  make_drift "draftee"
  make_multi "twins"
  write_registry "draftee" "twins"
  run_doctor "settings-two-tree-drift,settings-multi-tree"

  local wd_resolves
  wd_resolves="$(h_field settings-two-tree-drift draftee workdir_resolves_to)"
  smoke_assert_contains "$wd_resolves" "draftee/workdir/.claude/settings.json" \
    "T6 (a) evidence.workdir_resolves_to points at the real second file"

  local is_symlink
  is_symlink="$(h_field settings-two-tree-drift draftee workdir_is_symlink)"
  smoke_assert_eq "false" "$is_symlink" \
    "T6 (a) evidence.workdir_is_symlink false (it is a real file)"

  local count
  count="$(h_field settings-multi-tree twins count)"
  smoke_assert_eq "2" "$count" \
    "T6 (b) evidence.count == 2 physical effective files"

  smoke_assert_eq "no" "$(h_traceback)" \
    "T6 doctor output contains no Python traceback"
}

# ---------------------------------------------------------------------------
# T7 — same physical tree reachable via both bases is NOT a multi-tree
# finding (codex r1: dedupe by realpath before counting).
# ---------------------------------------------------------------------------
test_same_tree_no_false_positive() {
  reset_agents_root
  make_same_tree "shared"
  write_registry "shared"
  run_doctor "settings-two-tree-drift,settings-multi-tree"

  smoke_assert_eq "0" "$(h_count settings-multi-tree)" \
    "T7 same-tree: one physical effective file via two bases does not trip (b)"
  # The home settings.json and the workdir settings.json (reached through the
  # .claude parent-dir symlink) resolve to the SAME inode, so (a) is clean too.
  smoke_assert_eq "0" "$(h_count settings-two-tree-drift)" \
    "T7 same-tree: same-inode resolution does not trip (a)"
}

# ---------------------------------------------------------------------------
# Drive cases.
# ---------------------------------------------------------------------------
smoke_run "T1 invariant assertion (correct layout)" test_invariant_assertion
smoke_run "T2 healthy zero findings" test_healthy_zero_findings
smoke_run "T3 drift fires two-tree" test_drift_fires_two_tree
smoke_run "T4 multi-tree fires (b)" test_multi_fires_multi_tree
smoke_run "T5 no false positives" test_no_false_positives
smoke_run "T6 evidence shape + no traceback" test_evidence_shape
smoke_run "T7 same-tree no false positive" test_same_tree_no_false_positive

smoke_log "all 1455 settings single-tree detector cases passed"
