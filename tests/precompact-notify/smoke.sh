#!/usr/bin/env bash
# precompact-notify suite smoke — issue #597 Track D.
#
# Wires the pieces that are mergeable today:
#   * Track A — bridge-channels.py route-precompact-target primitive (merged)
#   * Track D — bridge-discord-relay.py activity-index writer (this PR)
#   * pre-compact.py hook resilience (exit 0 even on broken state dir)
#
# Cases covered now (W = writer-side, R = router-side, H = hook):
#
#   T1  W  writer populates schema_version=1 channels/discord/<agent>.json
#          with a USER inbound; bot-self echoes are filtered
#   T2  W  writer is atomic + lock-safe under two concurrent inbound updates
#   T3  W  writer survives a corrupted pre-existing index (rebuilds payload)
#   T4  R  routing happy path: writer-populated index resolves to the
#          recent inbound channel
#   T5  R  routing recency: cutoff older than entry → silent skip (exit 1)
#   T6  R  routing tie-break: ns wins inside the 1-second tie window
#   T7  R  malformed activity index → silent exit 1, no traceback
#   T8  H  pre-compact.py with unwritable state dir → exits 0 (compaction
#          contract preserved)
#
# Tracks B (daemon observer + send primitive + EMA + dedup + follow-up)
# and Track C (Teams/Mattermost TS plugin writers) are still in flight.
# The opt-in / static-only / manual-trigger / dedup / follow-up / EMA
# cases are noted below as DEFERRED — they will be activated by a
# follow-up PR once the daemon observer lands and exposes the marker
# pipeline + stats schema. Activating them earlier would couple this
# fixture to symbols (`process_precompact_events`, send-managed-message)
# that don't exist yet.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"
DISCORD_RELAY_PY="$REPO_ROOT/bridge-discord-relay.py"
ROUTE_PY="$REPO_ROOT/bridge-channels.py"
PRECOMPACT_HOOK="$REPO_ROOT/hooks/pre-compact.py"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi
for required in "$DISCORD_RELAY_PY" "$ROUTE_PY" "$PRECOMPACT_HOOK"; do
  if [[ ! -f "$required" ]]; then
    printf '[smoke][error] required file missing: %s\n' "$required" >&2
    exit 2
  fi
done

ROOT="$(mktemp -d -t precompact-notify-suite.XXXXXX)"
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
    printf '%s\n' "$2" >&2
  fi
}

