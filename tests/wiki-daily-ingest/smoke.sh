#!/usr/bin/env bash
# wiki-daily-ingest smoke — isolated BRIDGE_HOME proof that the Lane A
# watermark closes the strand-recovery gap from issue #321.
#
# What this asserts:
#
#   1. First-ever run (no watermark) — falls through to the YESTERDAY
#      default, copies notes within the 2-day window, and writes the
#      watermark file containing today's --until date.
#
#   2. Strand recovery — a daily note authored *after* a previous Lane A
#      run, dated within the last 14 days, is picked up by the next run
#      because the persisted watermark is used as --since instead of
#      "yesterday". This is the bug #321 was filed for.
#
#   3. wiki-daily-copy.py idempotency — re-running with overlapping
#      --since/--until does not re-copy an unchanged source. Hash-based
#      skip path stays correct under multi-day windows.
#
#   4. 14-day clamp — a stale watermark older than 14 days does not cause
#      an unbounded backfill. Effective --since is the floor, not the
#      stale watermark. Notes outside the floor are intentionally not
#      recovered (matches the documented contract).
#
#   5. Lane A failure does not advance the watermark — when Lane A reports
#      a non-zero error count the previous watermark stays, so the next
#      run retries the same window.
#
# Lane B (librarian-ingest task creation) full task-create is intentionally
# not exercised — that requires a real $BRIDGE_AGB binary. Scenarios 1-5
# populate only daily notes under memory/, so the find(1) over
# research/projects/shared/decisions returns zero and Lane B is a no-op.
# That matches the watermark scope (Lane A is the watermark consumer).
#
# Scenarios 6 and 7 exercise the Lane B v2-gate added in PR-D r2:
#   6. BRIDGE_LAYOUT unset/legacy → falls through to find-based
#      enumeration over $AGENTS_ROOT/*/memory/research, picks up the
#      research file under the legacy install-root memory path.
#   7. BRIDGE_LAYOUT=v2 + populated `agb agent list --json` (via
#      AGB_MOCK_AGENT_LIST_JSON) → strict enumeration picks up the
#      research file under the v2 workdir's memory tree.
#
# Usage:   ./tests/wiki-daily-ingest/smoke.sh
# Exit 0 if every scenario PASSes; exit 1 otherwise.

set -uo pipefail
# Note: -e (errexit) intentionally NOT set. The PASS/FAIL aggregator below
# needs to continue past individual scenario failures so the summary reports
# every failing case, not just the first. Each scenario uses explicit
# `|| fail ...` predicates, so missed errors cannot escape silently.

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"
INGEST_SH="$REPO_ROOT/scripts/wiki-daily-ingest.sh"
COPY_PY="$REPO_ROOT/scripts/wiki-daily-copy.py"

if [[ ! -x "$INGEST_SH" && ! -r "$INGEST_SH" ]]; then
  printf '[smoke][error] cannot find %s\n' "$INGEST_SH" >&2
  exit 2
fi

PASS=0
FAIL=0
declare -a FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }
banner() { printf '\n=== scenario %s ===\n' "$1"; }

# -----------------------------------------------------------------------------
# isolated BRIDGE_HOME setup
# -----------------------------------------------------------------------------
SMOKE_ROOT="$(mktemp -d -t wiki-daily-ingest-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

BRIDGE_HOME="$SMOKE_ROOT/bridge-home"
BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
BRIDGE_AGENTS_ROOT="$BRIDGE_HOME/agents"
BRIDGE_SHARED_ROOT="$BRIDGE_HOME/shared"
BRIDGE_WIKI_ROOT="$BRIDGE_SHARED_ROOT/wiki"
BRIDGE_SCRIPTS_ROOT="$REPO_ROOT/scripts"
# PR-D made wiki-daily-ingest.sh Lane B strict: it now calls
# `BRIDGE_AGB agent list --json` and refuses malformed JSON. /bin/true
# returns empty stdout which the strict parser rejects, so the smoke
# uses a tiny hermetic mock that returns a valid empty list and
# fails non-zero for unrelated subcommands.
#
# Issue #1042: the mock must live *inside* the fixture BRIDGE_HOME — Lane B's
# same-install guard (lane_b_same_install) refuses to enqueue a librarian
# task when BRIDGE_AGB resolves outside BRIDGE_HOME (so a hermetic repro
# cannot leak fixture-derived tasks into a different install's queue). A
# real install always has its `agent-bridge` CLI under BRIDGE_HOME, so the
# mock is installed at $BRIDGE_HOME/agent-bridge to mirror that layout.
WIKI_WATERMARK_FILE="$BRIDGE_STATE_DIR/wiki/last-ingest.txt"
mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_AGENTS_ROOT" "$BRIDGE_WIKI_ROOT/_audit"
BRIDGE_AGB="$BRIDGE_HOME/agent-bridge"
cp "$REPO_ROOT/tests/wiki-daily-ingest/agb-mock.sh" "$BRIDGE_AGB"
chmod +x "$BRIDGE_AGB" 2>/dev/null || true

export BRIDGE_HOME BRIDGE_STATE_DIR BRIDGE_AGENTS_ROOT \
       BRIDGE_SHARED_ROOT BRIDGE_WIKI_ROOT BRIDGE_SCRIPTS_ROOT BRIDGE_AGB

AGENT="smoke-claude"
AGENT_HOME="$BRIDGE_AGENTS_ROOT/$AGENT"
mkdir -p "$AGENT_HOME/memory"

# Date helper — works on macOS (BSD date) and Linux (GNU date).
days_ago() {
  local n="$1"
  date -v-"${n}"d +%Y-%m-%d 2>/dev/null || date -d "${n} days ago" +%Y-%m-%d
}

TODAY="$(date +%Y-%m-%d)"
D_MINUS_1="$(days_ago 1)"
D_MINUS_2="$(days_ago 2)"
D_MINUS_3="$(days_ago 3)"
D_MINUS_20="$(days_ago 20)"

write_note() {
  local date_str="$1"
  local body="$2"
  printf '%s\n' "$body" >"$AGENT_HOME/memory/$date_str.md"
}

wiki_replica_path() {
  printf '%s\n' "$BRIDGE_WIKI_ROOT/agents/$AGENT/daily/$AGENT-$1.md"
}

reset_runtime() {
  rm -rf "$BRIDGE_WIKI_ROOT/agents" 2>/dev/null || true
  rm -rf "$BRIDGE_WIKI_ROOT/_audit" 2>/dev/null || true
  rm -f "$WIKI_WATERMARK_FILE" 2>/dev/null || true
  rm -rf "$AGENT_HOME/memory" 2>/dev/null || true
  # Issue #582 / #583 Track C: scenarios that seed `$AGENT_HOME/raw/` (raw
  # PreCompact envelopes) must not bleed across into later scenarios — the
  # legacy walk iterates `$AGENTS_ROOT/*` and picks up any leftover envelope.
  # Clean both the raw/ subtree and any stray data-v2/ fixtures the v2
  # scenarios create under SMOKE_ROOT, so each `reset_runtime` returns a
  # genuinely empty AGENT_HOME and a clean v2 root.
  rm -rf "$AGENT_HOME/raw" 2>/dev/null || true
  if [[ -n "${SMOKE_ROOT:-}" && -d "$SMOKE_ROOT/data-v2" ]]; then
    chmod -R u+rwX "$SMOKE_ROOT/data-v2" 2>/dev/null || true
    rm -rf "$SMOKE_ROOT/data-v2" 2>/dev/null || true
  fi
  mkdir -p "$BRIDGE_WIKI_ROOT/_audit" "$AGENT_HOME/memory"
}

