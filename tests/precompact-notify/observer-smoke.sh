#!/usr/bin/env bash
# precompact-notify observer + send primitive smoke — issue #597 Track B.
#
# Exercises:
#   - hooks/pre-compact.py marker write under an isolated BRIDGE_HOME.
#   - hooks/session_start.py compact-matcher completion marker.
#   - bridge-channels.py render-precompact-message (en + ko, notice + followup).
#   - bridge-channels.py send-managed-message --dry-run (Discord + Telegram).
#   - bridge-channels.py record-precompact-completion (EMA stats schema).
#   - bridge-daemon.sh process_precompact_events end-to-end with a mocked
#     activity index + dry-run sender, verifying:
#       * pending-state JSON is written
#       * precompact-notice-last-ts / -last-event-id dedup files appear
#       * processed/<event_id>.json marker is moved
#       * precompact_notice_sent audit row lands
#       * a completed marker triggers a precompact_followup_sent audit + EMA update
#
# Track B does NOT register this in scripts/smoke-test.sh — Track D wires
# the full precompact-notify suite once the writers + TS plugin extensions
# are in place.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"
DAEMON="$REPO_ROOT/bridge-daemon.sh"
CHANNELS_PY="$REPO_ROOT/bridge-channels.py"
PRECOMPACT_HOOK="$REPO_ROOT/hooks/pre-compact.py"
SESSION_START_HOOK="$REPO_ROOT/hooks/session_start.py"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi
for f in "$DAEMON" "$CHANNELS_PY" "$PRECOMPACT_HOOK" "$SESSION_START_HOOK"; do
  if [[ ! -f "$f" ]]; then
    printf '[smoke][error] required file missing: %s\n' "$f" >&2
    exit 2
  fi
done

ROOT="$(mktemp -d -t precompact-observer.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '[smoke][fail] %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/[smoke][fail][detail]   /' >&2
  fi
}

# -- T1: hooks/pre-compact.py writes a started marker -------------------------

t1_started_marker() {
  local home="$ROOT/t1-home"
  local state_dir="$home/state"
  mkdir -p "$home/agents/dev"

  # Empty stdin payload — hook should still write a marker with trigger=unknown
  # (we then test trigger=auto explicitly below). bridge-memory.py absent =>
  # the existing capture path is a no-op, but the marker write should still happen.
  local payload='{"trigger": "auto"}'
  local out
  out="$(BRIDGE_HOME="$home" BRIDGE_STATE_DIR="$state_dir" BRIDGE_AGENT_ID=dev \
    BRIDGE_AGENT_HOME="$home/agents/dev" \
    "$PYTHON" "$PRECOMPACT_HOOK" 2>&1 <<<"$payload")"
  local rc=$?
  if (( rc != 0 )); then
    fail "T1 pre-compact hook should exit 0" "rc=$rc out=$out"
    return
  fi

  local started_count
  started_count="$(find "$state_dir/precompact-events/dev/started" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$started_count" != "1" ]]; then
    fail "T1 expected exactly 1 started marker; got $started_count" \
         "$(ls -la "$state_dir/precompact-events/dev/started" 2>/dev/null || true)"
    return
  fi

  local marker
  marker="$(find "$state_dir/precompact-events/dev/started" -name '*.json')"
  local trigger
  trigger="$("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("trigger") or "")
' "$marker")"
  if [[ "$trigger" != "auto" ]]; then
    fail "T1 marker trigger should be 'auto'; got '$trigger'"
    return
  fi
  pass "T1 hooks/pre-compact.py writes started marker (trigger=auto)"
}

# -- T2: hooks/session_start.py writes a completed marker on compact -----------

t2_completed_marker() {
  local home="$ROOT/t2-home"
  local state_dir="$home/state"
  mkdir -p "$home/agents/dev" "$state_dir"

  local payload='{"matcher": "compact"}'
  local out
  out="$(BRIDGE_HOME="$home" BRIDGE_STATE_DIR="$state_dir" BRIDGE_AGENT_ID=dev \
    "$PYTHON" "$SESSION_START_HOOK" 2>&1 <<<"$payload")"
  local rc=$?
  if (( rc != 0 )); then
    fail "T2 session_start hook should exit 0" "rc=$rc out=$out"
    return
  fi

  local count
  count="$(find "$state_dir/precompact-events/dev/completed" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" != "1" ]]; then
    fail "T2 expected exactly 1 completed marker; got $count"
    return
  fi
  pass "T2 hooks/session_start.py writes completed marker on compact matcher"
}

