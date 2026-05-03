#!/usr/bin/env bash
# compact-recovery smoke — end-to-end check for issue #509 P3 (C3+C4).
#
#   1  pre-compact writes <state>/agents/<agent>/compact-snapshot.json
#      with SOUL/MEMORY content
#   2  session_start matcher=compact emits a `## Restored Context` block
#      with live SOUL/MEMORY content, BEFORE the queue context
#   3  matcher=compact dedup: a second invocation within the dedup window
#      does NOT re-emit the restored block
#   4  fallback: when a canonical file is missing post-compact, the
#      session_start hook substitutes the snapshot content with the
#      `[restored from pre-compact snapshot]` marker
#   5  feature flag: BRIDGE_COMPACT_RECOVERY=off suppresses the block
#      entirely (note: dedup state is shared with #3, so we use a fresh
#      home with no prior dedup)
#   6  matcher=startup (non-compact): no restored block
#
# Each case runs in its own ephemeral BRIDGE_HOME.

set -u

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PRE_COMPACT="$REPO_ROOT/hooks/pre-compact.py"
SESSION_START="$REPO_ROOT/hooks/session_start.py"
COMMON="$REPO_ROOT/hooks/bridge_hook_common.py"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }
banner() { printf '\n=== case %s — %s ===\n' "$1" "$2"; }

SMOKE_ROOT="$(mktemp -d -t compact-recovery.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

# Build a minimal mock BRIDGE_HOME with hooks/ and a tester agent home.
make_bridge_home() {
  local root="$1" agent="$2"
  mkdir -p "$root/hooks" "$root/agents/$agent"
  cp "$COMMON" "$root/hooks/bridge_hook_common.py"
  cp "$PRE_COMPACT" "$root/hooks/pre-compact.py"
  cp "$SESSION_START" "$root/hooks/session_start.py"
  chmod +x "$root/hooks/pre-compact.py" "$root/hooks/session_start.py"
  # Provide a stub bridge-memory.py that exits 0 silently — pre-compact
  # invokes it for capture; we don't care about the memory pipeline here.
  cat > "$root/bridge-memory.py" <<'PYSTUB'
#!/usr/bin/env python3
import sys
sys.exit(0)
PYSTUB
  chmod +x "$root/bridge-memory.py"
  # Default canonical files for the agent.
  cat > "$root/agents/$agent/SOUL.md" <<EOF
# SOUL — $agent
identity = compact-recovery-tester
EOF
  cat > "$root/agents/$agent/MEMORY.md" <<EOF
# MEMORY — $agent
recent_anchor = anchor-row-1
EOF
}

run_pre_compact() {
  local bhome="$1" agent="$2" payload="$3"
  env -u BRIDGE_AGENT_WORKDIR -u BRIDGE_AGENT_HOME -u BRIDGE_AGENT_HOME_ROOT \
      -u BRIDGE_STATE_DIR -u BRIDGE_ACTIVE_AGENT_DIR \
      BRIDGE_HOME="$bhome" BRIDGE_AGENT_ID="$agent" \
      "$PYTHON" "$bhome/hooks/pre-compact.py" <<<"$payload"
}

run_session_start() {
  # $1 = bhome, $2 = agent, $3 = matcher, [$4 = extra env, e.g. "BRIDGE_COMPACT_RECOVERY=off"]
  local bhome="$1" agent="$2" matcher="$3" extra="${4:-}"
  if [[ -n "$extra" ]]; then
    # `extra` is intentionally word-split into KEY=value pairs that env
    # consumes — quoting it would break that.
    # shellcheck disable=SC2086
    env -u BRIDGE_AGENT_WORKDIR -u BRIDGE_AGENT_HOME -u BRIDGE_AGENT_HOME_ROOT \
        -u BRIDGE_STATE_DIR -u BRIDGE_ACTIVE_AGENT_DIR \
        BRIDGE_HOME="$bhome" BRIDGE_AGENT_ID="$agent" $extra \
        "$PYTHON" "$bhome/hooks/session_start.py" --matcher "$matcher"
  else
    env -u BRIDGE_AGENT_WORKDIR -u BRIDGE_AGENT_HOME -u BRIDGE_AGENT_HOME_ROOT \
        -u BRIDGE_STATE_DIR -u BRIDGE_ACTIVE_AGENT_DIR \
        BRIDGE_HOME="$bhome" BRIDGE_AGENT_ID="$agent" \
        "$PYTHON" "$bhome/hooks/session_start.py" --matcher "$matcher"
  fi
}

