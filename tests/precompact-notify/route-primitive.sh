#!/usr/bin/env bash
# precompact-notify route primitive smoke — issue #597 Track A.
#
# Exercises bridge-channels.py route-precompact-target with mocked
# state/channels/<plugin>/<agent>.json activity index files. No daemon, no
# real channel plugins, no roster — pure consumer-side primitive coverage.
#
# Cases:
#
#   T1  two channels with different last_user_inbound_ts
#       -> picks the newer one; exit 0; emits expected shell assignments.
#   T2  every channel is older than the recency cutoff
#       -> exit 1, no stdout (silent skip path).
#   T3  two candidates within 1 ms of each other
#       -> ns-precision tie-break picks the higher recorded_ns;
#          fallback lexical-plugin tie-break is also exercised.
#   T4  malformed JSON in the activity index
#       -> exit 1, no traceback (graceful skip).
#   T5  candidate is missing last_user_inbound_message_id
#       -> filtered out; the remaining valid candidate wins.
#   T6  --recency-seconds 0 is coerced to the 1800-second default
#       -> a candidate within the default window still routes.
#
# Each case sets up its own temp BRIDGE_STATE_DIR. The fixture is intentionally
# standalone — Track A does NOT register it in scripts/smoke-test.sh; Track D
# wires the full precompact-notify suite in once the writers and daemon
# observer are in place.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"
ROUTE_PY="$REPO_ROOT/bridge-channels.py"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi
if [[ ! -f "$ROUTE_PY" ]]; then
  printf '[smoke][error] bridge-channels.py not found at %s\n' "$ROUTE_PY" >&2
  exit 2
fi

ROOT="$(mktemp -d -t precompact-route.XXXXXX)"
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

write_activity() {
  # write_activity <state-dir> <plugin> <agent> <json-payload>
  local state_dir="$1"
  local plugin="$2"
  local agent="$3"
  local payload="$4"
  local dir="$state_dir/channels/$plugin"
  mkdir -p "$dir"
  printf '%s' "$payload" >"$dir/$agent.json"
}

ROUTE_EXIT=0
ROUTE_OUT=""
ROUTE_ERR=""

run_route() {
  # run_route <agent> <channels-csv> <state-dir> <recency> <now-ts>
  # Populates globals $ROUTE_OUT / $ROUTE_ERR / $ROUTE_EXIT.
  # We invoke via tmpfiles instead of $(...) so the exit code is visible in
  # the parent shell — the caller asserts on both stdout and exit code.
  local agent="$1"
  local channels="$2"
  local state_dir="$3"
  local recency="$4"
  local now="$5"
  local outfile="$ROOT/.route.out"
  local errfile="$ROOT/.route.err"

  "$PYTHON" "$ROUTE_PY" route-precompact-target \
    --agent "$agent" \
    --channels-csv "$channels" \
    --bridge-state-dir "$state_dir" \
    --recency-seconds "$recency" \
    --now-ts "$now" \
    --format shell >"$outfile" 2>"$errfile"
  ROUTE_EXIT=$?

  ROUTE_OUT="$(cat "$outfile")"
  ROUTE_ERR="$(cat "$errfile")"
}

# ---------- T1: argmax over last_user_inbound_ts ---------------------------
t1() {
  local case="T1 argmax picks newer candidate"
  local sd="$ROOT/t1"
  local now=2000000000
  local agent="alpha"

  # discord candidate is 600s old, telegram candidate is 60s old.
  # telegram should win.
  write_activity "$sd" discord "$agent" "$(cat <<EOF
{
  "schema_version": 1,
  "agent": "$agent",
  "plugin": "discord",
  "updated_ts": $((now - 600)),
  "channels": {
    "C-DISCORD-1": {
      "channel_id": "C-DISCORD-1",
      "last_user_inbound_ts": $((now - 600)),
      "last_user_inbound_ts_ms": $(( (now - 600) * 1000 )),
      "last_user_inbound_message_id": "MSG-DISCORD-1",
      "last_user_inbound_recorded_ns": 100
    }
  }
}
EOF
)"
  write_activity "$sd" telegram "$agent" "$(cat <<EOF
{
  "schema_version": 1,
  "agent": "$agent",
  "plugin": "telegram",
  "updated_ts": $((now - 60)),
  "channels": {
    "C-TELEGRAM-1": {
      "channel_id": "C-TELEGRAM-1",
      "last_user_inbound_ts": $((now - 60)),
      "last_user_inbound_ts_ms": $(( (now - 60) * 1000 )),
      "last_user_inbound_message_id": "MSG-TELEGRAM-1",
      "last_user_inbound_recorded_ns": 200
    }
  }
}
EOF
)"

  run_route "$agent" "plugin:discord@official,plugin:telegram@official" "$sd" 1800 "$now"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case" "expected exit 0; got $ROUTE_EXIT"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_PLUGIN="telegram"' <<<"$ROUTE_OUT"; then
    fail "$case" "expected telegram plugin; got: $ROUTE_OUT"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_CHANNEL_ID="C-TELEGRAM-1"' <<<"$ROUTE_OUT"; then
    fail "$case" "expected C-TELEGRAM-1 channel; got: $ROUTE_OUT"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID="MSG-TELEGRAM-1"' <<<"$ROUTE_OUT"; then
    fail "$case" "expected MSG-TELEGRAM-1 reply target; got: $ROUTE_OUT"
    return
  fi
  pass "$case"
}