read_watermark() {
  [ -f "$WIKI_WATERMARK_FILE" ] || { printf 'absent\n'; return 0; }
  head -n1 "$WIKI_WATERMARK_FILE" | tr -d '[:space:]'
}

# Run wiki-daily-ingest.sh under the isolated BRIDGE_HOME. Captures
# stdout into a per-run file and returns the script's exit code.
run_ingest() {
  local label="$1"
  local out="$SMOKE_ROOT/$label.out"
  local rc=0
  bash "$INGEST_SH" >"$out" 2>>"$SMOKE_ROOT/$label.err" || rc=$?
  printf '%s' "$out"
  return "$rc"
}

# =============================================================================
# Scenario 1 — first-ever run, no watermark, falls through to YESTERDAY default.
# =============================================================================
banner "1 — first-ever run uses YESTERDAY default and writes watermark"
reset_runtime
write_note "$D_MINUS_1" "# $D_MINUS_1 note"
write_note "$TODAY"     "# $TODAY note"

out_file="$(run_ingest s1)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "1" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s1.err" | head -c 200)"
elif ! grep -q "since=$D_MINUS_1" "$out_file"; then
  fail "1" "expected since=$D_MINUS_1 in: $(head -c 200 "$out_file")"
elif [[ ! -f "$(wiki_replica_path "$D_MINUS_1")" ]]; then
  fail "1" "expected replica for $D_MINUS_1 to exist"
elif [[ ! -f "$(wiki_replica_path "$TODAY")" ]]; then
  fail "1" "expected replica for $TODAY to exist"
elif [[ "$(read_watermark)" != "$TODAY" ]]; then
  fail "1" "watermark=$(read_watermark) expected=$TODAY"
else
  pass "1"
fi

# =============================================================================
# Scenario 2 — STRAND RECOVERY (the bug #321 was filed for).
# A note dated D-2 is written *after* the s1 run already completed. The next
# Lane A run must use the persisted watermark (=$TODAY from s1) ... wait —
# the watermark is "today's --until", so re-running on the same calendar day
# produces since=today=until. To exercise strand recovery realistically we
# rewind the watermark to D_MINUS_1 (simulating "yesterday's run finished
# at D-1"), strand a D-2 note, and assert the next run picks up D-2 because
# since=watermark=D-1 reaches back to it (window is [D-1, today], which
# excludes D-2 — that's why the recovery actually requires a watermark from
# a date *prior* to the strand). So we set watermark=D-3 to match the real
# "agent wrote yesterday's note this morning, ingest's previous successful
# run was three days ago" scenario.
# =============================================================================
banner "2 — strand-recovery: watermark older than YESTERDAY catches stranded note"
reset_runtime
# Simulate "previous successful Lane A run completed at D-3" by running
# ingest with no inputs at D-3 first — this is what would have happened
# in production three days ago. The natural-flow run produces a watermark
# of $TODAY (the script's --until is always "today"), so we then backdate
# the watermark file to D-3 to model the calendar gap. This separates
# "did the watermark mechanism work?" (Scenario 1) from "does an existing
# watermark of D-3 actually catch a D-2 strand?" (this scenario).
mkdir -p "$(dirname "$WIKI_WATERMARK_FILE")"
out_file_prelude="$(run_ingest s2-prelude)"   # creates watermark via natural path
[[ -s "$WIKI_WATERMARK_FILE" ]] || fail "2-prelude" "natural-path watermark not written: $(head -c 200 "$out_file_prelude" 2>/dev/null || true)"
# Backdate watermark to model "last successful run was D-3, agent has been
# offline since". Same-calendar-day re-runs cannot otherwise simulate strand
# recovery because the script writes watermark=today on every successful run.
printf '%s\n' "$D_MINUS_3" >"$WIKI_WATERMARK_FILE"
# Strand a D-2 note (within the 14-day clamp window, outside the default
# 2-day rolling window the bug describes).
write_note "$D_MINUS_2" "# $D_MINUS_2 stranded note"
write_note "$TODAY"     "# $TODAY note"

out_file="$(run_ingest s2)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "2" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s2.err" | head -c 200)"
elif ! grep -q "since=$D_MINUS_3" "$out_file"; then
  fail "2" "expected since=$D_MINUS_3 (watermark) in: $(head -c 200 "$out_file")"
elif [[ ! -f "$(wiki_replica_path "$D_MINUS_2")" ]]; then
  fail "2" "stranded $D_MINUS_2 note was NOT recovered (regression of issue #321)"
elif [[ "$(read_watermark)" != "$TODAY" ]]; then
  fail "2" "watermark after recovery=$(read_watermark) expected=$TODAY"
else
  pass "2"
fi

# =============================================================================
# Scenario 3 — wiki-daily-copy.py idempotency under overlapping --since.
# Re-running with the same source bytes must not re-copy.
# =============================================================================
banner "3 — idempotent re-run does not re-copy unchanged sources"
# Don't reset; reuse s2's wiki state. A second call with the same source
# bytes should report unchanged>=1, created=0, replaced=0 for those notes.
copy_json="$SMOKE_ROOT/s3-copy.json"
"$PYTHON" "$COPY_PY" --since "$D_MINUS_3" --until "$TODAY" --json >"$copy_json" 2>"$SMOKE_ROOT/s3.err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "3" "wiki-daily-copy rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s3.err" | head -c 200)"
else
  created="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("created",0))' "$copy_json")"
  replaced="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("replaced",0))' "$copy_json")"
  unchanged="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("unchanged",0))' "$copy_json")"
  if [[ "$created" != "0" || "$replaced" != "0" ]]; then
    fail "3" "idempotency violated: created=$created replaced=$replaced unchanged=$unchanged"
  elif [[ "$unchanged" -lt 1 ]]; then
    fail "3" "expected unchanged>=1 got $unchanged"
  else
    pass "3"
  fi
fi

# =============================================================================
# Scenario 4 — 14-day clamp: stale watermark older than the floor is clamped.
# Notes between [stale-watermark, floor) are intentionally not recovered.
# =============================================================================
banner "4 — stale watermark older than 14 days is clamped to the floor"
reset_runtime
mkdir -p "$(dirname "$WIKI_WATERMARK_FILE")"
# Stale watermark from 20 days ago — outside the default 14-day floor.
printf '%s\n' "$D_MINUS_20" >"$WIKI_WATERMARK_FILE"
FLOOR="$(days_ago 14)"
# A note within the floor (e.g. 3 days ago) must be picked up.
write_note "$D_MINUS_3" "# $D_MINUS_3 within-floor note"
write_note "$TODAY"     "# $TODAY note"

out_file="$(run_ingest s4)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "4" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s4.err" | head -c 200)"
elif ! grep -q "since=$FLOOR" "$out_file"; then
  fail "4" "expected since=$FLOOR (clamped) in: $(head -c 200 "$out_file")"
