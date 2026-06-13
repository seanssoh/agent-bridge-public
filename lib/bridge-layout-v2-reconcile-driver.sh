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

# Fresh-group preflight (#1820 rc4, PRIMARY — item 1).
#
# Root cause of the cm-prod rc3 6/8 Errno13 warnings: the agb-upgrade invoker
# shell (a 15-day-old login) carried a STALE login-time supplementary group set
# that lacked the ab-agent-<a> groups created after that login. The reconcile
# child inherited that stale set, so os.scandir(2770 iso home) threw Errno13 for
# bots whose groups were missing — even though the controller IS an on-disk
# member of every group (the home is readable from a FRESH process). This is the
# KNOWN_ISSUES §28 / #1836 pattern bridge_agent_start_supp_group_preflight
# already fixes for agent START.
#
# bridge_controller_supp_group_refresh detects the stale set (id -nG vs getent
# for every effectively-iso rostered agent's ab-agent group) and, when stale,
# RE-EXECS this driver under `sg <grp> -c ...` (layering every missing group) so
# the relaunched reconcile carries a fresh, complete group set and traverses the
# iso homes cleanly. An anti-loop sentinel (BRIDGE_RECONCILE_SUPP_REEXEC) stops a
# second pass from re-execing. When the refresh is impossible (`sg` missing) it
# emits a clear operator WARN and proceeds — never a silent mask, never aborts.
# Linux + iso only; a no-op on macOS / shared-mode. Best-effort: a missing helper
# (older bridge-agents.sh) simply skips the preflight (legacy behavior).
if command -v bridge_controller_supp_group_refresh >/dev/null 2>&1; then
  _reconcile_agents_csv=""
  if command -v bridge_layout_v2_reconcile_roster_agents >/dev/null 2>&1; then
    _reconcile_data_root=""
    if command -v bridge_layout_v2_reconcile_data_root >/dev/null 2>&1; then
      _reconcile_data_root="$(bridge_layout_v2_reconcile_data_root 2>/dev/null || true)"
    fi
    _reconcile_agents_csv="$(bridge_layout_v2_reconcile_roster_agents "$_reconcile_data_root" 2>/dev/null || true)"
  fi
  # Re-exec the SAME driver invocation (mode + remaining args) under a fresh
  # group set when stale. This exec does not return on the re-exec path.
  _reconcile_bash_bin="${BRIDGE_BASH_BIN:-${BASH:-$(command -v bash)}}"
  bridge_controller_supp_group_refresh \
    --agents "$_reconcile_agents_csv" \
    --reason "layout-v2 reconcile" \
    --sentinel BRIDGE_RECONCILE_SUPP_REEXEC \
    --mode reexec \
    -- "$_reconcile_bash_bin" "${BASH_SOURCE[0]}" "$mode" "$@"
fi

bridge_layout_v2_reconcile_run --mode "$mode" "$@"
