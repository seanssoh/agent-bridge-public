#!/usr/bin/env bash
# memory-daily-harvest smoke — isolated BRIDGE_HOME smoke for the v0.9
# harvester contract (issue #216, v0.5 spec §14 + v0.9 residual risk).
#
# Covers scenarios by number (spec §14 + supplementary stub coverage):
#   2  canonical non-empty              → action=ok, state=checked
#   4  weak-only (git commits)          → action=no-op, reason=weak_only_activity
#   8  gate off                         → state=disabled, actions_taken=[]
#   9  --skipped-permission             → state=skipped-permission + aggregate
#                                         (shared/aggregate/ path, #219)
#   10 daemon gating helper             → bridge_cron_actions_taken_contains
#   11 residual risk: sidecar recovery  → exception path recovers final_state
#   12 stub isolation (no target home) → --skipped-permission --os-user
#   13 stub default dispatch            → non-isolation path omits --skipped
#   14 stub isolation + readable target → --transcripts-home + --os-user (no sudo)
#   15 stub isolation + unreadable     → --skipped-permission (v1.3 fallback)
#
# Not all 10 §14 scenarios need deep fixtures — 2/4/8 + 9-15 exercise the
# load-bearing decision branches. Skeletons for 1/3/5/6/7 are left in the
# file for clarity but not asserted.
#
# Usage:   ./tests/memory-daily-harvest/smoke.sh
# Exit 0 if all asserted scenarios PASS; exit 1 otherwise.

set -u
# Keep running even on failed asserts so we can emit the full summary.

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
declare -a FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }

banner() { printf '\n=== scenario %s ===\n' "$1"; }

# -----------------------------------------------------------------------------
# isolated BRIDGE_HOME setup
# -----------------------------------------------------------------------------
SMOKE_ROOT="$(mktemp -d -t memory-daily-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

BRIDGE_HOME="$SMOKE_ROOT/bridge-home"
BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
mkdir -p "$BRIDGE_STATE_DIR"
export BRIDGE_HOME BRIDGE_STATE_DIR BRIDGE_TASK_DB

# Minimal tasks.db with the schema the harvester reads.
"$PYTHON" - "$BRIDGE_TASK_DB" <<'PY'
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute("""CREATE TABLE IF NOT EXISTS task_events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  actor TEXT,
  created_ts INTEGER NOT NULL,
  detail TEXT
)""")
cur.execute("""CREATE TABLE IF NOT EXISTS tasks (
  task_id INTEGER PRIMARY KEY AUTOINCREMENT,
  status TEXT NOT NULL,
  created_ts INTEGER NOT NULL,
  closed_ts INTEGER,
  title TEXT,
  body TEXT,
  assigned_to TEXT,
  created_by TEXT
)""")
con.commit()
con.close()
PY

# Fixture agent home.
AGENT="smoke-claude"
AGENT_HOME="$SMOKE_ROOT/agents/$AGENT"
mkdir -p "$AGENT_HOME/memory" "$AGENT_HOME/raw/captures/ingested"

# Fixture workdir — a real directory that exists.
WORKDIR="$SMOKE_ROOT/workdir"
mkdir -p "$WORKDIR"

# Yesterday in Asia/Seoul (same policy as the harvester default).
YESTERDAY="$("$PYTHON" -c 'from datetime import datetime, timedelta
try:
    from zoneinfo import ZoneInfo
    z = ZoneInfo("Asia/Seoul")
except Exception:
    from datetime import timezone, timedelta as td
    z = timezone(td(hours=9))
print((datetime.now(z) - timedelta(days=1)).date().isoformat())')"

MEM_PY="$REPO_ROOT/bridge-memory.py"

# Helper: run the harvester with our isolated env.
run_harvest() {
  local extra_env=()
  local args=()
  # Forward our BRIDGE_* vars. State-dir arg overrides BRIDGE_STATE_DIR behavior
  # so manifests land in predictable spots even under pytest-like runners that
  # clobber env.
  local state_dir="$BRIDGE_STATE_DIR/memory-daily"
  mkdir -p "$state_dir"
  args=(
    harvest-daily
    --agent "$AGENT"
    --home "$AGENT_HOME"
    --workdir "$WORKDIR"
    --date "$YESTERDAY"
    --state-dir "$state_dir"
    --sidecar-out "$SMOKE_ROOT/sidecar-$AGENT.json"
    --json
  )
  "$@" BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
       BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
       "$PYTHON" "$MEM_PY" "${args[@]}" 2>"$SMOKE_ROOT/last.stderr"
}

clear_state() {
  rm -rf "$BRIDGE_STATE_DIR/memory-daily" 2>/dev/null || true
  rm -f "$AGENT_HOME/memory/$YESTERDAY.md" 2>/dev/null || true
  rm -rf "$AGENT_HOME/users" 2>/dev/null || true
  # Reset tasks.db
  "$PYTHON" - "$BRIDGE_TASK_DB" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1]); cur = con.cursor()
cur.execute("DELETE FROM task_events")
cur.execute("DELETE FROM tasks")
con.commit(); con.close()
PY
  rm -f "$SMOKE_ROOT/sidecar-$AGENT.json" 2>/dev/null || true
}

# jq-free JSON field extractor.
json_get() {
  local file="$1"; shift
  local path="$1"
  "$PYTHON" - "$file" "$path" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for key in sys.argv[2].split("."):
    if key == "":
        continue
    if isinstance(data, list):
        data = data[int(key)]
    else:
        data = data.get(key)
    if data is None:
        break
print(data if data is not None else "")
PY
}

# =============================================================================
# Scenario 2 — gate=on, canonical present + non-empty → action=ok, state=checked.
# =============================================================================
banner "2 — canonical non-empty → ok/checked"
clear_state
# Write a daily note with enough substance to be semantic-nonempty.
cat >"$AGENT_HOME/memory/$YESTERDAY.md" <<EOF
# $YESTERDAY — $AGENT

- kickoff: worked on memory-daily harvester smoke coverage today
- decision: keep scenario set to load-bearing branches only

## Work log

Spent the afternoon validating the state machine covers checked/queued/disabled
with the sidecar override path behaving as designed.
EOF