# ---------- T2: only-stale candidates -------------------------------------
t2() {
  local case="T2 stale-only candidates → silent skip"
  local sd="$ROOT/t2"
  local now=2000000000
  local agent="alpha"

  # Both candidates are well outside a 1800s recency window.
  write_activity "$sd" discord "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "discord",
  "updated_ts": $((now - 5000)),
  "channels": {
    "C-A": {
      "channel_id": "C-A",
      "last_user_inbound_ts": $((now - 5000)),
      "last_user_inbound_ts_ms": $(( (now - 5000) * 1000 )),
      "last_user_inbound_message_id": "MSG-A",
      "last_user_inbound_recorded_ns": 1
    }
  }
}
EOF
)"
  write_activity "$sd" telegram "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "telegram",
  "updated_ts": $((now - 4000)),
  "channels": {
    "C-B": {
      "channel_id": "C-B",
      "last_user_inbound_ts": $((now - 4000)),
      "last_user_inbound_ts_ms": $(( (now - 4000) * 1000 )),
      "last_user_inbound_message_id": "MSG-B",
      "last_user_inbound_recorded_ns": 2
    }
  }
}
EOF
)"

  run_route "$agent" "plugin:discord,plugin:telegram" "$sd" 1800 "$now"
  if [[ "$ROUTE_EXIT" -eq 0 ]]; then
    fail "$case" "expected non-zero exit; got 0 with stdout: $ROUTE_OUT"
    return
  fi
  if [[ -n "$ROUTE_OUT" ]]; then
    fail "$case" "expected empty stdout on no-route; got: $ROUTE_OUT"
    return
  fi
  pass "$case"
}

# ---------- T3: tie-break by recorded_ns then lexical plugin --------------
t3() {
  local case="T3 ms-tie → ns wins, then lexical plugin"
  local sd="$ROOT/t3"
  local now=2000000000
  local agent="alpha"
  local same_ms=$(( (now - 30) * 1000 ))

  # Two candidates with identical inbound_ms; discord has higher recorded_ns
  # so it wins on the ns tie-break.
  write_activity "$sd" discord "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "discord",
  "updated_ts": $((now - 30)),
  "channels": {
    "C-D-1": {
      "channel_id": "C-D-1",
      "last_user_inbound_ts": $((now - 30)),
      "last_user_inbound_ts_ms": $same_ms,
      "last_user_inbound_message_id": "MSG-D-1",
      "last_user_inbound_recorded_ns": 999000000
    }
  }
}
EOF
)"
  write_activity "$sd" telegram "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "telegram",
  "updated_ts": $((now - 30)),
  "channels": {
    "C-T-1": {
      "channel_id": "C-T-1",
      "last_user_inbound_ts": $((now - 30)),
      "last_user_inbound_ts_ms": $same_ms,
      "last_user_inbound_message_id": "MSG-T-1",
      "last_user_inbound_recorded_ns": 100000000
    }
  }
}
EOF
)"

  run_route "$agent" "plugin:discord,plugin:telegram" "$sd" 1800 "$now"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case" "expected exit 0; got $ROUTE_EXIT"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_PLUGIN="discord"' <<<"$ROUTE_OUT"; then
    fail "$case (ns)" "expected discord (higher recorded_ns); got: $ROUTE_OUT"
    return
  fi

  # Now flip ns to be equal — fall through to lexical plugin (discord < telegram).
  rm -rf "$sd"
  write_activity "$sd" discord "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "discord",
  "updated_ts": $((now - 30)),
  "channels": {
    "C-D-1": {
      "channel_id": "C-D-1",
      "last_user_inbound_ts": $((now - 30)),
      "last_user_inbound_ts_ms": $same_ms,
      "last_user_inbound_message_id": "MSG-D-1",
      "last_user_inbound_recorded_ns": 500
    }
  }
}
EOF
)"
  write_activity "$sd" telegram "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "telegram",
  "updated_ts": $((now - 30)),
  "channels": {
    "C-T-1": {
      "channel_id": "C-T-1",
      "last_user_inbound_ts": $((now - 30)),
      "last_user_inbound_ts_ms": $same_ms,
      "last_user_inbound_message_id": "MSG-T-1",
      "last_user_inbound_recorded_ns": 500
    }
  }
}
EOF
)"

  run_route "$agent" "plugin:discord,plugin:telegram" "$sd" 1800 "$now"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case (lex)" "expected exit 0; got $ROUTE_EXIT"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_PLUGIN="discord"' <<<"$ROUTE_OUT"; then
    fail "$case (lex)" "expected discord (lexical < telegram); got: $ROUTE_OUT"
    return
  fi
  pass "$case"
}

