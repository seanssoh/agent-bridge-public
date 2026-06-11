#!/usr/bin/env bash
# scripts/smoke/1801-watchdog-bounded-broken-links.sh — Issue #1801
# regression smoke for the bounded broken-symlink scan.
#
# THE BUG (live-diagnosed, v0.16.9 LTS head, macOS, 2026-06-12):
#   `bridge-watchdog.py: collect_broken_links()` did
#       for path in agent_dir.rglob("*"):
#   with NO entry cap, depth cap, wall-time budget, or directory
#   exclusions. The scan path is registry-anchored to the agent's
#   *workdir*. A monitor-style agent created with `--workdir /Users/<op>`
#   makes the walk traverse the operator's entire home (Library caches,
#   ~/.codex rollout files, ~/.agent-bridge itself, every checkout):
#   measured 3m21s wall (7× the 30s BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS
#   ceiling), exit-124 on every watchdog-due tick for 9+ days, drift
#   report never produced, a 67,932-line report body. The #1563 PR-6
#   pgroup-kill rail prevents the daemon wedge, but the watchdog is
#   effectively disabled and burns ~30s CPU/IO per tick on discarded work.
#
# THE FIX (this smoke pins):
#   collect_broken_links now returns a BrokenLinksResult with an explicit
#   3-state contract surfaced in BOTH the JSON payload and the markdown
#   render — a bound/ambiguity NEVER silently drops data and NEVER
#   escalates a healthy agent for a scanner limitation:
#     (a) complete  → truncated=false, scan_skipped=false, full list.
#     (b) truncated → a bound (entries/depth/time) tripped → truncated=true,
#         partial list + a note naming the bound. Never a silent cap.
#     (c) skipped   → agent_dir resolves to a HOME-scale / fs-root path →
#         scan_skipped=true, empty list + degrade note, agent NOT escalated.
#   The walk is bounded on every axis (os.walk in-place dir pruning over
#   BROKEN_LINKS_EXCLUDE_DIRS, max-depth, max-entries, wall-time budget),
#   and the markdown render caps the per-agent broken_links list.
#
# Assertions (teeth-carrying):
#   T1 — COMPLETE + EXCLUSIONS: a bounded workdir with genuine broken
#        symlinks near the top AND a heavy EXCLUDE dir (.cache) full of
#        broken symlinks classifies the genuine links and does NOT report
#        the excluded dir's links; truncated=false, scan_skipped=false.
#   T2 — TRUNCATED (entries): a workdir with >max-entries broken symlinks
#        (max-entries forced low via the env knob) sets truncated=true and
#        the partial list is non-empty (no silent cap). status stays warn
#        (real drift, not a crash).
#   T3 — TRUNCATED (depth): a deep tree past max-depth (forced low) sets
#        truncated=true and does NOT descend below the cap (a broken
#        symlink planted below the cap is absent).
#   T4 — SKIPPED (HOME-scale): a workdir whose realpath == $HOME sets
#        scan_skipped=true, broken_links empty, agent NOT escalated
#        (status is ok / not driven to warn/error by the scanner degrade),
#        and the markdown render carries the skip note.
#   T5 — REPORT CAP: the markdown render of a many-broken-link workdir
#        lists at most BROKEN_LINKS_REPORT_CAP entries + a "(N more …)"
#        summary line — never the full 10k+ rows.
#
# Isolated: everything runs under smoke_setup_bridge_home (mktemp); no live
# bridge state touched. Footgun #11: pipe/argv stdin only — no heredoc-stdin
# to a subprocess capture; python assertions are extracted to a helper.

set -uo pipefail

SMOKE_NAME="1801-watchdog-bounded-broken-links"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

HELPER="$SCRIPT_DIR/1801-helpers/assert-bounded-scan.py"
if [[ ! -r "$HELPER" ]]; then
  smoke_fail "required helper not found: $HELPER"
fi

