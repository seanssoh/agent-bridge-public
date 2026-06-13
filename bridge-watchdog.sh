#!/usr/bin/env bash
# bridge-watchdog.sh — scan bridge-owned agent homes for drift and onboarding gaps

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

# Fresh-group preflight (#1820 rc4, item 2 — SHARED with the reconcile invoker).
#
# The cm-prod watchdog iso-uid-side rows are a TRANSIENT stale-group window: a
# scan forked from a daemon whose login-time supplementary group set predates an
# `agent create`/`isolate` (KNOWN_ISSUES §28 / #1836) briefly lacks the new
# ab-agent-<a> groups, so os.scandir(2770 workdir/home) throws Errno13 →
# permission_denied even on a healthy iso bot. Refreshing the group set BEFORE
# the scan eliminates that window, so a genuine iso-uid-side row then means a
# REAL misconfiguration (not a transient). Same shared helper the reconcile
# driver uses (bridge_controller_supp_group_refresh in lib/bridge-agents.sh).
#
# Primary path: re-exec THIS watchdog entry under `sg <grp>` (fresh, complete
# group set), anti-loop via BRIDGE_WATCHDOG_SUPP_REEXEC. Fallback when re-exec is
# impossible (`sg` missing / not a member): export
# BRIDGE_WATCHDOG_ISO_GROUP_STALE=1 so bridge-watchdog.py DOWNGRADES iso-uid-side
# permission_denied rows to `info` (not problem/HIGH) — the operator-priority
# order is remove+preflight > info-downgrade > plain-remove. Linux + iso only;
# a no-op on macOS / shared-mode. Best-effort: a missing helper skips it.
if command -v bridge_controller_supp_group_refresh >/dev/null 2>&1; then
  if command -v bridge_load_roster >/dev/null 2>&1; then
    bridge_load_roster >/dev/null 2>&1 || true
  fi
  _wd_agents_csv=""
  if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    _wd_agents_csv="$(IFS=,; printf '%s' "${BRIDGE_AGENT_IDS[*]:-}")"
  fi
  _wd_bash_bin="${BRIDGE_BASH_BIN:-${BASH:-$(command -v bash)}}"
  # Already re-exec'd (groups now fresh) — skip the whole preflight; a stale
  # signal from a parent pass must NOT leak into this fresh-group scan.
  if [[ "${BRIDGE_WATCHDOG_SUPP_REEXEC:-0}" != "1" ]]; then
    # Attempt the in-process refresh (re-exec). If the helper CAN deliver the
    # missing groups it exec-replaces this process under `sg` (the re-exec'd
    # pass has fresh groups and short-circuits via the sentinel) and never
    # returns. If the live set is already fresh it returns immediately (no-op).
    # It returns WITHOUT exec-ing only when the set is stale AND the refresh is
    # impossible (`sg` missing) — that is the ONLY case we want the
    # info-downgrade fallback, so we detect-confirm staleness AFTER the reexec
    # attempt returns and set the env signal only then.
    bridge_controller_supp_group_refresh \
      --agents "$_wd_agents_csv" \
      --reason "watchdog scan" \
      --sentinel BRIDGE_WATCHDOG_SUPP_REEXEC \
      --mode reexec \
      -- "$_wd_bash_bin" "${BASH_SOURCE[0]}" "$@"
    # Reached here ⇒ no exec happened. If the set is STILL stale (detect returns
    # 10), the refresh was impossible — fall back to the info-downgrade signal
    # so the transient restart-window rows do not churn as HIGH problems.
    if ! bridge_controller_supp_group_refresh \
        --agents "$_wd_agents_csv" \
        --reason "watchdog scan" \
        --mode detect; then
      export BRIDGE_WATCHDOG_ISO_GROUP_STALE=1
    fi
  fi
fi

bridge_require_python
exec python3 "$SCRIPT_DIR/bridge-watchdog.py" "$@"
