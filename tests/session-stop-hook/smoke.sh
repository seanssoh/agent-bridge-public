#!/usr/bin/env bash
# session-stop hook smoke — covers the 6 acceptance cases from the
# issue #390 PR-2 brief, plus settings.json validation.
#
#   1  no agent context (BRIDGE_AGENT_ID unset) → exit 0, no reconcile
#   2  no reconcile script (PR-1 not installed) → exit 0 + stderr warn
#   3  no jsonl found (transcript_path missing + helper fails) → exit 0
#   4  reconcile succeeds (transcript_path on stdin) → daily note has new content
#   5  reconcile fails (jsonl unreadable) → exit 0 + non-blocking error
#   6  reconcile times out (sleep 60 stub) → exit 0 + timeout warning
#   7  agents/.claude/settings.json (shared renderer base) is valid JSON
#      and registers the full Stop suite — surface-reply-enforce.py +
#      session-stop.py. The renderer is the SSOT (#1068), so the suite
#      is verified on the rendered base, not on the now-minimal
#      agents/_template/.claude/settings.json bootstrap marker.
#
# Exit code: 0 if all cases PASS, 1 otherwise.
#
# Each case runs in its own ephemeral BRIDGE_HOME so we never touch the
# operator's real install.

set -u

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
HOOK="$REPO_ROOT/hooks/session-stop.py"
RECONCILE_SRC="$REPO_ROOT/scripts/daily-note-reconcile.py"
FIXTURE_DIR="$REPO_ROOT/tests/session-stop-hook/fixtures"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }
banner() { printf '\n=== case %s — %s ===\n' "$1" "$2"; }

SMOKE_ROOT="$(mktemp -d -t session-stop-hook.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

# Build a mock BRIDGE_HOME with scripts/ + hooks/ symlinked from the
# repo so the hook resolves the reconcile script under our temp root.
make_bridge_home() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/hooks" "$root/agents"
  cp "$RECONCILE_SRC" "$root/scripts/daily-note-reconcile.py"
  chmod +x "$root/scripts/daily-note-reconcile.py"
  cp "$HOOK" "$root/hooks/session-stop.py"
  chmod +x "$root/hooks/session-stop.py"
  # bridge-memory.py is needed only for the helper-fallback path; copy a
  # stub that always fails so case-3 exercises the "no jsonl" branch.
  cat > "$root/bridge-memory.py" <<'PYSTUB'
#!/usr/bin/env python3
import sys
sys.stderr.write("[bridge-memory stub] no project dir\n")
sys.exit(1)
PYSTUB
  chmod +x "$root/bridge-memory.py"
}

run_hook() {
  # $1 = stdin payload (string, possibly empty)
  # $2 = BRIDGE_HOME
  # $3 = BRIDGE_AGENT_ID (may be empty)
  # remaining args: stderr capture path
  local payload="$1" bhome="$2" agent="$3" stderr_log="$4"
  if [[ -n "$agent" ]]; then
    env -u BRIDGE_AGENT_HOME -u BRIDGE_AGENT_WORKDIR -u BRIDGE_TRANSCRIPTS_HOME \
      -u CLAUDE_PROJECT_DIR \
      BRIDGE_HOME="$bhome" BRIDGE_AGENT_ID="$agent" \
      "$PYTHON" "$bhome/hooks/session-stop.py" \
      <<<"$payload" 2>"$stderr_log"
  else
    env -u BRIDGE_AGENT_ID -u BRIDGE_AGENT_HOME -u BRIDGE_AGENT_WORKDIR \
      -u BRIDGE_TRANSCRIPTS_HOME -u CLAUDE_PROJECT_DIR \
      BRIDGE_HOME="$bhome" \
      "$PYTHON" "$bhome/hooks/session-stop.py" \
      <<<"$payload" 2>"$stderr_log"
  fi
}

# ---------- case 1: no agent context ----------
banner 1 "no BRIDGE_AGENT_ID → fast-path exit 0"
C1_HOME="$SMOKE_ROOT/c1"
make_bridge_home "$C1_HOME"
C1_ERR="$SMOKE_ROOT/c1.err"
# Strip any inherited BRIDGE_AGENT_ID from the parent shell so the hook
# sees the unset case (operator invokes outside of a bridge agent).
if run_hook "" "$C1_HOME" "" "$C1_ERR"; then
  if [[ -s "$C1_ERR" ]]; then
    fail 1 "stderr non-empty when no agent context: $(cat "$C1_ERR")"
  else
    pass 1
  fi
