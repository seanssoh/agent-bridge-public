#!/usr/bin/env bash
# 1442-config-protected-globs-v2 — protected globs cover the v2
# per-agent-workdir layout (issue #1442).
#
# On a v2-layout install the live per-agent Discord/Telegram access.json
# files the channel relays read/write are at
#   $BRIDGE_HOME/data/agents/<agent>/workdir/.discord/access.json
# but PROTECTED_GLOBS used to encode only the pre-v2 layout
# (agents/<agent>/.discord/access.json). The #341 operator-gated
# `config get/set` wrapper therefore denied EVERY per-agent access.json
# edit on v2 with `deny: path not in system-config protected list` —
# and since direct edits are PreToolUse-hook-blocked, the operator had no
# sanctioned edit route (catch-22).
#
# This smoke asserts, on an isolated mktemp BRIDGE_HOME:
#
#   1. `config list-protected` lists the v2 glob
#      `data/agents/*/workdir/.discord/access.json` (and .telegram).
#   2. `config set` on a v2 per-agent .discord/access.json is ALLOWED
#      (operator-tui + admin caller) and actually writes the change —
#      NOT `deny: path not in system-config protected list`.
#   3. A non-protected path under the same workdir is still DENIED.
#   4. The pre-v2 layout (agents/<agent>/.discord/access.json) still
#      matches (no regression).
#
# Never touches the live install.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi

BRIDGE_HOME="$(mktemp -d -t agb-1442-smoke.XXXXXX)"
export BRIDGE_HOME
# Issue #1738: pin BRIDGE_STATE_DIR under the isolated home so the wrapper's
# config-caller-binding lookup does NOT leak to an ambient live BRIDGE_STATE_DIR
# inherited from a bridge-managed session env.
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
trap 'rm -rf "$BRIDGE_HOME"' EXIT

ADMIN_AGENT="patch"
AGENT="reviewer"

# v2 layout: per-agent workspace lives under data/agents/<agent>/workdir.
V2_DISCORD_PATH="$BRIDGE_HOME/data/agents/$AGENT/workdir/.discord/access.json"
V2_TELEGRAM_PATH="$BRIDGE_HOME/data/agents/$AGENT/workdir/.telegram/access.json"
V2_NONPROTECTED_PATH="$BRIDGE_HOME/data/agents/$AGENT/workdir/.discord/other.json"
# pre-v2 layout: per-agent dir directly under agents/<agent>.
PREV2_DISCORD_PATH="$BRIDGE_HOME/agents/$AGENT/.discord/access.json"
AUDIT_LOG="$BRIDGE_HOME/logs/audit.jsonl"

mkdir -p "$(dirname "$V2_DISCORD_PATH")"
mkdir -p "$(dirname "$V2_TELEGRAM_PATH")"
mkdir -p "$(dirname "$PREV2_DISCORD_PATH")"
mkdir -p "$BRIDGE_HOME/logs"

write_access_fixture() {
  cat >"$1" <<'JSON'
{
  "version": 1,
  "groups": [],
  "policy": "owner-only"
}
JSON
}

write_access_fixture "$V2_DISCORD_PATH"
write_access_fixture "$V2_TELEGRAM_PATH"
write_access_fixture "$PREV2_DISCORD_PATH"
# A non-protected JSON sibling in the same workdir/.discord dir.
printf '{"note": "not a protected file"}\n' >"$V2_NONPROTECTED_PATH"

# Issue #1738: the wrapper now authorizes from a controller-published pane
# binding matched against its own process ancestry (NOT env identity). The
# wrapper subprocess is a descendant of THIS smoke shell ($$), so a binding
# whose pane_pid == $$ matches its ancestry — that drives the admin path here.
BINDINGS_DIR="$BRIDGE_HOME/state/config-caller-bindings"
mkdir -p "$BINDINGS_DIR"
printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"s","pane_pid":%s,"engine":"claude","updated_at":"now"}\n' \
  "$ADMIN_AGENT" "$ADMIN_AGENT" "$$" >"$BINDINGS_DIR/$ADMIN_AGENT.json"

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
}

