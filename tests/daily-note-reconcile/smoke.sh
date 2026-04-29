#!/usr/bin/env bash
# daily-note-reconcile smoke — covers the 8 acceptance cases from the
# issue #390 PR-1 brief plus the 7 r2 codex-review cases.
#
#   1  empty jsonl → no daily note created (or empty manifest)
#   2  single-turn jsonl → daily note created with 1 turn + manifest entry
#   3  re-run with same jsonl → no change (idempotency)
#   4  re-run after appending a new turn → 2 turns + 2 manifest entries
#   5  --dry-run returns diff without writing
#   6  malformed jsonl line → script tolerates (skips), continues
#   7  long turn truncation → respects 2000 head + 500 tail
#   8  --date filter → only that day's turns extracted
#  --- r2 (codex r1 review) -----------------------------------------
#   9  manifest recovery: corrupted manifest + non-empty body → no dup
#  10  concurrent reconciles (flock) → both inputs land in the note
#  11  malformed meta lines → quarantine block at bottom, body intact
#  12  input batch dedupe → identical fingerprints collapse to 1 entry
#  13  path traversal: --agent ../../etc → non-zero exit
#       and --memory-dir /etc/passwd → non-zero exit
#  14  defensive type guards: non-string role → skipped, no crash
#  15  --json + --dry-run → stdout is parseable JSON only
#
# Usage:   bash tests/daily-note-reconcile/smoke.sh
# Exit 0 if all 15 cases PASS, 1 otherwise.

set -u

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/daily-note-reconcile.py"
FIXTURE="$REPO_ROOT/tests/daily-note-reconcile/fixtures/sample.jsonl"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }
banner() { printf '\n=== case %s — %s ===\n' "$1" "$2"; }

SMOKE_ROOT="$(mktemp -d -t daily-note-reconcile.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

# r2 — Item 6 path-traversal sanitisation requires --memory-dir to live
# under BRIDGE_HOME. Anchor the smoke's BRIDGE_HOME at SMOKE_ROOT so the
# operator-override path stays inside the allowed root.
export BRIDGE_HOME="$SMOKE_ROOT"

AGENT="smoke-agent"
MEMDIR="$SMOKE_ROOT/memory"
mkdir -p "$MEMDIR"

# ---------- case 1: empty jsonl ----------
banner 1 "empty jsonl → noop"
EMPTY_JSONL="$SMOKE_ROOT/empty.jsonl"
: > "$EMPTY_JSONL"
out_json="$("$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$EMPTY_JSONL" \
    --date 2026-04-01 --memory-dir "$MEMDIR" --json 2>/dev/null)"
rc=$?
if [[ $rc -ne 0 ]]; then
  fail 1 "non-zero rc=$rc"
elif ! printf '%s' "$out_json" | "$PYTHON" -c '
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get("turns_new") == 0 and d.get("applied") == "noop" else 1)
'; then
  fail 1 "expected noop+turns_new=0 in JSON: $out_json"
elif [[ -e "$MEMDIR/2026-04-01.md" ]]; then
  fail 1 "daily note created from empty jsonl"
else
  pass 1
fi

# ---------- case 2: single-turn jsonl ----------
banner 2 "single-turn jsonl → 1 turn + manifest"
SINGLE="$SMOKE_ROOT/single.jsonl"
cat > "$SINGLE" <<'EOF'
{"type":"user","sessionId":"sess-A","timestamp":"2026-04-02T10:00:00.000Z","message":{"role":"user","content":"hello world"}}
EOF
out_json="$("$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$SINGLE" \
    --date 2026-04-02 --memory-dir "$MEMDIR" --json)"
rc=$?
note="$MEMDIR/2026-04-02.md"
if [[ $rc -ne 0 ]]; then
  fail 2 "non-zero rc=$rc"
elif [[ ! -f "$note" ]]; then
  fail 2 "daily note not created at $note"
elif ! grep -q "## Session sess-A — reconcile" "$note"; then
  fail 2 "section header missing"
elif ! grep -q "hello world" "$note"; then
  fail 2 "turn text missing"
elif ! head -1 "$note" | grep -q "bridge-daily-meta:"; then
  fail 2 "meta block missing on line 1"