else
  rc=$?
  fail 1 "non-zero rc=$rc when no agent context"
fi

# ---------- case 2: no reconcile script ----------
banner 2 "missing daily-note-reconcile.py → exit 0 with stderr warn"
C2_HOME="$SMOKE_ROOT/c2"
make_bridge_home "$C2_HOME"
rm -f "$C2_HOME/scripts/daily-note-reconcile.py"
C2_ERR="$SMOKE_ROOT/c2.err"
if run_hook '{}' "$C2_HOME" "smoke-agent" "$C2_ERR"; then
  if grep -q "daily-note-reconcile.py missing" "$C2_ERR"; then
    pass 2
  else
    fail 2 "expected stderr warn 'daily-note-reconcile.py missing'; got: $(cat "$C2_ERR")"
  fi
else
  rc=$?
  fail 2 "non-zero rc=$rc with reconcile script removed"
fi

# ---------- case 3: no jsonl found ----------
banner 3 "no transcript_path + helper fails → exit 0 with stderr warn"
C3_HOME="$SMOKE_ROOT/c3"
make_bridge_home "$C3_HOME"
C3_ERR="$SMOKE_ROOT/c3.err"
# Empty stdin payload → no transcript_path → falls back to helper which
# exits 1 → resolve returns None → "no current jsonl ...".
if run_hook '{}' "$C3_HOME" "smoke-agent" "$C3_ERR"; then
  if grep -q "no current jsonl\|no session-id" "$C3_ERR"; then
    pass 3
  else
    fail 3 "expected stderr 'no current jsonl' or 'no session-id'; got: $(cat "$C3_ERR")"
  fi
else
  rc=$?
  fail 3 "non-zero rc=$rc when no jsonl resolvable"
fi