elif [[ ! -f "$(wiki_replica_path "$D_MINUS_3")" ]]; then
  fail "4" "expected $D_MINUS_3 (within floor) to be copied"
elif [[ "$(read_watermark)" != "$TODAY" ]]; then
  fail "4" "watermark=$(read_watermark) expected=$TODAY"
else
  pass "4"
fi

# =============================================================================
# Scenario 5 — Lane A failure does NOT advance the watermark.
# We force errors=1 by making the wiki target dir non-writable, then assert
# the previous watermark (D_MINUS_3) survives the failed run.
# =============================================================================
banner "5 — Lane A failure leaves the watermark untouched"
reset_runtime
mkdir -p "$(dirname "$WIKI_WATERMARK_FILE")"
printf '%s\n' "$D_MINUS_3" >"$WIKI_WATERMARK_FILE"
write_note "$D_MINUS_2" "# $D_MINUS_2 note"
write_note "$TODAY"     "# $TODAY note"

# Pre-create the per-agent destination dir as a regular file so
# wiki-daily-copy.py's `dest.parent.mkdir(...)` raises an OSError on the
# first copy attempt → errors counter increments → watermark gate fails.
# This is portable across macOS and Linux without needing chmod magic.
dest_parent="$BRIDGE_WIKI_ROOT/agents/$AGENT/daily"
mkdir -p "$BRIDGE_WIKI_ROOT/agents/$AGENT"
: >"$dest_parent"   # collide: a file where a directory should exist

out_file="$(run_ingest s5 || true)"
# Don't fail on rc — Lane A may exit 0 with errors>0 inside the JSON. We
# only care that the watermark is unchanged.
post_watermark="$(read_watermark)"
if [[ "$post_watermark" != "$D_MINUS_3" ]]; then
  fail "5" "watermark advanced on failure: pre=$D_MINUS_3 post=$post_watermark"
else
  # Confirm the run actually produced a non-zero copy_errors / copy_rc; if
  # not, the test assumption is wrong and the assertion above passed
  # vacuously.
  if grep -q "errors=" "$out_file" && ! grep -q "errors=0" "$out_file"; then
    pass "5"
  elif grep -qi "lane a exit code" "$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md" 2>/dev/null; then
    pass "5"
  else
    fail "5" "could not confirm Lane A failure path was exercised; out=$(head -c 200 "$out_file")"
  fi
fi

# Cleanup the deliberate collision so EXIT trap removes things cleanly.
rm -f "$dest_parent" 2>/dev/null || true

# =============================================================================
# Scenario 6 — Lane B legacy fallback enumeration.
# When BRIDGE_LAYOUT is unset/legacy, Lane B must fall through to the
# original $AGENTS_ROOT/*/memory/<sub> find-based enumeration. We populate
# a research/*.md file under the install-root agent path and assert the
# audit log records it. The v2 strict path would never look at install-root
# memory (frozen snapshot under v2), so this case proves the gate.
# =============================================================================
banner "6 — Lane B legacy fallback enumeration via install-root memory"
reset_runtime
unset BRIDGE_LAYOUT 2>/dev/null || true
write_note "$TODAY" "# $TODAY note"

# Drop a fresh research file under the install-root memory path.
mkdir -p "$AGENT_HOME/memory/research"
echo "# probe research note" >"$AGENT_HOME/memory/research/probe.md"
# Ensure the file's mtime is within last-24h (BSD vs GNU touch differ; the
# default mtime is "now" so this is just a belt-and-suspenders).
touch "$AGENT_HOME/memory/research/probe.md"

out_file="$(run_ingest s6 || true)"
audit_file="$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md"
if [[ ! -f "$audit_file" ]]; then
  fail "6" "audit log missing: $audit_file"
elif ! grep -q "research/probe.md" "$audit_file"; then
  fail "6" "legacy fallback did NOT enumerate $AGENT_HOME/memory/research/probe.md; audit body: $(head -c 400 "$audit_file")"
elif ! grep -q "Research files (1)" "$audit_file"; then
  fail "6" "expected 'Research files (1)' in audit; got: $(head -c 400 "$audit_file")"
else
  pass "6"
fi

# =============================================================================
# Scenario 7 — Lane B v2 strict enumeration via populated agent list.
# BRIDGE_LAYOUT=v2 + AGB_MOCK_AGENT_LIST_JSON pointing at a fixture v2
# workdir: the audit log must reference the v2 workdir's memory tree, not
# the install-root path.
# =============================================================================
banner "7 — Lane B v2 strict enumeration uses agb agent list workdir"
reset_runtime
write_note "$TODAY" "# $TODAY note"

# Build a v2-style workdir for the smoke agent and put a research file
# under its memory subtree. The legacy install-root memory must NOT
# contain a matching file in this case so we can prove the v2 path is
# what populated the audit log.
V2_WORKDIR="$SMOKE_ROOT/data-v2/agents/$AGENT/workdir"
mkdir -p "$V2_WORKDIR/memory/research"
echo "# v2 probe research" >"$V2_WORKDIR/memory/research/v2probe.md"
touch "$V2_WORKDIR/memory/research/v2probe.md"

# Mock returns a single active claude agent with workdir pointing at the
# fixture v2 workdir. Use python to emit valid JSON without escaping pain.
AGB_MOCK_AGENT_LIST_JSON="$("$PYTHON" -c "
import json, sys
print(json.dumps([{
    'agent': '$AGENT',
    'engine': 'claude',
    'active': True,
    'workdir': '$V2_WORKDIR',
}]))
")"
export AGB_MOCK_AGENT_LIST_JSON
export BRIDGE_LAYOUT=v2
# PR-F active-contract gate: the script also checks that BRIDGE_DATA_ROOT
# is set and exists. Provide both so the v2 path is taken; without them
# the gate falls back to the legacy enumeration even with LAYOUT=v2.
BRIDGE_DATA_ROOT_FIXTURE="$SMOKE_ROOT/data-v2"
mkdir -p "$BRIDGE_DATA_ROOT_FIXTURE"
export BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT_FIXTURE"

out_file="$(run_ingest s7 || true)"
audit_file="$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md"
if [[ ! -f "$audit_file" ]]; then
  fail "7" "audit log missing: $audit_file"
elif ! grep -q "v2probe.md" "$audit_file"; then
  fail "7" "v2 strict enumeration did NOT pick up $V2_WORKDIR/memory/research/v2probe.md; audit body: $(head -c 400 "$audit_file")"
elif ! grep -q "$V2_WORKDIR" "$audit_file"; then
  fail "7" "audit log path is not the v2 workdir: $(head -c 400 "$audit_file")"
else
  pass "7"
fi

# Restore env for any later scenarios.
unset AGB_MOCK_AGENT_LIST_JSON BRIDGE_LAYOUT BRIDGE_DATA_ROOT 2>/dev/null || true

# =============================================================================
# Scenario 8 — Issue #582: legacy (v1) raw PreCompact envelope enumeration.
# Drop a schema_version=1 JSON envelope under the install-root layout
# `<agent_home>/raw/captures/inbox/`. Lane B in legacy mode (no
# BRIDGE_LAYOUT) must include it in the audit log under the new
# `### Raw envelopes` section, count it as raw=1, and add it to the
# non-daily total. This is the regression test for the loop that PR #585
# added: prior to that PR these envelopes landed on disk and never reached
# the librarian.
# =============================================================================
banner "8 — Lane B legacy raw envelope enumeration counts schema_version=1 JSON"
reset_runtime
unset BRIDGE_LAYOUT 2>/dev/null || true
write_note "$TODAY" "# $TODAY note"