# Seed a v2 agent: tracked-tree dir under $BRIDGE_AGENT_HOME_ROOT/<a> (so
# the registry-anchored enumerator picks it up) + a runtime workdir under
# $BRIDGE_DATA_ROOT/agents/<a>/workdir that the registry `workdir` field
# redirects the scan to. The workdir carries a well-formed Claude profile
# so the only drift signal is the broken-link channel under test.
seed_profile() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
  : >"$dir/SOUL.md"
  : >"$dir/MEMORY-SCHEMA.md"
  : >"$dir/MEMORY.md"
  cat >"$dir/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF
}

# ---------------------------------------------------------------------------
# T1 — complete scan + exclusions
# ---------------------------------------------------------------------------
A1="mon-complete"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$A1"
WD1="$BRIDGE_DATA_ROOT/agents/$A1/workdir"
seed_profile "$WD1"
ln -s /nonexistent/genuine1 "$WD1/broken-top"
mkdir -p "$WD1/sub"
ln -s /nonexistent/genuine2 "$WD1/sub/broken-sub"
# heavy EXCLUDE dir full of broken symlinks — must NOT be reported
mkdir -p "$WD1/.cache/codex-runtimes"
for i in $(seq 1 30); do
  ln -s "/var/folders/zz/stale-$i" "$WD1/.cache/codex-runtimes/stale-$i"
done

REG1="$SMOKE_TMP_ROOT/reg-$A1.json"
cat >"$REG1" <<EOF
[{"id":"$A1","class":"static","agent_source":"static","engine":"claude","workdir":"$WD1"}]
EOF

OUT1="$("$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REG1" 2>"$SMOKE_TMP_ROOT/t1.err")"
"$PY_BIN" "$HELPER" t1 "$OUT1" "$A1" \
  || smoke_fail "T1 failed: complete-scan / exclusion contract regressed (see $SMOKE_TMP_ROOT/t1.err)"
smoke_log "T1 PASS: complete scan reports genuine links, excludes .cache, truncated=false skipped=false"

# ---------------------------------------------------------------------------
# T2 — truncated by max-entries (forced low via env knob)
# ---------------------------------------------------------------------------
A2="mon-entries"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$A2"
WD2="$BRIDGE_DATA_ROOT/agents/$A2/workdir"
seed_profile "$WD2"
mkdir -p "$WD2/many"
for i in $(seq 1 60); do
  ln -s "/nonexistent/e-$i" "$WD2/many/broken-$i"
done

REG2="$SMOKE_TMP_ROOT/reg-$A2.json"
cat >"$REG2" <<EOF
[{"id":"$A2","class":"static","agent_source":"static","engine":"claude","workdir":"$WD2"}]
EOF

OUT2="$(BRIDGE_WATCHDOG_BROKEN_LINKS_MAX_ENTRIES=10 \
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REG2" 2>"$SMOKE_TMP_ROOT/t2.err")"
"$PY_BIN" "$HELPER" t2 "$OUT2" "$A2" \
  || smoke_fail "T2 failed: max-entries truncation contract regressed (see $SMOKE_TMP_ROOT/t2.err)"
smoke_log "T2 PASS: max-entries bound sets truncated=true, partial list non-empty (no silent cap), status warn"

# ---------------------------------------------------------------------------
# T3 — truncated by max-depth (forced low; deep planted link not reported)
# ---------------------------------------------------------------------------
A3="mon-depth"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$A3"
WD3="$BRIDGE_DATA_ROOT/agents/$A3/workdir"
seed_profile "$WD3"
DEEP="$WD3/d1/d2/d3/d4/d5"
mkdir -p "$DEEP"
ln -s /nonexistent/too-deep "$DEEP/broken-deep"   # below max-depth=2 → absent
ln -s /nonexistent/shallow "$WD3/broken-shallow"  # at top → present