# ---------- case 4: reconcile succeeds via transcript_path ----------
banner 4 "transcript_path on stdin → daily note has new content"
C4_HOME="$SMOKE_ROOT/c4"
make_bridge_home "$C4_HOME"
C4_AGENT="smoke-agent"
mkdir -p "$C4_HOME/agents/$C4_AGENT/memory"
# The reconcile script defaults --date to UTC today; build a fixture
# whose timestamps are within today's UTC window so the live hook path
# (no --date flag) actually merges turns. The static
# fixtures/single-turn.jsonl uses fixed 2026-04-01 timestamps so it can
# be referenced from other tests; here we render the same shape with
# today's UTC date so the smoke isn't pinned to a wall-clock day.
TODAY_UTC="$("$PYTHON" -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%d"))')"
C4_JSONL="$SMOKE_ROOT/c4-session.jsonl"
cat > "$C4_JSONL" <<EOF
{"type":"user","sessionId":"sess-stop-A","timestamp":"${TODAY_UTC}T01:00:00.000Z","message":{"role":"user","content":"hello from stop hook smoke"}}
{"type":"assistant","sessionId":"sess-stop-A","timestamp":"${TODAY_UTC}T01:00:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"acknowledged"}]}}
EOF
C4_ERR="$SMOKE_ROOT/c4.err"
C4_PAYLOAD="{\"transcript_path\":\"$C4_JSONL\",\"session_id\":\"sess-stop-A\"}"
if run_hook "$C4_PAYLOAD" "$C4_HOME" "$C4_AGENT" "$C4_ERR"; then
  C4_NOTE="$C4_HOME/agents/$C4_AGENT/memory/${TODAY_UTC}.md"
  if [[ ! -f "$C4_NOTE" ]]; then
    fail 4 "expected daily note at $C4_NOTE; not created. stderr: $(cat "$C4_ERR")"
  elif ! grep -q "hello from stop hook smoke" "$C4_NOTE"; then
    fail 4 "user turn text missing from daily note"
  elif ! grep -q "## Session sess-stop-A — reconcile" "$C4_NOTE"; then
    fail 4 "expected section header 'Session sess-stop-A — reconcile' in note"
  else
    pass 4
  fi
else
  rc=$?
  fail 4 "non-zero rc=$rc on successful reconcile path. stderr: $(cat "$C4_ERR")"
fi

# ---------- case 5: reconcile fails (jsonl unreadable) ----------
banner 5 "jsonl points at a directory → reconcile fails, hook exit 0"
C5_HOME="$SMOKE_ROOT/c5"
make_bridge_home "$C5_HOME"
C5_AGENT="smoke-agent"
mkdir -p "$C5_HOME/agents/$C5_AGENT/memory"
C5_BAD="$SMOKE_ROOT/c5-not-a-file"
mkdir -p "$C5_BAD"  # is_file() will be False → hook treats as no jsonl
C5_ERR="$SMOKE_ROOT/c5.err"
C5_PAYLOAD="{\"transcript_path\":\"$C5_BAD\"}"
if run_hook "$C5_PAYLOAD" "$C5_HOME" "$C5_AGENT" "$C5_ERR"; then
  if grep -q "no current jsonl" "$C5_ERR"; then
    if [[ -e "$C5_HOME/agents/$C5_AGENT/memory/$(date -u +%Y-%m-%d).md" ]]; then
      fail 5 "daily note created despite unreadable jsonl"
    else
      pass 5
    fi
  else
    fail 5 "expected 'no current jsonl' warning; got: $(cat "$C5_ERR")"
  fi
else
  rc=$?
  fail 5 "non-zero rc=$rc when jsonl unreadable"
fi

# ---------- case 5b: reconcile actually fails on a corrupt jsonl ----------
# A jsonl that exists but exercises reconcile-side error path. We pick
# an --agent that violates the reconcile script's allowlist (with the
# fixture jsonl) so reconcile exits 2 and our hook logs the rc and
# exits 0 anyway.
banner "5b" "reconcile rc=2 on bad agent id → hook exit 0 + non-blocking log"
C5B_HOME="$SMOKE_ROOT/c5b"
make_bridge_home "$C5B_HOME"
C5B_AGENT="bad..agent"  # contains '..' → reconcile rejects it
mkdir -p "$C5B_HOME/agents"
C5B_JSONL="$SMOKE_ROOT/c5b.jsonl"
cp "$FIXTURE_DIR/single-turn.jsonl" "$C5B_JSONL"
C5B_ERR="$SMOKE_ROOT/c5b.err"
C5B_PAYLOAD="{\"transcript_path\":\"$C5B_JSONL\"}"
if BRIDGE_HOME="$C5B_HOME" BRIDGE_AGENT_ID="$C5B_AGENT" \
    "$PYTHON" "$C5B_HOME/hooks/session-stop.py" \
    <<<"$C5B_PAYLOAD" 2>"$C5B_ERR"; then
  if grep -q "reconcile failed (rc=" "$C5B_ERR"; then
    pass "5b"
  else
    fail "5b" "expected 'reconcile failed (rc=...)'; got: $(cat "$C5B_ERR")"
  fi
else
  rc=$?
  fail "5b" "non-zero rc=$rc; hook must exit 0 even when reconcile fails"
fi

# ---------- case 6: reconcile times out ----------
banner 6 "reconcile sleep 60 → hook reports timeout, exits 0"
C6_HOME="$SMOKE_ROOT/c6"
make_bridge_home "$C6_HOME"
# Replace the reconcile script with a sleep-forever stub.
cat > "$C6_HOME/scripts/daily-note-reconcile.py" <<'STUB'
#!/usr/bin/env python3
import time
time.sleep(60)
STUB
chmod +x "$C6_HOME/scripts/daily-note-reconcile.py"
C6_AGENT="smoke-agent"
mkdir -p "$C6_HOME/agents/$C6_AGENT/memory"
C6_JSONL="$SMOKE_ROOT/c6.jsonl"
cp "$FIXTURE_DIR/single-turn.jsonl" "$C6_JSONL"
C6_ERR="$SMOKE_ROOT/c6.err"
C6_PAYLOAD="{\"transcript_path\":\"$C6_JSONL\"}"

# Patch the hook copy under C6_HOME so subprocess timeout fires fast
# (5s instead of 30) — keeps the smoke test under ~6s.
"$PYTHON" - <<'PATCH' "$C6_HOME/hooks/session-stop.py"
import sys
p = sys.argv[1]
src = open(p, "r", encoding="utf-8").read()
src2 = src.replace("timeout=30)", "timeout=5)").replace(
    "reconcile timed out (30s)", "reconcile timed out (5s)"
)
if src == src2:
    sys.stderr.write("PATCH: timeout marker not found\n")
    sys.exit(2)
open(p, "w", encoding="utf-8").write(src2)
PATCH
patch_rc=$?
if [[ $patch_rc -ne 0 ]]; then
  fail 6 "could not patch hook for short timeout"
else
  start=$(date +%s)
  if BRIDGE_HOME="$C6_HOME" BRIDGE_AGENT_ID="$C6_AGENT" \
      "$PYTHON" "$C6_HOME/hooks/session-stop.py" \
      <<<"$C6_PAYLOAD" 2>"$C6_ERR"; then
    end=$(date +%s)
    elapsed=$((end - start))
    if (( elapsed > 15 )); then
      fail 6 "hook did not honour timeout (took ${elapsed}s)"
    elif grep -q "reconcile timed out" "$C6_ERR"; then
      pass 6
    else
      fail 6 "expected 'reconcile timed out'; got: $(cat "$C6_ERR")"
    fi
  else
    rc=$?
    fail 6 "non-zero rc=$rc on reconcile timeout"
  fi
fi

# ---------- case 7: settings.json is valid JSON ----------
# #1068 HOOKS-SSOT: the SSOT for the rendered hook surface is
# agents/.claude/settings.json (the renderer's base), not the
# now-minimal agents/_template/.claude/settings.json bootstrap marker.
# Verify the full Stop suite (surface-reply-enforce.py + session-stop.py
# with timeout 35) is present on the shared base.
banner 7 "agents/.claude/settings.json (renderer base) validates Stop suite"
SETTINGS="$REPO_ROOT/agents/.claude/settings.json"
if "$PYTHON" -c "
import json, sys
data = json.load(open('$SETTINGS', encoding='utf-8'))
stop = data.get('hooks', {}).get('Stop', [])
# Must have the surface-reply-enforce entry AND the session-stop entry.
cmds = []
for entry in stop:
    for h in (entry.get('hooks') or []):
        cmds.append(h.get('command') or '')
if not any('surface-reply-enforce.py' in c for c in cmds):
    sys.exit('surface-reply-enforce.py registration missing')
if not any('session-stop.py' in c for c in cmds):
    sys.exit('session-stop.py registration missing')
# Confirm session-stop has timeout 35.
for entry in stop:
    for h in (entry.get('hooks') or []):
        if 'session-stop.py' in (h.get('command') or ''):
            if h.get('timeout') != 35:
                sys.exit(f'session-stop timeout != 35 (got {h.get(\"timeout\")})')
# Verify the template marker is the empty bootstrap shape {} — anything
# else would be a second source of truth for the hook surface.
TEMPLATE = '$REPO_ROOT/agents/_template/.claude/settings.json'
template = json.load(open(TEMPLATE, encoding='utf-8'))
if template != {}:
    sys.exit(f'template marker must be empty bootstrap shape; got {template!r}')
"; then
  pass 7
else
  fail 7 "settings.json validation failed"
fi

# ---------- case 8: BRIDGE_HOME unset + non-bridge fallback dir ----------
# codex r1 PR #450: when BRIDGE_HOME is unset AND the script's parent.parent
# is not a bridge home (no scripts/+agents/ siblings), the hook must fast-path
# return 0 — it must NOT invoke reconcile from an arbitrary location.
banner 8 "BRIDGE_HOME unset + non-bridge fallback path -> exit 0 fast-path"
C8_FAKE_HOME="$(mktemp -d)"
mkdir -p "$C8_FAKE_HOME/hooks"
cp "$REPO_ROOT/hooks/session-stop.py" "$C8_FAKE_HOME/hooks/session-stop.py"
# Deliberately do NOT create scripts/ or agents/ — fallback dir doesn't look
# like a bridge home. With BRIDGE_HOME unset, hook must return 0.
C8_ERR="$(mktemp)"
if env -u BRIDGE_HOME BRIDGE_AGENT_ID=anyone \
    "$PYTHON" "$C8_FAKE_HOME/hooks/session-stop.py" 2>"$C8_ERR" </dev/null; then
  pass 8
else
  rc=$?
  fail 8 "non-zero rc=$rc when BRIDGE_HOME unset + non-bridge fallback (stderr: $(cat "$C8_ERR"))"
fi
rm -rf "$C8_FAKE_HOME" "$C8_ERR"

# ---------- summary ----------
printf '\n=== summary: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
