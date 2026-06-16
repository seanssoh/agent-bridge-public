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
# Restore any non-writable config-caller bindings dir (#1738 r2 makes it 0555 to
# simulate the controller-owned store) before the recursive rm so cleanup is not
# blocked by the dropped write bit.
trap 'chmod -R u+w "$BRIDGE_HOME" 2>/dev/null || true; rm -rf "$BRIDGE_HOME"' EXIT

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

# Issue #1738 r3: the wrapper authorizes a `set` from a controller-published pane
# binding matched against the wrapper's process ancestry (NOT env identity), and
# the positive ADMIN WRITE path requires (a) the bound session to be LIVE —
# re-resolved via a REAL tmux (the env-stub seam was REMOVED, FIX 2), so the
# wrapper must run INSIDE a real pane — AND (b) a store the caller does NOT own
# (FIX 1: ownership, not chmod). We reuse the shared smoke lib helpers to start a
# real session + make the store foreign-owned (sudo); the mutating ALLOW
# scenarios (2, 4) are SKIPPED (logged) where a real tmux session or passwordless
# sudo is unavailable. The read-only `list-protected` (scenario 1) and the
# path-gate DENY scenarios (3, 5 — denied BEFORE authorization) need no binding
# and run as a direct subprocess regardless.
# shellcheck source=scripts/smoke/lib.sh
source "$REPO_ROOT/scripts/smoke/lib.sh"
SMOKE_NAME="1442-config-protected-globs-v2"
SMOKE_TMP_ROOT="$BRIDGE_HOME"
export SMOKE_TMP_ROOT
# Augment the existing EXIT trap with the lib's live-session teardown.
trap 'smoke_config_caller_stop_live_session; chmod -R u+w "$BRIDGE_HOME" 2>/dev/null || true; if [[ "${SMOKE_CONFIG_CALLER_ISO_OK:-0}" == "1" ]] && command -v sudo >/dev/null 2>&1; then sudo -n chown -R "$(id -u):$(id -g)" "$BRIDGE_HOME" 2>/dev/null || true; fi; rm -rf "$BRIDGE_HOME"' EXIT

BINDINGS_DIR="$BRIDGE_HOME/state/config-caller-bindings"
mkdir -p "$BINDINGS_DIR"
smoke_config_caller_start_live_session || true

# True iff the iso positive WRITE path is exercisable here.
config_caller_positive_available() {
  [[ "${SMOKE_CONFIG_CALLER_LIVE_OK:-0}" == "1" ]] || return 1
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

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

skip() {
  printf '[smoke][skip] %s\n' "$1"
}

# Read-only / path-gate-deny verbs (list-protected, get, and `set` on a
# non-protected path) need NO binding — run as a direct subprocess.
run_config() {
  BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_AUDIT_LOG="$AUDIT_LOG" \
    BRIDGE_CALLER_SOURCE="operator-tui" \
    BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
    BRIDGE_AGENT_ID="$ADMIN_AGENT" \
    "$PYTHON" "$REPO_ROOT/bridge-config.py" "$@" </dev/null 2>&1 || true
}

# Authorized `set` on a PROTECTED path: run the wrapper IN the live pane against
# a foreign-owned store (the iso admin positive path), so the binding is trusted
# and the write lands. Seeds the binding + foreign store on first use. Echoes the
# wrapper's combined stdout/stderr (matching run_config's shape).
config_caller_set_ready=0
run_config_set_authorized() {
  if [[ "$config_caller_set_ready" != "1" ]]; then
    smoke_clear_config_caller_bindings "$BINDINGS_DIR"
    smoke_seed_trusted_admin_binding "$BINDINGS_DIR" "$ADMIN_AGENT" "$ADMIN_AGENT"
    smoke_config_caller_make_store_foreign "$BINDINGS_DIR"
    config_caller_set_ready=1
  fi
  SMOKE_CC_ENV=(
    "BRIDGE_HOME=$BRIDGE_HOME"
    "BRIDGE_STATE_DIR=$BRIDGE_STATE_DIR"
    "BRIDGE_AUDIT_LOG=$AUDIT_LOG"
    "BRIDGE_ADMIN_AGENT_ID=$ADMIN_AGENT"
    "BRIDGE_AGENT_ID=$ADMIN_AGENT"
  )
  smoke_config_caller_run_in_pane "$REPO_ROOT/bridge-config.py" "$@" --from "$ADMIN_AGENT" >/dev/null
  cat "$SMOKE_TMP_ROOT/wrap.out" "$SMOKE_TMP_ROOT/wrap.err" 2>/dev/null || true
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
# Authorized writes need the iso positive path (real tmux + foreign store).
if config_caller_positive_available; then
  set2_out="$(run_config_set_authorized set --path "$V2_DISCORD_PATH" --change "groups.append=12345")"
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
  set2t_out="$(run_config_set_authorized set --path "$V2_TELEGRAM_PATH" --change "groups.append=67890")"
  if [[ "$set2t_out" == applied:* ]]; then
    pass "scenario 2: config set on v2 .telegram/access.json ALLOWED (applied)"
  else
    fail "scenario 2: config set on v2 telegram path NOT allowed — output: $set2t_out"
  fi
else
  skip "scenario 2: v2 ALLOWED+write path (no real tmux live session + passwordless sudo)"
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
if config_caller_positive_available; then
  set4_out="$(run_config_set_authorized set --path "$PREV2_DISCORD_PATH" --change "groups.append=55555")"
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
else
  skip "scenario 4: pre-v2 ALLOWED+write path (no real tmux live session + passwordless sudo)"
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