REG3="$SMOKE_TMP_ROOT/reg-$A3.json"
cat >"$REG3" <<EOF
[{"id":"$A3","class":"static","agent_source":"static","engine":"claude","workdir":"$WD3"}]
EOF

OUT3="$(BRIDGE_WATCHDOG_BROKEN_LINKS_MAX_DEPTH=2 \
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REG3" 2>"$SMOKE_TMP_ROOT/t3.err")"
"$PY_BIN" "$HELPER" t3 "$OUT3" "$A3" \
  || smoke_fail "T3 failed: max-depth truncation contract regressed (see $SMOKE_TMP_ROOT/t3.err)"
smoke_log "T3 PASS: max-depth bound sets truncated=true, does not descend past cap (deep link absent, shallow present)"

# ---------------------------------------------------------------------------
# T4 — skipped: HOME-scale workdir (realpath == $HOME)
# ---------------------------------------------------------------------------
# Point the agent's workdir at a temp HOME (its realpath equals Path.home())
# so the HOME-scale guard trips. Seed a profile + a broken symlink there to
# prove the scan is SKIPPED (not just empty-by-accident) and the agent is
# NOT escalated for the scanner degrade.
FAKE_HOME="$SMOKE_TMP_ROOT/fakehome"
seed_profile "$FAKE_HOME"
ln -s /nonexistent/should-not-be-scanned "$FAKE_HOME/broken-in-home"

A4="mon-home"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$A4"
REG4="$SMOKE_TMP_ROOT/reg-$A4.json"
cat >"$REG4" <<EOF
[{"id":"$A4","class":"dynamic","agent_source":"dynamic","engine":"claude","workdir":"$FAKE_HOME"}]
EOF

# Drive HOME to the fixture dir so Path.home() == realpath(workdir).
OUT4="$(HOME="$FAKE_HOME" \
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REG4" 2>"$SMOKE_TMP_ROOT/t4.err")"
"$PY_BIN" "$HELPER" t4 "$OUT4" "$A4" \
  || smoke_fail "T4 failed: HOME-scale skip/degrade contract regressed (see $SMOKE_TMP_ROOT/t4.err)"
smoke_log "T4 PASS: HOME-scale workdir sets scan_skipped=true, links empty, agent NOT escalated"

# Markdown render must carry the skip note (degrade is never silent).
MD4="$(HOME="$FAKE_HOME" \
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan \
  --agent-registry-json "$REG4" 2>>"$SMOKE_TMP_ROOT/t4.err")"
smoke_assert_contains "$MD4" "broken_links_scan_skipped: yes" \
  "T4 markdown render must surface the scan-skipped degrade note"
smoke_log "T4 PASS: markdown render surfaces broken_links_scan_skipped note"

# ---------------------------------------------------------------------------
# T5 — report-body cap (many broken links → capped markdown + summary)
# ---------------------------------------------------------------------------
A5="mon-cap"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$A5"
WD5="$BRIDGE_DATA_ROOT/agents/$A5/workdir"
seed_profile "$WD5"
mkdir -p "$WD5/links"
for i in $(seq 1 80); do
  ln -s "/nonexistent/cap-$i" "$WD5/links/broken-$i"
done

REG5="$SMOKE_TMP_ROOT/reg-$A5.json"
cat >"$REG5" <<EOF
[{"id":"$A5","class":"static","agent_source":"static","engine":"claude","workdir":"$WD5"}]
EOF

MD5="$("$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan \
  --agent-registry-json "$REG5" 2>"$SMOKE_TMP_ROOT/t5.err")"
# The render lists at most BROKEN_LINKS_REPORT_CAP (50) entries + a summary.
# 80 broken links must produce the "...(N more — truncated for report" line.
smoke_assert_contains "$MD5" "more — truncated for report" \
  "T5 markdown render must cap the per-agent broken_links list with a (N more …) summary"