# call_writer — invoke the relay's _record_user_inbound_activity via a
# small Python harness. Importing the relay module by file path keeps
# this fixture independent of the runtime install.
call_writer() {
  # call_writer <state-dir> <agent> <channel-id> <snowflake-id> <author-id> <is-bot 0|1> <now-ts>
  local sd="$1" agent="$2" cid="$3" snowflake="$4" author="$5" is_bot="$6" now_ts="$7"
  "$PYTHON" - "$DISCORD_RELAY_PY" "$sd" "$agent" "$cid" "$snowflake" "$author" "$is_bot" "$now_ts" <<'PY'
import importlib.util
import sys
from pathlib import Path

(_, mod_path, sd, agent, cid, snowflake, author, is_bot, now_ts) = sys.argv
spec = importlib.util.spec_from_file_location("bridge_discord_relay", mod_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod._record_user_inbound_activity(
    Path(sd),
    agent,
    cid,
    {
        "id": snowflake,
        "author": {"id": author, "bot": (is_bot == "1")},
    },
    int(now_ts),
)
PY
}

run_route() {
  # run_route <agent> <channels-csv> <state-dir> <recency> <now-ts>
  local agent="$1" channels="$2" sd="$3" recency="$4" now="$5"
  local outfile="$ROOT/.route.out" errfile="$ROOT/.route.err"
  "$PYTHON" "$ROUTE_PY" route-precompact-target \
    --agent "$agent" \
    --channels-csv "$channels" \
    --bridge-state-dir "$sd" \
    --recency-seconds "$recency" \
    --now-ts "$now" \
    --format shell >"$outfile" 2>"$errfile"
  ROUTE_EXIT=$?
  ROUTE_OUT="$(cat "$outfile")"
  ROUTE_ERR="$(cat "$errfile")"
}

# ---------- T1: writer happy path -----------------------------------------
t1() {
  local case="T1 writer populates schema_version=1 activity index"
  local sd="$ROOT/t1"
  local agent="alpha"
  local cid="100000000000000001"
  # Pick a snowflake so its decoded ms is well within any sane recency
  # window of now_ts.
  local now_ts=2000000000
  # Snowflake = (ts_ms_since_discord_epoch << 22). For ts_ms = now_ts*1000
  # we need (now_ts*1000 - 1420070400000) << 22 ≥ 0 — true for any
  # post-2015 timestamp, which "$now_ts" satisfies.
  local discord_epoch_ms=1420070400000
  local target_ms=$(( now_ts * 1000 ))
  local snowflake=$(( (target_ms - discord_epoch_ms) << 22 ))

  call_writer "$sd" "$agent" "$cid" "$snowflake" "987" "0" "$now_ts"
  local index_file="$sd/channels/discord/$agent.json"
  if [[ ! -f "$index_file" ]]; then
    fail "$case" "expected index at $index_file"
    return
  fi
  if ! "$PYTHON" -c "
import json, sys
data = json.load(open(r'$index_file'))
assert data.get('schema_version') == 1, data
assert data.get('agent') == r'$agent', data
assert data.get('plugin') == 'discord', data
ch = data.get('channels', {}).get(r'$cid')
assert ch is not None, data
assert ch.get('last_user_inbound_message_id') == r'$snowflake', ch
assert ch.get('last_user_inbound_user_id') == '987', ch
assert isinstance(ch.get('last_user_inbound_recorded_ns'), int), ch
assert ch.get('last_user_inbound_recorded_ns') > 0, ch
assert ch.get('last_user_inbound_ts_ms') > 0, ch
"; then
    fail "$case" "schema or field validation failed"
    return
  fi

  # Bot-self echo must NOT update the index (defensive guard inside the
  # writer, even if the relay's outer caller filters first).
  local bot_snowflake=$(( snowflake + (1 << 22) ))
  call_writer "$sd" "$agent" "$cid" "$bot_snowflake" "999" "1" "$((now_ts + 1))"
  if ! "$PYTHON" -c "
import json
data = json.load(open(r'$index_file'))
ch = data['channels'][r'$cid']
assert ch['last_user_inbound_message_id'] == r'$snowflake', ch
"; then
    fail "$case (bot-skip)" "bot echo should not have overwritten the user inbound id"
    return
  fi
  pass "$case"
}

# ---------- T2: concurrent writes don't corrupt the file ------------------
t2() {
  local case="T2 concurrent writes preserve atomicity"
  local sd="$ROOT/t2"
  local agent="beta"
  local now_ts=2000000050
  local discord_epoch_ms=1420070400000

  # Five distinct channels updated in parallel; final file must contain
  # all of them and parse as valid JSON.
  local pids=()
  for i in 1 2 3 4 5; do
    local target_ms=$(( now_ts * 1000 + i ))
    local snowflake=$(( (target_ms - discord_epoch_ms) << 22 ))
    local cid="200000000000000000$i"
    call_writer "$sd" "$agent" "$cid" "$snowflake" "user-$i" "0" "$now_ts" &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do
    wait "$p" || true
  done

  local index_file="$sd/channels/discord/$agent.json"
  if [[ ! -f "$index_file" ]]; then
    fail "$case" "no index file written"
    return
  fi
  if ! "$PYTHON" -c "
import json
data = json.load(open(r'$index_file'))
assert isinstance(data, dict), data
assert data.get('schema_version') == 1
ch = data.get('channels') or {}
assert len(ch) == 5, ch
for k, v in ch.items():
    assert isinstance(v, dict), v
    assert v.get('last_user_inbound_message_id'), v
"; then
    fail "$case" "concurrent write produced incomplete or malformed index"
    return
  fi
  pass "$case"
}

# ---------- T3: corrupted pre-existing index → writer rebuilds ------------
t3() {
  local case="T3 writer rebuilds atop a malformed index file"
  local sd="$ROOT/t3"
  local agent="gamma"
  local cid="300000000000000001"
  local now_ts=2000000100
  local discord_epoch_ms=1420070400000
  local target_ms=$(( now_ts * 1000 ))
  local snowflake=$(( (target_ms - discord_epoch_ms) << 22 ))

  mkdir -p "$sd/channels/discord"
  printf '%s' '{not json' >"$sd/channels/discord/$agent.json"

  call_writer "$sd" "$agent" "$cid" "$snowflake" "user-x" "0" "$now_ts"
  if ! "$PYTHON" -c "
import json
data = json.load(open(r'$sd/channels/discord/$agent.json'))
assert data.get('schema_version') == 1, data
assert r'$cid' in data.get('channels', {}), data
"; then
    fail "$case" "writer did not recover from malformed payload"
    return
  fi
  pass "$case"
}

# ---------- T4: routing happy path consumes writer output -----------------
t4() {
  local case="T4 routing primitive consumes writer-populated index"
  local sd="$ROOT/t4"
  local agent="delta"
  local cid="400000000000000001"
  local now_ts=2000000200
  local discord_epoch_ms=1420070400000
  # Inbound at now-30s (well within default 1800s recency).
  local target_ms=$(( (now_ts - 30) * 1000 ))
  local snowflake=$(( (target_ms - discord_epoch_ms) << 22 ))

  call_writer "$sd" "$agent" "$cid" "$snowflake" "user-z" "0" "$((now_ts - 30))"
  run_route "$agent" "plugin:discord" "$sd" 1800 "$now_ts"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case" "expected exit 0 from route; got $ROUTE_EXIT err=$ROUTE_ERR"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_PLUGIN="discord"' <<<"$ROUTE_OUT"; then
    fail "$case" "expected discord plugin in route output; got: $ROUTE_OUT"
    return
  fi
  if ! grep -qF "CHANNEL_ROUTE_CHANNEL_ID=\"$cid\"" <<<"$ROUTE_OUT"; then
    fail "$case" "expected channel id $cid; got: $ROUTE_OUT"
    return
  fi
  if ! grep -qF "CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID=\"$snowflake\"" <<<"$ROUTE_OUT"; then
    fail "$case" "expected reply-to message id $snowflake; got: $ROUTE_OUT"
    return
  fi
  pass "$case"
}

# ---------- T5: stale entry → no route ------------------------------------
t5() {
  local case="T5 entry older than recency cutoff → silent skip"
  local sd="$ROOT/t5"
  local agent="epsilon"
  local cid="500000000000000001"
  local now_ts=2000000300
  local discord_epoch_ms=1420070400000
  # Inbound 4000s ago (outside 1800s default).
  local target_ms=$(( (now_ts - 4000) * 1000 ))
  local snowflake=$(( (target_ms - discord_epoch_ms) << 22 ))

  call_writer "$sd" "$agent" "$cid" "$snowflake" "user-y" "0" "$((now_ts - 4000))"
  run_route "$agent" "plugin:discord" "$sd" 1800 "$now_ts"
  if [[ "$ROUTE_EXIT" -eq 0 ]]; then
    fail "$case" "expected non-zero exit on stale entry; got 0 stdout=$ROUTE_OUT"
    return
  fi
  if [[ -n "$ROUTE_OUT" ]]; then
    fail "$case" "expected empty stdout; got: $ROUTE_OUT"
    return
  fi
  pass "$case"
}

# ---------- T6: tie-break by recorded_ns inside 1s window -----------------
t6() {
  local case="T6 sub-second tie window → ns precedence"
  local sd="$ROOT/t6"
  local agent="zeta"
  local now_ts=2000000400

  # Two pre-built activity index files, same agent, two plugins,
  # ts_ms 700 ms apart but both inside the 1-second tie window. The
  # candidate with the higher recorded_ns must win regardless of which
  # plugin's ts_ms is technically newer.
  mkdir -p "$sd/channels/discord" "$sd/channels/telegram"
  cat >"$sd/channels/discord/$agent.json" <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "discord",
  "updated_ts": $now_ts,
  "channels": {
    "C-D": {
      "channel_id": "C-D",
      "last_user_inbound_ts": $((now_ts - 30)),
      "last_user_inbound_ts_ms": $(( (now_ts - 30) * 1000 - 700 )),
      "last_user_inbound_message_id": "MSG-D",
      "last_user_inbound_recorded_ns": 999000000
    }
  }
}
EOF
  cat >"$sd/channels/telegram/$agent.json" <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "telegram",
  "updated_ts": $now_ts,
  "channels": {
    "C-T": {
      "channel_id": "C-T",
      "last_user_inbound_ts": $((now_ts - 30)),
      "last_user_inbound_ts_ms": $(( (now_ts - 30) * 1000 )),
      "last_user_inbound_message_id": "MSG-T",
      "last_user_inbound_recorded_ns": 100000000
    }
  }
}
EOF

  run_route "$agent" "plugin:discord,plugin:telegram" "$sd" 1800 "$now_ts"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case" "expected exit 0; got $ROUTE_EXIT err=$ROUTE_ERR"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_PLUGIN="discord"' <<<"$ROUTE_OUT"; then
    fail "$case" "expected discord (higher ns within 1s window); got: $ROUTE_OUT"
    return
  fi
  pass "$case"
}