mkdir -p "$AGENT_HOME/raw/captures/inbox"
cat >"$AGENT_HOME/raw/captures/inbox/precompact-v1.json" <<EOF
{
  "schema_version": "1",
  "agent": "$AGENT",
  "captured_at": "${TODAY}T00:00:00Z",
  "session_type": "default",
  "trigger": "manual",
  "source": "pre-compact-hook",
  "custom_instructions_excerpt": "",
  "suggested_entities": ["projects/raw-envelope-v1-smoke"],
  "suggested_concepts": [],
  "suggested_slug": "raw-envelope-v1-smoke",
  "suggested_title": "raw envelope v1 smoke",
  "excerpt": "pre-compact trigger=manual agent=$AGENT v1 smoke",
  "transcript_available": false
}
EOF
touch "$AGENT_HOME/raw/captures/inbox/precompact-v1.json"

out_file="$(run_ingest s8 || true)"
audit_file="$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md"
if [[ ! -f "$audit_file" ]]; then
  fail "8" "audit log missing: $audit_file"
elif ! grep -q "Raw envelopes (1)" "$audit_file"; then
  fail "8" "expected 'Raw envelopes (1)' in audit; got: $(head -c 400 "$audit_file")"
elif ! grep -q "precompact-v1.json" "$audit_file"; then
  fail "8" "raw envelope path missing from audit; got: $(head -c 400 "$audit_file")"
elif ! grep -q "raw=1" "$out_file"; then
  fail "8" "expected raw=1 on stdout summary; got: $(head -c 400 "$out_file")"
else
  pass "8"
fi

# =============================================================================
# Scenario 9 — Issue #582 r2 / Finding 1: v2 workdir raw envelope path.
# After the pre-compact.py fix, BRIDGE_AGENT_WORKDIR is the producer's home,
# and wiki-daily-ingest.sh's v2 enumeration also walks `<workdir>/raw/
# captures/inbox`. We invoke the real producer (`hooks/pre-compact.py`)
# with the env shape v2 runner-side sets — BRIDGE_AGENT_ID, BRIDGE_AGENT_
# WORKDIR set, BRIDGE_AGENT_HOME unset — and assert the envelope lands
# under the v2 workdir's raw inbox, NOT the install-root fallback. Then
# run wiki-daily-ingest.sh with BRIDGE_LAYOUT=v2 and the populated agent
# list and assert the daily audit picks it up from the v2 path.
#
# Codex r2 review noted: the prior r2 version of this scenario seeded the
# v2 envelope by hand which bypassed `_agent_home()` entirely, so the
# test passed even on r1 as long as the v2 enumeration walked the seeded
# directory. Driving the real producer makes the BRIDGE_AGENT_WORKDIR
# fallback the load-bearing assertion: pre-r2, _agent_home() returns the
# install-root candidate (or None) and the v2 inbox stays empty.
# =============================================================================
banner "9 — pre-compact.py routes raw envelope to BRIDGE_AGENT_WORKDIR (v2 fallback)"
reset_runtime
write_note "$TODAY" "# $TODAY note"

V2_WORKDIR="$SMOKE_ROOT/data-v2/agents/$AGENT/workdir"
mkdir -p "$V2_WORKDIR/memory"
mkdir -p "$V2_WORKDIR/raw/captures/inbox"

# Build an isolated BRIDGE_HOME for the hook invocation. The hook needs
# `bridge-memory.py` and `agents/_template/` reachable under BRIDGE_HOME
# (it computes both via _bridge_home()). We symlink rather than copy so
# the smoke stays cheap and stays in sync with the live source tree.
HOOK_BRIDGE_HOME="$SMOKE_ROOT/hook-bridge-home-s9"
mkdir -p "$HOOK_BRIDGE_HOME/agents" "$HOOK_BRIDGE_HOME/hooks"
ln -snf "$REPO_ROOT/bridge-memory.py" "$HOOK_BRIDGE_HOME/bridge-memory.py"
ln -snf "$REPO_ROOT/agents/_template" "$HOOK_BRIDGE_HOME/agents/_template"
ln -snf "$REPO_ROOT/hooks/bridge_hook_common.py" "$HOOK_BRIDGE_HOME/hooks/bridge_hook_common.py"

# Pre-create the install-root fallback agent dir so the pre-r2 (legacy)
# resolver actually returns a Path rather than None — that way "did the
# envelope land under the install-root fallback?" is a real, falsifiable
# assertion. With r1's _agent_home(), the envelope ends up here. With
# r2's _agent_home(), BRIDGE_AGENT_WORKDIR wins and the envelope ends up
# under V2_WORKDIR instead.
INSTALL_FALLBACK_HOME="$HOOK_BRIDGE_HOME/agents/$AGENT"
mkdir -p "$INSTALL_FALLBACK_HOME/raw/captures/inbox"

# Drive hooks/pre-compact.py with v2-runner env: BRIDGE_AGENT_ID set,
# BRIDGE_AGENT_WORKDIR set, BRIDGE_AGENT_HOME explicitly unset. The hook
# reads stdin for the trigger payload and exits 0 regardless of failure,
# so we rely on the on-disk artifact rather than rc to signal success.
echo '{"trigger":"manual","custom_instructions":""}' | \
  env -u BRIDGE_AGENT_HOME \
      BRIDGE_HOME="$HOOK_BRIDGE_HOME" \
      BRIDGE_AGENT_ID="$AGENT" \
      BRIDGE_AGENT_WORKDIR="$V2_WORKDIR" \
      "$PYTHON" "$REPO_ROOT/hooks/pre-compact.py" \
      >"$SMOKE_ROOT/s9-precompact.out" 2>"$SMOKE_ROOT/s9-precompact.err"