# -- T3: bridge-channels.py render-precompact-message (en + ko) ---------------

t3_render_templates() {
  local state_dir="$ROOT/t3-state"
  mkdir -p "$state_dir"

  local out
  out="$("$PYTHON" "$CHANNELS_PY" render-precompact-message \
    --agent dev --kind notice --lang en \
    --plugin discord --channel-id ch1 --trigger auto \
    --expected-seconds 60 \
    --bridge-state-dir "$state_dir" \
    --format json)"
  if ! grep -q '"BODY"' <<<"$out"; then
    fail "T3 render notice/en should emit BODY field" "$out"
    return
  fi
  if ! grep -q 'compacting' <<<"$out"; then
    fail "T3 render notice/en should include 'compacting'" "$out"
    return
  fi

  local out_ko
  out_ko="$("$PYTHON" "$CHANNELS_PY" render-precompact-message \
    --agent dev --kind notice --lang ko \
    --plugin telegram --channel-id ch2 --trigger auto \
    --expected-seconds 45 \
    --bridge-state-dir "$state_dir" \
    --format json)"
  # Korean template includes "압축" (compaction). Match via python in case grep
  # locale acts up on macOS.
  local has_ko
  has_ko="$("$PYTHON" -c '
import json, sys
data = json.loads(sys.argv[1])
print("ok" if "압축" in data.get("BODY", "") else "no")
' "$out_ko")"
  if [[ "$has_ko" != "ok" ]]; then
    fail "T3 render notice/ko should include 압축" "$out_ko"
    return
  fi

  local out_followup
  out_followup="$("$PYTHON" "$CHANNELS_PY" render-precompact-message \
    --agent dev --kind followup --lang en \
    --plugin discord --channel-id ch1 \
    --duration-seconds 30 \
    --bridge-state-dir "$state_dir" \
    --format json)"
  if ! grep -q 'back online' <<<"$out_followup"; then
    fail "T3 render followup/en should include 'back online'" "$out_followup"
    return
  fi
  pass "T3 render-precompact-message renders en + ko notice + followup"
}

# -- T4: bridge-channels.py send-managed-message --dry-run --------------------

t4_send_dry_run() {
  local home="$ROOT/t4-home"
  local state_dir="$home/state"
  mkdir -p "$home" "$state_dir"

  local out
  out="$("$PYTHON" "$CHANNELS_PY" send-managed-message \
    --plugin discord --agent dev --channel-id 1234 \
    --reply-to-message-id 9999 \
    --body 'hello' --kind notice \
    --bridge-home "$home" --bridge-state-dir "$state_dir" \
    --format shell --dry-run)"
  if ! grep -q '^CHANNEL_SEND_STATUS="ok"' <<<"$out"; then
    fail "T4 send --dry-run should emit CHANNEL_SEND_STATUS=ok" "$out"
    return
  fi
  if ! grep -q '^CHANNEL_SEND_DRY_RUN="1"' <<<"$out"; then
    fail "T4 send --dry-run should emit CHANNEL_SEND_DRY_RUN=1" "$out"
    return
  fi
  if ! grep -q '^CHANNEL_SEND_MESSAGE_ID="dryrun-' <<<"$out"; then
    fail "T4 send --dry-run should emit a dryrun-* synthetic message id" "$out"
    return
  fi
  pass "T4 send-managed-message --dry-run emits CHANNEL_SEND_* envelope"
}

# -- T5: record-precompact-completion seeds EMA stats -------------------------

