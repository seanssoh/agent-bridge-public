#!/usr/bin/env bash
# shellcheck shell=bash
# lib/bridge-layout-v2-reconcile-driver.sh — thin upgrade-time entry point for
# the gated v1->v2 reconcile (#1820).
#
# bridge-upgrade.sh invokes this file-as-argv (NOT via an inline source+call in
# a subshell) so the reconcile runs with bridge-lib + the lock primitive + the
# reconcile module all sourced, without adding heredoc-stdin to the upgrader
# (footgun #11). It is intentionally tiny: source, dispatch, propagate JSON +
# exit code.
#
# Usage: bridge-layout-v2-reconcile-driver.sh <apply|dry-run> [--force-live-daemon]
#   Requires BRIDGE_HOME (live target root) and BRIDGE_SCRIPT_DIR (= same root)
#   in the environment. Emits the reconcile JSON on stdout. Exit code mirrors
#   bridge_layout_v2_reconcile_run (0 ok, 2 nothing-to-do/legacy, non-zero on
#   refusal/error).

set -uo pipefail

_self_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${BRIDGE_SCRIPT_DIR:=$_self_dir}"

mode="${1:-dry-run}"
shift || true

# shellcheck source=bridge-lib.sh
source "$BRIDGE_SCRIPT_DIR/bridge-lib.sh" >/dev/null 2>&1 || true
# shellcheck source=lib/bridge-lock.sh
source "$BRIDGE_SCRIPT_DIR/lib/bridge-lock.sh" >/dev/null 2>&1 || true
# shellcheck source=lib/bridge-layout-v2-reconcile.sh
source "$BRIDGE_SCRIPT_DIR/lib/bridge-layout-v2-reconcile.sh" >/dev/null 2>&1 || true

# Best-effort: load the roster so BRIDGE_AGENT_IDS scopes the reconcile to
# rostered agents (the wrapper falls back to a v2-tree scan if it is empty).
if command -v bridge_load_roster >/dev/null 2>&1; then
  bridge_load_roster >/dev/null 2>&1 || true
fi

if ! command -v bridge_layout_v2_reconcile_run >/dev/null 2>&1; then
  printf '{"error":"reconcile module not loaded"}\n' >&2
  exit 1
fi

bridge_layout_v2_reconcile_run --mode "$mode" "$@"