# Count envelopes in each location. Post-r2: v2_count=1, install_count=0.
# Pre-r2: v2_count=0, install_count=1 (envelope routed to legacy fallback).
v2_count=$(find "$V2_WORKDIR/raw/captures/inbox" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
install_count=$(find "$INSTALL_FALLBACK_HOME/raw/captures/inbox" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')

if [[ "$v2_count" -ne 1 ]]; then
  fail "9-producer" "expected exactly 1 envelope under V2_WORKDIR/raw/captures/inbox/, got $v2_count (install_count=$install_count). pre-compact stderr: $(tr '\n' ' ' <"$SMOKE_ROOT/s9-precompact.err" | head -c 200)"
elif [[ "$install_count" -ne 0 ]]; then
  fail "9-producer" "envelope leaked into install-root fallback: install_count=$install_count under $INSTALL_FALLBACK_HOME/raw/captures/inbox/ (regression of issue #582 r2 _agent_home fix)"
else
  # Producer-side assertion passed. Now exercise Lane B's v2 strict
  # enumeration end-to-end: BRIDGE_LAYOUT=v2 + AGB_MOCK_AGENT_LIST_JSON
  # pointing at the same V2_WORKDIR. The audit log must reference the v2
  # path of the just-produced envelope.
  AGB_MOCK_AGENT_LIST_JSON="$("$PYTHON" -c "
import json
print(json.dumps([{
    'agent': '$AGENT',
    'engine': 'claude',
    'active': True,
    'workdir': '$V2_WORKDIR',
}]))
")"
  export AGB_MOCK_AGENT_LIST_JSON
  export BRIDGE_LAYOUT=v2
  BRIDGE_DATA_ROOT_FIXTURE="$SMOKE_ROOT/data-v2"
  mkdir -p "$BRIDGE_DATA_ROOT_FIXTURE"
  export BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT_FIXTURE"

  out_file="$(run_ingest s9 || true)"
  audit_file="$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md"
  v2_envelope_path="$(find "$V2_WORKDIR/raw/captures/inbox" -maxdepth 1 -type f -name '*.json' | head -n1)"
  if [[ ! -f "$audit_file" ]]; then
    fail "9" "audit log missing: $audit_file"
  elif ! grep -q "Raw envelopes (1)" "$audit_file"; then
    fail "9" "expected 'Raw envelopes (1)' in audit; got: $(head -c 400 "$audit_file")"
  elif ! grep -qF "$v2_envelope_path" "$audit_file"; then
    fail "9" "audit log does not reference v2 envelope path $v2_envelope_path; got: $(head -c 400 "$audit_file")"
  elif ! grep -q "raw=1" "$out_file"; then
    fail "9" "expected raw=1 on stdout summary; got: $(head -c 400 "$out_file")"
  else
    pass "9"
  fi
fi

unset AGB_MOCK_AGENT_LIST_JSON BRIDGE_LAYOUT BRIDGE_DATA_ROOT 2>/dev/null || true

# =============================================================================
# Scenario 10 — Issue #582 r2 / Finding 2: librarian content-hash dedup.
# Drives `scripts/librarian-process-ingest.py` directly with a fake
# bridge-knowledge that always succeeds. Run twice on the same task body /
# capture file and assert:
#   - first run promotes (status=ok, recorded into promoted-hashes.log)
#   - second run reports status=duplicate (no fresh promote call) and
#     emits a duplicate_count summary line.
# This is the proof for the original PR's idempotency claim, which prior to
# r2 was vacuous because process_one only deduped within one task body.
# =============================================================================
banner "10 — librarian content-hash dedup short-circuits a re-ingest of the same envelope"

LIBRARIAN_PY="$REPO_ROOT/scripts/librarian-process-ingest.py"
S10_DIR="$SMOKE_ROOT/s10"
S10_SHARED="$S10_DIR/shared"
S10_CAPTURE="$S10_DIR/capture-dedup.json"
S10_TASK_BODY="$S10_DIR/task-body.md"
S10_BK_LOG="$S10_DIR/fake-bk.log"
mkdir -p "$S10_DIR" "$S10_SHARED"

# Fake bridge-knowledge.py: prints a minimal promote payload as JSON and
# exits 0 so the canary + real promote both succeed, then the script
# records the content hash. We log every invocation so we can assert how
# many times the second run actually called bridge-knowledge (must be 1:
# only the canary dry-run; the real path is skipped via duplicate).
cat >"$S10_DIR/fake-bk.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
log = os.environ.get("FAKE_BK_LOG", "")
if log:
    with open(log, "a", encoding="utf-8") as f:
        f.write(" ".join(sys.argv) + "\n")
print(json.dumps({"relative_path": "operating-rules/raw-dedup-smoke.md",
                  "related_pages": []}))
PY
chmod +x "$S10_DIR/fake-bk.py"

cat >"$S10_CAPTURE" <<EOF
{
  "schema_version": "1",
  "agent": "$AGENT",
  "captured_at": "${TODAY}T00:00:00Z",
  "session_type": "default",
  "trigger": "manual",
  "source": "pre-compact-hook",
  "custom_instructions_excerpt": "",
  "suggested_entities": ["shared/raw-dedup-smoke"],
  "suggested_concepts": [],
  "suggested_slug": "raw-dedup-smoke",
  "suggested_title": "raw dedup smoke",
  "excerpt": "pre-compact trigger=manual agent=$AGENT dedup smoke",
  "transcript_available": false
}
EOF

cat >"$S10_TASK_BODY" <<EOF
# fake librarian-ingest body for dedup smoke

### Raw envelopes (1)
- $S10_CAPTURE
EOF

run_librarian() {
  local label="$1"
  FAKE_BK_LOG="$S10_BK_LOG" "$PYTHON" "$LIBRARIAN_PY" \
    --task-body "$S10_TASK_BODY" \
    --shared-root "$S10_SHARED" \
    --template-root "$S10_DIR" \
    --team-name "smoke" \
    --bridge-knowledge "$S10_DIR/fake-bk.py" \
    --sleep 0 \
    >"$SMOKE_ROOT/$label.out" 2>"$SMOKE_ROOT/$label.err"
}

: >"$S10_BK_LOG"
run_librarian s10-r1
r1_rc=$?
hashes_log="$S10_SHARED/wiki/_audit/promoted-hashes.log"
# Snapshot bridge-knowledge invocation count after r1. With one capture in
# the batch the librarian invokes promote twice on a fresh run: the
# canary (--dry-run) and the real (non-dry-run) promote. The exact count
# isn't load-bearing here — we only need r2's delta to pin down what the
# second run does.
after_r1_count=$(wc -l <"$S10_BK_LOG" | tr -d ' ')
if [[ "$r1_rc" -ne 0 ]]; then
  fail "10-r1" "librarian first-run rc=$r1_rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s10-r1.err" | head -c 200)"
elif ! grep -q '"status": "ok"' "$SMOKE_ROOT/s10-r1.out"; then
  fail "10-r1" "expected status=ok on first run; got: $(head -c 400 "$SMOKE_ROOT/s10-r1.out")"
elif [[ ! -s "$hashes_log" ]]; then
  fail "10-r1" "promoted-hashes.log was not written under $S10_SHARED/wiki/_audit/"
else
  run_librarian s10-r2
  r2_rc=$?
  after_r2_count=$(wc -l <"$S10_BK_LOG" | tr -d ' ')
  delta=$(( after_r2_count - after_r1_count ))
  # Codex r2 finding 2: assert the dedup contract — the second run must
  # call bridge-knowledge.py exactly once (the canary --dry-run preview
  # that always runs first), and MUST NOT issue a second non-dry-run
  # promote. Reading process_one() post-r2 confirms: dry_run=True calls
  # never consult the marker store, so the canary still flows through;
  # the real-batch call short-circuits on dedup before run_promote().
  # Therefore delta == 1 and that line carries `--dry-run`.
  delta_line="$(diff <(head -n "$after_r1_count" "$S10_BK_LOG") "$S10_BK_LOG" | grep '^>' | sed 's/^> //')"
  if [[ "$r2_rc" -ne 0 ]]; then
    fail "10-r2" "librarian second-run rc=$r2_rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/s10-r2.err" | head -c 200)"
  elif ! grep -q '"status": "duplicate"' "$SMOKE_ROOT/s10-r2.out"; then
    fail "10-r2" "expected status=duplicate on second run; got: $(head -c 400 "$SMOKE_ROOT/s10-r2.out")"
  elif ! grep -q '"duplicate_count": 1' "$SMOKE_ROOT/s10-r2.out"; then
    fail "10-r2" "expected duplicate_count=1 in summary; got: $(head -c 400 "$SMOKE_ROOT/s10-r2.out")"
  elif ! grep -q '"reason": "content-hash-already-promoted"' "$SMOKE_ROOT/s10-r2.out"; then
    fail "10-r2" "duplicate result missing reason marker; got: $(head -c 400 "$SMOKE_ROOT/s10-r2.out")"
  elif [[ "$delta" -ne 1 ]]; then
    fail "10-r2-bk-delta" "expected exactly 1 new bridge-knowledge invocation on r2 (canary dry-run only); got delta=$delta (after_r1=$after_r1_count after_r2=$after_r2_count). New lines: $delta_line"
  elif ! grep -qF -- '--dry-run' <<<"$delta_line"; then
    fail "10-r2-bk-delta" "r2's new bridge-knowledge invocation lacks --dry-run; line: $delta_line"
  elif grep -qE '(^| )promote( |$)' <<<"$delta_line" && ! grep -qF -- '--dry-run' <<<"$delta_line"; then
    fail "10-r2-bk-delta" "r2 issued a non-dry-run promote on a duplicate; line: $delta_line"
  else
    pass "10"
  fi