t5_record_ema() {
  local state_dir="$ROOT/t5-state"
  mkdir -p "$state_dir"

  # First sample: duration 60s with alpha=0.5 should set ema_seconds == 60.
  "$PYTHON" "$CHANNELS_PY" record-precompact-completion \
    --agent dev --trigger auto \
    --started-ts 1000 --completed-ts 1060 \
    --alpha 0.5 \
    --bridge-state-dir "$state_dir" \
    --format json >/dev/null

  # Second sample: duration 30s with alpha=0.5 should produce ema = 0.5*30 + 0.5*60 = 45.
  local out
  out="$("$PYTHON" "$CHANNELS_PY" record-precompact-completion \
    --agent dev --trigger auto \
    --started-ts 2000 --completed-ts 2030 \
    --alpha 0.5 \
    --bridge-state-dir "$state_dir" \
    --format json)"
  local expected
  expected="$("$PYTHON" -c '
import json, sys
data = json.loads(sys.argv[1])
print(data["EXPECTED_SECONDS"])
' "$out")"
  if [[ "$expected" != "45" ]]; then
    fail "T5 EMA expected_seconds should be 45 after two samples; got $expected" "$out"
    return
  fi

  # Verify schema version + agent block on disk.
  local schema_ok
  schema_ok="$("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
ok = (
    data.get("schema_version") == 1
    and isinstance(data.get("agents"), dict)
    and "dev" in data["agents"]
    and data["agents"]["dev"].get("auto_count") == 2
)
print("ok" if ok else "fail")
' "$state_dir/precompact-stats.json")"
  if [[ "$schema_ok" != "ok" ]]; then
    fail "T5 stats file schema/agent count mismatch"
    return
  fi
  pass "T5 record-precompact-completion seeds EMA stats with alpha=0.5"
}

# -- T6: end-to-end daemon observer with mocked activity index + dry-run send -