# ---------- case 1: pre-compact writes snapshot ----------
banner 1 "pre-compact writes compact-snapshot.json"
C1_HOME="$SMOKE_ROOT/c1"
make_bridge_home "$C1_HOME" "tester"
if run_pre_compact "$C1_HOME" "tester" '{"trigger":"manual"}' >/dev/null 2>&1; then
  SNAPSHOT="$C1_HOME/state/agents/tester/compact-snapshot.json"
  if [[ ! -f "$SNAPSHOT" ]]; then
    fail 1 "expected snapshot at $SNAPSHOT (state dir contents: $(find "$C1_HOME/state" -type f 2>/dev/null || echo '<none>'))"
  elif ! "$PYTHON" -c "
import json, sys
data = json.load(open('$SNAPSHOT', encoding='utf-8'))
files = data.get('files') or {}
if 'identity = compact-recovery-tester' not in files.get('SOUL.md', ''):
    sys.exit(f'SOUL.md content missing: {files.get(\"SOUL.md\", \"<empty>\")[:80]}')
if 'recent_anchor' not in files.get('MEMORY.md', ''):
    sys.exit(f'MEMORY.md content missing: {files.get(\"MEMORY.md\", \"<empty>\")[:80]}')
"; then
    fail 1 "snapshot validation failed"
  else
    pass 1
  fi
else
  rc=$?
  fail 1 "pre-compact rc=$rc"
fi

# ---------- case 2: session_start matcher=compact emits restored block ----------
banner 2 "session_start matcher=compact emits Restored Context block"
C2_HOME="$SMOKE_ROOT/c2"
make_bridge_home "$C2_HOME" "tester"
C2_OUT="$SMOKE_ROOT/c2.out"
if run_session_start "$C2_HOME" "tester" "compact" >"$C2_OUT" 2>&1; then
  if ! grep -q "## Restored Context (post-compact)" "$C2_OUT"; then
    fail 2 "missing '## Restored Context' header. output:\n$(cat "$C2_OUT")"
  elif ! grep -q "identity = compact-recovery-tester" "$C2_OUT"; then
    fail 2 "SOUL.md content missing"
  elif ! grep -q "recent_anchor" "$C2_OUT"; then
    fail 2 "MEMORY.md content missing"
  else
    # Ordering: restored block must come BEFORE queue protocol line.
    RESTORED_LINE=$(grep -n "## Restored Context" "$C2_OUT" | head -1 | cut -d: -f1)
    QUEUE_LINE=$(grep -n "Agent Bridge queue protocol" "$C2_OUT" | head -1 | cut -d: -f1)
    if [[ -z "$RESTORED_LINE" || -z "$QUEUE_LINE" ]]; then
      fail 2 "could not find both markers for ordering check"
    elif (( RESTORED_LINE >= QUEUE_LINE )); then
      fail 2 "restored block (line $RESTORED_LINE) not before queue context (line $QUEUE_LINE)"
    else
      pass 2
    fi
  fi
else
  rc=$?
  fail 2 "session_start rc=$rc; output:\n$(cat "$C2_OUT")"
fi

# ---------- case 3: dedup on second compact within window ----------
banner 3 "second compact within dedup window does NOT re-emit restored block"
C3_OUT="$SMOKE_ROOT/c3.out"
# Reuse C2_HOME — first run already stamped the dedup marker.
if run_session_start "$C2_HOME" "tester" "compact" >"$C3_OUT" 2>&1; then
  if grep -q "## Restored Context" "$C3_OUT"; then
    fail 3 "restored block re-emitted on second compact within dedup window"
  else
    pass 3
  fi
else
  rc=$?
  fail 3 "session_start (second compact) rc=$rc; output:\n$(cat "$C3_OUT")"
fi

# ---------- case 4: snapshot fallback when live file vanished ----------
banner 4 "snapshot fallback when live SOUL.md missing post-compact"
C4_HOME="$SMOKE_ROOT/c4"
make_bridge_home "$C4_HOME" "tester"
# 4a — pre-compact captures live state
run_pre_compact "$C4_HOME" "tester" '{"trigger":"manual"}' >/dev/null 2>&1 || true
# 4b — simulate worst case: SOUL.md vanishes between pre-compact and resume
rm -f "$C4_HOME/agents/tester/SOUL.md"
C4_OUT="$SMOKE_ROOT/c4.out"
if run_session_start "$C4_HOME" "tester" "compact" >"$C4_OUT" 2>&1; then
  if ! grep -q "identity = compact-recovery-tester" "$C4_OUT"; then
    fail 4 "snapshot SOUL.md content not restored. output:\n$(cat "$C4_OUT")"
  elif ! grep -q "restored from pre-compact snapshot" "$C4_OUT"; then
    fail 4 "snapshot fallback marker missing"
  else
    pass 4
  fi
else
  rc=$?
  fail 4 "session_start rc=$rc"
fi