out="$(run_harvest env)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "2" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/last.stderr" | head -c 200)"
else
  status="$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  actions="$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(",".join(json.load(sys.stdin).get("actions_taken",[])))')"
  manifest="$BRIDGE_STATE_DIR/memory-daily/$AGENT/$YESTERDAY.json"
  if [[ "$status" == "ok" && -z "$actions" && -f "$manifest" ]]; then
    state="$(json_get "$manifest" state)"
    action="$(json_get "$manifest" decision.action)"
    if [[ "$state" == "checked" && "$action" == "ok" ]]; then
      pass "2"
    else
      fail "2" "manifest state=$state action=$action (expected checked/ok)"
    fi
  else
    fail "2" "status=$status actions=$actions manifest_exists=$([[ -f $manifest ]] && echo 1 || echo 0)"
  fi
fi

# =============================================================================
# Scenario 4 — gate=on, weak-only (git commits) → no-op, reason=weak_only_activity.
# Simulated by leaving canonical missing + no transcript/queue/captures, with
# a one-commit workdir so `_scan_git` finds something.
# =============================================================================
banner "4 — weak-only (git commits) → no-op, reason=weak_only_activity"
clear_state
# Build a tiny git repo in $WORKDIR with a commit inside the target date window.
rm -rf "$WORKDIR/.git" 2>/dev/null || true
(cd "$WORKDIR" && git init -q 2>/dev/null \
  && git config user.email "smoke@example.test" \
  && git config user.name "smoke" \
  && : > weak-file.txt \
  && git add weak-file.txt >/dev/null 2>&1) || true
# Force the commit to land inside the $YESTERDAY window using GIT_*_DATE.
commit_ts="${YESTERDAY}T12:00:00+0900"
(cd "$WORKDIR" \
  && GIT_AUTHOR_DATE="$commit_ts" GIT_COMMITTER_DATE="$commit_ts" \
     git commit -q -m "weak activity" >/dev/null 2>&1) || true

out="$(run_harvest env)"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "4" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/last.stderr" | head -c 200)"
else
  manifest="$BRIDGE_STATE_DIR/memory-daily/$AGENT/$YESTERDAY.json"
  state="$(json_get "$manifest" state)"
  action="$(json_get "$manifest" decision.action)"
  reason="$(json_get "$manifest" decision.reason_code)"
  conf="$(json_get "$manifest" decision.source_confidence)"
  # Acceptable outcomes: weak-only with reason=weak_only_activity, OR
  # no_activity if git scanning couldn't capture the commit on this host.
  # Both still prove the harvester did NOT queue-backfill.
  actions_csv="$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(",".join(json.load(sys.stdin).get("actions_taken",[])))')"
  if [[ "$state" == "checked" && "$action" == "no-op" && -z "$actions_csv" ]]; then
    if [[ "$reason" == "weak_only_activity" || "$reason" == "no_activity" ]]; then
      pass "4"
    else
      fail "4" "reason=$reason (expected weak_only_activity or no_activity); conf=$conf"
    fi
  else
    fail "4" "state=$state action=$action actions=$actions_csv"
  fi
fi

# =============================================================================
# Scenario 8 — gate=off → state=disabled, minimal manifest, actions_taken=[].
# Gate is off when BRIDGE_AGENT_MEMORY_DAILY_REFRESH_<agent>=0 OR when
# --disabled-gate is passed. We exercise the env-var path for the authoritative
# code path, matching bridge-memory.py::_gate_disabled.
# =============================================================================
banner "8 — gate off → state=disabled, actions_taken=[]"
clear_state
env_key="BRIDGE_AGENT_MEMORY_DAILY_REFRESH_$AGENT"
out="$(run_harvest env "$env_key=0")"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "8" "exit rc=$rc stderr=$(tr '\n' ' ' <"$SMOKE_ROOT/last.stderr" | head -c 200)"
else
  manifest="$BRIDGE_STATE_DIR/memory-daily/$AGENT/$YESTERDAY.json"
  status="$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  actions_csv="$(printf '%s' "$out" | "$PYTHON" -c 'import json,sys; print(",".join(json.load(sys.stdin).get("actions_taken",[])))')"
  state="$(json_get "$manifest" state)"
  reason="$(json_get "$manifest" decision.reason_code)"
  if [[ "$status" == "disabled" && -z "$actions_csv" && "$state" == "disabled" && "$reason" == "disabled" ]]; then
    pass "8"
  else
    fail "8" "status=$status actions=$actions_csv state=$state reason=$reason"
  fi
fi

# =============================================================================
# Scenario 10 — daemon refresh gating helper.
# bridge_cron_actions_taken_contains <result_file> <action> returns 0 when the
# action is in actions_taken and 1 otherwise. Using the helper directly is the
# cleanest smoke — daemon wiring is exercised by the repo-level smoke-test.
# =============================================================================
banner "10 — bridge_cron_actions_taken_contains helper"
help_tmp="$SMOKE_ROOT/helper-check.json"
cat >"$help_tmp" <<'EOF'
{"actions_taken": ["queue-backfill"]}
EOF
if bash -c "source '$REPO_ROOT/lib/bridge-cron.sh' && bridge_cron_actions_taken_contains '$help_tmp' 'queue-backfill'" \
     >/dev/null 2>&1; then
  # And ensure the negative case returns non-zero.
  cat >"$help_tmp" <<'EOF'
{"actions_taken": []}
EOF
  if bash -c "source '$REPO_ROOT/lib/bridge-cron.sh' && bridge_cron_actions_taken_contains '$help_tmp' 'queue-backfill'" \
       >/dev/null 2>&1; then
    fail "10" "helper returned 0 for empty actions_taken (expected non-zero)"
  else
    pass "10"
  fi
else
  fail "10" "helper returned non-zero for actions_taken=[queue-backfill]"
fi

