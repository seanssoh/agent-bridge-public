#!/usr/bin/env bash
# Runtime regression: bridge_tmux_wait_for_claude_foreground must return
# promptly when the tmux session dies mid-wait, not burn the full timeout
# budget. Catches the P2 liveness edge raised on the controller-watcher
# foreground gate (bridge-start.sh:113): without an in-loop session-exists
# check, a hard plugin-cache failure (session exits while watcher is
# waiting) leaves the watcher polling for the full foreground budget — up
# to 10 minutes per failed start under the default 600s ceiling.

set -euo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

die() {
  printf '[tmux-wait-foreground-liveness][error] %s\n' "$*" >&2
  exit 1
}

command -v tmux >/dev/null 2>&1 || die "tmux not on PATH; runtime smoke requires tmux"

SOCKET="ab-fg-liveness-$$"
SESSION="ab-fg-liveness-session-$$"
SOCKET_DIR="$(mktemp -d)"
export TMUX_TMPDIR="$SOCKET_DIR"

cleanup() {
  command tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [[ -n "${SOCKET_DIR:-}" && -d "$SOCKET_DIR" ]] && rm -rf "$SOCKET_DIR"
}
trap cleanup EXIT

# Route every bridge-tmux call to our isolated socket. Bash resolves function
# names at call time, so this override applies to functions sourced below.
tmux() { command tmux -L "$SOCKET" "$@"; }
export -f tmux

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-tmux.sh"

tmux new-session -d -s "$SESSION" 'sleep 300'
tmux has-session -t "$SESSION" >/dev/null 2>&1 \
  || die "failed to create isolated test tmux session"

# Kill the session ~1s into the wait. The helper must observe the dead
# session and return rc=1 within a poll cycle, not after the 10s timeout.
( sleep 1 && command tmux -L "$SOCKET" kill-session -t "=$SESSION" >/dev/null 2>&1 || true ) &
killer_pid=$!

rc=0
t0=$(date +%s)
bridge_tmux_wait_for_claude_foreground "$SESSION" 10 1 12 >/dev/null 2>&1 || rc=$?
t1=$(date +%s)
elapsed=$(( t1 - t0 ))

wait "$killer_pid" 2>/dev/null || true

(( rc == 1 )) || die "expected rc=1 from helper, got rc=$rc"
(( elapsed <= 4 )) \
  || die "expected helper to return within 4s of session-kill, got elapsed=${elapsed}s (in-loop session-liveness check missing or broken)"

printf '[tmux-wait-foreground-liveness][ok] helper returned rc=1 in %ss after session kill (budget=10s)\n' "$elapsed"