fi

# =============================================================================
# Scenario 11 — Issue #583 Track C: linux-user-isolated agent is skipped from
# Lane B before any filesystem read AND recorded in the audit log + stdout
# under the stable reason `isolated_private_root_unreadable_by_design`.
#
# We populate a 0700-mode private memory root for an "isolated" agent (the
# operator UID still owns it in this hermetic smoke, but the test asserts
# the SKIP path triggers regardless of whether the operator could actually
# read it — the Track C contract is "don't even try"). The mock returns
# isolation.mode=linux-user for this agent in `agb agent list --json`. The
# audit log must show "Skipped (isolated private root) (1)" with the
# stable reason string and must NOT enumerate the projects file. The
# stdout summary must include `skipped-isolated=1` and the literal reason.
#
# Renumbered from scenario 8 to 11 to avoid colliding with PR #585's
# scenarios 8/9/10 (raw envelope enumeration + dedup) on `main`.
# =============================================================================
banner "11 — Track C: linux-user agent is skipped explicitly with stable reason"
reset_runtime
write_note "$TODAY" "# $TODAY note"

ISO_AGENT="iso-agent"
ISO_WORKDIR="$SMOKE_ROOT/data-v2/agents/$ISO_AGENT/workdir"
mkdir -p "$ISO_WORKDIR/memory/projects"
echo "# would-be-promote" >"$ISO_WORKDIR/memory/projects/foo.md"
touch "$ISO_WORKDIR/memory/projects/foo.md"
chmod 0700 "$ISO_WORKDIR/memory/projects" 2>/dev/null || true
chmod 0700 "$ISO_WORKDIR/memory" 2>/dev/null || true

# Mock returns one active claude agent flagged isolation.mode=linux-user.
AGB_MOCK_AGENT_LIST_JSON="$("$PYTHON" -c "
import json, sys
print(json.dumps([{
    'agent': '$ISO_AGENT',
    'engine': 'claude',
    'active': True,
    'workdir': '$ISO_WORKDIR',
    'isolation': {'mode': 'linux-user'},
}]))
")"
export AGB_MOCK_AGENT_LIST_JSON

export BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT_FIXTURE="$SMOKE_ROOT/data-v2"
mkdir -p "$BRIDGE_DATA_ROOT_FIXTURE"
export BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT_FIXTURE"

# Issue #583 Track C r2: capture every `task create` invocation the mock
# observes during this scenario. The Track C contract requires that NO
# [librarian-ingest] task is created when every active agent is
# linux-user-isolated (Lane B has nothing to enumerate, so the librarian
# call site is short-circuited).
S11_TASK_LOG="$SMOKE_ROOT/s11.task-log"
: >"$S11_TASK_LOG"
export AGB_MOCK_TASK_LOG="$S11_TASK_LOG"

out_file="$(run_ingest s11 || true)"
audit_file="$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md"
err_file="$SMOKE_ROOT/s11.err"
if [[ ! -f "$audit_file" ]]; then
  fail "11" "audit log missing: $audit_file"
elif grep -qiE "permission denied|EACCES" "$err_file" "$out_file"; then
  fail "11" "EACCES leaked into ingest output (stderr or stdout); err=$(head -c 200 "$err_file") out=$(head -c 200 "$out_file")"
elif ! grep -q "Skipped (isolated private root) (1)" "$audit_file"; then
  fail "11" "audit log missing 'Skipped (isolated private root) (1)' header; body: $(head -c 400 "$audit_file")"
elif ! grep -q "$ISO_AGENT — reason: isolated_private_root_unreadable_by_design" "$audit_file"; then
  fail "11" "audit log missing skipped agent + reason line; body: $(head -c 400 "$audit_file")"
elif grep -q "projects/foo.md" "$audit_file"; then
  fail "11" "private root was enumerated despite linux-user isolation; body: $(head -c 400 "$audit_file")"
elif ! grep -q "skipped-isolated=1" "$out_file"; then
  fail "11" "stdout missing skipped-isolated=1 counter; got: $(head -c 200 "$out_file")"
elif ! grep -q "skipped-isolated-reason=isolated_private_root_unreadable_by_design" "$out_file"; then
  fail "11" "stdout missing stable reason literal; got: $(head -c 200 "$out_file")"
elif ! grep -q "skipped-isolated-agents=$ISO_AGENT" "$out_file"; then
  fail "11" "stdout missing isolated agent name; got: $(head -c 200 "$out_file")"
elif grep -q '\[librarian-ingest\]' "$S11_TASK_LOG"; then
  fail "11" "[librarian-ingest] task was created for skipped isolated agent; task-log: $(head -c 200 "$S11_TASK_LOG")"
else
  pass "11"
fi

# Restore mode so the EXIT trap can rm -rf without permission errors.
chmod -R u+rwX "$ISO_WORKDIR" 2>/dev/null || true
unset AGB_MOCK_AGENT_LIST_JSON BRIDGE_LAYOUT BRIDGE_DATA_ROOT AGB_MOCK_TASK_LOG 2>/dev/null || true

# =============================================================================
# Scenario 12 — Issue #583 Track C: non-isolated (shared) agent is unaffected.
# Same shape as scenario 7, but explicitly assert that an agent without
# isolation.mode=linux-user is enumerated as before AND that the audit log's
# Track C section reports zero skips. This proves the filter is gated on the
# isolation field and does not regress the existing path.
#
# Renumbered from scenario 9 to 12 to avoid colliding with PR #585's
# scenarios 8/9/10 on `main`.
# =============================================================================
banner "12 — Track C: shared (non-isolated) agent is enumerated as before"
reset_runtime
write_note "$TODAY" "# $TODAY note"

SHARED_WORKDIR="$SMOKE_ROOT/data-v2/agents/$AGENT/workdir"
mkdir -p "$SHARED_WORKDIR/memory/projects"
echo "# shared probe" >"$SHARED_WORKDIR/memory/projects/bar.md"
touch "$SHARED_WORKDIR/memory/projects/bar.md"