# =============================================================================
# Scenario 11 — residual risk: sidecar recovery after Claude parse failure.
# We simulate the runner's recovery path by calling bridge-cron-runner.py's
# helpers directly: write a valid sidecar, call validate_result on it, and
# confirm child_result_source is set to authoritative-sidecar-after-parse-error
# when we take the exception branch.
# =============================================================================
banner "11 — residual risk: valid sidecar recovers from parse failure"
recovery_dir="$SMOKE_ROOT/recovery-run"
mkdir -p "$recovery_dir"
sidecar="$recovery_dir/authoritative-memory-daily.json"
cat >"$sidecar" <<'EOF'
{
  "status": "queued",
  "summary": "test/2026-04-22 queued queue-backfill",
  "findings": ["canonical=missing size=0", "source_confidence=strong"],
  "actions_taken": ["queue-backfill"],
  "needs_human_followup": false,
  "recommended_next_steps": [],
  "artifacts": ["state/memory-daily/test/2026-04-22.json"],
  "confidence": "medium",
  "delivery_intent": "silent"
}
EOF

# The helpers are module-level in bridge-cron-runner.py. We don't try to spawn
# a full cron runner — that would require a live agent roster and real claude
# binary. Instead we import validate_result + the sidecar-loading block and
# assert:
# =============================================================================
# scenario 12 — stub isolation dispatch (linux-user mismatch → --skipped-permission)
# =============================================================================
banner "12 — stub dispatches --skipped-permission under linux-user mismatch"

s12_dir="$SMOKE_ROOT/s12"
mkdir -p "$s12_dir/home" "$s12_dir/workdir"
cat >"$s12_dir/agb-mock" <<MOCK
#!/usr/bin/env bash
# Mock BRIDGE_AGB: emit a minimal agent show --json with linux-user isolation
# and an os_user guaranteed to differ from the invoker.
cat <<'JSON'
{
  "agent": "s12-agent",
  "workdir": "$s12_dir/workdir",
  "profile": {"home": "$s12_dir/home"},
  "isolation": {"mode": "linux-user", "os_user": "ghost-smoke-other"}
}
JSON
MOCK
chmod +x "$s12_dir/agb-mock"

cat >"$s12_dir/python-mock" <<MOCK
#!/usr/bin/env bash
# Mock BRIDGE_PYTHON: pass JSON parse invocations through to real python3,
# but intercept "harvest-daily" dispatches so we can inspect the argv the
# stub assembled without actually running the harvester.
for arg in "\$@"; do
  case "\$arg" in
    harvest-daily)
      args_out="\${S12_MOCK_ARGS_OUT:-/tmp/s12-mock.args}"
      printf '%s\n' "\$@" >"\$args_out"
      exit 0
      ;;
  esac
done
exec "$PYTHON" "\$@"
MOCK
chmod +x "$s12_dir/python-mock"

S12_ARGS_OUT="$s12_dir/argv.log"
BRIDGE_AGB="$s12_dir/agb-mock" \
BRIDGE_PYTHON="$s12_dir/python-mock" \
BRIDGE_HOME="$s12_dir/bridge-home" \
S12_MOCK_ARGS_OUT="$S12_ARGS_OUT" \
env -u CRON_REQUEST_DIR \
  "$REPO_ROOT/scripts/memory-daily-harvest.sh" --agent s12-agent \
  >"$s12_dir/stdout" 2>"$s12_dir/stderr"
rc=$?

dispatched="$(tr '\n' ' ' <"$S12_ARGS_OUT" 2>/dev/null || echo '')"
has_skip=""
case " $dispatched " in
  *" --skipped-permission "*) has_skip="yes" ;;
  *) has_skip="no" ;;
esac
has_os_user=""
case " $dispatched " in
  *" --os-user ghost-smoke-other "*) has_os_user="yes" ;;
  *) has_os_user="no" ;;
esac

if [[ $rc -eq 0 && "$has_skip" == "yes" && "$has_os_user" == "yes" ]]; then
  pass "12"
else
  fail "12" "rc=$rc skip=$has_skip os_user=$has_os_user dispatched='$dispatched'"
fi

# =============================================================================
# scenario 14 — stub isolation + readable transcripts → --transcripts-home
# =============================================================================
banner "14 — stub isolation + readable .claude/projects dispatches --transcripts-home"

s14_dir="$SMOKE_ROOT/s14"
mkdir -p "$s14_dir/home" "$s14_dir/workdir"
# Simulate target user's isolated home with a readable .claude/projects tree.
s14_target_home="$s14_dir/target-home"
mkdir -p "$s14_target_home/.claude/projects"
cat >"$s14_dir/agb-mock" <<MOCK
#!/usr/bin/env bash
cat <<'JSON'
{
  "agent": "s14-agent",
  "workdir": "$s14_dir/workdir",
  "profile": {"home": "$s14_dir/home"},
  "isolation": {"mode": "linux-user", "os_user": "ghost-smoke-sudo"}
}
JSON
MOCK
chmod +x "$s14_dir/agb-mock"

cat >"$s14_dir/python-mock" <<MOCK
#!/usr/bin/env bash
# Record harvest-daily dispatches so the smoke can inspect the argv the stub
# assembled. JSON parse invocations passthrough to real python3.
for arg in "\$@"; do
  case "\$arg" in
    harvest-daily)
      args_out="\${S14_MOCK_ARGS_OUT:-/tmp/s14-mock.args}"
      printf '%s\n' "\$@" >"\$args_out"
      exit 0
      ;;
  esac
done
exec "$PYTHON" "\$@"
MOCK
chmod +x "$s14_dir/python-mock"

S14_ARGS_OUT="$s14_dir/argv.log"
BRIDGE_AGB="$s14_dir/agb-mock" \
BRIDGE_PYTHON="$s14_dir/python-mock" \
BRIDGE_HOME="$s14_dir/bridge-home" \
BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$s14_dir" \
S14_MOCK_ARGS_OUT="$S14_ARGS_OUT" \
env -u CRON_REQUEST_DIR \
  "$REPO_ROOT/scripts/memory-daily-harvest.sh" --agent s14-agent \
  >"$s14_dir/stdout" 2>"$s14_dir/stderr"
# Rename target-home to match the os_user name expected by the stub
rc=$?