run_config() {
  # Admin pane-binding context (issue #1738) — the wrapper authorizes from the
  # controller binding matched against this process's ancestry. `--from` is
  # appended for the mutating verbs so the binding-agent identity is confirmed;
  # `list-protected` ignores it. BRIDGE_AGENT_ID / BRIDGE_CALLER_SOURCE are kept
  # to prove they no longer drive the decision (the binding does).
  local verb="${1:-}"
  local -a from_args=()
  if [[ "$verb" == "set" || "$verb" == "set-env" ]]; then
    from_args=(--from "$ADMIN_AGENT")
  fi
  BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
    BRIDGE_CALLER_SOURCE="operator-tui" \
    BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
    BRIDGE_AGENT_ID="$ADMIN_AGENT" \
    "$PYTHON" "$REPO_ROOT/bridge-config.py" "$@" "${from_args[@]}" </dev/null 2>&1 || true
}

# --- Scenario 1: list-protected includes the v2 globs --------------------
lp_out="$(run_config list-protected)"
if [[ "$lp_out" == *"data/agents/*/workdir/.discord/access.json"* ]]; then
  pass "scenario 1: list-protected includes v2 discord glob"
else
  fail "scenario 1: list-protected missing v2 discord glob — output: $lp_out"
fi
if [[ "$lp_out" == *"data/agents/*/workdir/.telegram/access.json"* ]]; then
  pass "scenario 1: list-protected includes v2 telegram glob"
else
  fail "scenario 1: list-protected missing v2 telegram glob — output: $lp_out"
fi
# Pre-v2 globs must still be present (no regression in the printed list).
if [[ "$lp_out" == *"agents/*/.discord/access.json"* ]]; then
  pass "scenario 1: list-protected still includes pre-v2 discord glob"
else
  fail "scenario 1: list-protected dropped pre-v2 discord glob — output: $lp_out"
fi

# --- Scenario 2: config set on v2 access.json is ALLOWED + writes --------
set2_out="$(run_config set --path "$V2_DISCORD_PATH" --change "groups.append=12345")"
if [[ "$set2_out" == applied:* ]]; then
  pass "scenario 2: config set on v2 .discord/access.json ALLOWED (applied)"
else
  fail "scenario 2: config set on v2 path NOT allowed — output: $set2_out"
fi
# Explicitly assert it was NOT the stale-glob denial.
if [[ "$set2_out" == *"not in system-config protected list"* ]]; then
  fail "scenario 2: v2 path hit the stale 'not in protected list' deny — output: $set2_out"
else
  pass "scenario 2: v2 path did not hit the stale 'not in protected list' deny"
fi
# The change must have actually landed on disk.
if "$PYTHON" -c "
import json, sys
data = json.load(open('$V2_DISCORD_PATH'))
sys.exit(0 if data.get('groups') == [12345] else 1)
"; then
  pass "scenario 2: v2 .discord/access.json groups now [12345]"
else
  fail "scenario 2: v2 .discord/access.json was not mutated"
fi
# Telegram path is also protected + mutable.
set2t_out="$(run_config set --path "$V2_TELEGRAM_PATH" --change "groups.append=67890")"
if [[ "$set2t_out" == applied:* ]]; then
  pass "scenario 2: config set on v2 .telegram/access.json ALLOWED (applied)"
else
  fail "scenario 2: config set on v2 telegram path NOT allowed — output: $set2t_out"
fi

# --- Scenario 3: non-protected path under the same workdir denied --------
set3_out="$(run_config set --path "$V2_NONPROTECTED_PATH" --change "note=changed")"
if [[ "$set3_out" == *"deny:"* ]] && [[ "$set3_out" == *"not in system-config protected list"* ]]; then
  pass "scenario 3: non-protected sibling (other.json) still denied"
else
  fail "scenario 3: non-protected sibling not denied — output: $set3_out"