# ---------- T7: malformed JSON in activity index → silent skip ------------
t7() {
  local case="T7 malformed activity index → graceful exit 1"
  local sd="$ROOT/t7"
  local agent="eta"
  local now_ts=2000000500

  mkdir -p "$sd/channels/discord"
  printf '%s' '{not json' >"$sd/channels/discord/$agent.json"
  run_route "$agent" "plugin:discord" "$sd" 1800 "$now_ts"
  if [[ "$ROUTE_EXIT" -eq 0 ]]; then
    fail "$case" "expected non-zero exit; got 0"
    return
  fi
  if grep -qE 'Traceback|JSONDecodeError' <<<"$ROUTE_ERR"; then
    fail "$case" "expected no traceback on stderr; saw: $ROUTE_ERR"
    return
  fi
  pass "$case"
}

# ---------- T8: pre-compact hook resilience -------------------------------
t8() {
  local case="T8 pre-compact.py exits 0 with unwritable state dir"
  local sd="$ROOT/t8-state"
  local agent="theta"
  local home="$ROOT/t8-home"
  mkdir -p "$home"

  # Empty stdin payload — the hook's broad try/except covers any state
  # access failure; the contract is that compaction is never blocked.
  BRIDGE_STATE_DIR="/dev/null/does-not-exist" \
  BRIDGE_HOME="$home" \
  BRIDGE_AGENT_ID="$agent" \
  AGENT_BRIDGE_HOME="$home" \
    "$PYTHON" "$PRECOMPACT_HOOK" </dev/null >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "$case" "expected exit 0; got $rc"
    return
  fi
  pass "$case"
}