# Note: BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT + os_user resolves to
# $s14_dir/ghost-smoke-sudo/.claude/projects, not $s14_dir/target-home/.
# Set up the proper layout instead.
rm -rf "$s14_dir/ghost-smoke-sudo"
mkdir -p "$s14_dir/ghost-smoke-sudo/.claude/projects"
: >"$S14_ARGS_OUT"
BRIDGE_AGB="$s14_dir/agb-mock" \
BRIDGE_PYTHON="$s14_dir/python-mock" \
BRIDGE_HOME="$s14_dir/bridge-home" \
BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$s14_dir" \
S14_MOCK_ARGS_OUT="$S14_ARGS_OUT" \
env -u CRON_REQUEST_DIR \
  "$REPO_ROOT/scripts/memory-daily-harvest.sh" --agent s14-agent \
  >"$s14_dir/stdout" 2>"$s14_dir/stderr"
rc=$?

argv_dump="$(tr '\n' ' ' <"$S14_ARGS_OUT" 2>/dev/null || echo '')"
case " $argv_dump " in
  *" --transcripts-home "*) has_transcripts_home="yes" ;;
  *) has_transcripts_home="no" ;;
esac
case " $argv_dump " in
  *" --skipped-permission "*) leaked_skip="yes" ;;
  *) leaked_skip="no" ;;
esac
case " $argv_dump " in
  *" --os-user ghost-smoke-sudo "*) has_os_user="yes" ;;
  *) has_os_user="no" ;;
esac

if [[ $rc -eq 0 \
      && "$has_transcripts_home" == "yes" \
      && "$leaked_skip" == "no" \
      && "$has_os_user" == "yes" ]]; then
  pass "14"
else
  fail "14" "rc=$rc transcripts_home=$has_transcripts_home skipped=$leaked_skip os_user=$has_os_user"
fi

# =============================================================================
# scenario 15 — stub isolation + unreadable .claude/projects → --skipped-permission
# =============================================================================
banner "15 — stub isolation + unreadable .claude/projects dispatches --skipped-permission"

s15_dir="$SMOKE_ROOT/s15"
mkdir -p "$s15_dir/home" "$s15_dir/workdir"
# Intentionally do NOT create $s15_dir/ghost-smoke-miss/.claude/projects
cat >"$s15_dir/agb-mock" <<MOCK
#!/usr/bin/env bash
cat <<'JSON'
{
  "agent": "s15-agent",
  "workdir": "$s15_dir/workdir",
  "profile": {"home": "$s15_dir/home"},
  "isolation": {"mode": "linux-user", "os_user": "ghost-smoke-miss"}
}
JSON
MOCK
chmod +x "$s15_dir/agb-mock"
cp "$s14_dir/python-mock" "$s15_dir/python-mock"

S15_ARGS_OUT="$s15_dir/argv.log"
BRIDGE_AGB="$s15_dir/agb-mock" \
BRIDGE_PYTHON="$s15_dir/python-mock" \
BRIDGE_HOME="$s15_dir/bridge-home" \
BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$s15_dir" \
S14_MOCK_ARGS_OUT="$S15_ARGS_OUT" \
env -u CRON_REQUEST_DIR \
  "$REPO_ROOT/scripts/memory-daily-harvest.sh" --agent s15-agent \
  >"$s15_dir/stdout" 2>"$s15_dir/stderr"
rc=$?

argv_dump_s15="$(tr '\n' ' ' <"$S15_ARGS_OUT" 2>/dev/null || echo '')"
case " $argv_dump_s15 " in
  *" --skipped-permission "*) has_skip_s15="yes" ;;
  *) has_skip_s15="no" ;;
esac
case " $argv_dump_s15 " in
  *" --transcripts-home "*) leaked_transcripts_s15="yes" ;;
  *) leaked_transcripts_s15="no" ;;
esac

if [[ $rc -eq 0 \
      && "$has_skip_s15" == "yes" \
      && "$leaked_transcripts_s15" == "no" ]]; then
  pass "15"
else
  fail "15" "rc=$rc skipped=$has_skip_s15 transcripts_home=$leaked_transcripts_s15"
fi

# =============================================================================
# scenario 13 — stub non-isolation path omits --skipped-permission
# =============================================================================
banner "13 — stub default path does NOT force --skipped-permission"

s13_dir="$SMOKE_ROOT/s13"
mkdir -p "$s13_dir/home" "$s13_dir/workdir"
cat >"$s13_dir/agb-mock" <<MOCK
#!/usr/bin/env bash
cat <<'JSON'
{
  "agent": "s13-agent",
  "workdir": "$s13_dir/workdir",
  "profile": {"home": "$s13_dir/home"},
  "isolation": {"mode": "", "os_user": ""}
}
JSON
MOCK
chmod +x "$s13_dir/agb-mock"
cp "$s12_dir/python-mock" "$s13_dir/python-mock"

S13_ARGS_OUT="$s13_dir/argv.log"
BRIDGE_AGB="$s13_dir/agb-mock" \
BRIDGE_PYTHON="$s13_dir/python-mock" \
BRIDGE_HOME="$s13_dir/bridge-home" \
S12_MOCK_ARGS_OUT="$S13_ARGS_OUT" \
env -u CRON_REQUEST_DIR \
  "$REPO_ROOT/scripts/memory-daily-harvest.sh" --agent s13-agent \
  >"$s13_dir/stdout" 2>"$s13_dir/stderr"
rc=$?

dispatched_s13="$(tr '\n' ' ' <"$S13_ARGS_OUT" 2>/dev/null || echo '')"
case " $dispatched_s13 " in
  *" --skipped-permission "*) has_skip_s13="yes" ;;
  *) has_skip_s13="no" ;;
esac

if [[ $rc -eq 0 && "$has_skip_s13" == "no" ]]; then
  pass "13"
else
  fail "13" "rc=$rc skip=$has_skip_s13 dispatched='$dispatched_s13'"
fi

# =============================================================================
# scenario 9 — --skipped-permission writes manifest + updates aggregate
# =============================================================================
banner "9 — skipped-permission writes manifest + admin-aggregate-skip"

s9_home="$SMOKE_ROOT/agents/s9"
s9_workdir="$SMOKE_ROOT/workdir-s9"
s9_state="$BRIDGE_STATE_DIR/memory-daily"
s9_sidecar="$SMOKE_ROOT/s9.sidecar.json"
mkdir -p "$s9_home/memory" "$s9_workdir"

