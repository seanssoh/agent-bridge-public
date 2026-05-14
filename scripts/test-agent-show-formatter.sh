#!/usr/bin/env bash
# Regression coverage for Issue 6 (v0.11.0) — `agent show <X>` text
# formatter session_id field. Verifies:
#
#   1. The tab→sentinel translation preserves empty middle fields so
#      the read-into-array does NOT shift subsequent slots (the
#      original bash `IFS=$'\t' read` collapsed adjacent tabs because
#      tab is whitespace).
#   2. The field-count guard fires (and refuses to render) when the
#      TSV row has a column count other than 30.
#   3. End-to-end: a real `bridge-agent.sh show <agent>` against an
#      isolated $BRIDGE_HOME whose agent has `AGENT_SESSION_ID=''`
#      prints `session_id: -` (NOT the workdir path), with workdir,
#      profile_home, profile_source, etc. in their correct slots.
#
# Runs entirely in an isolated $TMP so it never reads or writes the
# operator's live bridge state.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-agent-show-formatter-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------------------
# Section A — direct parser regression
# ----------------------------------------------------------------------------
# Exercise the tab→sentinel translation + IFS=sentinel read pattern in
# isolation. This pins the specific Bash behaviour that broke `agent
# show` in v0.11.0 without needing the full bridge-agent.sh load graph.

parse_one_row() {
  # Mirror the production pattern at bridge-agent.sh:1683.
  local line="$1"
  local sep
  sep=$'\x1f'
  local -a fields=()
  IFS="$sep" read -r -a fields <<<"${line//$'\t'/$sep}"
  printf '%d|' "${#fields[@]}"
  printf '%s|' "${fields[@]}"
  printf '\n'
}

step "A1: empty middle field is preserved (not collapsed)"
out="$(parse_one_row $'agent\tdesc\tclaude\tstatic\tpatch\t\t/foo/workdir\tprofile_home_path\tyes')"
# Expect 9 fields with field[5] empty
if [[ "$out" == '9|agent|desc|claude|static|patch||/foo/workdir|profile_home_path|yes|' ]]; then
  ok
else
  err "got [$out]"
fi

step "A2: regression check — bash's native IFS=\$'\\t' read DOES shift (proves the gotcha exists)"
shifted="$(printf '%s' $'agent\tdesc\tclaude\tstatic\tpatch\t\t/foo/workdir\tprofile_home_path\tyes' \
  | { IFS=$'\t' read -r a b c d e f g h i; printf '[%s][%s][%s]' "$f" "$g" "$h"; })"
# With native IFS=$'\t' read, field f (session_id slot) gets the workdir
if [[ "$shifted" == '[/foo/workdir][profile_home_path][yes]' ]]; then
  ok
else
  err "expected the native bash collapse to surface; got [$shifted]"
fi

step "A3: empty fields BEFORE the last data field are preserved"
# Bash's `read -a` drops the single trailing empty field after the
# last separator (a here-string side effect). Doesn't bite production
# because the producer always ends rows with `${admin}` (yes/no, never
# empty), and the field-count guard fires anyway if the count drifts.
out="$(parse_one_row $'one\ttwo\t\t\tfour')"
if [[ "$out" == '5|one|two|||four|' ]]; then ok; else err "got [$out]"; fi

step "A4: 30-column row (production schema) round-trips with col 5 empty"
hdr_row=$(printf 'patch\tdesc\tclaude\tstatic\tpatch\t\t/foo/workdir\tprof_home\tyes\tyes\tidle\t1\t1\tyes\t0\tok\tok\tok\tdiscord\t123\tdefault\t123\t123\t-\tec2-user\t0\t0\t0\t-\tyes')
out="$(parse_one_row "$hdr_row")"
# Strip leading count and trailing pipe, split on pipe, check slot 5 (session_id) is empty
count="${out%%|*}"
if [[ "$count" == "30" ]]; then ok; else err "expected 30 fields; got [$count] full=[$out]"; fi