# ---------- case 5: BRIDGE_COMPACT_RECOVERY=off suppresses the block ----------
banner 5 "BRIDGE_COMPACT_RECOVERY=off suppresses Restored Context entirely"
C5_HOME="$SMOKE_ROOT/c5"
make_bridge_home "$C5_HOME" "tester"
C5_OUT="$SMOKE_ROOT/c5.out"
if run_session_start "$C5_HOME" "tester" "compact" "BRIDGE_COMPACT_RECOVERY=off" >"$C5_OUT" 2>&1; then
  if grep -q "## Restored Context" "$C5_OUT"; then
    fail 5 "restored block emitted despite BRIDGE_COMPACT_RECOVERY=off"
  elif ! grep -q "Agent Bridge queue protocol" "$C5_OUT"; then
    fail 5 "queue context missing — hook should still emit baseline output"
  else
    pass 5
  fi
else
  rc=$?
  fail 5 "session_start rc=$rc"
fi

# ---------- case 6: matcher=startup never emits restored block ----------
banner 6 "matcher=startup omits Restored Context block"
C6_HOME="$SMOKE_ROOT/c6"
make_bridge_home "$C6_HOME" "tester"
C6_OUT="$SMOKE_ROOT/c6.out"
if run_session_start "$C6_HOME" "tester" "startup" >"$C6_OUT" 2>&1; then
  if grep -q "## Restored Context" "$C6_OUT"; then
    fail 6 "restored block emitted on matcher=startup"
  else
    pass 6
  fi
else
  rc=$?
  fail 6 "session_start rc=$rc"
fi

# ---------- case 7: BRIDGE_COMPACT_RECOVERY_MAX_BYTES is a UTF-8 byte cap ----------
banner 7 "MAX_BYTES enforced as UTF-8 bytes, not Python char count (codex r1)"
C7_HOME="$SMOKE_ROOT/c7"
make_bridge_home "$C7_HOME" "tester"
# Korean text: each char is 3 bytes in UTF-8. 300 chars = 900 bytes, well
# above a 256-byte cap. The pre-fix code (len(text) <= cap on chars) would
# emit the full 900 bytes; the fix must keep the raw section under cap.
"$PYTHON" -c "
from pathlib import Path
Path('$C7_HOME/agents/tester/SOUL.md').write_text('안녕' * 150, encoding='utf-8')
"
C7_OUT="$SMOKE_ROOT/c7.out"
if env -u BRIDGE_AGENT_WORKDIR -u BRIDGE_AGENT_HOME -u BRIDGE_AGENT_HOME_ROOT \
    -u BRIDGE_STATE_DIR -u BRIDGE_ACTIVE_AGENT_DIR \
    BRIDGE_HOME="$C7_HOME" BRIDGE_AGENT_ID="tester" \
    BRIDGE_COMPACT_RECOVERY_MAX_BYTES=256 \
    "$PYTHON" "$C7_HOME/hooks/session_start.py" --matcher compact >"$C7_OUT" 2>&1; then
  # Extract bytes between '### SOUL.md\n' and the truncation marker.
  RAW_BYTES=$("$PYTHON" - "$C7_OUT" <<'PY'
import sys, pathlib, re
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"### SOUL\.md\n(.*?)\n\[…truncated by compact-recovery cap…\]", text, re.S)
if not m:
    print("NO_TRUNC_MARKER")
    sys.exit(0)
print(len(m.group(1).encode("utf-8")))
PY
)
  if [[ "$RAW_BYTES" == "NO_TRUNC_MARKER" ]]; then
    fail 7 "expected '[…truncated by compact-recovery cap…]' marker — pre-fix bug would skip truncation entirely. output:\n$(cat "$C7_OUT")"
  elif (( RAW_BYTES > 256 )); then
    fail 7 "raw SOUL section bytes=$RAW_BYTES exceed cap=256 (regression — char vs byte cap)"
  else
    pass 7
  fi
else
  rc=$?
  fail 7 "session_start rc=$rc; output:\n$(cat "$C7_OUT")"
fi

# ---------- case 8: cap default covers patch's 5607-byte SESSION-TYPE.md ----------
# Issue #509 follow-up: patch's PR #510 verify report flagged that the
# default cap (5120 bytes) was hit by patch's SESSION-TYPE.md (5607 bytes),
# truncating the admin bootstrap content. The default was raised to 8192;
# pin that here so a future "performance optimisation" doesn't silently
# drop it back below the observed admin bootstrap size.
banner 8 "default cap (>= 8192) covers a 5607-byte canonical file untruncated"
"$PYTHON" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/hooks')
import bridge_hook_common as m
import os
for k in list(os.environ):
    if k.startswith('BRIDGE_COMPACT_RECOVERY'):
        del os.environ[k]
cap = m.compact_recovery_per_file_cap()
assert cap >= 8192, f'default cap regressed below 8192: {cap}'
print('OK', cap)
" >/dev/null && pass 8 || fail 8 "default cap is below 8192 (regressed below patch's observed SESSION-TYPE size)"

# ---------- summary ----------
printf '\n=== summary: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