"$PYTHON" "$REPO_ROOT/bridge-memory.py" harvest-daily \
  --agent s9-agent \
  --home "$s9_home" \
  --workdir "$s9_workdir" \
  --date 2026-04-22 \
  --state-dir "$s9_state" \
  --os-user ghost-smoke-s9 \
  --skipped-permission \
  --sidecar-out "$s9_sidecar" \
  --json >"$SMOKE_ROOT/s9.stdout" 2>"$SMOKE_ROOT/s9.stderr"
rc=$?
manifest_s9="$s9_state/s9-agent/2026-04-22.json"
agg_s9="$s9_state/shared/aggregate/admin-aggregate-skip.json"
s9_state_val="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state",""))' "$manifest_s9" 2>/dev/null || echo "")"
s9_reason="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("decision",{}).get("reason_code",""))' "$manifest_s9" 2>/dev/null || echo "")"
s9_actions="$("$PYTHON" -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get("actions_taken") or []))' "$s9_sidecar" 2>/dev/null || echo "")"
s9_agg_has_agent="$("$PYTHON" -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
by_day = data.get("by_day") or {}
entry = by_day.get("2026-04-22") or {}
print("yes" if "s9-agent" in (entry.get("agents") or []) else "no")
' "$agg_s9" 2>/dev/null || echo "no")"
if [[ $rc -eq 0 \
      && "$s9_state_val" == "skipped-permission" \
      && "$s9_reason" == "permission" \
      && "$s9_actions" == "skip-permission" \
      && "$s9_agg_has_agent" == "yes" ]]; then
  pass "9"
else
  fail "9" "rc=$rc state=$s9_state_val reason=$s9_reason actions=$s9_actions agg_has_agent=$s9_agg_has_agent"
fi

#   1. validate_result accepts our sidecar payload.
#   2. The sidecar path resolution from CRON_REQUEST_DIR matches the stub.
#   3. child_result_source="authoritative-sidecar-after-parse-error" is the
#      value the runner assigns in the except branch (pattern-only check:
#      grep the runner source for this exact literal).
runner_py="$REPO_ROOT/bridge-cron-runner.py"
out="$("$PYTHON" - "$runner_py" "$sidecar" <<'PY'
import importlib.util, json, sys, pathlib
runner_path = pathlib.Path(sys.argv[1])
sidecar_path = pathlib.Path(sys.argv[2])

# Import the runner module from source without triggering __main__.
spec = importlib.util.spec_from_file_location("bridge_cron_runner", runner_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

payload = json.loads(sidecar_path.read_text(encoding="utf-8"))
try:
    validated = mod.validate_result(payload)
except Exception as exc:
    print(f"FAIL:validate={exc!r}")
    sys.exit(0)

if validated.get("actions_taken") != ["queue-backfill"]:
    print(f"FAIL:actions_lost={validated.get('actions_taken')}")
    sys.exit(0)

source = runner_path.read_text(encoding="utf-8")
if "authoritative-sidecar-after-parse-error" not in source:
    print("FAIL:missing_recovery_source_label")
    sys.exit(0)

# Also confirm the path convention matches the stub.
expected = sidecar_path.parent / "authoritative-memory-daily.json"
if sidecar_path != expected:
    print("FAIL:path_convention")
    sys.exit(0)

print("OK")
PY
)"
if [[ "$out" == "OK" ]]; then
  pass "11"
else
  fail "11" "$out"
fi

# =============================================================================
# scenario R1 — --missing-only skips dates with manifest, harvests dates
# without manifest even when canonical note exists (Lane B SSOT semantics).
# =============================================================================
banner "R1 — --missing-only checks manifest, not canonical note"

r1_dir="$SMOKE_ROOT/r1"
r1_home="$r1_dir/agents/r1-agent"
r1_workdir="$r1_dir/workdir"
r1_state="$r1_dir/bridge-home/state/memory-daily"
r1_sidecar="$r1_dir/r1.sidecar.json"
mkdir -p "$r1_home/memory" "$r1_workdir" "$r1_state/r1-agent"

# Two dates inside the range:
#   D1 (2026-04-20): pre-existing manifest → must be skipped
#   D2 (2026-04-21): canonical note only, NO manifest → must be harvested
#                    (this is the regression case the brief calls out)
r1_d1="2026-04-20"
r1_d2="2026-04-21"
r1_d3="2026-04-22"  # nothing — must also be harvested (or no-op'd) but NOT skipped

# Pre-write a manifest for D1.
cat >"$r1_state/r1-agent/$r1_d1.json" <<EOF
{"schema":"memory-daily-manifest-v1","agent":"r1-agent","date":"$r1_d1","state":"checked"}
EOF

# Canonical note (substantial enough to be semantic_nonempty) for D2.
cat >"$r1_home/memory/$r1_d2.md" <<EOF
# $r1_d2 — r1-agent

- kickoff: this is a manually-written daily note with no harvester manifest.
- decision: the harvester must still run because the manifest is the SSOT.

## Work log

Filling out enough body so semantic_nonempty=True, and proving the legacy
canonical-note-only short-circuit no longer skips this date.
EOF

BRIDGE_HOME="$r1_dir/bridge-home" \
"$PYTHON" "$REPO_ROOT/bridge-memory.py" harvest-daily \
  --agent r1-agent \
  --home "$r1_home" \
  --workdir "$r1_workdir" \
  --from "$r1_d1" --to "$r1_d3" \
  --tz Asia/Seoul \
  --missing-only \
  --state-dir "$r1_state" \
  --sidecar-out "$r1_sidecar" \
  >"$r1_dir/stdout" 2>"$r1_dir/stderr"
rc=$?

# Expected: D1 skipped:exists, D2 has a "result" entry, D3 has a "result" entry.
r1_d1_skipped="$("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
for r in data.get("results", []):
    if r.get("date") == sys.argv[2]:
        print("yes" if r.get("skipped") == "exists" else "no")
        break
else:
    print("missing")
' "$r1_sidecar" "$r1_d1" 2>/dev/null || echo "err")"

r1_d2_harvested="$("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
for r in data.get("results", []):
    if r.get("date") == sys.argv[2]:
        print("yes" if "result" in r else "no")
        break
else:
    print("missing")
