#!/usr/bin/env bash
# scripts/smoke/1569-askuserquestion-bound.sh — issue #1569 regression smoke.
#
# Pins the bounded-AskUserQuestion PreToolUse intercept: an autonomous agent
# that calls AskUserQuestion must NEVER hang on the interactive picker. The
# hook (hooks/tool-policy.py -> handle_askuserquestion ->
# hooks/askuserquestion_escalate.py) converts the call into a bounded,
# channel-routed escalation with an autonomous fallback.
#
# Layer-1 (real PreToolUse hook end-to-end) assertions:
#   (a) NO reply within the window  -> fallback fires, hook returns a `deny`
#       with proceed-with-note guidance, BOUNDED wall-clock (no hang).
#   (b) high-stakes question, NO reply  -> fallback is `blocked` (do not
#       silently guess), still bounded.
#   (c) a channel reply present within the window  -> the chosen option is
#       returned to the agent (`deny` carrying the human's answer), fast wait.
#   (d) every OTHER tool (Bash) is handled byte-identically — the credential
#       env-dump deny is unchanged, proving the intercept did not weaken the
#       guard.
#
# Smoke layout mirrors scripts/smoke/6607-hook-admin-allowlist.sh: printf-built
# JSON payload to a temp file, `< file` into the hook (NEVER an interpreter
# heredoc-stdin — footgun #11). The wait window is shrunk via
# BRIDGE_ASKUSERQUESTION_WAIT_SECONDS so the bound is asserted in ~seconds, not
# the 30s default.

set -euo pipefail

SMOKE_NAME="1569-askuserquestion-bound"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

AGENT="auq-1569-agent"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$AGENT"

# Short, but non-zero, wait so (a)/(b) prove the bound without a 30s wall-clock.
# Kept at 5s (still far under the 30s default) so case (c)'s in-window reply has
# comfortable headroom over the escalate-subprocess startup + poll cadence.
WAIT_SECONDS=5
export BRIDGE_ASKUSERQUESTION_WAIT_SECONDS="$WAIT_SECONDS"

# Tight ceiling on the total wall-clock. The escalation subprocess shares the
# SAME deadline budget as the reply poll (it is not additive), so a correct
# implementation returns within ~WAIT_SECONDS plus a few seconds of
# process-spawn / python-startup overhead. A regression that lets the escalate
# time stack ON TOP of the full poll window (codex #1569 r1 finding 2) would
# blow this ceiling. +4s slack absorbs CI jitter without hiding that class.
BOUND_CEILING=$((WAIT_SECONDS + 4))

REPLY_FILE="$BRIDGE_STATE_DIR/agents/$AGENT/askuserquestion-reply.json"