t6_observer_e2e() {
  local home="$ROOT/t6-home"
  local state_dir="$home/state"
  local agent="dev"
  local plugin="discord"
  local channel_id="111111"
  local message_id="222222"

  mkdir -p "$home" "$state_dir/agents/$agent"
  mkdir -p "$state_dir/channels/$plugin"

  # Mock the activity index Track A's primitive consumes.
  local now_ts
  now_ts="$(date +%s)"
  "$PYTHON" -c '
import json, sys
now = int(sys.argv[1])
data = {
    "schema_version": 1,
    "agent": "dev",
    "plugin": "discord",
    "updated_ts": now,
    "channels": {
        sys.argv[2]: {
            "channel_id": sys.argv[2],
            "reply_kind": "thread",
            "last_seen_id": sys.argv[3],
            "last_seen_ts": now,
            "last_user_inbound_ts": now,
            "last_user_inbound_ts_ms": now * 1000,
            "last_user_inbound_message_id": sys.argv[3],
            "last_user_inbound_user_id": "user1",
            "last_user_inbound_recorded_ns": now * 1_000_000_000,
        }
    },
}
with open(sys.argv[4], "w") as fh:
    json.dump(data, fh)
' "$now_ts" "$channel_id" "$message_id" "$state_dir/channels/$plugin/$agent.json"

  # Build a minimal roster snapshot the daemon can source. We bypass
  # bridge_load_roster by supplying BRIDGE_AGENT_ENV_FILE so the scoped path
  # bridge-state.sh:1260+ uses fires; that loads the env file directly and
  # skips reading the public roster.
  cat >"$home/agent-env.sh" <<EOF
declare -ga BRIDGE_AGENT_IDS=("$agent")
declare -gA BRIDGE_AGENT_ENGINE=([${agent}]="claude")
declare -gA BRIDGE_AGENT_SOURCE=([${agent}]="static")
declare -gA BRIDGE_AGENT_CHANNELS=([${agent}]="plugin:${plugin}")
declare -gA BRIDGE_AGENT_DESC=([${agent}]="t6 fixture")
declare -gA BRIDGE_AGENT_SESSION=([${agent}]="$agent")
declare -gA BRIDGE_AGENT_PRECOMPACT_NOTIFY=([${agent}]="1")
declare -gA BRIDGE_AGENT_PRECOMPACT_NOTIFY_LANG=([${agent}]="en")
EOF

  # Drop a started marker as if hooks/pre-compact.py just ran.
  mkdir -p "$state_dir/precompact-events/$agent/started"
  local event_id
  event_id="$(date +%s%N | head -c 18)-deadbeef"
  cat >"$state_dir/precompact-events/$agent/started/$event_id.json" <<EOF
{
  "schema_version": "1",
  "event_id": "$event_id",
  "agent": "$agent",
  "trigger": "auto",
  "raw_trigger": "auto",
  "started_ts": $now_ts,
  "started_iso": "1970-01-01T00:00:00+00:00",
  "hook_pid": 1
}
EOF

  # Run the daemon's sync cycle once with the dry-run sender enabled.
  # `env -i` scrubs the parent's leaked BRIDGE_* exports (the test harness
  # runs inside a live agent-bridge session where BRIDGE_HOME/STATE_DIR/etc.
  # point at the real runtime — without -i those leak into the daemon and
  # writes land under the live install instead of the test BRIDGE_HOME).
  local daemon_out
  daemon_out="$(env -i \
    PATH="$PATH" HOME="$HOME" \
    BRIDGE_HOME="$home" \
    BRIDGE_STATE_DIR="$state_dir" \
    BRIDGE_AGENT_ENV_FILE="$home/agent-env.sh" \
    BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN=1 \
    BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS=3600 \
    BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 \
    BRIDGE_DISCORD_RELAY_ENABLED=0 \
    BRIDGE_CRON_SYNC_ENABLED=0 \
    bash "$DAEMON" sync 2>&1)" || true

  # Pending file should exist and reference our event_id.
  local pending="$state_dir/agents/$agent/precompact-notice-pending.json"
  if [[ ! -f "$pending" ]]; then
    fail "T6 expected precompact-notice-pending.json after notice send" \
         "daemon_out=$daemon_out"
    return
  fi

  local stored_event_id
  stored_event_id="$("$PYTHON" -c '
import json, sys
print(json.load(open(sys.argv[1])).get("event_id") or "")
' "$pending")"
  if [[ "$stored_event_id" != "$event_id" ]]; then
    fail "T6 pending event_id mismatch (expected $event_id; got $stored_event_id)"
    return
  fi

  # Dedup state should be present.
  if [[ ! -f "$state_dir/agents/$agent/precompact-notice-last-ts" ]]; then
    fail "T6 expected precompact-notice-last-ts dedup file"
    return
  fi
  if [[ ! -f "$state_dir/agents/$agent/precompact-notice-last-event-id" ]]; then
    fail "T6 expected precompact-notice-last-event-id dedup file"
    return
  fi

  # Started marker should have moved to processed/.
  local processed_marker="$state_dir/precompact-events/$agent/processed/$event_id.json"
  if [[ ! -f "$processed_marker" ]]; then
    fail "T6 expected started marker to move to processed/"
    return
  fi

  # Audit row: precompact_notice_sent.
  local audit_log="$home/logs/audit.jsonl"
  if [[ ! -f "$audit_log" ]]; then
    fail "T6 expected audit log at $audit_log"
    return
  fi
  if ! grep -q precompact_notice_sent "$audit_log"; then
    fail "T6 expected precompact_notice_sent audit row" "$(cat "$audit_log")"
    return
  fi

  # Drop a completed marker; second daemon cycle should send the followup.
  mkdir -p "$state_dir/precompact-events/$agent/completed"
  local completed_ts=$((now_ts + 25))
  cat >"$state_dir/precompact-events/$agent/completed/${completed_ts}-1.json" <<EOF
{
  "schema_version": "1",
  "agent": "$agent",
  "completed_ts": $completed_ts,
  "completed_iso": "1970-01-01T00:00:00+00:00",
  "hook_pid": 1,
  "matcher": "compact"
}
EOF

  env -i \
    PATH="$PATH" HOME="$HOME" \
    BRIDGE_HOME="$home" \
    BRIDGE_STATE_DIR="$state_dir" \
    BRIDGE_AGENT_ENV_FILE="$home/agent-env.sh" \
    BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN=1 \
    BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS=3600 \
    BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 \
    BRIDGE_DISCORD_RELAY_ENABLED=0 \
    BRIDGE_CRON_SYNC_ENABLED=0 \
    bash "$DAEMON" sync >/dev/null 2>&1 || true

  if ! grep -q precompact_followup_sent "$audit_log"; then
    fail "T6 expected precompact_followup_sent audit row" "$(cat "$audit_log")"
    return
  fi

  # Pending should now be archived under precompact-notice-history/.
  local history="$state_dir/agents/$agent/precompact-notice-history/$event_id.json"
  if [[ ! -f "$history" ]]; then
    fail "T6 expected pending state to be archived to history/"
    return
  fi
  if [[ -f "$pending" ]]; then
    fail "T6 expected pending file to be removed after followup"
    return
  fi

  # Stats file should reflect the recorded duration.
  local duration_ok
  duration_ok="$("$PYTHON" -c '
import json, sys
data = json.load(open(sys.argv[1]))
agent = data.get("agents", {}).get("dev", {})
print("ok" if agent.get("count", 0) >= 1 else "fail")
' "$state_dir/precompact-stats.json" 2>/dev/null || echo fail)"
  if [[ "$duration_ok" != "ok" ]]; then
    fail "T6 precompact-stats.json should reflect at least one sample"
    return
  fi
  pass "T6 daemon observer: notice -> pending -> followup -> history (dry-run)"
}