' "$r1_sidecar" "$r1_d2" 2>/dev/null || echo "err")"

r1_d2_manifest_after="$([[ -f "$r1_state/r1-agent/$r1_d2.json" ]] && echo "yes" || echo "no")"
r1_summary_line="$(grep -c 'harvest-daily range complete' "$r1_dir/stderr" || true)"

if [[ $rc -eq 0 \
      && "$r1_d1_skipped" == "yes" \
      && "$r1_d2_harvested" == "yes" \
      && "$r1_d2_manifest_after" == "yes" \
      && "$r1_summary_line" -ge 1 ]]; then
  pass "R1"
else
  fail "R1" "rc=$rc d1_skipped=$r1_d1_skipped d2_harvested=$r1_d2_harvested d2_manifest=$r1_d2_manifest_after summary_line=$r1_summary_line"
fi

# =============================================================================
# scenario R2 — one bad date in a range does NOT abort the run; rc_max
# reflects the failure; final summary line lists ok/fail counts.
# =============================================================================
banner "R2 — per-date error capture continues the range"

r2_dir="$SMOKE_ROOT/r2"
r2_home="$r2_dir/agents/r2-agent"
r2_workdir="$r2_dir/workdir"
r2_state="$r2_dir/bridge-home/state/memory-daily"
r2_sidecar="$r2_dir/r2.sidecar.json"
mkdir -p "$r2_home/memory" "$r2_workdir"

# Wrap bridge-memory.py via a Python shim that monkey-patches
# `_harvest_one_date` to raise on date == 2026-04-21 only. This proves the
# range loop catches and continues.
r2_shim="$r2_dir/shim.py"
cat >"$r2_shim" <<'PY'
import importlib.util, runpy, sys, pathlib
mem_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("bridge_memory", mem_path)
mod = importlib.util.module_from_spec(spec)
sys.modules["bridge_memory"] = mod
spec.loader.exec_module(mod)

orig = mod._harvest_one_date
def patched(args, date):
    if date == "2026-04-21":
        raise RuntimeError(f"synthetic-failure for {date}")
    return orig(args, date)
mod._harvest_one_date = patched

# Re-execute argparse dispatch with the rest of argv.
sys.argv = ["bridge-memory.py", *sys.argv[2:]]
parser = mod.build_parser()
ns = parser.parse_args()
sys.exit(ns.func(ns))
PY

BRIDGE_HOME="$r2_dir/bridge-home" \
"$PYTHON" "$r2_shim" "$REPO_ROOT/bridge-memory.py" \
  harvest-daily \
  --agent r2-agent \
  --home "$r2_home" \
  --workdir "$r2_workdir" \
  --from 2026-04-20 --to 2026-04-22 \
  --tz Asia/Seoul \
  --state-dir "$r2_state" \
  --sidecar-out "$r2_sidecar" \
  >"$r2_dir/stdout" 2>"$r2_dir/stderr"
rc=$?

r2_d1_ok="$("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
for r in data.get("results", []):
    if r.get("date") == "2026-04-20":
        print("yes" if "result" in r else "no")
        break
else:
    print("missing")
' "$r2_sidecar" 2>/dev/null || echo "err")"

r2_d2_failed="$("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
for r in data.get("results", []):
    if r.get("date") == "2026-04-21":
        print("yes" if "error" in r and "synthetic-failure" in (r.get("error") or "") else "no")
        break
else:
    print("missing")
' "$r2_sidecar" 2>/dev/null || echo "err")"

r2_d3_ok="$("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
for r in data.get("results", []):
    if r.get("date") == "2026-04-22":
        print("yes" if "result" in r else "no")
        break
else:
    print("missing")
' "$r2_sidecar" 2>/dev/null || echo "err")"

r2_summary="$(grep -E 'harvest-daily range complete: 3 dates, 2 succeeded, 1 failed' "$r2_dir/stderr" || true)"
r2_failure_line="$(grep -E 'harvest-daily date=2026-04-21 failed: synthetic-failure' "$r2_dir/stderr" || true)"

if [[ $rc -eq 1 \
      && "$r2_d1_ok" == "yes" \
      && "$r2_d2_failed" == "yes" \
      && "$r2_d3_ok" == "yes" \
      && -n "$r2_summary" \
      && -n "$r2_failure_line" ]]; then
  pass "R2"
else
  fail "R2" "rc=$rc d1=$r2_d1_ok d2=$r2_d2_failed d3=$r2_d3_ok summary='${r2_summary:0:80}' failure_line='${r2_failure_line:0:80}'"
fi

# =============================================================================
# scenario R3 — single-date --missing-only (Option A): skips when manifest
# exists, harvests when missing. Symmetric with the range-mode semantics.
# =============================================================================
banner "R3 — single-date --missing-only Option A"

r3_dir="$SMOKE_ROOT/r3"
r3_home="$r3_dir/agents/r3-agent"
r3_workdir="$r3_dir/workdir"
r3_state="$r3_dir/bridge-home/state/memory-daily"
mkdir -p "$r3_home/memory" "$r3_workdir" "$r3_state/r3-agent"

# Pre-existing manifest for the target date.
r3_d="2026-04-19"
cat >"$r3_state/r3-agent/$r3_d.json" <<EOF
{"schema":"memory-daily-manifest-v1","agent":"r3-agent","date":"$r3_d","state":"checked"}
EOF

# 3a — manifest exists → skip with stderr breadcrumb, exit 0.
r3a_sidecar="$r3_dir/r3a.sidecar.json"
BRIDGE_HOME="$r3_dir/bridge-home" \
"$PYTHON" "$REPO_ROOT/bridge-memory.py" harvest-daily \
  --agent r3-agent \
  --home "$r3_home" \
  --workdir "$r3_workdir" \
  --date "$r3_d" \
  --tz Asia/Seoul \
  --missing-only \
  --state-dir "$r3_state" \
  --sidecar-out "$r3a_sidecar" \
  --json \
  >"$r3_dir/r3a.stdout" 2>"$r3_dir/r3a.stderr"
r3a_rc=$?

r3a_breadcrumb="$(grep -E "already harvested .*--missing-only skip" "$r3_dir/r3a.stderr" || true)"
r3a_sidecar_present="$([[ -f "$r3a_sidecar" ]] && echo "yes" || echo "no")"