AGB_MOCK_AGENT_LIST_JSON="$("$PYTHON" -c "
import json, sys
print(json.dumps([{
    'agent': '$AGENT',
    'engine': 'claude',
    'active': True,
    'workdir': '$SHARED_WORKDIR',
    'isolation': {'mode': 'shared'},
}]))
")"
export AGB_MOCK_AGENT_LIST_JSON
export BRIDGE_LAYOUT=v2
mkdir -p "$BRIDGE_DATA_ROOT_FIXTURE"
export BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT_FIXTURE"

# Issue #583 Track C r2: companion to scenario 11. The shared-agent
# passthrough must still produce exactly one [librarian-ingest] task — this
# is the regression sentinel that proves the Track C filter does not
# accidentally suppress task creation for non-isolated agents.
#
# Issue #1042: Lane B's librarian gate (lane_b_librarian_enabled) no-ops on a
# dev host profile. Write an explicit `server` host-profile.json so this
# enqueue-asserting scenario exercises the enabled path deterministically —
# independent of whether the agb mock answers `cron list` (it does not, so
# the gate's cron check stays permissive, but the profile is the load-bearing
# signal and is made explicit here).
mkdir -p "$BRIDGE_STATE_DIR/install"
printf '{"profile":"server","set_at":"smoke","set_by":"smoke"}\n' \
  >"$BRIDGE_STATE_DIR/install/host-profile.json"
S12_TASK_LOG="$SMOKE_ROOT/s12.task-log"
: >"$S12_TASK_LOG"
export AGB_MOCK_TASK_LOG="$S12_TASK_LOG"

out_file="$(run_ingest s12 || true)"
audit_file="$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md"
if [[ ! -f "$audit_file" ]]; then
  fail "12" "audit log missing: $audit_file"
elif ! grep -q "projects/bar.md" "$audit_file"; then
  fail "12" "shared agent's projects/bar.md was NOT enumerated; body: $(head -c 400 "$audit_file")"
elif ! grep -q "Skipped (isolated private root) (0)" "$audit_file"; then
  fail "12" "audit log expected 'Skipped (isolated private root) (0)' header; body: $(head -c 400 "$audit_file")"
elif ! grep -q "skipped-isolated=0" "$out_file"; then
  fail "12" "stdout missing skipped-isolated=0 counter; got: $(head -c 200 "$out_file")"
elif ! grep -q "skipped-isolated-agents=none" "$out_file"; then
  fail "12" "stdout expected skipped-isolated-agents=none; got: $(head -c 200 "$out_file")"
elif ! grep -q '\[librarian-ingest\]' "$S12_TASK_LOG"; then
  fail "12" "shared-agent passthrough did NOT create a [librarian-ingest] task; task-log: $(head -c 200 "$S12_TASK_LOG")"
else
  pass "12"
fi

unset AGB_MOCK_AGENT_LIST_JSON BRIDGE_LAYOUT BRIDGE_DATA_ROOT AGB_MOCK_TASK_LOG 2>/dev/null || true

# =============================================================================
# Scenario 13 — Issue #583 Track C r2: legacy-path isolated agent is skipped
# BEFORE any stat into its memory subdir.
#
# This is the Finding-1 load-bearing case. The legacy iteration must:
#   - record the isolated agent under SKIPPED_ISOLATED_AGENTS via deny-list
#   - NOT enumerate $AGENTS_ROOT/<iso>/memory at all
#
# We deliberately give the isolated agent a memory subtree containing a
# research file. With the correct r2 ordering (deny-list BEFORE memory
# `[[ -d ]]`) the file is not enumerated and the agent is recorded as
# skipped. The pre-r2 ordering (memory `[[ -d ]]` first, then deny-list)
# would also avoid enumerating because the deny-list still runs before
# AGENT_MEMORY_ROOTS+=, but the stat into the private memory subdir would
# already have happened — which is exactly the contract violation Finding 1
# called out. To observe the difference *behaviorally* in this hermetic
# smoke, we exercise the case where the isolated agent has NO memory
# subdir: r2 still records the skip via deny-list, while r1 (which gates on
# `[[ -d "$_legacy_dir" ]]` first) silently drops the agent before the
# deny-list runs and reports zero skips.
#
# Renumbered from scenario 10 to 13 to avoid colliding with PR #585's
# scenarios 8/9/10 on `main`.
# =============================================================================
banner "13 — Track C r2: legacy-path isolated agent skip is recorded even without memory/"
reset_runtime
unset BRIDGE_LAYOUT 2>/dev/null || true
write_note "$TODAY" "# $TODAY note"

ISO_LEGACY_AGENT="iso-legacy-agent"
# Create the agent home but intentionally NO memory subdir. Under r2 the
# deny-list short-circuits before the memory `[[ -d ]]` test, so the skip
# is still recorded. Under r1 the missing memory subdir caused the iter
# body to `continue` before the deny-list ran, so the skip went unrecorded.
mkdir -p "$BRIDGE_AGENTS_ROOT/$ISO_LEGACY_AGENT"

# Mock declares this agent linux-user-isolated.
AGB_MOCK_AGENT_LIST_JSON="$("$PYTHON" -c "
import json, sys
print(json.dumps([{
    'agent': '$ISO_LEGACY_AGENT',
    'engine': 'claude',
    'active': True,
    'isolation': {'mode': 'linux-user'},
}]))
")"
export AGB_MOCK_AGENT_LIST_JSON

S13_TASK_LOG="$SMOKE_ROOT/s13.task-log"
: >"$S13_TASK_LOG"
export AGB_MOCK_TASK_LOG="$S13_TASK_LOG"

out_file="$(run_ingest s13 || true)"
audit_file="$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md"
if [[ ! -f "$audit_file" ]]; then
  fail "13" "audit log missing: $audit_file"
elif ! grep -q "Skipped (isolated private root) (1)" "$audit_file"; then
  fail "13" "audit log missing 'Skipped (isolated private root) (1)' for legacy iso agent; body: $(head -c 400 "$audit_file")"
elif ! grep -q "$ISO_LEGACY_AGENT — reason: isolated_private_root_unreadable_by_design" "$audit_file"; then
  fail "13" "audit log missing skipped legacy agent + reason line; body: $(head -c 400 "$audit_file")"
elif ! grep -q "skipped-isolated=1" "$out_file"; then
  fail "13" "stdout missing skipped-isolated=1 for legacy iso agent; got: $(head -c 200 "$out_file")"
elif ! grep -q "skipped-isolated-agents=$ISO_LEGACY_AGENT" "$out_file"; then
  fail "13" "stdout missing legacy isolated agent name; got: $(head -c 200 "$out_file")"
elif grep -q '\[librarian-ingest\]' "$S13_TASK_LOG"; then
  fail "13" "[librarian-ingest] task created for legacy-path isolated agent; task-log: $(head -c 200 "$S13_TASK_LOG")"
else
  pass "13"
fi

unset AGB_MOCK_AGENT_LIST_JSON AGB_MOCK_TASK_LOG 2>/dev/null || true