elif ! "$PYTHON" -c '
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<!-- bridge-daily-meta: (\{.*\}) -->", text)
meta = json.loads(m.group(1))
fps = meta.get("reconciled_fingerprints", {}).get("sess-A", [])
sys.exit(0 if len(fps) == 1 else 1)
' "$note"; then
  fail 2 "manifest does not have exactly 1 fingerprint"
else
  pass 2
fi

# ---------- case 3: re-run same jsonl → idempotent ----------
banner 3 "re-run same jsonl → byte-identical (modulo last_reconciled_at)"
before_hash="$("$PYTHON" -c '
import re, sys, hashlib
t = open(sys.argv[1], encoding="utf-8").read()
# strip last_reconciled_at — that field is allowed to update
t = re.sub(r"\"last_reconciled_at\":\s*\"[^\"]+\"", "\"last_reconciled_at\":\"X\"", t)
print(hashlib.sha256(t.encode("utf-8")).hexdigest())
' "$note")"
out_json2="$("$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$SINGLE" \
    --date 2026-04-02 --memory-dir "$MEMDIR" --json)"
after_hash="$("$PYTHON" -c '
import re, sys, hashlib
t = open(sys.argv[1], encoding="utf-8").read()
t = re.sub(r"\"last_reconciled_at\":\s*\"[^\"]+\"", "\"last_reconciled_at\":\"X\"", t)
print(hashlib.sha256(t.encode("utf-8")).hexdigest())
' "$note")"
applied2="$(printf '%s' "$out_json2" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["applied"])')"
if [[ "$before_hash" != "$after_hash" ]]; then
  fail 3 "content-hash changed on idempotent re-run"
elif [[ "$applied2" != "noop" ]]; then
  fail 3 "applied should be noop on re-run, got $applied2"
else
  pass 3
fi