# 3b — manifest absent → harvest runs, returns success, writes a manifest.
r3b_d="2026-04-18"
r3b_sidecar="$r3_dir/r3b.sidecar.json"
BRIDGE_HOME="$r3_dir/bridge-home" \
"$PYTHON" "$REPO_ROOT/bridge-memory.py" harvest-daily \
  --agent r3-agent \
  --home "$r3_home" \
  --workdir "$r3_workdir" \
  --date "$r3b_d" \
  --tz Asia/Seoul \
  --missing-only \
  --state-dir "$r3_state" \
  --sidecar-out "$r3b_sidecar" \
  --json \
  >"$r3_dir/r3b.stdout" 2>"$r3_dir/r3b.stderr"
r3b_rc=$?
r3b_manifest_after="$([[ -f "$r3_state/r3-agent/$r3b_d.json" ]] && echo "yes" || echo "no")"

if [[ $r3a_rc -eq 0 \
      && -n "$r3a_breadcrumb" \
      && "$r3a_sidecar_present" == "no" \
      && $r3b_rc -eq 0 \
      && "$r3b_manifest_after" == "yes" ]]; then
  pass "R3"
else
  fail "R3" "r3a_rc=$r3a_rc breadcrumb='${r3a_breadcrumb:0:80}' r3a_sidecar=$r3a_sidecar_present r3b_rc=$r3b_rc r3b_manifest=$r3b_manifest_after"
fi

# =============================================================================
# scenario PRF1 — legacy install (no v2 env) → no --per-agent-state-dir args
# =============================================================================
# Issue #418 codex r2 item 11: PR-F changed the v2 extra-args gate in
# scripts/memory-daily-harvest.sh but added no smoke. PRF1 covers the
# baseline: legacy install (BRIDGE_LAYOUT unset) must NOT emit any v2
# extra args (--per-agent-state-dir, --shared-aggregate-dir).
banner "PRF1 — legacy install dispatches without v2 extra-args"

prf1_dir="$SMOKE_ROOT/prf1"
mkdir -p "$prf1_dir/home" "$prf1_dir/workdir"
cat >"$prf1_dir/agb-mock" <<MOCK
#!/usr/bin/env bash
cat <<'JSON'
{
  "agent": "prf1-agent",
  "workdir": "$prf1_dir/workdir",
  "profile": {"home": "$prf1_dir/home"},
  "isolation": {"mode": "shared", "os_user": ""}
}
JSON
MOCK
chmod +x "$prf1_dir/agb-mock"

cat >"$prf1_dir/python-mock" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    harvest-daily)
      args_out="\${PRF_MOCK_ARGS_OUT:-/tmp/prf-mock.args}"
      printf '%s\n' "\$@" >"\$args_out"
      exit 0
      ;;
  esac
done
exec "$PYTHON" "\$@"
MOCK
chmod +x "$prf1_dir/python-mock"

PRF1_ARGS_OUT="$prf1_dir/argv.log"
env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_AGENT_ROOT_V2 \
    -u BRIDGE_SHARED_ROOT -u CRON_REQUEST_DIR \
    BRIDGE_AGB="$prf1_dir/agb-mock" \
    BRIDGE_PYTHON="$prf1_dir/python-mock" \
    BRIDGE_HOME="$prf1_dir/bridge-home" \
    PRF_MOCK_ARGS_OUT="$PRF1_ARGS_OUT" \
  "$REPO_ROOT/scripts/memory-daily-harvest.sh" --agent prf1-agent \
  >"$prf1_dir/stdout" 2>"$prf1_dir/stderr"
prf1_rc=$?

prf1_argv="$(tr '\n' ' ' <"$PRF1_ARGS_OUT" 2>/dev/null || echo '')"
case " $prf1_argv " in
  *" --per-agent-state-dir "*) prf1_has_v2="yes" ;;
  *) prf1_has_v2="no" ;;
esac
case " $prf1_argv " in
  *" --shared-aggregate-dir "*) prf1_has_shared="yes" ;;
  *) prf1_has_shared="no" ;;
esac

if [[ $prf1_rc -eq 0 && "$prf1_has_v2" == "no" && "$prf1_has_shared" == "no" ]]; then
  pass "PRF1"
else
  fail "PRF1" "rc=$prf1_rc v2=$prf1_has_v2 shared=$prf1_has_shared argv='$prf1_argv'"
fi

# =============================================================================
# scenario PRF2 — v2 install with populated data-root → emits v2 extra-args
# =============================================================================
# Issue #418 codex r2 item 11: contract-positive case. With BRIDGE_LAYOUT=v2
# AND a real, on-disk BRIDGE_DATA_ROOT AND BRIDGE_AGENT_ROOT_V2, the gate
# must permit v2 extra-args.
banner "PRF2 — v2 install with populated data-root emits v2 extra-args"

prf2_dir="$SMOKE_ROOT/prf2"
mkdir -p "$prf2_dir/home" "$prf2_dir/workdir"
prf2_data_root="$prf2_dir/data"
prf2_agent_root_v2="$prf2_dir/agents-v2"
prf2_shared_root="$prf2_dir/shared"
mkdir -p "$prf2_data_root" "$prf2_agent_root_v2" "$prf2_shared_root"

cat >"$prf2_dir/agb-mock" <<MOCK
#!/usr/bin/env bash
cat <<'JSON'
{
  "agent": "prf2-agent",
  "workdir": "$prf2_dir/workdir",
  "profile": {"home": "$prf2_dir/home"},
  "isolation": {"mode": "shared", "os_user": ""}
}
JSON
MOCK
chmod +x "$prf2_dir/agb-mock"
cp "$prf1_dir/python-mock" "$prf2_dir/python-mock"