fi
# Confirm the non-protected file was NOT mutated.
if grep -q "not a protected file" "$V2_NONPROTECTED_PATH" && ! grep -q "changed" "$V2_NONPROTECTED_PATH"; then
  pass "scenario 3: non-protected file unchanged after deny"
else
  fail "scenario 3: non-protected file was mutated despite deny"
fi

# --- Scenario 4: pre-v2 layout still matches (no regression) -------------
set4_out="$(run_config set --path "$PREV2_DISCORD_PATH" --change "groups.append=55555")"
if [[ "$set4_out" == applied:* ]]; then
  pass "scenario 4: config set on pre-v2 .discord/access.json still ALLOWED"
else
  fail "scenario 4: pre-v2 path regressed (no longer allowed) — output: $set4_out"
fi
if "$PYTHON" -c "
import json, sys
data = json.load(open('$PREV2_DISCORD_PATH'))
sys.exit(0 if data.get('groups') == [55555] else 1)
"; then
  pass "scenario 4: pre-v2 .discord/access.json groups now [55555]"
else
  fail "scenario 4: pre-v2 .discord/access.json was not mutated"
fi

# --- Scenario 5: nested look-alike paths are NOT protected (no over-reach)
# The match must be segment-aware: a `*` matches a single agent slot, not an
# arbitrary `/`-spanning run. A deeper path that merely contains the same
# trailing segments (e.g. an extra dir between data/agents/<a> and workdir,
# or a second workdir/ deeper down) must remain UN-protected so the wrapper
# refuses it (codex r1 #1442: fnmatch `*` spans `/`).
NESTED_DISCORD_PATH="$BRIDGE_HOME/data/agents/$AGENT/nested/workdir/.discord/access.json"
DOUBLE_WD_PATH="$BRIDGE_HOME/data/agents/$AGENT/workdir/tmp/workdir/.telegram/access.json"
mkdir -p "$(dirname "$NESTED_DISCORD_PATH")"
mkdir -p "$(dirname "$DOUBLE_WD_PATH")"
write_access_fixture "$NESTED_DISCORD_PATH"
write_access_fixture "$DOUBLE_WD_PATH"

set5a_out="$(run_config set --path "$NESTED_DISCORD_PATH" --change "groups.append=1")"
if [[ "$set5a_out" == *"deny:"* ]] && [[ "$set5a_out" == *"not in system-config protected list"* ]]; then
  pass "scenario 5: nested data/agents/<a>/nested/workdir/.discord/access.json denied (no over-reach)"
else
  fail "scenario 5: nested look-alike not denied — output: $set5a_out"
fi

set5b_out="$(run_config set --path "$DOUBLE_WD_PATH" --change "groups.append=1")"
if [[ "$set5b_out" == *"deny:"* ]] && [[ "$set5b_out" == *"not in system-config protected list"* ]]; then
  pass "scenario 5: nested double-workdir .telegram/access.json denied (no over-reach)"
else
  fail "scenario 5: double-workdir look-alike not denied — output: $set5b_out"
fi

# Pre-v2 look-alike with an extra dir between agents/<a> and .discord too.
PREV2_NESTED_PATH="$BRIDGE_HOME/agents/$AGENT/extra/.discord/access.json"
mkdir -p "$(dirname "$PREV2_NESTED_PATH")"
write_access_fixture "$PREV2_NESTED_PATH"
set5c_out="$(run_config set --path "$PREV2_NESTED_PATH" --change "groups.append=1")"
if [[ "$set5c_out" == *"deny:"* ]] && [[ "$set5c_out" == *"not in system-config protected list"* ]]; then
  pass "scenario 5: nested pre-v2 agents/<a>/extra/.discord/access.json denied (no over-reach)"
else
  fail "scenario 5: nested pre-v2 look-alike not denied — output: $set5c_out"
fi

# --- Summary -------------------------------------------------------------
printf '\n[smoke] 1442-config-protected-globs-v2: %d pass, %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failing scenarios:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi
exit 0