# Count the rendered "  - ...broken-" link lines for agent A5's block — must
# not be all 80. The cap line is the proof; a hard count guard backstops it.
RENDERED="$(printf '%s\n' "$MD5" | grep -c -- '-> /nonexistent/cap-' || true)"
if [[ "$RENDERED" -gt 50 ]]; then
  smoke_fail "T5 failed: markdown rendered $RENDERED link rows (> cap 50) — report body not capped"
fi
smoke_log "T5 PASS: markdown render caps broken_links list at $RENDERED rows (≤ 50) + (N more …) summary"

# ---------------------------------------------------------------------------
# T6 — #1801 r2: exclude .claude/worktrees from the walk
# ---------------------------------------------------------------------------
# THE r2 BUG (live follow-up #12626): the dominant cost was `.claude/worktrees/`
# — agent-isolation worktrees, each a FULL repo checkout (401k+ entries),
# multiplied by N agents. Without pruning that tree the bounded walk burns its
# whole max-entries / wall-time budget INSIDE the worktree checkouts, sets
# truncated=true, and MISSES the genuine top-level broken links it should
# report (truncation hiding real drift). This is a CORRECTNESS fix.
#
# Fixture: a bounded workdir with ONE genuine top-level broken link plus a
# populated `.claude/worktrees/wt-a/` full of broken symlinks. We force
# max-entries LOW so that WITHOUT the exclusion the worktree volume would trip
# truncated and the genuine top-level link would be lost. WITH the exclusion
# the worktree is pruned, the top-level link is found, and truncated stays
# false.
A6="mon-worktrees"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$A6"
WD6="$BRIDGE_DATA_ROOT/agents/$A6/workdir"
seed_profile "$WD6"
ln -s /nonexistent/genuine-top "$WD6/genuine-top"   # genuine, top-level → MUST report
# Populate .claude/worktrees/wt-a/ with many broken symlinks (the heavy tree
# that must NOT be walked). 200 entries >> the forced max-entries=20 below, so
# without the exclusion the budget is exhausted before the genuine link is
# even reached (the genuine link sorts AFTER `.claude` in os.walk order at the
# top level, so a budget burned in .claude/worktrees would miss it).
WT6="$WD6/.claude/worktrees/wt-a"
mkdir -p "$WT6"
for i in $(seq 1 200); do
  ln -s "/nonexistent/wt-broken-$i" "$WT6/wt-broken-$i"
done
# Before/after entry-count proof: count what the walk WOULD see with vs
# without the worktrees prune (deterministic filesystem count, independent of
# the scanner). With the prune, .claude/worktrees is never descended.
WT_ENTRY_COUNT="$(find "$WT6" -mindepth 1 | wc -l | tr -d ' ')"
smoke_log "T6 fixture: .claude/worktrees/wt-a holds $WT_ENTRY_COUNT entries (must be skipped); 1 genuine top-level link"

REG6="$SMOKE_TMP_ROOT/reg-$A6.json"
cat >"$REG6" <<EOF
[{"id":"$A6","class":"static","agent_source":"static","engine":"claude","workdir":"$WD6"}]
EOF

# Force max-entries low: WITHOUT the exclusion, the 200-entry worktree tree
# would trip truncated and miss the genuine link. WITH it, the prune keeps the
# walk tiny so the genuine link is found and truncated stays false.
OUT6="$(BRIDGE_WATCHDOG_BROKEN_LINKS_MAX_ENTRIES=20 \
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REG6" 2>"$SMOKE_TMP_ROOT/t6.err")"
"$PY_BIN" "$HELPER" t6 "$OUT6" "$A6" \
  || smoke_fail "T6 failed: .claude/worktrees exclusion contract regressed (see $SMOKE_TMP_ROOT/t6.err)"
smoke_log "T6 PASS: .claude/worktrees ($WT_ENTRY_COUNT entries) pruned, genuine top-level link reported, truncated=false"

