#!/usr/bin/env bash
# scripts/smoke/2171-rotate-preflight-budget.sh — regression for issue #2171
# PR-B2 Part1 (operator incident #19460 M4 fleet-down).
#
# PR-B1 added an opt-in `rotate --preflight` that LIVE-probes the selected
# rotation candidate before committing, but it was DORMANT in the fleet: the
# daemon's usage-monitor rotate call never passed `--preflight`, and a multi-
# candidate ring of slow probes had no global time bound. PR-B2 Part1:
#   * `rotate --preflight-budget <total_sec>` caps the SUMMED probe time across
#     the whole ring; each candidate's actual probe = min(--preflight-timeout,
#     remaining_budget).
#   * Budget-exhausted, UNPROBED candidates FAIL CLOSED — excluded with the
#     stable trace reason `preflight_budget_exhausted`, NEVER committed from
#     stale registry availability alone (commit authority stays a parseable live
#     `available` probe).
#   * A fully budget-exhausted/failed pass emits the EXISTING
#     `skipped:all_tokens_limited` envelope (never a truncated/invalid rotate
#     JSON), which the daemon already routes through the #1789 D2 path.
#   * bridge-daemon.sh now enables `--preflight --preflight-budget` for EVERY
#     rotation and raises the `bridge_with_timeout` ceiling to budget + overhead.
#
# Coverage:
#   PY  — scripts/smoke/2171-rotate-preflight-budget-helper.py drives 3 budget
#         scenarios with an INJECTED probe (fake claude, NO network, MOCK tokens),
#         and feeds every envelope through the REAL bridge-daemon-helpers.py
#         rotation-status-parse to prove the budget paths never degrade to
#         `error:invalid_rotation_output`:
#           1 budget expires before a registry-available candidate is probed ->
#             fail-closed (active unchanged, sync not triggered, trace
#             preflight_budget_exhausted, envelope skipped:all_tokens_limited);
#           2 three-alternate ring (timeout + auth-fail then success) commits the
#             last candidate within budget; daemon parser sees `rotated`, never a
#             SIGKILL/invalid output;
#           3 mixed auth-fail + timeout + budget-exhausted-available pool ->
#             all_tokens_limited preserved (#1789 D2).
#   D1  — daemon enablement: bridge-daemon.sh's usage-monitor rotate call passes
#         `--preflight` AND `--preflight-budget` AND `--preflight-timeout`, still
#         passes `--if-auto-enabled` + `--sync` (no second rotator/notifier), and
#         the `bridge_with_timeout` ceiling default is >= the preflight budget
#         default (the ceiling absorbs a full budgeted ring).
#   S4  — footgun #11: no heredoc-stdin into a python3/bash subprocess.

set -euo pipefail

SMOKE_NAME="2171-rotate-preflight-budget"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

DAEMON="$REPO_ROOT/bridge-daemon.sh"
HELPER="$SCRIPT_DIR/2171-rotate-preflight-budget-helper.py"

# Hermetic: never touch the live runtime / token registry / live daemon.
unset BRIDGE_HOME BRIDGE_RUNTIME_CONFIG_FILE BRIDGE_RUNTIME_ROOT BRIDGE_STATE_DIR 2>/dev/null || true

failed=0
fail() { echo "  FAIL  $1" >&2; failed=1; }
ok() { echo "  PASS  $1"; }

# --- PY: behavioral budget harness (injected probe, no network, mock tokens) ---
echo "[PY] injected-probe budget scenarios (3 cases + daemon-parse roundtrip)"
if python3 "$HELPER"; then
  ok "python harness: all budget assertions pass"
else
  fail "python harness: one or more budget assertions failed"
fi

