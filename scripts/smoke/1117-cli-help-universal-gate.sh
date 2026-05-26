#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1117-cli-help-universal-gate.sh — Issue #1117.
#
# Universal CI gate for the `--help` / `-h` contract across every
# operator-facing agent-bridge command + sub-verb. Follow-up to #1114
# (16-site manual pin landed in PR #1132) — #1117 generalizes the
# contract to all documented groups + every verb a `case "$sub" in` /
# `case "$COMMAND" in` block dispatches.
#
# Contract pinned by this smoke:
#
#   T1. Every TOP-LEVEL command routed by the `agent-bridge` dispatcher's
#       `case "$1" in` block accepts both `--help` and `-h` with rc==0
#       + non-empty stdout. This pins the RUNTIME contract — the smoke
#       parses the dispatcher itself (not the usage template) so any
#       command actually wired into the case-switch must honor the
#       contract regardless of whether the operator-facing usage.txt
#       documents it. #1115 pins the separate set-equality between
#       case-switch ↔ usage.txt ↔ `_top_valid` typo array; this smoke
#       owns the per-command rc/stdout assertion at runtime.
#
#   T2. Every SUB-VERB enumerated in a dispatcher's `case "$subcommand"`
#       / `case "$COMMAND"` / `case "$CMD"` block (bridge-agent.sh,
#       bridge-cron.sh, bridge-task.sh, bridge-daemon.sh) accepts
#       `--help` with rc==0 + non-empty stdout, unless the verb is
#       pinned in KNOWN_BROKEN_VERBS below (pre-existing carry-over
#       for follow-up PRs — see the comment beside each entry).
#
#   T3. Dangerous-case regression: `agent-bridge daemon ensure --help`
#       must NOT create `state/bridge-daemon.pid`. This is the
#       safety contract #1114 PR #1132 introduced for the daemon
#       dispatcher (the verb arms now short-circuit on `--help` /
#       `-h` before reaching `cmd_start`). The smoke asserts the
#       no-side-effect property for every daemon verb.
#
#   T4. Ratchet: the KNOWN_BROKEN_VERBS pin list must shrink over
#       time. If a pinned verb unexpectedly passes, the smoke fails
#       with "verb now passes — prune from KNOWN_BROKEN_VERBS". This
#       mirrors the BRIDGE_*_HEREDOC_CEILING ratchet pattern.
#
# Footgun #11 (heredoc_write deadlock class): every captured stdout
# goes through `out=$("$@" 2>&1)` — no `<<EOF` to subprocess, no
# `<<<` here-strings (which silently degrade in restricted sandboxes,
# refs #1115 codex catch 2026-05-23).

set -uo pipefail

SMOKE_NAME="1117-cli-help-universal-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"
AGB_FILE="$REPO_ROOT/agent-bridge"
USAGE_FILE="$REPO_ROOT/scripts/cli-help/agent-bridge-usage.txt"
AGENT_DISPATCHER="$REPO_ROOT/bridge-agent.sh"
CRON_DISPATCHER="$REPO_ROOT/bridge-cron.sh"
TASK_DISPATCHER="$REPO_ROOT/bridge-task.sh"
DAEMON_DISPATCHER="$REPO_ROOT/bridge-daemon.sh"

smoke_assert_file_exists "$AGB_FILE" "agent-bridge dispatcher present"
smoke_assert_file_exists "$USAGE_FILE" "cli-help usage template present"