# ---------- case 4: append new turn → 2 turns ----------
banner 4 "append new turn → 2 turns + 2 manifest entries"
cat >> "$SINGLE" <<'EOF'
{"type":"assistant","sessionId":"sess-A","timestamp":"2026-04-02T10:30:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"second turn arrived"}]}}
EOF
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$SINGLE" \
    --date 2026-04-02 --memory-dir "$MEMDIR" --json > "$SMOKE_ROOT/out4.json"
rc=$?
turn_blocks="$(grep -c '^### turn ' "$note" || true)"
fp_count="$("$PYTHON" -c '
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<!-- bridge-daily-meta: (\{.*\}) -->", text)
meta = json.loads(m.group(1))
print(len(meta.get("reconciled_fingerprints", {}).get("sess-A", [])))
' "$note")"
if [[ $rc -ne 0 ]]; then
  fail 4 "non-zero rc=$rc"
elif [[ "$turn_blocks" != "2" ]]; then
  fail 4 "expected 2 turn blocks, got $turn_blocks"
elif [[ "$fp_count" != "2" ]]; then
  fail 4 "expected 2 manifest fingerprints, got $fp_count"
elif ! grep -q "second turn arrived" "$note"; then
  fail 4 "second turn text missing"
else
  pass 4
fi

# ---------- case 5: --dry-run shows diff, no write ----------
banner 5 "--dry-run shows diff and does not write"
DRY_JSONL="$SMOKE_ROOT/dry.jsonl"
cat > "$DRY_JSONL" <<'EOF'
{"type":"user","sessionId":"sess-DRY","timestamp":"2026-04-03T09:00:00.000Z","message":{"role":"user","content":"dry-run probe"}}
EOF
dry_note="$MEMDIR/2026-04-03.md"
[[ -e "$dry_note" ]] && rm "$dry_note"
diff_out="$("$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$DRY_JSONL" \
    --date 2026-04-03 --memory-dir "$MEMDIR" --dry-run 2>/dev/null)"
rc=$?
if [[ $rc -ne 0 ]]; then
  fail 5 "dry-run rc=$rc"
elif [[ -e "$dry_note" ]]; then
  fail 5 "dry-run created note file"
elif ! printf '%s' "$diff_out" | grep -q "dry-run probe"; then
  fail 5 "dry-run output missing turn text"
else
  pass 5
fi

# ---------- case 6: malformed jsonl line ----------
banner 6 "malformed line tolerated (uses fixture sample.jsonl)"
fix_note="$MEMDIR/2026-04-01.md"
[[ -e "$fix_note" ]] && rm "$fix_note"
out_json6="$("$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$FIXTURE" \
    --date 2026-04-01 --memory-dir "$MEMDIR" --json --verbose 2>"$SMOKE_ROOT/err6.log")"
rc=$?
turns_new6="$(printf '%s' "$out_json6" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["turns_new"])')"
if [[ $rc -ne 0 ]]; then
  fail 6 "rc=$rc with malformed line in fixture"
elif [[ ! -f "$fix_note" ]]; then
  fail 6 "daily note not created"
elif ! grep -q "Phase 0 부터 시작" "$fix_note"; then
  fail 6 "expected real assistant text missing"
elif grep -q "hidden chain of thought" "$fix_note"; then
  fail 6 "thinking block leaked into daily note"
elif grep -q "scaffolding wrapper" "$fix_note"; then
  fail 6 "system-reminder scaffolding leaked"
elif grep -q "tool_result" "$fix_note"; then
  fail 6 "tool_result leaked"
elif grep -q "어제 메시지" "$fix_note"; then
  fail 6 "out-of-date turn leaked into 2026-04-01 note"
elif [[ "$turns_new6" -lt 2 ]]; then
  fail 6 "expected at least 2 new turns, got $turns_new6"
else
  pass 6
fi

# ---------- case 7: long turn truncation ----------
banner 7 "long turn truncated to 2000 head + 500 tail"
LONG_JSONL="$SMOKE_ROOT/long.jsonl"
"$PYTHON" - "$LONG_JSONL" <<'PY'
import json, sys
path = sys.argv[1]
big = "A" * 2000 + "M" * 5000 + "Z" * 500
rec = {
    "type": "user",
    "sessionId": "sess-LONG",
    "timestamp": "2026-04-04T05:00:00.000Z",
    "message": {"role": "user", "content": big},
}
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
long_note="$MEMDIR/2026-04-04.md"
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$LONG_JSONL" \
    --date 2026-04-04 --memory-dir "$MEMDIR" >/dev/null
if ! grep -q "truncated, see jsonl" "$long_note"; then
  fail 7 "truncation marker missing"
elif grep -q "MMMMMMMMMMMMMMMMMMMM" "$long_note"; then
  # The middle "M" run should NOT survive truncation — head is "A...A",
  # tail is "Z...Z", marker in between.
  fail 7 "middle of long turn was not truncated"
else
  pass 7
fi

# ---------- case 8: --date filter ----------
banner 8 "--date filter selects only target day"
filt_note_1="$MEMDIR/2026-04-01.md"
# We already wrote 2026-04-01 in case 6. Now run for 2026-04-02 against
# the same fixture; nothing in the fixture is on 2026-04-02, so we
# should get noop and no new daily note for that date.
d2_note="$MEMDIR/_d2_only.md"
mkdir -p "$SMOKE_ROOT/d2"
out_json8="$("$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$FIXTURE" \
    --date 2026-04-05 --memory-dir "$SMOKE_ROOT/d2" --json 2>/dev/null)"
rc=$?
turns8="$(printf '%s' "$out_json8" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read())["turns_new"])')"
if [[ $rc -ne 0 ]]; then
  fail 8 "rc=$rc on date with no turns"
elif [[ "$turns8" != "0" ]]; then
  fail 8 "expected 0 turns_new for 2026-04-05, got $turns8"
elif [[ -e "$SMOKE_ROOT/d2/2026-04-05.md" ]]; then
  fail 8 "daily note created for date with no turns"
else
  pass 8
fi

# ---------- case 9: manifest recovery — corrupt manifest + non-empty body ----------
banner 9 "corrupt manifest + non-empty body → no duplicate-on-first-run"
R9_DIR="$SMOKE_ROOT/r9"
mkdir -p "$R9_DIR"
R9_JSONL="$SMOKE_ROOT/r9.jsonl"
cat > "$R9_JSONL" <<'EOF'
{"type":"user","sessionId":"sess-R9","timestamp":"2026-04-09T10:00:00.000Z","message":{"role":"user","content":"recovery turn 1"}}
{"type":"assistant","sessionId":"sess-R9","timestamp":"2026-04-09T10:30:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"recovery turn 2"}]}}
EOF
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R9_JSONL" \
    --date 2026-04-09 --memory-dir "$R9_DIR" >/dev/null
r9_note="$R9_DIR/2026-04-09.md"
turns_before="$(grep -c '^### turn ' "$r9_note" || true)"
# Wipe the manifest entry by replacing the JSON value of
# reconciled_fingerprints with {} (simulates operator hand-edit).
"$PYTHON" - "$r9_note" <<'PY'
import json, re, sys
p = sys.argv[1]
text = open(p, encoding="utf-8").read()
m = re.search(r"<!-- bridge-daily-meta: (\{.*\}) -->", text)
meta = json.loads(m.group(1))
meta["reconciled_fingerprints"] = {}
new_meta_line = "<!-- bridge-daily-meta: " + json.dumps(meta, ensure_ascii=False) + " -->"
text = text[:m.start()] + new_meta_line + text[m.end():]
open(p, "w", encoding="utf-8").write(text)
PY
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R9_JSONL" \
    --date 2026-04-09 --memory-dir "$R9_DIR" >/dev/null 2>"$SMOKE_ROOT/err9.log"
rc9=$?
turns_after="$(grep -c '^### turn ' "$r9_note" || true)"
fps9="$("$PYTHON" -c '
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<!-- bridge-daily-meta: (\{.*\}) -->", text)
meta = json.loads(m.group(1))
print(len(meta.get("reconciled_fingerprints", {}).get("sess-R9", [])))
' "$r9_note")"
if [[ $rc9 -ne 0 ]]; then
  fail 9 "rc=$rc9 after manifest wipe"
elif [[ "$turns_before" != "2" ]]; then
  fail 9 "expected 2 turn blocks before wipe, got $turns_before"
elif [[ "$turns_after" != "2" ]]; then
  fail 9 "expected still-2 turn blocks after recovery, got $turns_after (duplicate appended?)"
elif [[ "$fps9" != "2" ]]; then
  fail 9 "expected 2 recovered fingerprints, got $fps9"
else
  pass 9
fi

# ---------- case 10: concurrent reconciles → both land ----------
banner 10 "two concurrent reconciles with disjoint jsonls → no lost update"
R10_DIR="$SMOKE_ROOT/r10"
mkdir -p "$R10_DIR"
R10_JSONL_A="$SMOKE_ROOT/r10a.jsonl"
R10_JSONL_B="$SMOKE_ROOT/r10b.jsonl"
cat > "$R10_JSONL_A" <<'EOF'
{"type":"user","sessionId":"sess-CA","timestamp":"2026-04-10T10:00:00.000Z","message":{"role":"user","content":"concurrent input A"}}
EOF
cat > "$R10_JSONL_B" <<'EOF'
{"type":"user","sessionId":"sess-CB","timestamp":"2026-04-10T10:00:01.000Z","message":{"role":"user","content":"concurrent input B"}}
EOF
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R10_JSONL_A" \
    --date 2026-04-10 --memory-dir "$R10_DIR" >/dev/null 2>>"$SMOKE_ROOT/err10.log" &
pid_a=$!
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R10_JSONL_B" \
    --date 2026-04-10 --memory-dir "$R10_DIR" >/dev/null 2>>"$SMOKE_ROOT/err10.log" &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
r10_note="$R10_DIR/2026-04-10.md"
if [[ $rc_a -ne 0 || $rc_b -ne 0 ]]; then
  fail 10 "concurrent rc: A=$rc_a B=$rc_b"
elif [[ ! -f "$r10_note" ]]; then
  fail 10 "concurrent note not created"
elif ! grep -q "concurrent input A" "$r10_note"; then
  fail 10 "input A lost"
elif ! grep -q "concurrent input B" "$r10_note"; then
  fail 10 "input B lost (lost update)"
else
  pass 10
fi

# ---------- case 11: malformed meta → quarantine block ----------
banner 11 "corrupt meta lines → quarantine block at bottom, body intact"
R11_DIR="$SMOKE_ROOT/r11"
mkdir -p "$R11_DIR"
R11_JSONL="$SMOKE_ROOT/r11.jsonl"
cat > "$R11_JSONL" <<'EOF'
{"type":"user","sessionId":"sess-Q","timestamp":"2026-04-11T10:00:00.000Z","message":{"role":"user","content":"body should survive"}}
EOF
r11_note="$R11_DIR/2026-04-11.md"
# Pre-seed a daily note whose meta envelope is malformed (broken JSON).
cat > "$r11_note" <<'EOF'
<!-- bridge-daily-meta: {"schema_version": 1, "session_ids": [BROKEN -->
some operator stray line above title
# 2026-04-11 — smoke-agent

## Session sess-Q — reconcile

### turn 1 · user · 2026-04-11T10:00:00+00:00

body should survive
EOF
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R11_JSONL" \
    --date 2026-04-11 --memory-dir "$R11_DIR" >/dev/null 2>"$SMOKE_ROOT/err11.log"
rc11=$?
if [[ $rc11 -ne 0 ]]; then
  fail 11 "rc=$rc11"
elif ! grep -q "<!-- daily-note-reconcile-quarantine -->" "$r11_note"; then
  fail 11 "quarantine open marker missing"
elif ! grep -q "<!-- /daily-note-reconcile-quarantine -->" "$r11_note"; then
  fail 11 "quarantine close marker missing"
elif ! grep -q "body should survive" "$r11_note"; then
  fail 11 "body content lost"
elif ! grep -q "BROKEN" "$r11_note"; then
  fail 11 "corrupt meta line not preserved in quarantine"
elif ! "$PYTHON" -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Quarantine block must come AFTER the title, not before.
title_idx = text.find("# 2026-04-11")
quar_idx = text.find("<!-- daily-note-reconcile-quarantine -->")
sys.exit(0 if title_idx > -1 and quar_idx > title_idx else 1)
' "$r11_note"; then
  fail 11 "quarantine block not at bottom"
elif ! head -1 "$r11_note" | grep -q '"reconciled_fingerprints"'; then
  fail 11 "clean meta envelope not on line 1"
else
  pass 11
fi

# ---------- case 12: input batch dedupe ----------
banner 12 "duplicate fingerprints within input → collapsed to 1 entry"
R12_DIR="$SMOKE_ROOT/r12"
mkdir -p "$R12_DIR"
R12_JSONL="$SMOKE_ROOT/r12.jsonl"
cat > "$R12_JSONL" <<'EOF'
{"type":"user","sessionId":"sess-D","timestamp":"2026-04-12T10:00:00.000Z","message":{"role":"user","content":"dup probe"}}
{"type":"user","sessionId":"sess-D","timestamp":"2026-04-12T10:00:00.000Z","message":{"role":"user","content":"dup probe"}}
{"type":"user","sessionId":"sess-D","timestamp":"2026-04-12T10:01:00.000Z","message":{"role":"user","content":"distinct probe"}}
EOF
out_json12="$("$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R12_JSONL" \
    --date 2026-04-12 --memory-dir "$R12_DIR" --json)"
rc12=$?
r12_note="$R12_DIR/2026-04-12.md"
turns12="$(grep -c '^### turn ' "$r12_note" || true)"
fps12="$("$PYTHON" -c '
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<!-- bridge-daily-meta: (\{.*\}) -->", text)
meta = json.loads(m.group(1))
print(len(meta.get("reconciled_fingerprints", {}).get("sess-D", [])))
' "$r12_note")"
filtered12="$(printf '%s' "$out_json12" | "$PYTHON" -c 'import json,sys; print(json.loads(sys.stdin.read()).get("turns_filtered", -1))')"
if [[ $rc12 -ne 0 ]]; then
  fail 12 "rc=$rc12"
elif [[ "$turns12" != "2" ]]; then
  fail 12 "expected 2 turn blocks (dup collapsed), got $turns12"
elif [[ "$fps12" != "2" ]]; then
  fail 12 "expected 2 fingerprints, got $fps12"
elif [[ "$filtered12" != "1" ]]; then
  fail 12 "expected 1 turn filtered as dup, got $filtered12"
else
  pass 12
fi

# ---------- case 13: path traversal sanitisation ----------
banner 13 "--agent traversal + --memory-dir escape → non-zero exit"
R13_JSONL="$SMOKE_ROOT/r13.jsonl"
cat > "$R13_JSONL" <<'EOF'
{"type":"user","sessionId":"sess-T","timestamp":"2026-04-13T10:00:00.000Z","message":{"role":"user","content":"trav probe"}}
EOF
"$PYTHON" "$SCRIPT" --agent "../../etc" --jsonl "$R13_JSONL" \
    --date 2026-04-13 --memory-dir "$SMOKE_ROOT/r13" >/dev/null 2>"$SMOKE_ROOT/err13a.log"
rc13a=$?
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R13_JSONL" \
    --date 2026-04-13 --memory-dir "/etc/passwd" >/dev/null 2>"$SMOKE_ROOT/err13b.log"
rc13b=$?
if [[ $rc13a -eq 0 ]]; then
  fail 13 "--agent ../../etc unexpectedly succeeded"
elif ! grep -q "agent id invalid" "$SMOKE_ROOT/err13a.log"; then
  fail 13 "expected agent-id rejection message"
elif [[ $rc13b -eq 0 ]]; then
  fail 13 "--memory-dir /etc/passwd unexpectedly succeeded"
elif ! grep -q "BRIDGE_HOME" "$SMOKE_ROOT/err13b.log"; then
  fail 13 "expected BRIDGE_HOME containment error"
else
  pass 13
fi

# ---------- case 14: defensive type guard on role ----------
banner 14 "non-string role → skipped with warning, no crash"
R14_DIR="$SMOKE_ROOT/r14"
mkdir -p "$R14_DIR"
R14_JSONL="$SMOKE_ROOT/r14.jsonl"
"$PYTHON" - "$R14_JSONL" <<'PY'
import json, sys
path = sys.argv[1]
records = [
    # Non-string role: list. Should be skipped with a warning.
    {"type": "user", "sessionId": "sess-G",
     "timestamp": "2026-04-14T09:00:00.000Z",
     "message": {"role": ["unexpected", "list"], "content": "should be skipped"}},
    # Healthy turn — should land.
    {"type": "user", "sessionId": "sess-G",
     "timestamp": "2026-04-14T09:01:00.000Z",
     "message": {"role": "user", "content": "healthy turn"}},
]
with open(path, "w", encoding="utf-8") as fh:
    for r in records:
        fh.write(json.dumps(r) + "\n")
PY
"$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R14_JSONL" \
    --date 2026-04-14 --memory-dir "$R14_DIR" >"$SMOKE_ROOT/out14.log" 2>"$SMOKE_ROOT/err14.log"
rc14=$?
r14_note="$R14_DIR/2026-04-14.md"
if [[ $rc14 -ne 0 ]]; then
  fail 14 "rc=$rc14 — script crashed on non-string role"
elif [[ ! -f "$r14_note" ]]; then
  fail 14 "healthy turn was not written"
elif grep -q "should be skipped" "$r14_note"; then
  fail 14 "non-string role turn leaked into note"
elif ! grep -q "healthy turn" "$r14_note"; then
  fail 14 "healthy turn missing"
elif ! grep -q "role not a string" "$SMOKE_ROOT/err14.log"; then
  fail 14 "no stderr warning for non-string role"
else
  pass 14
fi

# ---------- case 15: --dry-run --json → parseable JSON only ----------
banner 15 "--dry-run --json on non-empty input → stdout is JSON"
R15_DIR="$SMOKE_ROOT/r15"
mkdir -p "$R15_DIR"
R15_JSONL="$SMOKE_ROOT/r15.jsonl"
cat > "$R15_JSONL" <<'EOF'
{"type":"user","sessionId":"sess-J","timestamp":"2026-04-15T10:00:00.000Z","message":{"role":"user","content":"json probe"}}
EOF
out15="$("$PYTHON" "$SCRIPT" --agent "$AGENT" --jsonl "$R15_JSONL" \
    --date 2026-04-15 --memory-dir "$R15_DIR" --dry-run --json 2>/dev/null)"
rc15=$?
parse15_outcome="$(printf '%s' "$out15" | "$PYTHON" -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d.get("outcome", ""))
' 2>"$SMOKE_ROOT/err15.log" || true)"
if [[ $rc15 -ne 0 ]]; then
  fail 15 "rc=$rc15"
elif [[ "$parse15_outcome" != "dry-run" ]]; then
  fail 15 "stdout not parseable as JSON or wrong outcome (got '$parse15_outcome'): $out15"
elif printf '%s' "$out15" | grep -q "^no changes$"; then
  fail 15 "human prose 'no changes' leaked into JSON stdout"
elif [[ -e "$R15_DIR/2026-04-15.md" ]]; then
  fail 15 "dry-run created note file"
else
  pass 15
fi

# ---------- summary ----------
printf '\n=== summary: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