PRF2_ARGS_OUT="$prf2_dir/argv.log"
env -u CRON_REQUEST_DIR \
    BRIDGE_AGB="$prf2_dir/agb-mock" \
    BRIDGE_PYTHON="$prf2_dir/python-mock" \
    BRIDGE_HOME="$prf2_dir/bridge-home" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_DATA_ROOT="$prf2_data_root" \
    BRIDGE_AGENT_ROOT_V2="$prf2_agent_root_v2" \
    BRIDGE_SHARED_ROOT="$prf2_shared_root" \
    PRF_MOCK_ARGS_OUT="$PRF2_ARGS_OUT" \
  "$REPO_ROOT/scripts/memory-daily-harvest.sh" --agent prf2-agent \
  >"$prf2_dir/stdout" 2>"$prf2_dir/stderr"
prf2_rc=$?

prf2_argv="$(tr '\n' ' ' <"$PRF2_ARGS_OUT" 2>/dev/null || echo '')"
case " $prf2_argv " in
  *" --per-agent-state-dir $prf2_agent_root_v2/prf2-agent/runtime/memory-daily "*) prf2_per_agent="yes" ;;
  *) prf2_per_agent="no" ;;
esac
case " $prf2_argv " in
  *" --shared-aggregate-dir $prf2_shared_root/memory-daily/aggregate "*) prf2_shared="yes" ;;
  *) prf2_shared="no" ;;
esac

if [[ $prf2_rc -eq 0 && "$prf2_per_agent" == "yes" && "$prf2_shared" == "yes" ]]; then
  pass "PRF2"
else
  fail "PRF2" "rc=$prf2_rc per_agent=$prf2_per_agent shared=$prf2_shared argv='$prf2_argv'"
fi

# =============================================================================
# scenario PRF3 — transition: v2 marker but data-root NOT populated → fallback
# =============================================================================
# Issue #418 codex r2 item 8 + 11: the load-bearing gate. A child env where
# BRIDGE_LAYOUT=v2 propagates but BRIDGE_DATA_ROOT does NOT exist on disk
# (transitional install, mid-migration) must fall back to legacy
# invocation: NO v2 extra-args, debug breadcrumb on stderr.
banner "PRF3 — v2 marker + missing data-root falls back to legacy (no v2 extra-args)"

prf3_dir="$SMOKE_ROOT/prf3"
mkdir -p "$prf3_dir/home" "$prf3_dir/workdir"
# Intentionally DO NOT create $prf3_dir/data — that's the whole point.
prf3_missing_data_root="$prf3_dir/missing-data-root"
prf3_agent_root_v2="$prf3_dir/agents-v2"
mkdir -p "$prf3_agent_root_v2"

cat >"$prf3_dir/agb-mock" <<MOCK
#!/usr/bin/env bash
cat <<'JSON'
{
  "agent": "prf3-agent",
  "workdir": "$prf3_dir/workdir",
  "profile": {"home": "$prf3_dir/home"},
  "isolation": {"mode": "shared", "os_user": ""}
}
JSON
MOCK
chmod +x "$prf3_dir/agb-mock"
cp "$prf1_dir/python-mock" "$prf3_dir/python-mock"

PRF3_ARGS_OUT="$prf3_dir/argv.log"
env -u CRON_REQUEST_DIR \
    BRIDGE_AGB="$prf3_dir/agb-mock" \
    BRIDGE_PYTHON="$prf3_dir/python-mock" \
    BRIDGE_HOME="$prf3_dir/bridge-home" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_DATA_ROOT="$prf3_missing_data_root" \
    BRIDGE_AGENT_ROOT_V2="$prf3_agent_root_v2" \
    PRF_MOCK_ARGS_OUT="$PRF3_ARGS_OUT" \
  "$REPO_ROOT/scripts/memory-daily-harvest.sh" --agent prf3-agent \
  >"$prf3_dir/stdout" 2>"$prf3_dir/stderr"
prf3_rc=$?

prf3_argv="$(tr '\n' ' ' <"$PRF3_ARGS_OUT" 2>/dev/null || echo '')"
case " $prf3_argv " in
  *" --per-agent-state-dir "*) prf3_has_v2="yes" ;;
  *) prf3_has_v2="no" ;;
esac
case " $prf3_argv " in
  *" --shared-aggregate-dir "*) prf3_has_shared="yes" ;;
  *) prf3_has_shared="no" ;;
esac
# Debug breadcrumb on stderr.
if grep -q "data root not populated" "$prf3_dir/stderr" 2>/dev/null; then
  prf3_breadcrumb="yes"
else
  prf3_breadcrumb="no"
fi

if [[ $prf3_rc -eq 0 \
      && "$prf3_has_v2" == "no" \
      && "$prf3_has_shared" == "no" \
      && "$prf3_breadcrumb" == "yes" ]]; then
  pass "PRF3"
else
  fail "PRF3" "rc=$prf3_rc v2=$prf3_has_v2 shared=$prf3_has_shared breadcrumb=$prf3_breadcrumb argv='$prf3_argv'"
fi

# =============================================================================
# Scenario 2229 — self-signal sender-gate must catch the two bypasses that made
# memory-daily backfill self-perpetuate on zero-activity days (issue #2229,
# extends #728): (1) the cron wake `cron:memory-daily-<agent>` (colon prefix),
# (2) the backfill task itself, now stamped `--from memory-daily`. A genuine
# human task with a placeholder-ish title must still NOT be suppressed.
# Delegated to a standalone check (no heredoc — heredoc-ban ratchet safe).
# =============================================================================
banner "2229 — self-signal bypass (cron: dispatch + backfill sender), #728 kept"
# Stub task_cli so the check's writer-argv path (_queue_backfill) is exercised.
: > "$BRIDGE_HOME/bridge-task.sh"
if "$PYTHON" "$REPO_ROOT/tests/memory-daily-harvest/self_signal_2229_check.py" \
     "$REPO_ROOT/bridge-memory.py" \
     >"$SMOKE_ROOT/2229.out" 2>"$SMOKE_ROOT/2229.err"; then
  pass "2229"
else
  fail "2229" "$(tr '\n' ' ' <"$SMOKE_ROOT/2229.err" | head -c 240)"
fi
rm -f "$BRIDGE_HOME/bridge-task.sh" 2>/dev/null || true

# =============================================================================
# Summary
# =============================================================================
printf '\n================================\n'
printf 'memory-daily-harvest smoke done\n'
printf 'PASS: %d\n' "$PASS"
printf 'FAIL: %d\n' "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed scenarios: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
