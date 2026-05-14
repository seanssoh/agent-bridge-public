#!/usr/bin/env bash
# scripts/smoke/heredoc-regression-helpers/health-signal-driver.sh
#
# Driver for case 4 of scripts/smoke/heredoc-regression.sh — exercises
# the three derivations of bridge_daemon_health_signal:
#   4a — no heartbeat + no pid   → health=down
#   4b — stale heartbeat + alive → health=silent
#   4c — fresh heartbeat + alive → health=ok
#
# Shipped as a tracked file (see context-pressure-driver.sh head for the
# same rationale — heredoc-to-file `cat <<EOF >$driver` for a multi-line
# body recurs the Bash 5.3.9 heredoc_write deadlock class).
#
# Invocation:
#   bash scripts/smoke/heredoc-regression-helpers/health-signal-driver.sh \
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

# 4a: no heartbeat + no pid → health=down
rm -f "$state_dir/daemon.heartbeat" 2>/dev/null || true
bridge_daemon_pid() { return 1; }
out_4a="$(bridge_daemon_health_signal)"
[[ "$out_4a" == *"health=down"* ]] || { echo "4a expected health=down, got:"; echo "$out_4a"; exit 1; }
[[ "$out_4a" == *"tick_fresh=false"* ]] || { echo "4a expected tick_fresh=false, got:"; echo "$out_4a"; exit 1; }

# 4b: stale heartbeat (10000s ago) + alive pid → health=silent
stale_epoch=$(( $(date +%s) - 10000 ))
printf "%s\n" "$stale_epoch" > "$state_dir/daemon.heartbeat"
bridge_daemon_pid() { printf "%s" "$$"; return 0; }
out_4b="$(bridge_daemon_health_signal)"
[[ "$out_4b" == *"health=silent"* ]] || { echo "4b expected health=silent, got:"; echo "$out_4b"; exit 1; }
[[ "$out_4b" == *"tick_age_seconds=10"* ]] || { echo "4b expected tick_age_seconds>=10000, got:"; echo "$out_4b"; exit 1; }
[[ "$out_4b" == *"tick_fresh=false"* ]] || { echo "4b expected tick_fresh=false, got:"; echo "$out_4b"; exit 1; }

# 4c: fresh heartbeat + alive pid → health=ok
date +%s > "$state_dir/daemon.heartbeat"
out_4c="$(bridge_daemon_health_signal)"
[[ "$out_4c" == *"health=ok"* ]] || { echo "4c expected health=ok, got:"; echo "$out_4c"; exit 1; }
[[ "$out_4c" == *"tick_fresh=true"* ]] || { echo "4c expected tick_fresh=true, got:"; echo "$out_4c"; exit 1; }

echo ok