# ---------------------------------------------------------------------------
# KNOWN_BROKEN_VERBS — pre-existing carry-over.
#
# Each entry is a `<group> <verb>` pair whose `--help` invocation
# currently fails on integration HEAD. Filed as follow-ups; pinned
# here so the universal gate lands now and shrinks as fixes ship.
# When a pinned verb starts passing, the smoke fails with a "prune"
# instruction so the operator knows the row is stale.
#
# Same bug class as #1114 (verb dispatcher consumed `--help` as the
# first positional argument before checking the flag). bridge-agent.sh's
# `bridge_require_agent_id` arg-parser swallows `--help` as the agent
# id and falls into the registry-list error path. To be fixed in
# follow-up by adding the same `case "${1:-}" in -h|--help) usage; exit 0`
# guard at the top of each affected run_* function.
# ---------------------------------------------------------------------------
KNOWN_BROKEN_VERBS=(
  # #1236 Lane γ landed the run_update pre-bind short-circuit (matches
  # run_create's #526 pattern); the verb now prints usage on --help so
  # the row is removed from the pin list.
  "agent show"            # #1114 bug class — run_show treats --help as agent id
  "agent safe-mode"       # #1114 bug class — run_safe_mode treats --help as agent id
  "agent restart"         # #1114 bug class — run_restart treats --help as agent id
  "agent ack-crash"       # #1114 bug class — run_ack_crash treats --help as agent id
  "agent forget-session"  # #1114 bug class — run_forget_session treats --help as agent id
  "agent attach"          # #1114 bug class — run_attach treats --help as agent id
  "agent compact"         # #1114 bug class — run_compact treats --help as agent id
  "agent handoff"         # #1114 bug class — run_handoff treats --help as agent id
  "cron update"           # rc=127 — `usage` heredoc redirection bug surfaces on --help path
  "cron run-subagent"     # rc=1 — run_subagent treats --help as run-id arg
  "cron show"             # bridge_require_cron_source_jobs fires before --help reaches argparse
)

# Top-level commands whose `--help` short-circuits depend on bridge
# configuration (admin agent, etc.) that an isolated smoke
# BRIDGE_HOME cannot satisfy. Pinned here so the universal gate
# lands; follow-up PRs will move the --help short-circuit ahead of
# the configuration requirement at the dispatch arm itself.
KNOWN_BROKEN_TOP_LEVEL=(
  "admin"   # bridge_require_admin_agent fires before --help reaches the arg loop
)

is_known_broken_top() {
  local key="$1"
  local entry
  for entry in "${KNOWN_BROKEN_TOP_LEVEL[@]}"; do
    if [[ "$entry" == "$key" ]]; then
      return 0
    fi
  done
  return 1
}

is_known_broken() {
  local key="$1"
  local entry
  for entry in "${KNOWN_BROKEN_VERBS[@]}"; do
    # Compare on the leading "<group> <verb>" prefix so trailing
    # comments are ignored.
    if [[ "$entry" == "$key" || "$entry" == "$key "* ]]; then
      return 0
    fi
  done
  return 1
}

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Common rejection markers from the affected dispatchers' error paths.
# Mirror the #1114 list so any --help output that contains one of these
# is treated as a contract violation even when rc==0.
ERROR_MARKERS=(
  "지원하지 않는 하위 명령"
  "지원하지 않는 명령"
  "지원하지 않는 옵션"
  "알 수 없는 옵션"
  "옵션 값이 필요"
  "등록된 에이전트:"
)

# Pass count + structured failure-detail collection. Failures are
# rendered as a single block at the end so the operator sees every
# offending verb at once, not just the first.
PASSED_COUNT=0
FAILURE_LIST=""
RECORDED_FAILURE=0

record_failure() {
  local label="$1"
  local detail="$2"
  FAILURE_LIST+="  - $label: $detail"$'\n'
  RECORDED_FAILURE=1
}