# --- D1: daemon enablement + ceiling absorbs the budget -----------------------
echo "[D1] bridge-daemon.sh enables --preflight --preflight-budget; ceiling >= budget"
# Capture the usage-monitor rotate call block (the bridge_with_timeout line down
# to its `|| true)"` close) so the assertions are scoped to that one call.
rotate_block="$(awk '/daemon_auth_token_rotate .*claude-token rotate/{f=1} f{print} f&&/\|\| true\)"/{exit}' "$DAEMON")"
if [[ -z "$rotate_block" ]]; then
  fail "could not locate the usage-monitor rotate call in bridge-daemon.sh"
else
  printf '%s\n' "$rotate_block" | grep -qE -- '--preflight\b' \
    && ok "daemon rotate call passes --preflight (B1 un-dormanted for the fleet)" \
    || fail "daemon rotate call does NOT pass --preflight"
  printf '%s\n' "$rotate_block" | grep -qE -- '--preflight-budget' \
    && ok "daemon rotate call passes --preflight-budget (global ring bound)" \
    || fail "daemon rotate call does NOT pass --preflight-budget"
  printf '%s\n' "$rotate_block" | grep -qE -- '--preflight-timeout' \
    && ok "daemon rotate call passes --preflight-timeout (per-candidate cap)" \
    || fail "daemon rotate call does NOT pass --preflight-timeout"
  printf '%s\n' "$rotate_block" | grep -qE -- '--if-auto-enabled' \
    && ok "daemon rotate call still gates on --if-auto-enabled (no behavior drift)" \
    || fail "daemon rotate call dropped --if-auto-enabled"
  printf '%s\n' "$rotate_block" | grep -qE -- '--sync' \
    && ok "daemon rotate call still reuses the existing --sync fanout (no second rotator)" \
    || fail "daemon rotate call dropped --sync"

  # Ceiling absorbs the budget: the bridge_with_timeout default must be >= the
  # preflight-budget default so a full budgeted ring + sync fanout fits inside it
  # (never SIGKILLed into error:invalid_rotation_output).
  ceiling_default="$(printf '%s\n' "$rotate_block" | grep -oE 'BRIDGE_CLAUDE_ROTATE_TIMEOUT_SECONDS:-[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
  budget_default="$(printf '%s\n' "$rotate_block" | grep -oE 'BRIDGE_CLAUDE_ROTATE_PREFLIGHT_BUDGET_SECONDS:-[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
  if [[ -z "$ceiling_default" ]]; then
    fail "could not parse the bridge_with_timeout ceiling default"
  elif [[ "$ceiling_default" == "20" ]]; then
    fail "bridge_with_timeout ceiling is still the pre-B2 default 20 (not raised for the budget)"
  elif [[ -z "$budget_default" ]]; then
    fail "could not parse the --preflight-budget default"
  elif (( ceiling_default >= budget_default )); then
    ok "ceiling default ${ceiling_default}s >= budget default ${budget_default}s (ceiling absorbs a full ring)"
  else
    fail "ceiling default ${ceiling_default}s < budget default ${budget_default}s (a full ring would be SIGKILLed)"
  fi
fi

# --- S4: footgun #11 — no heredoc-stdin into python3/bash in smoke/helper ------
echo "[S4] footgun #11: smoke + helper invoke python3 by file path (no heredoc-stdin)"
# Build the redirect tokens at runtime so this scanner line itself does not
# contain the literal operators the sister heredoc-ban lint matches on.
lt='<'
redir_pattern="python3[^|]*${lt}${lt}|bash[[:space:]]+${lt}${lt}"
hd_hit=0
for f in "$SCRIPT_DIR/${SMOKE_NAME}.sh" "$HELPER"; do
  if grep -nE "$redir_pattern" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
    fail "heredoc-stdin into a subprocess found in $(basename "$f")"
    hd_hit=1
  fi
done
[[ "$hd_hit" -eq 0 ]] && ok "no heredoc-stdin into a python3/bash subprocess in the smoke or helper"

if [[ "$failed" -ne 0 ]]; then
  echo "[smoke:${SMOKE_NAME}] FAILED"
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] PASS"