# ---------------------------------------------------------------------------
# T7 — #1801 r2: within-pass dedupe of a shared workdir
# ---------------------------------------------------------------------------
# Two agents registered against the SAME workdir (same realpath). The scan
# loops agents and calls the scanner once per agent → that tree was walked
# once PER agent. The dedupe walks it once per pass, keyed by realpath, and
# annotates the second agent's row with a `shared workdir, scanned via <first>`
# note while keeping BOTH rows truthful (same broken_links, same 3-state).
A7A="mon-shareA"
A7B="mon-shareB"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$A7A" "$BRIDGE_AGENT_HOME_ROOT/$A7B"
SHARED_WD="$BRIDGE_DATA_ROOT/agents/$A7A/workdir"
seed_profile "$SHARED_WD"
ln -s /nonexistent/shared-broken "$SHARED_WD/shared-broken"   # genuine, both rows must report

REG7="$SMOKE_TMP_ROOT/reg-share.json"
cat >"$REG7" <<EOF
[{"id":"$A7A","class":"static","agent_source":"static","engine":"claude","workdir":"$SHARED_WD"},
 {"id":"$A7B","class":"static","agent_source":"static","engine":"claude","workdir":"$SHARED_WD"}]
EOF

# Enable the dedupe instrumentation so we can PROVE the walk fired exactly
# once across the two agents (1 MISS = walked, 1 HIT = reused).
OUT7="$(BRIDGE_WATCHDOG_DEBUG_DEDUPE=1 \
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REG7" 2>"$SMOKE_TMP_ROOT/t7.err")"
"$PY_BIN" "$HELPER" t7 "$OUT7" "$A7A,$A7B" \
  || smoke_fail "T7 failed: shared-workdir dedupe contract regressed (see $SMOKE_TMP_ROOT/t7.err)"

# Instrumentation proof: exactly one MISS (the walk) + one HIT (the reuse).
DEDUPE_MISS="$(grep -c 'dedupe MISS (walked)' "$SMOKE_TMP_ROOT/t7.err" || true)"
DEDUPE_HIT="$(grep -c 'dedupe HIT' "$SMOKE_TMP_ROOT/t7.err" || true)"
if [[ "$DEDUPE_MISS" -ne 1 || "$DEDUPE_HIT" -ne 1 ]]; then
  smoke_fail "T7 failed: shared workdir must be walked exactly once (1 MISS + 1 HIT); got MISS=$DEDUPE_MISS HIT=$DEDUPE_HIT (see $SMOKE_TMP_ROOT/t7.err)"
fi
smoke_log "T7 PASS: shared workdir walked once (MISS=$DEDUPE_MISS, HIT=$DEDUPE_HIT), both rows present + correct"

# ---------------------------------------------------------------------------
# T8 — #1801 review r3: a mount-ROOT workdir is HOME-scale (degrade), not walked
# ---------------------------------------------------------------------------
# THE r3 BUG (queue gate): _is_home_scale_workdir only caught `/` via
# `parent == self`; real mount points (/dev, /System/Volumes/*, an external
# volume, /Users/<op>/OrbStack) have a normal-directory parent and slipped
# through, so a monitor agent whose workdir is a mount root would still
# deep-walk the whole mount — the same scan-ceiling class outside literal
# $HOME and `/`. The fix adds an os.path.ismount() leg. This unit check
# monkeypatches ismount and asserts: mount ROOT -> skip, mount SUBDIR -> walk.
"$PY_BIN" "$SCRIPT_DIR/1801-helpers/assert-mount-skip.py" "$REPO_ROOT/bridge-watchdog.py" \
  || smoke_fail "T8 failed: mount-root HOME-scale guard regressed (ismount leg missing)"
smoke_log "T8 PASS: mount-root workdir sets scan_skipped (ismount leg), mount subdir still walked"

smoke_log "all 8 tests PASS (#1801 bounded broken-links scan + r2 worktrees-exclusion + shared-workdir dedupe + r3 mount-root guard)"