# -- T7: kill switch suppresses sends -----------------------------------------

t7_kill_switch() {
  local home="$ROOT/t7-home"
  local state_dir="$home/state"
  local agent="dev"
  local plugin="discord"
  local channel_id="333"

  mkdir -p "$home" "$state_dir/agents/$agent" "$state_dir/channels/$plugin"

  local now_ts
  now_ts="$(date +%s)"
  "$PYTHON" -c '
import json, sys
now = int(sys.argv[1])
data = {
    "schema_version": 1, "agent": "dev", "plugin": "discord", "updated_ts": now,
    "channels": {sys.argv[2]: {
        "channel_id": sys.argv[2], "reply_kind": "thread",
        "last_user_inbound_ts": now, "last_user_inbound_ts_ms": now * 1000,
        "last_user_inbound_message_id": "msg1",
        "last_user_inbound_recorded_ns": now * 1_000_000_000,
    }}
}
json.dump(data, open(sys.argv[3], "w"))
' "$now_ts" "$channel_id" "$state_dir/channels/$plugin/$agent.json"

  cat >"$home/agent-env.sh" <<EOF
declare -ga BRIDGE_AGENT_IDS=("$agent")
declare -gA BRIDGE_AGENT_ENGINE=([${agent}]="claude")
declare -gA BRIDGE_AGENT_SOURCE=([${agent}]="static")
declare -gA BRIDGE_AGENT_CHANNELS=([${agent}]="plugin:${plugin}")
declare -gA BRIDGE_AGENT_DESC=([${agent}]="t7 fixture")
declare -gA BRIDGE_AGENT_SESSION=([${agent}]="$agent")
declare -gA BRIDGE_AGENT_PRECOMPACT_NOTIFY=([${agent}]="1")
EOF

  mkdir -p "$state_dir/precompact-events/$agent/started"
  cat >"$state_dir/precompact-events/$agent/started/evt1.json" <<EOF
{"schema_version":"1","event_id":"evt1","agent":"$agent","trigger":"auto","raw_trigger":"auto","started_ts":$now_ts,"started_iso":"1970","hook_pid":1}
EOF

  env -i \
    PATH="$PATH" HOME="$HOME" \
    BRIDGE_HOME="$home" \
    BRIDGE_STATE_DIR="$state_dir" \
    BRIDGE_AGENT_ENV_FILE="$home/agent-env.sh" \
    BRIDGE_PRECOMPACT_NOTIFY_DISABLED=1 \
    BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN=1 \
    BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS=3600 \
    BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 \
    BRIDGE_DISCORD_RELAY_ENABLED=0 \
    BRIDGE_CRON_SYNC_ENABLED=0 \
    bash "$DAEMON" sync >/dev/null 2>&1 || true

  if [[ -f "$state_dir/agents/$agent/precompact-notice-pending.json" ]]; then
    fail "T7 kill switch should prevent pending state being written"
    return
  fi
  # Marker should still be in started/ — kill switch returns before processing.
  if [[ ! -f "$state_dir/precompact-events/$agent/started/evt1.json" ]]; then
    fail "T7 kill switch should leave started marker untouched"
    return
  fi
  pass "T7 BRIDGE_PRECOMPACT_NOTIFY_DISABLED=1 short-circuits the helper"
}

# -- run all ------------------------------------------------------------------

t1_started_marker
t2_completed_marker
t3_render_templates
t4_send_dry_run
t5_record_ema
t6_observer_e2e
t7_kill_switch

printf '\n[smoke][summary] passes=%d fails=%d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke][summary] failures:\n'
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure"
  done
  exit 1
fi
exit 0