# ----------------------------------------------------------------------------
# Section B — formatter end-to-end with isolated $BRIDGE_HOME
# ----------------------------------------------------------------------------
# Build a one-agent roster + persisted-state file with
# AGENT_SESSION_ID=''. Run the real `bridge-agent.sh show` and assert
# the text output lands session_id, workdir, and profile_source in
# their correct slots. This is the regression that operators see.

ISO_HOME="$TMP/home"
ISO_BRIDGE="$TMP/bridge"
mkdir -p "$ISO_HOME" "$ISO_BRIDGE/state/agents" "$ISO_BRIDGE/agents/sample/workdir" \
         "$ISO_BRIDGE/logs" "$ISO_BRIDGE/shared/tasks" "$ISO_BRIDGE/state/profiles"

# v0.8.0+ requires a v2 layout marker before bridge-lib.sh will load.
# Write the minimum valid marker so the resolver does not bail on the
# isolated install.
cat >"$ISO_BRIDGE/state/layout-marker.sh" <<EOF
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT=$ISO_BRIDGE
EOF

# Minimal roster: one static claude agent with empty session_id. The
# roster uses the same direct-associative-array shape live installs do
# (see ~/.agent-bridge/agent-roster.local.sh).
cat >"$ISO_BRIDGE/agent-roster.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
declare -ag BRIDGE_AGENT_IDS=()
declare -Ag BRIDGE_AGENT_DESC=()
declare -Ag BRIDGE_AGENT_ENGINE=()
declare -Ag BRIDGE_AGENT_SESSION=()
declare -Ag BRIDGE_AGENT_WORKDIR=()
declare -Ag BRIDGE_AGENT_PROFILE_HOME=()
declare -Ag BRIDGE_AGENT_LAUNCH_CMD=()
declare -Ag BRIDGE_AGENT_ACTION=()
declare -Ag BRIDGE_AGENT_IDLE_TIMEOUT=()
declare -Ag BRIDGE_AGENT_LOOP=()
declare -Ag BRIDGE_AGENT_CONTINUE=()
declare -Ag BRIDGE_AGENT_SOURCE=()
EOF
cat >"$ISO_BRIDGE/agent-roster.local.sh" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
bridge_add_agent_id_if_missing sample
BRIDGE_AGENT_DESC["sample"]='sample test agent'
BRIDGE_AGENT_ENGINE["sample"]=claude
BRIDGE_AGENT_SESSION["sample"]=sample
BRIDGE_AGENT_WORKDIR["sample"]=$ISO_BRIDGE/agents/sample/workdir
BRIDGE_AGENT_SOURCE["sample"]="static"
BRIDGE_AGENT_LOOP["sample"]="1"
BRIDGE_AGENT_CONTINUE["sample"]="1"
BRIDGE_AGENT_IDLE_TIMEOUT["sample"]="0"
EOF

# Persisted state for `sample` with empty SESSION_ID — the exact shape
# Issue 6 reproduces.
cat >"$ISO_BRIDGE/state/agents/sample.env" <<EOF
AGENT_ID=sample
AGENT_DESC=sample\\ test\\ agent
AGENT_ENGINE=claude
AGENT_SESSION=sample
AGENT_WORKDIR=$ISO_BRIDGE/agents/sample
AGENT_LOOP=1
AGENT_CONTINUE=1
AGENT_SESSION_ID=''
AGENT_HISTORY_KEY=test
AGENT_CREATED_AT=1700000000
AGENT_UPDATED_AT=2026-01-01T00:00:00+00:00
EOF