# ---------- T4: malformed JSON → graceful skip ----------------------------
t4() {
  local case="T4 malformed JSON → silent skip"
  local sd="$ROOT/t4"
  local now=2000000000
  local agent="alpha"

  mkdir -p "$sd/channels/discord"
  printf '%s' '{not valid json' >"$sd/channels/discord/$agent.json"

  run_route "$agent" "plugin:discord" "$sd" 1800 "$now"

  if [[ "$ROUTE_EXIT" -eq 0 ]]; then
    fail "$case" "expected non-zero exit; got 0 stdout=$ROUTE_OUT"
    return
  fi
  if [[ -n "$ROUTE_OUT" ]]; then
    fail "$case" "expected empty stdout; got: $ROUTE_OUT"
    return
  fi
  if grep -qE 'Traceback|JSONDecodeError' <<<"$ROUTE_ERR"; then
    fail "$case" "expected no traceback on stderr; saw: $ROUTE_ERR"
    return
  fi
  pass "$case"
}

# ---------- T5: missing last_user_inbound_message_id ----------------------
t5() {
  local case="T5 missing message_id filters out the candidate"
  local sd="$ROOT/t5"
  local now=2000000000
  local agent="alpha"

  # discord newer but missing message_id; telegram older but valid → telegram wins.
  write_activity "$sd" discord "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "discord",
  "updated_ts": $((now - 10)),
  "channels": {
    "C-D-1": {
      "channel_id": "C-D-1",
      "last_user_inbound_ts": $((now - 10)),
      "last_user_inbound_ts_ms": $(( (now - 10) * 1000 )),
      "last_user_inbound_recorded_ns": 1
    }
  }
}
EOF
)"
  write_activity "$sd" telegram "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "telegram",
  "updated_ts": $((now - 100)),
  "channels": {
    "C-T-1": {
      "channel_id": "C-T-1",
      "last_user_inbound_ts": $((now - 100)),
      "last_user_inbound_ts_ms": $(( (now - 100) * 1000 )),
      "last_user_inbound_message_id": "MSG-T-1",
      "last_user_inbound_recorded_ns": 2
    }
  }
}
EOF
)"

  run_route "$agent" "plugin:discord,plugin:telegram" "$sd" 1800 "$now"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case" "expected exit 0 (telegram should win); got $ROUTE_EXIT, stdout=$ROUTE_OUT"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_PLUGIN="telegram"' <<<"$ROUTE_OUT"; then
    fail "$case" "expected telegram (discord filtered out); got: $ROUTE_OUT"
    return
  fi
  if grep -qF 'CHANNEL_ROUTE_REPLY_TO_MESSAGE_ID="MSG-T-1"' <<<"$ROUTE_OUT"; then
    pass "$case"
    return
  fi
  fail "$case" "expected MSG-T-1; got: $ROUTE_OUT"
}

# ---------- T6: --recency-seconds 0 coerced to 1800 default ---------------
t6() {
  local case="T6 recency=0 is coerced to default 1800"
  local sd="$ROOT/t6"
  local now=2000000000
  local agent="alpha"

  # Candidate is 1000s old: outside any tiny window but well inside 1800s default.
  write_activity "$sd" discord "$agent" "$(cat <<EOF
{
  "schema_version": 1, "agent": "$agent", "plugin": "discord",
  "updated_ts": $((now - 1000)),
  "channels": {
    "C-D-1": {
      "channel_id": "C-D-1",
      "last_user_inbound_ts": $((now - 1000)),
      "last_user_inbound_ts_ms": $(( (now - 1000) * 1000 )),
      "last_user_inbound_message_id": "MSG-D-1",
      "last_user_inbound_recorded_ns": 1
    }
  }
}
EOF
)"

  run_route "$agent" "plugin:discord" "$sd" 0 "$now"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case" "expected exit 0 (1000s within 1800s default); got $ROUTE_EXIT"
    return
  fi
  if ! grep -qF 'CHANNEL_ROUTE_PLUGIN="discord"' <<<"$ROUTE_OUT"; then
    fail "$case" "expected discord route; got: $ROUTE_OUT"
    return
  fi

  # Sanity: empty string and non-numeric also coerce.
  run_route "$agent" "plugin:discord" "$sd" "" "$now"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case (empty)" "expected exit 0 with empty recency; got $ROUTE_EXIT"
    return
  fi
  run_route "$agent" "plugin:discord" "$sd" "abc" "$now"
  if [[ "$ROUTE_EXIT" -ne 0 ]]; then
    fail "$case (non-numeric)" "expected exit 0 with non-numeric recency; got $ROUTE_EXIT"
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

printf '\n[smoke] %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failures:\n'
  for entry in "${FAILURES[@]}"; do
    printf '  - %s\n' "$entry"
  done
  exit 1
fi
exit 0
