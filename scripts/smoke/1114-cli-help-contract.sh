#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1114-cli-help-contract.sh — Issue #1114.
#
# Pins the CLI --help contract for the 16 subcommand-group sites bundled by
# PR fixing #1114. For each site:
#   * `<entry> --help`  → exit 0, non-empty stdout, no error markers.
#   * `<entry> -h`      → same shape (where the site accepts -h).
#   * The dispatcher must NOT execute the verb's side effect.
#
# The most dangerous case is `bridge-daemon.sh ensure --help`, which
# historically consumed the verb without inspecting --help and ran
# `cmd_start` — silently starting the daemon when the operator only asked
# for usage. This smoke asserts no pid file is created.
#
# Out of scope: enforcing the contract for every dispatcher in the repo
# (that is issue #1117's job). This smoke covers ONLY the sites this PR
# touched.
#
# Footgun #11 (heredoc_write deadlock class): all stdout capture goes
# through `$(... 2>&1)` against the shell script directly — no python
# heredoc-stdin into a subprocess, no `<<<` here-strings.

set -uo pipefail

SMOKE_NAME="1114-cli-help-contract"
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

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Common rejection markers from the affected dispatchers' error paths. If
# any of these appear in --help output the contract is broken.
ERROR_MARKERS=(
  "지원하지 않는 하위 명령"
  "지원하지 않는 명령"
  "지원하지 않는 옵션"
  "지원하지 않는 memory 명령"
  "지원하지 않는 intake 명령"
  "지원하지 않는 bundle 명령"
  "지원하지 않는 agent list 옵션"
  "지원하지 않는 agent registry 옵션"
  "지원하지 않는 agent stop 옵션"
  "지원하지 않는 worktree 명령"
  "알 수 없는 옵션"
  "옵션 값이 필요"
  "task id가 필요"
)

assert_help_ok() {
  # assert_help_ok <label> <cmd...>
  local label="$1"
  shift

  local out rc=0
  out="$("$@" 2>&1)" || rc=$?

  if [[ $rc -ne 0 ]]; then
    echo "------ output ------" >&2
    echo "$out" >&2
    echo "--------------------" >&2
    smoke_fail "$label: expected rc=0, got rc=$rc"
  fi
  if [[ ${#out} -eq 0 ]]; then
    smoke_fail "$label: expected non-empty stdout"
  fi
  local marker
  for marker in "${ERROR_MARKERS[@]}"; do
    if [[ "$out" == *"$marker"* ]]; then
      echo "------ output ------" >&2
      echo "$out" >&2
      echo "--------------------" >&2
      smoke_fail "$label: --help output contained error marker '$marker'"
    fi
  done
  smoke_log "ok: $label (rc=0, ${#out}B)"
}

# --- Sites 1-6: shell scripts whose top-level / subcommand-group dispatchers --
# --- previously rejected --help. -------------------------------------------

assert_help_ok "1. upgrade conflicts --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-upgrade.sh" conflicts --help
assert_help_ok "1. upgrade conflicts -h" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-upgrade.sh" conflicts -h

assert_help_ok "2. memory --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-memory.sh" --help
assert_help_ok "2. memory -h" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-memory.sh" -h
assert_help_ok "2. memory help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-memory.sh" help

assert_help_ok "3. intake --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-intake.sh" --help

assert_help_ok "4. bundle --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-bundle.sh" --help

assert_help_ok "5. cron errors --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-cron.sh" errors --help

assert_help_ok "6. cron cleanup --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-cron.sh" cleanup --help

# --- Site 7: daemon top dispatcher + per-verb safety guards -----------------
# The critical safety case is `daemon ensure --help` — the dispatcher must
# NOT execute cmd_start. Assert by checking the daemon pid file is absent
# after each invocation.
DAEMON_PID_FILE="$BRIDGE_STATE_DIR/bridge-daemon.pid"

assert_help_ok "7a. daemon --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-daemon.sh" --help
[[ ! -f "$DAEMON_PID_FILE" ]] \
  || smoke_fail "7a. daemon --help: pid file unexpectedly present at $DAEMON_PID_FILE"

# Each verb's --help guard must short-circuit before the cmd_* runs.
for verb in start ensure run sync status stop run-cron-worker; do
  assert_help_ok "7b. daemon $verb --help" \
    "$BRIDGE_BASH" "$REPO_ROOT/bridge-daemon.sh" "$verb" --help
  [[ ! -f "$DAEMON_PID_FILE" ]] \
    || smoke_fail "7b. daemon $verb --help: pid file unexpectedly present (verb side effect leaked)"
done

# --- Site 8: discord status/sync --help (arity check used to reject) -------

assert_help_ok "8a. discord status --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-discord-relay.sh" status --help
assert_help_ok "8b. discord sync --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-discord-relay.sh" sync --help

# --- Site 9: agent-bridge top-level shorthand commands ---------------------

assert_help_ok "9a. agb list --help" \
  "$REPO_ROOT/agent-bridge" list --help
assert_help_ok "9b. agb kill --help" \
  "$REPO_ROOT/agent-bridge" kill --help
assert_help_ok "9c. agb attach --help" \
  "$REPO_ROOT/agent-bridge" attach --help
assert_help_ok "9d. agb urgent --help" \
  "$REPO_ROOT/agent-bridge" urgent --help
assert_help_ok "9e. agb worktree --help" \
  "$REPO_ROOT/agent-bridge" worktree --help
assert_help_ok "9f. agb worktree list --help" \
  "$REPO_ROOT/agent-bridge" worktree list --help

# --- Site 10: bridge-send.sh --help -----------------------------------------

assert_help_ok "10. bridge-send --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-send.sh" --help

# --- Sites 11-14: agent <sub> --help where <sub> previously rejected -------

assert_help_ok "11. agent list --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" list --help
assert_help_ok "12. agent registry --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" registry --help
assert_help_ok "13. agent start --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" start --help
assert_help_ok "14. agent stop --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" stop --help

# --- Site 15: profile status --help (was treated as agent id) --------------

assert_help_ok "15. profile status --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-profile.sh" status --help

# --- Site 16: task summary --help (was treated as agent id) ----------------

assert_help_ok "16. task summary --help" \
  "$BRIDGE_BASH" "$REPO_ROOT/bridge-task.sh" summary --help

smoke_log "all 16 sites PASS — CLI --help contract holds (#1114)"
exit 0
