#!/usr/bin/env bash
# daily-note-reconcile smoke — covers the 8 acceptance cases from the
# issue #390 PR-1 brief.
#
#   1 empty jsonl → no daily note created (or empty manifest)
#   2 single-turn jsonl → daily note created with 1 turn + manifest entry
#   3 re-run with same jsonl → no change (idempotency)
#   4 re-run after appending a new turn → 2 turns + 2 manifest entries
#   5 --dry-run returns diff without writing
#   6 malformed jsonl line → script tolerates (skips), continues
#   7 long turn truncation → respects 2000 head + 500 tail
#   8 --date filter → only that day's turns extracted
#
# Usage:   bash tests/daily-note-reconcile/smoke.sh
# Exit 0 if all 8 cases PASS, 1 otherwise.

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

# ---------- summary ----------
printf '\n=== summary: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