write_auq_payload() {
  # $1 target file, $2 question text, $3 (optional) options-json array literal.
  local target="$1" question="$2" options="${3:-[\"yes\", \"no\"]}"
  local esc
  esc="${question//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "AskUserQuestion",' \
    "  \"tool_input\": {\"question\": \"${esc}\", \"options\": ${options}}," \
    '  "tool_use_id": "smoke-1569",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

write_bash_payload() {
  # $1 target file, $2 command string.
  local target="$1" command="$2" esc
  esc="${command//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1569-bash",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

run_pretool_hook() {
  # $1 payload file. Echoes the hook's stdout (the decision JSON).
  local payload_file="$1"
  BRIDGE_AGENT_ID="$AGENT" \
    "$PYTHON_BIN" "$SMOKE_REPO_ROOT/hooks/tool-policy.py" <"$payload_file"
}

audit_log() {
  printf '%s\n' "${BRIDGE_AUDIT_LOG:-$BRIDGE_LOG_DIR/audit.jsonl}"
}

count_audit_rows() {
  # $1 action.
  local audit
  audit="$(audit_log)"
  if [[ ! -f "$audit" ]]; then
    printf '0\n'
    return 0
  fi
  grep -c "\"action\": \"$1\"" "$audit" 2>/dev/null || true
}

# --- (a) NO reply -> proceed-with-note fallback, bounded --------------------

smoke_log "(a) no reply within window -> bounded proceed-with-note fallback"
rm -f "$REPLY_FILE"
PAYLOAD="$SMOKE_TMP_ROOT/auq-a.json"
write_auq_payload "$PAYLOAD" "Which color theme should the dashboard use?"

START="$(date +%s)"
OUT_A="$(run_pretool_hook "$PAYLOAD")"
END="$(date +%s)"
ELAPSED=$((END - START))

# Bound: must complete within ~window + generous slack (escalate subprocess
# fails fast against the admin-less smoke home, so this is dominated by the
# 2s poll, never a hang).
if (( ELAPSED > BOUND_CEILING )); then
  smoke_fail "(a) hook did not return within the bound: ${ELAPSED}s > ${BOUND_CEILING}s (HANG / escalate-stacked-on-poll)"
fi
smoke_assert_contains "$OUT_A" '"permissionDecision": "deny"' "(a) AskUserQuestion is short-circuited (deny)"
smoke_assert_contains "$OUT_A" 'proceed with your best-judgment default' "(a) reversible fallback = proceed + note"
smoke_log "ok: (a) bounded in ${ELAPSED}s, proceed-with-note fallback returned"

# --- (b) high-stakes question, NO reply -> blocked fallback -----------------

smoke_log "(b) high-stakes question, no reply -> blocked fallback (no silent guess)"
rm -f "$REPLY_FILE"
PAYLOAD="$SMOKE_TMP_ROOT/auq-b.json"
write_auq_payload "$PAYLOAD" "Should I delete the production database now?"

START="$(date +%s)"
OUT_B="$(run_pretool_hook "$PAYLOAD")"
END="$(date +%s)"
ELAPSED=$((END - START))
if (( ELAPSED > BOUND_CEILING )); then
  smoke_fail "(b) hook did not return within the bound: ${ELAPSED}s > ${BOUND_CEILING}s (HANG)"
fi
smoke_assert_contains "$OUT_B" '"permissionDecision": "deny"' "(b) AskUserQuestion short-circuited (deny)"
smoke_assert_contains "$OUT_B" 'high-stakes / consequential. Do NOT guess' "(b) consequential fallback = block + escalate"
smoke_log "ok: (b) bounded in ${ELAPSED}s, blocked fallback returned"

# --- (c) channel reply within window -> chosen option returned --------------

smoke_log "(c) channel reply present -> chosen option returned to the agent"
mkdir -p "$(dirname "$REPLY_FILE")"
rm -f "$REPLY_FILE"
PAYLOAD="$SMOKE_TMP_ROOT/auq-c.json"
write_auq_payload "$PAYLOAD" "Which color theme should the dashboard use?" '["dark", "light"]'

# Simulate a human answering on the channel WITHIN the window: the hook clears
# any stale reply first, then polls — so the answer must land AFTER the hook
# starts. Write it from the background shortly after launch; the bounded poll
# picks it up well before the window closes.
( sleep 1; printf '%s\n' '{"answer": "light"}' >"$REPLY_FILE" ) &
REPLY_WRITER_PID=$!

START="$(date +%s)"
OUT_C="$(run_pretool_hook "$PAYLOAD")"
END="$(date +%s)"
wait "$REPLY_WRITER_PID" 2>/dev/null || true
ELAPSED=$((END - START))
if (( ELAPSED > BOUND_CEILING )); then
  smoke_fail "(c) hook did not return within the bound: ${ELAPSED}s > ${BOUND_CEILING}s (HANG)"
fi
smoke_assert_contains "$OUT_C" '"permissionDecision": "deny"' "(c) AskUserQuestion short-circuited (deny)"
smoke_assert_contains "$OUT_C" 'A human answered your question' "(c) human answer surfaced to the agent"
smoke_assert_contains "$OUT_C" 'light' "(c) the chosen option is carried back"
# The reply file must be consumed so a later question can't be satisfied by it.
if [[ -f "$REPLY_FILE" ]]; then
  smoke_fail "(c) reply file was not consumed after the answer was applied"
fi
smoke_log "ok: (c) bounded in ${ELAPSED}s, chosen option 'light' returned + reply consumed"

# --- (d) guard-not-weakened: every other tool handled identically ----------

smoke_log "(d) non-AskUserQuestion tool handling is byte-identical (guard intact)"
PAYLOAD="$SMOKE_TMP_ROOT/auq-d.json"
# A process-environment dump is denied with the credential reason — this path
# is entirely outside the AskUserQuestion branch and must be unchanged.
write_bash_payload "$PAYLOAD" "env > /tmp/leak"
OUT_D="$(run_pretool_hook "$PAYLOAD")"
smoke_assert_contains "$OUT_D" '"permissionDecision": "deny"' "(d) env-dump still denied"
smoke_assert_contains "$OUT_D" 'credentials are blocked' "(d) credential deny reason preserved"
smoke_assert_not_contains "$OUT_D" 'proceed with your best-judgment default' "(d) Bash deny did NOT route through AUQ fallback"

# A benign read tool must NOT be intercepted at all (no deny, no AUQ audit row).
PAYLOAD="$SMOKE_TMP_ROOT/auq-d2.json"
printf '%s\n' \
  '{' \
  '  "hook_event_name": "PreToolUse",' \
  '  "tool_name": "Read",' \
  "  \"tool_input\": {\"file_path\": \"$BRIDGE_AGENT_HOME_ROOT/$AGENT/notes.md\"}," \
  '  "tool_use_id": "smoke-1569-read",' \
  '  "session_id": "smoke-session"' \
  '}' \
  >"$PAYLOAD"
OUT_D2="$(run_pretool_hook "$PAYLOAD")"
smoke_assert_not_contains "$OUT_D2" '"permissionDecision": "deny"' "(d) benign self-home Read not denied"
smoke_log "ok: (d) guard intact — Bash/Read paths unchanged"

# --- (e) helper-level: total budget is a HARD cap (escalate does NOT stack) -

# Drive the helper with an injected clock + a slow (budget-consuming) escalate
# subprocess, and assert the TOTAL elapsed virtual time never exceeds the
# configured window. This pins codex #1569 r1 finding 2 (escalate time must
# share the deadline budget, not stack on top of the poll window) without a
# real wall-clock wait.
smoke_log "(e) helper-level: escalate time shares the budget, total <= window"
"$PYTHON_BIN" - "$SMOKE_REPO_ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "hooks"))
import askuserquestion_escalate as a
from pathlib import Path
import tempfile

os.environ["BRIDGE_ASKUSERQUESTION_WAIT_SECONDS"] = "30"
state = Path(tempfile.mkdtemp()) / "state"

class Clock:
    def __init__(self): self.t = 0.0
    def now(self): return self.t
    def sleep(self, s): self.t += s

# Force the escalate subprocess to "consume" a big slice of virtual time by
# monkeypatching _post_escalation to advance the clock by its allotted budget.
clk = Clock()
orig_post = a._post_escalation
def slow_post(*, subprocess_timeout, **kw):
    clk.t += subprocess_timeout  # escalate eats its whole (bounded) slice
    return False
a._post_escalation = slow_post

r = a.resolve_escalation(
    {"question": "Pick a low-stakes default?", "options": ["x", "y"]},
    agent="ag-e", state_dir=state, script_dir=Path("/nonexistent"),
    now=clk.now, sleep=clk.sleep,
)
a._post_escalation = orig_post
total = clk.now()
assert total <= 30.0 + 0.01, f"total virtual time {total} exceeded the 30s window"
assert r["decision"] == "proceed_with_note", r
assert r["waited_seconds"] <= 30.0, r
print(f"(e) ok: total virtual elapsed {total:.1f}s <= 30s window; escalate did NOT stack")
PY
smoke_log "ok: (e) escalate time shares the budget — total wall-clock hard-capped"

# --- (f) missing helper still bounds (does NOT fall through to raw picker) ---

# Force the escalation helper to be unavailable (`_auq_escalate = None`, the
# defensive-import outcome on a broken/partial install) and assert the real
# hook STILL short-circuits AskUserQuestion with the bounded proceed-with-note
# fallback rather than letting the raw, UNBOUNDED interactive picker through
# (codex #1569 r1 finding 1). Driven through the hook's own
# handle_pretool/handle_askuserquestion entry points, with the module imported
# (not run as __main__) so we can null out the helper handle.
smoke_log "(f) missing helper -> still bounded (no fall-through to raw picker)"
# Load tool-policy.py by path (hyphenated filename isn't a normal module name)
# and exercise the None-helper branch directly.
OUT_F="$(BRIDGE_AGENT_ID="$AGENT" "$PYTHON_BIN" - "$SMOKE_REPO_ROOT" <<'PY'
import sys, os, json, importlib.util
repo = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "hooks"))
spec = importlib.util.spec_from_file_location(
    "tool_policy_under_test", os.path.join(repo, "hooks", "tool-policy.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
# Simulate the broken/partial install: helper unavailable.
mod._auq_escalate = None
payload = {
    "hook_event_name": "PreToolUse",
    "tool_name": "AskUserQuestion",
    "tool_input": {"question": "Which color theme?", "options": ["dark", "light"]},
    "tool_use_id": "smoke-1569-f",
    "session_id": "smoke-session",
}
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    mod.handle_pretool(payload, os.environ["BRIDGE_AGENT_ID"])
sys.stdout.write(buf.getvalue())
PY
)"
smoke_assert_contains "$OUT_F" '"permissionDecision": "deny"' "(f) missing helper still denies (bounded)"
smoke_assert_contains "$OUT_F" 'proceed with your best-judgment default' "(f) missing helper -> proceed+note fallback"
smoke_log "ok: (f) missing helper bounded via proceed-with-note (no raw fall-through)"

# --- audit trail: each AskUserQuestion intercept wrote exactly one row ------

# (a), (b), (c) each wrote one row through the real hook. (f) ran an imported
# copy of tool-policy.py against the SAME isolated BRIDGE_HOME audit log, so it
# adds a fourth proceed-with-note row. (e) is helper-level only (no hook → no
# row).
AUQ_ROWS="$(count_audit_rows askuserquestion_bounded)"
if (( AUQ_ROWS != 4 )); then
  smoke_fail "expected 4 askuserquestion_bounded audit rows (a,b,c,f), got ${AUQ_ROWS}"
fi
smoke_log "ok: 4 askuserquestion_bounded audit rows recorded"

smoke_log "PASS: $SMOKE_NAME"