# =============================================================================
# Scenario 14 — Issue #583 Track C ∩ Issue #582: an isolated agent with a
# raw PreCompact envelope under `<workdir>/raw/captures/inbox/` is skipped
# from BOTH Lane B walks (memory + raw envelope) without an EACCES leak.
#
# This is the load-bearing assertion for the Track C extension to PR #585's
# raw envelope walk. We seed:
#   - a 0700/2750 isolated workdir for an agent flagged
#     `isolation.mode=linux-user` in `agb agent list --json`,
#   - a schema_version=1 raw envelope at
#     `<workdir>/raw/captures/inbox/precompact-isolated.json`.
#
# Track C requires that AGENT_MEMORY_ROOTS exclude this agent before either
# the memory walk or the new raw envelope walk runs. The audit log must
# therefore:
#   - report `Raw envelopes (0)` (the raw inbox is NEVER stat'd),
#   - NOT mention `precompact-isolated.json`,
#   - record `Skipped (isolated private root) (1)` with the stable reason,
#   - mention the isolated agent ONCE (no double-count for memory + raw).
# Stdout: `raw=0`, `skipped-isolated=1`. No EACCES on either stream.
# No `[librarian-ingest]` task is created for the isolated agent.
#
# Pre-extension verification: with the raw-walk loop unguarded by the
# AGENT_MEMORY_ROOTS filter (e.g., walking the install-root or workdir
# directly), the envelope would be enumerated and `Raw envelopes (1)` /
# `raw=1` would appear — making this scenario fail. With the extension in
# place (the raw walk reuses the already-filtered AGENT_MEMORY_ROOTS), the
# envelope is invisible to Lane B.
# =============================================================================
banner "14 — Track C: isolated agent's raw envelope inbox is skipped without EACCES"
reset_runtime
write_note "$TODAY" "# $TODAY note"

ISO_RAW_AGENT="iso-raw-agent"
ISO_RAW_WORKDIR="$SMOKE_ROOT/data-v2/agents/$ISO_RAW_AGENT/workdir"
mkdir -p "$ISO_RAW_WORKDIR/memory/projects"
mkdir -p "$ISO_RAW_WORKDIR/raw/captures/inbox"
echo "# would-be-promote" >"$ISO_RAW_WORKDIR/memory/projects/foo.md"
touch "$ISO_RAW_WORKDIR/memory/projects/foo.md"

# Seed a raw PreCompact envelope under the isolated workdir. If the Track C
# raw-walk skip is missing, this file would be picked up.
cat >"$ISO_RAW_WORKDIR/raw/captures/inbox/precompact-isolated.json" <<EOF
{
  "schema_version": "1",
  "agent": "$ISO_RAW_AGENT",
  "captured_at": "${TODAY}T00:00:00Z",
  "session_type": "default",
  "trigger": "manual",
  "source": "pre-compact-hook",
  "custom_instructions_excerpt": "",
  "suggested_entities": ["projects/iso-raw-smoke"],
  "suggested_concepts": [],
  "suggested_slug": "iso-raw-smoke",
  "suggested_title": "iso raw smoke",
  "excerpt": "pre-compact trigger=manual agent=$ISO_RAW_AGENT iso-raw smoke",
  "transcript_available": false
}
EOF
touch "$ISO_RAW_WORKDIR/raw/captures/inbox/precompact-isolated.json"
# 2750 mirrors the production isolated layout (sgid + group-traverse, owner-
# only read). `chmod 0700` on memory + raw mirrors the per-UID lockdown.
chmod 0700 "$ISO_RAW_WORKDIR/memory" 2>/dev/null || true
chmod 0700 "$ISO_RAW_WORKDIR/raw" 2>/dev/null || true
chmod 0700 "$ISO_RAW_WORKDIR/raw/captures" 2>/dev/null || true
chmod 0700 "$ISO_RAW_WORKDIR/raw/captures/inbox" 2>/dev/null || true

AGB_MOCK_AGENT_LIST_JSON="$("$PYTHON" -c "
import json
print(json.dumps([{
    'agent': '$ISO_RAW_AGENT',
    'engine': 'claude',
    'active': True,
    'workdir': '$ISO_RAW_WORKDIR',
    'isolation': {'mode': 'linux-user'},
}]))
")"
export AGB_MOCK_AGENT_LIST_JSON
export BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT_FIXTURE="$SMOKE_ROOT/data-v2"
mkdir -p "$BRIDGE_DATA_ROOT_FIXTURE"
export BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT_FIXTURE"

S14_TASK_LOG="$SMOKE_ROOT/s14.task-log"
: >"$S14_TASK_LOG"
export AGB_MOCK_TASK_LOG="$S14_TASK_LOG"

out_file="$(run_ingest s14 || true)"
audit_file="$BRIDGE_WIKI_ROOT/_audit/ingest-$TODAY.md"
err_file="$SMOKE_ROOT/s14.err"
if [[ ! -f "$audit_file" ]]; then
  fail "14" "audit log missing: $audit_file"
elif grep -qiE "permission denied|EACCES" "$err_file" "$out_file"; then
  fail "14" "EACCES leaked into ingest output (stderr or stdout); err=$(head -c 200 "$err_file") out=$(head -c 200 "$out_file")"
elif grep -q "precompact-isolated.json" "$audit_file"; then
  fail "14" "isolated agent's raw envelope was enumerated despite linux-user isolation; body: $(head -c 400 "$audit_file")"
elif ! grep -q "Raw envelopes (0)" "$audit_file"; then
  fail "14" "audit log expected 'Raw envelopes (0)' for skipped isolated agent; body: $(head -c 400 "$audit_file")"
elif ! grep -q "Skipped (isolated private root) (1)" "$audit_file"; then
  fail "14" "audit log missing 'Skipped (isolated private root) (1)' header; body: $(head -c 400 "$audit_file")"
elif ! grep -q "$ISO_RAW_AGENT — reason: isolated_private_root_unreadable_by_design" "$audit_file"; then
  fail "14" "audit log missing skipped agent + reason line; body: $(head -c 400 "$audit_file")"
elif ! grep -q "raw=0" "$out_file"; then
  fail "14" "stdout expected raw=0 for skipped isolated agent; got: $(head -c 200 "$out_file")"
elif ! grep -q "skipped-isolated=1" "$out_file"; then
  fail "14" "stdout missing skipped-isolated=1 counter; got: $(head -c 200 "$out_file")"
elif ! grep -q "skipped-isolated-agents=$ISO_RAW_AGENT" "$out_file"; then
  fail "14" "stdout missing isolated agent name; got: $(head -c 200 "$out_file")"
elif grep -q '\[librarian-ingest\]' "$S14_TASK_LOG"; then
  fail "14" "[librarian-ingest] task was created for skipped isolated raw-walk agent; task-log: $(head -c 200 "$S14_TASK_LOG")"
elif [[ "$(grep -c "$ISO_RAW_AGENT — reason:" "$audit_file" || true)" -ne 1 ]]; then
  fail "14" "skipped isolated agent listed more than once in audit log (memory + raw should dedup); body: $(head -c 400 "$audit_file")"
else
  pass "14"
fi

# Restore mode so the EXIT trap can rm -rf without permission errors.
chmod -R u+rwX "$ISO_RAW_WORKDIR" 2>/dev/null || true
unset AGB_MOCK_AGENT_LIST_JSON BRIDGE_LAYOUT BRIDGE_DATA_ROOT AGB_MOCK_TASK_LOG 2>/dev/null || true

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n=== summary ===\n'
printf 'pass=%d fail=%d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'failed: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
