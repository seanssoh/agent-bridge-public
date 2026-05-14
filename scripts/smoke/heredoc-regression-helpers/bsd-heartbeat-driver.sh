#!/usr/bin/env bash
# scripts/smoke/heredoc-regression-helpers/bsd-heartbeat-driver.sh
#
# Driver for case 5 of scripts/smoke/heredoc-regression.sh — exercises
# bridge_daemon_heartbeat_age_seconds against the literal colonized-offset
# ISO heartbeat documented in CHANGELOG as the Wave C r2 BLOCKING
# regression vector (`2026-05-13T07:30:05+09:00`). Pre-r2 this failed
# BSD `date -j -f` silently because BSD does not accept `+09:00` (only
# `+0900`), and the helper returned empty / rc=1 — letting
# bridge_daemon_health_signal report `health=down` on a real wedge,
# masking the silent-but-alive condition cmd_start auto-repair depends on.
#
# Branch must pass on both Linux (GNU `date -d`) and macOS (BSD
# `date -j -f` with the r2-introduced offset normalization).
#
# Shipped as a tracked file (see context-pressure-driver.sh head for the
# same rationale — heredoc-to-file `cat <<EOF >$driver` for a multi-line
# body recurs the Bash 5.3.9 heredoc_write deadlock class).
#
# Invocation:
#   bash scripts/smoke/heredoc-regression-helpers/bsd-heartbeat-driver.sh \
#     <state_dir> <repo_root>

set -euo pipefail
state_dir="$1"
repo_root="$2"

export BRIDGE_HOME="$state_dir/.."
export BRIDGE_STATE_DIR="$state_dir"
export BRIDGE_DAEMON_PID_FILE="$state_dir/daemon.pid"
mkdir -p "$state_dir"

# shellcheck source=/dev/null
source "$repo_root/lib/bridge-state.sh"

printf "%s\n" "2026-05-13T07:30:05+09:00" > "$state_dir/daemon.heartbeat"

set +e
age="$(bridge_daemon_heartbeat_age_seconds)"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || { echo "BSD ISO parse failed: rc=$rc (regression — Wave C r2 fix gone)"; exit 1; }
[[ -n "$age" ]] || { echo "BSD ISO parse returned empty age (regression — Wave C r2 fix gone)"; exit 1; }
[[ "$age" =~ ^[0-9]+$ ]] || { echo "BSD ISO parse returned non-numeric age: $age"; exit 1; }

echo ok