assert_help_ok() {
  # assert_help_ok <label> <cmd...>
  local label="$1"
  shift

  local out rc=0
  out="$("$@" 2>&1)" || rc=$?

  if [[ $rc -ne 0 ]]; then
    record_failure "$label" "expected rc=0, got rc=$rc; first line: $(printf '%s' "$out" | head -n 1)"
    return 1
  fi
  if [[ ${#out} -eq 0 ]]; then
    record_failure "$label" "expected non-empty stdout"
    return 1
  fi
  local marker
  for marker in "${ERROR_MARKERS[@]}"; do
    if [[ "$out" == *"$marker"* ]]; then
      record_failure "$label" "--help output contained error marker '$marker'"
      return 1
    fi
  done
  PASSED_COUNT=$((PASSED_COUNT + 1))
  return 0
}

# Inverse of assert_help_ok — assert that the call currently fails.
# Used for KNOWN_BROKEN_VERBS so the ratchet catches a verb that
# silently starts passing (operator should then prune the pin list).
assert_help_currently_broken() {
  local label="$1"
  shift

  local out rc=0
  out="$("$@" 2>&1)" || rc=$?

  if [[ $rc -eq 0 ]]; then
    # rc=0 with an error marker still counts as broken — the verb
    # is returning the agent registry instead of usage.
    local marker
    for marker in "${ERROR_MARKERS[@]}"; do
      if [[ "$out" == *"$marker"* ]]; then
        smoke_log "still broken: $label (rc=0 but error marker '$marker' present)"
        return 0
      fi
    done
    record_failure "$label" "pinned in KNOWN_BROKEN_VERBS but now passes — prune the pin (rc=0, ${#out}B clean output)"
    return 1
  fi
  smoke_log "still broken: $label (rc=$rc)"
  return 0
}

# ---------------------------------------------------------------------------
# Parsers — reuse the #1115 logic (parse_top_level_branches +
# parse_top_valid_array) for the cross-check. We re-implement here
# locally to keep the smoke standalone; #1115 owns the set-equality
# assertion, this smoke owns the runtime contract.
# ---------------------------------------------------------------------------

parse_top_level_branches() {
  awk '
    /^if \[\[ \$# -gt 0 \]\]; then$/ { found = 1; next }
    found && /^  case "\$1" in$/ { in_case = 1; next }
    in_case && /^  esac$/ { exit }
    in_case && /^    [a-z][a-z0-9_|-]*\)$/ {
      line = $0
      gsub(/[ \t)]/, "", line)
      n = split(line, parts, "|")
      for (i = 1; i <= n; i++) {
        if (parts[i] != "") print parts[i]
      }
    }
  ' "$AGB_FILE" | sort -u
}

# Parse a generic `case "$VAR" in` block's verb list from a dispatcher
# file. Takes the file path and the case-header regex as args so we
# can re-use it across bridge-agent.sh (`case "$subcommand" in`),
# bridge-cron.sh (same), bridge-task.sh (`case "$COMMAND" in`), and
# bridge-daemon.sh (`case "$CMD" in`).
parse_verb_block() {
  local file="$1"
  local case_header_regex="$2"
  awk -v hdr="$case_header_regex" '
    $0 ~ hdr { in_case = 1; depth = 1; next }
    in_case && /^esac$/ { exit }
    # 2-space-indented verb arms (closing paren on the same line).
    # Skip alternation arms that look like ""|-h|--help|help) and
    # bare `*)` catch-alls; the verb list is the operator surface.
    in_case && /^  [a-z][a-z0-9_-]*\)$/ {
      line = $0
      gsub(/[ \t)]/, "", line)
      if (line != "") print line
    }
  ' "$file" | sort -u
}

# ---------------------------------------------------------------------------
# T1 — Every top-level command accepts `--help` and `-h`.
# ---------------------------------------------------------------------------
smoke_log "T1: every top-level command accepts --help and -h"

TOP_LEVEL_FILE="$SMOKE_TMP_ROOT/top-level.txt"
parse_top_level_branches >"$TOP_LEVEL_FILE"

if [[ ! -s "$TOP_LEVEL_FILE" ]]; then
  smoke_fail "T1: parser found no top-level branches — parser drift?"
fi

T1_COUNT=0
while IFS= read -r cmd; do
  [[ -n "$cmd" ]] || continue
  T1_COUNT=$((T1_COUNT + 1))
  if is_known_broken_top "$cmd"; then
    assert_help_currently_broken "T1: $cmd --help (pinned KNOWN_BROKEN_TOP_LEVEL)" \
      "$AGB_FILE" "$cmd" --help
    assert_help_currently_broken "T1: $cmd -h (pinned KNOWN_BROKEN_TOP_LEVEL)" \
      "$AGB_FILE" "$cmd" -h
  else
    assert_help_ok "T1: $cmd --help" \
      "$AGB_FILE" "$cmd" --help
    assert_help_ok "T1: $cmd -h" \
      "$AGB_FILE" "$cmd" -h
  fi
done <"$TOP_LEVEL_FILE"

if (( T1_COUNT == 0 )); then
  smoke_fail "T1: loop iterated zero rows — parser/IO drift"
fi
smoke_log "T1: covered $T1_COUNT top-level commands (each x2 for --help + -h)"

# ---------------------------------------------------------------------------
# T2 — Sub-verb `--help` contract for the four enumerable dispatchers.
# ---------------------------------------------------------------------------
smoke_log "T2: sub-verb --help contract across enumerable dispatchers"

# bridge-agent.sh — case "$subcommand" in
# Use awk character-class `[$]` for the literal `$` (awk regex treats
# bare `$` as end-of-line and `\$` is undefined-behavior across awk
# implementations).
AGENT_VERBS_FILE="$SMOKE_TMP_ROOT/agent-verbs.txt"
parse_verb_block "$AGENT_DISPATCHER" '^case "[$]subcommand" in$' >"$AGENT_VERBS_FILE"
[[ -s "$AGENT_VERBS_FILE" ]] || smoke_fail "T2: agent verb parser drift"

# bridge-cron.sh — case "$subcommand" in
CRON_VERBS_FILE="$SMOKE_TMP_ROOT/cron-verbs.txt"
parse_verb_block "$CRON_DISPATCHER" '^case "[$]subcommand" in$' >"$CRON_VERBS_FILE"
[[ -s "$CRON_VERBS_FILE" ]] || smoke_fail "T2: cron verb parser drift"
# `finalize-run` is an internal runtime callback (refs #1116) — never
# exposed to operators, so the gate skips it. The 1115 smoke pins
# the absence elsewhere.
grep -v -x 'finalize-run' "$CRON_VERBS_FILE" >"$CRON_VERBS_FILE.tmp" \
  && mv "$CRON_VERBS_FILE.tmp" "$CRON_VERBS_FILE"

# bridge-task.sh — case "$COMMAND" in
TASK_VERBS_FILE="$SMOKE_TMP_ROOT/task-verbs.txt"
parse_verb_block "$TASK_DISPATCHER" '^case "[$]COMMAND" in$' >"$TASK_VERBS_FILE"
[[ -s "$TASK_VERBS_FILE" ]] || smoke_fail "T2: task verb parser drift"

# bridge-daemon.sh — case "$CMD" in
DAEMON_VERBS_FILE="$SMOKE_TMP_ROOT/daemon-verbs.txt"
parse_verb_block "$DAEMON_DISPATCHER" '^case "[$]CMD" in$' >"$DAEMON_VERBS_FILE"
[[ -s "$DAEMON_VERBS_FILE" ]] || smoke_fail "T2: daemon verb parser drift"

run_verb_contract() {
  local group="$1"
  local verbs_file="$2"
  local count=0
  while IFS= read -r verb; do
    [[ -n "$verb" ]] || continue
    count=$((count + 1))
    local key="$group $verb"
    if is_known_broken "$key"; then
      assert_help_currently_broken "T2: $key --help (pinned KNOWN_BROKEN)" \
        "$AGB_FILE" "$group" "$verb" --help
    else
      assert_help_ok "T2: $key --help" \
        "$AGB_FILE" "$group" "$verb" --help
    fi
  done <"$verbs_file"
  smoke_log "T2: $group: covered $count verbs"
}

run_verb_contract agent  "$AGENT_VERBS_FILE"
run_verb_contract cron   "$CRON_VERBS_FILE"
run_verb_contract task   "$TASK_VERBS_FILE"
run_verb_contract daemon "$DAEMON_VERBS_FILE"

# bridge-plugins.sh uses `case "${1:-}" in` at the script bottom (not the
# enumerable `case "$subcommand" in` pattern the four dispatchers above
# share), so its sub-verbs aren't reached by parse_verb_block. Pin the
# documented operator surface here directly — keep this list in sync
# with the `usage()` printf block in bridge-plugins.sh and the case
# branches at the bottom of that file. New plugins sub-verbs added
# downstream should append a row here.
PLUGINS_VERBS=(
  "seed"
  "show"
  "list"           # #1236 (Lane ζ): read-only installed plugin enumeration
  "marketplaces"   # #1236 (Lane ζ): read-only known-marketplace enumeration
)
for verb in "${PLUGINS_VERBS[@]}"; do
  assert_help_ok "T2: plugins $verb --help" \
    "$AGB_FILE" plugins "$verb" --help
done
smoke_log "T2: plugins: covered ${#PLUGINS_VERBS[@]} verbs"

# ---------------------------------------------------------------------------
# T3 — Dangerous-case regression: daemon verbs' --help must NOT
# execute the verb body. The canonical case is `daemon ensure --help`
# which historically ran cmd_start; we extend the property to every
# daemon verb so a future PR cannot reintroduce the leak under a
# different dispatch arm.
# ---------------------------------------------------------------------------
smoke_log "T3: daemon verbs --help must NOT create pid file (no-side-effect)"

DAEMON_PID_FILE="$BRIDGE_STATE_DIR/bridge-daemon.pid"

while IFS= read -r verb; do
  [[ -n "$verb" ]] || continue
  rm -f "$DAEMON_PID_FILE" 2>/dev/null || true
  out="$("$AGB_FILE" daemon "$verb" --help 2>&1)" || true
  if [[ -f "$DAEMON_PID_FILE" ]]; then
    record_failure "T3: daemon $verb --help" \
      "pid file unexpectedly present at $DAEMON_PID_FILE (verb side effect leaked)"
    rm -f "$DAEMON_PID_FILE" 2>/dev/null || true
  fi
done <"$DAEMON_VERBS_FILE"

# ---------------------------------------------------------------------------
# T4 — Cross-check the _top_valid typo-suggestion array reaches every
# dispatched top-level branch. #1115 owns the set-equality assertion;
# this smoke adds a runtime canary by feeding the array contents back
# through the runtime dispatcher and confirming each resolves cleanly.
# ---------------------------------------------------------------------------
smoke_log "T4: _top_valid runtime canary — each pinned candidate routes through dispatch"

# Re-parse the _top_valid array from agent-bridge directly (mirrors
# #1115's parse_top_valid_array but inlined to keep this smoke
# standalone). The smoke fails if a candidate the typo-suggestion path
# advertises is missing from the runtime dispatcher.
TOP_VALID_FILE="$SMOKE_TMP_ROOT/top-valid.txt"
awk '
  /^[[:space:]]*_top_valid="/ {
    line = $0
    sub(/^[[:space:]]*_top_valid="/, "", line)
    sub(/".*$/, "", line)
    n = split(line, words, " ")
    for (i = 1; i <= n; i++) {
      if (words[i] != "") print words[i]
    }
    exit
  }
' "$AGB_FILE" | sort -u >"$TOP_VALID_FILE"
[[ -s "$TOP_VALID_FILE" ]] || smoke_fail "T4: parser found no _top_valid entries"

# Every _top_valid candidate must appear in the dispatched-top-level
# set we already walked in T1. (Set-equality is the #1115 contract;
# here we just confirm the runtime gate already covers each candidate.)
T4_DRIFT=0
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  if ! grep -qx "$candidate" "$TOP_LEVEL_FILE"; then
    record_failure "T4: _top_valid candidate '$candidate'" \
      "not present in dispatched top-level case-block — drift from #1115 contract"
    T4_DRIFT=1
  fi
done <"$TOP_VALID_FILE"
if (( T4_DRIFT == 0 )); then
  smoke_log "T4: _top_valid candidates ($(wc -l <"$TOP_VALID_FILE" | tr -d ' ')) all reach the dispatcher"
fi

# ---------------------------------------------------------------------------
# Final report.
# ---------------------------------------------------------------------------
smoke_log "summary: $PASSED_COUNT assertions passed"

if (( RECORDED_FAILURE == 1 )); then
  printf '%s\n' "[smoke:$SMOKE_NAME] failures:" >&2
  printf '%s' "$FAILURE_LIST" >&2
  smoke_fail "one or more --help contract assertions failed"
fi

smoke_log "passed"
exit 0