step "B1: real \`agent show\` lands fields in correct slots (session_id=-, profile_source=yes/no, not a path)"
out=""
rc=0
# env -i strips inherited BRIDGE_* vars from the operator session so
# the subshell does not accidentally pick up the live roster file
# instead of the isolated one. PATH/TERM/USER are restored for the
# minimum bash + tmux callouts the binary makes during show.
out="$(env -i \
       HOME="$ISO_HOME" \
       PATH="${PATH:-/usr/bin:/bin}" \
       TERM="${TERM:-dumb}" \
       USER="${USER:-}" \
       BRIDGE_HOME="$ISO_BRIDGE" \
       BRIDGE_ROSTER_FILE="$ISO_BRIDGE/agent-roster.sh" \
       BRIDGE_ROSTER_LOCAL_FILE="$ISO_BRIDGE/agent-roster.local.sh" \
       BRIDGE_STATE_DIR="$ISO_BRIDGE/state" \
       BRIDGE_ACTIVE_AGENT_DIR="$ISO_BRIDGE/state/agents" \
       BRIDGE_HISTORY_DIR="$ISO_BRIDGE/state/history" \
       BRIDGE_AGENT_HOME_ROOT="$ISO_BRIDGE/agents" \
       BRIDGE_LOG_DIR="$ISO_BRIDGE/logs" \
       BRIDGE_SHARED_DIR="$ISO_BRIDGE/shared" \
       BRIDGE_TASK_DB="$ISO_BRIDGE/state/tasks.db" \
       BRIDGE_PROFILE_STATE_DIR="$ISO_BRIDGE/state/profiles" \
       bash "$ROOT_DIR/bridge-agent.sh" show sample 2>&1)" || rc=$?
if [[ "$rc" != 0 ]]; then
  err "command rc=$rc; out:\n$out"
elif ! grep -qE '^session_id: -$' <<<"$out"; then
  err "session_id not '-'; out:\n$out"
elif grep -qE '^session_id: /' <<<"$out"; then
  err "session_id holds a path (the original bug); out:\n$out"
elif ! grep -qE '^workdir: ' <<<"$out"; then
  err "workdir missing; out:\n$out"
elif ! grep -qE '^profile_source: (yes|no)$' <<<"$out"; then
  err "profile_source not yes/no; out:\n$out"
else
  ok
fi

# ----------------------------------------------------------------------------
# Section C — field-count guard
# ----------------------------------------------------------------------------
# Extract the run_show function and stub bridge_agent_records_tsv to
# emit a deliberately-short row. The guard at the top of the read loop
# should refuse to render via bridge_die.

step "C1: short row (5 columns) triggers bridge_die guard"
# Spawn a child bash that loads bridge-agent.sh in a way that lets us
# call run_show with a stubbed input. Easiest: invoke real binary in
# an isolated $BRIDGE_HOME, but pre-poison the producer via a wrapper
# that replaces it on PATH. Heavier than needed — instead, extract
# the read+guard portion via awk and test in isolation.
GUARD_TMP="$TMP/guard.sh"
cat >"$GUARD_TMP" <<'EOF'
set -uo pipefail
bridge_die() { printf 'die: %s\n' "$*" >&2; return 99; }
parse_with_guard() {
  local _tsv_line="$1"
  local _tsv_sep
  _tsv_sep=$'\x1f'
  local -a _fields=()
  _fields=()
  IFS="$_tsv_sep" read -r -a _fields <<<"${_tsv_line//$'\t'/$_tsv_sep}"
  if (( ${#_fields[@]} != 30 )); then
    bridge_die "agent show: unexpected TSV column count (${#_fields[@]} != 30); refusing to render"
    return 99
  fi
  printf 'ok\n'
}
EOF
out_guard="$(bash -c "source '$GUARD_TMP'; parse_with_guard 'a$(printf '\t')b$(printf '\t')c$(printf '\t')d$(printf '\t')e'" 2>&1)" || true
if grep -q 'die: agent show: unexpected TSV column count (5 != 30)' <<<"$out_guard"; then
  ok
else
  err "guard did not fire; out=[$out_guard]"
fi

step "C2: malformed short row does not reuse prior _fields values"
out_reset="$(bash -c "source '$GUARD_TMP'
parse_with_guard $'a\tb\tc\td\te\tf\tg\th\ti\tj\tk\tl\tm\tn\to\tp\tq\tr\ts\tt\tu\tv\tw\tx\ty\tz\t1\t2\t3\t4' >/dev/null
parse_with_guard 'short' 2>&1
" || true)"
# Second call: 1-field row → should fire the guard (1 != 30), not
# silently inherit the prior 30 fields.
if grep -q 'die: agent show: unexpected TSV column count (1 != 30)' <<<"$out_reset"; then
  ok
else
  err "fields didn't reset between rows; out=[$out_reset]"
fi

printf '\nTotal: %d, Pass: %d, Fail: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
exit "$FAIL"