t1
t2
t3
t4
t5
t6
t7
t8

# ---------------------------------------------------------------------------
# Cases deferred until Track B/C land. Documented here so the next fixer
# (or a follow-up to this PR) knows exactly which assertions to add and
# in what order, without rediscovering the spec:
#
#   Opt-in unit             — needs Track B daemon observer + roster opt-in
#                             getter; assert no pending file when
#                             BRIDGE_AGENT_PRECOMPACT_NOTIFY[agent] unset.
#   Static-only unit        — same; assert source=dynamic agent silently
#                             skipped.
#   Manual-trigger unit     — assert trigger=manual marker is silently
#                             skipped (no pending state, no audit row).
#   Auto-happy path         — assert pending JSON, last-ts file, and
#                             precompact_notice_sent audit row, all in
#                             dry-run mode (BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN=1).
#   Dedup unit              — second eligible marker inside the dedup
#                             window does not produce a second pending.
#   Follow-up unit          — completion marker after a successful notice
#                             routes via notice_message_id.
#   Follow-up skip unit     — completion marker without pending notice is
#                             a silent no-op.
#   EMA unit                — durations 60 + 30 at alpha=0.5 land EMA at
#                             45 in the stats schema.
#   Malformed marker unit   — invalid marker JSON is moved to invalid/
#                             and the daemon continues.
# ---------------------------------------------------------------------------

printf '\n[smoke] %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failures:\n'
  for entry in "${FAILURES[@]}"; do
    printf '  - %s\n' "$entry"
  done
  exit 1
fi
exit 0
