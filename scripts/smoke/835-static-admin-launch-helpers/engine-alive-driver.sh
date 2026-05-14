#!/usr/bin/env bash
# scripts/smoke/835-static-admin-launch-helpers/engine-alive-driver.sh
#
# Issue #835 Wave C — driver for cases 2 and 3 of the regression smoke.
# Wave B (PR #847) added the `bridge_agent_engine_process_alive` helper
# in lib/bridge-tmux.sh and the `starting`/`stalled before engine`
# activity states downstream. Wave B also shipped a dedicated unit-level
# smoke (scripts/smoke/status-engine-detect.sh) that exercises the
# predicate against synthesized tmux sessions.
#
# This driver re-exercises the same two scenarios — tmux-without-engine
# (rc=1) and tmux-with-engine (rc=0) — at the integration level the
# operator sees in `agb status`. It is intentionally a thin re-verification
# layer on top of Wave B's helper; the goal is the closing acceptance
# criterion 5 ("Add a regression smoke that fails if a static admin
# startup hangs before spawning the engine") covers BOTH the launch-cmd
# return time (driver 1) AND the post-launch engine-alive detection that
# distinguishes "starting" from "wedged" in the status output.
#
# Shipped as a tracked file (rather than a heredoc-to-file body inside
# the smoke wrapper) to match the convention established by
# scripts/smoke/heredoc-regression-helpers/ and to keep the smoke's own
# bytes off the Bash 5.3.9 heredoc-write class. (Forbidden pattern
# strings intentionally omitted from this comment so the footgun #11
# self-audit grep recipe does not flag a textual mention as a real
# callsite.)
#
# Invocation:
#   bash scripts/smoke/835-static-admin-launch-helpers/engine-alive-driver.sh \
#     <repo_root> <mode> <session_name> <fake_bin_dir>
#
# Where:
#   mode             — `no-engine` or `with-engine`
#   session_name     — pre-existing tmux session created by the parent
#                      smoke (parent owns lifetime via its trap)
#   fake_bin_dir     — only used when mode=with-engine; contains a
#                      `claude` symlink to /usr/bin/sleep so the pane's
#                      kernel-truthful `comm` reads as `claude`
#
# Output (on success, stdout):
#   ENGINE_ALIVE_RC=<0|1>
#
# Always exits 0 — the parent smoke asserts on the rc value, not on this
# driver's exit code.

set -euo pipefail

repo_root="$1"
mode="$2"
session_name="$3"

# Source only bridge-tmux.sh (matches Wave B's status-engine-detect.sh
# pattern — full bridge-lib.sh sourcing would trigger bridge_load_roster
# against an unrelated runtime).
# shellcheck source=../../../lib/bridge-tmux.sh
source "$repo_root/lib/bridge-tmux.sh"

# Provide the two accessor stubs the predicate calls.
declare -g -A SMOKE_AGENT_SESSION=()
declare -g -A SMOKE_AGENT_ENGINE=()
bridge_agent_session() { printf '%s' "${SMOKE_AGENT_SESSION[$1]-}"; }
bridge_agent_engine() { printf '%s' "${SMOKE_AGENT_ENGINE[$1]-}"; }

case "$mode" in
  no-engine)
    SMOKE_AGENT_SESSION["target"]="$session_name"
    SMOKE_AGENT_ENGINE["target"]="claude"
    ;;
  with-engine)
    SMOKE_AGENT_SESSION["target"]="$session_name"
    SMOKE_AGENT_ENGINE["target"]="claude"
    ;;
  *)
    printf 'engine-alive-driver: unknown mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac

rc=0
bridge_agent_engine_process_alive target claude || rc=$?
printf 'ENGINE_ALIVE_RC=%d\n' "$rc"
