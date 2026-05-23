#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1151-step-a-helper.sh — Issue #1151
#
# Beta9 follow-up to #1145/#1149. PR #1149 (r3) landed the ownership-based
# defer for `cmd_link_shared_settings` at `lib/bridge-hooks.sh:237-251`. It
# worked structurally, but live verification on v0.14.5-beta9 proved it
# closed only 1 of 5+ controller-side helpers that mutate the isolated
# workdir tree. The other 4 still tripped the same race / post-Step-A
# Permission denied flood.
#
# This smoke pins the lifted predicate `bridge_agent_workdir_step_a_complete`
# (lib/bridge-agents.sh) so that the 5-site application can share one
# tested contract. The function is intentionally NOT isolation-aware itself
# — callers pair-gate it with `bridge_agent_linux_user_isolation_effective`
# so legacy non-isolated callers keep their pre-#1151 behavior. See the
# helper's docstring for the recommended call shape.
#
# Truth table the helper enforces:
#
#   workdir-missing                          → return 1 (defer)
#   stat both flavors fail (empty owner)     → return 1 (fail-closed defer)
#   bridge_agent_os_user empty (roster miss) → return 1 (fail-closed defer)
#   owner != expected                        → return 1 (defer, Step A pending)
#   owner == expected (default agent-bridge-<a>) → return 0 (Step A complete)
#   owner == expected (custom --os-user svc-foo) → return 0 (Step A complete)
#
# T6 (custom --os-user) is the explicit r3 regression contract from #1149:
# the helper must NOT use a `agent-bridge-*` prefix glob; it must exact-
# match against the roster `os_user`.
#
# Stat-shim pattern mirrors the existing 1145-option1-deferral-guard smoke:
# a PATH-prepended fake `stat` reads $SMOKE_FAKE_STAT_OWNER. No real
# `agent-bridge-*` accounts created on the host, no sudo, no python.
#
# Footgun #11 (heredoc_write deadlock class): every driver is built with
# `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash functions; no
# `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1151-step-a-helper"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

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

# ---------- fake stat wrapper ----------
#
# The helper calls `stat -c %U "$workdir"` (GNU/Linux) with `stat -f %Su`
# (BSD/macOS) as a fallback. The shim only handles those two invocations;
# anything else falls through to the real stat. Owner string is sourced
# from $SMOKE_FAKE_STAT_OWNER; "FAIL" or empty makes both flavors exit
# non-zero (exercising the fail-closed defer arm).
FAKE_BIN="$SMOKE_TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
FAKE_STAT="$FAKE_BIN/stat"
REAL_STAT="$(command -v stat 2>/dev/null || true)"
[[ -n "$REAL_STAT" ]] || smoke_fail "host has no stat in PATH"
printf '%s\n' '#!/usr/bin/env bash' >"$FAKE_STAT"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' '# Fake stat shim for 1151-step-a-helper.' >>"$FAKE_STAT"
printf '%s\n' 'set -u' >>"$FAKE_STAT"
printf '%s\n' "REAL_STAT='$REAL_STAT'" >>"$FAKE_STAT"
printf '%s\n' 'owner="${SMOKE_FAKE_STAT_OWNER:-}"' >>"$FAKE_STAT"
printf '%s\n' 'if [[ "$#" -ge 2 && ( "$1" == "-c" || "$1" == "-f" ) ]]; then' >>"$FAKE_STAT"
printf '%s\n' '  fmt="$2"' >>"$FAKE_STAT"
printf '%s\n' '  if [[ "$fmt" == "%U" || "$fmt" == "%Su" ]]; then' >>"$FAKE_STAT"
printf '%s\n' '    if [[ "$owner" == "FAIL" || -z "$owner" ]]; then' >>"$FAKE_STAT"
printf '%s\n' '      exit 1' >>"$FAKE_STAT"
printf '%s\n' '    fi' >>"$FAKE_STAT"
printf '%s\n' '    printf "%s\n" "$owner"' >>"$FAKE_STAT"
printf '%s\n' '    exit 0' >>"$FAKE_STAT"
printf '%s\n' '  fi' >>"$FAKE_STAT"
printf '%s\n' 'fi' >>"$FAKE_STAT"
printf '%s\n' 'exec "$REAL_STAT" "$@"' >>"$FAKE_STAT"
chmod +x "$FAKE_STAT"

# ---------- driver template ----------
#
# Each case builds a tiny bash driver that:
#   1. Extracts the helper body verbatim from lib/bridge-agents.sh
#      (between `^bridge_agent_workdir_step_a_complete() {` and the next
#      top-level `^}`). Keeps the smoke aligned to the live source.
#   2. Stubs `bridge_agent_os_user` to read $SMOKE_FAKE_OS_USER.
#   3. Prepends $FAKE_BIN to $PATH so stat calls hit the shim.
#   4. Invokes the helper and writes "RC=$?" to the log.

build_driver() {
  # $1 = driver path
  local driver="$1"
  printf '%s\n' '#!/usr/bin/env bash' >"$driver"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  printf '%s\n' 'set -uo pipefail' >>"$driver"
  printf '%s\n' 'REPO_ROOT="$1"' >>"$driver"
  printf '%s\n' 'CALL_LOG="$2"' >>"$driver"
  printf '%s\n' 'WORKDIR="$3"' >>"$driver"
  printf '%s\n' 'AGENT="$4"' >>"$driver"
  printf '%s\n' 'FAKE_BIN="$5"' >>"$driver"
  printf '%s\n' 'export PATH="$FAKE_BIN:$PATH"' >>"$driver"
  printf '%s\n' ': >"$CALL_LOG"' >>"$driver"
  printf '%s\n' 'EXTRACT="$(dirname "$CALL_LOG")/helper-fn.sh"' >>"$driver"
  printf '%s\n' 'awk "/^bridge_agent_workdir_step_a_complete\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh" >"$EXTRACT"' >>"$driver"
  printf '%s\n' '# Stub bridge_agent_os_user to read $SMOKE_FAKE_OS_USER.' >>"$driver"
  printf '%s\n' 'bridge_agent_os_user() {' >>"$driver"
  printf '%s\n' '  printf "%s" "${SMOKE_FAKE_OS_USER-}"' >>"$driver"
  printf '%s\n' '}' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1090' >>"$driver"
  printf '%s\n' 'source "$EXTRACT"' >>"$driver"
  printf '%s\n' 'bridge_agent_workdir_step_a_complete "$AGENT" "$WORKDIR"' >>"$driver"
  printf '%s\n' 'echo "RC=$?" >>"$CALL_LOG"' >>"$driver"
  chmod +x "$driver"
}

DRIVER="$SMOKE_TMP_ROOT/driver.sh"
build_driver "$DRIVER"

# ---------- T1 — workdir missing → return 1 (defer) ----------
T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR"
T1_CALL_LOG="$T1_DIR/calls.log"
T1_WORKDIR="$T1_DIR/workdir-does-not-exist"
SMOKE_FAKE_STAT_OWNER="" \
  SMOKE_FAKE_OS_USER="agent-bridge-smoke-agent" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$T1_CALL_LOG" "$T1_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T1_DIR/err" || true
grep -q '^RC=1$' "$T1_CALL_LOG" \
  || smoke_fail "T1 expected RC=1 (workdir missing → defer), got: $(tr '\n' '|' <"$T1_CALL_LOG")"
smoke_log "T1 PASS: workdir-missing → return 1 (defer)"

# ---------- T2 — stat fails (empty owner) → return 1 (defer) ----------
T2_DIR="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_DIR"
T2_CALL_LOG="$T2_DIR/calls.log"
T2_WORKDIR="$T2_DIR/workdir-exists"
mkdir -p "$T2_WORKDIR"
# Owner=FAIL → fake stat exits non-zero on both flavors → guard sees
# empty owner → fail-closed defer.
SMOKE_FAKE_STAT_OWNER="FAIL" \
  SMOKE_FAKE_OS_USER="agent-bridge-smoke-agent" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$T2_CALL_LOG" "$T2_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T2_DIR/err" || true
grep -q '^RC=1$' "$T2_CALL_LOG" \
  || smoke_fail "T2 expected RC=1 (stat fail → fail-closed defer), got: $(tr '\n' '|' <"$T2_CALL_LOG")"
smoke_log "T2 PASS: stat-fail (empty owner) → return 1 (fail-closed defer)"

# ---------- T3 — roster lookup empty (expected_owner empty) → return 1 ----------
T3_DIR="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_DIR"
T3_CALL_LOG="$T3_DIR/calls.log"
T3_WORKDIR="$T3_DIR/workdir-exists"
mkdir -p "$T3_WORKDIR"
# Owner present (stat OK) but expected_owner empty (roster lookup returns
# empty). Guard must NOT proceed — fail-closed defer protects against a
# misconfigured roster.
SMOKE_FAKE_STAT_OWNER="agent-bridge-smoke-agent" \
  SMOKE_FAKE_OS_USER="" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$T3_CALL_LOG" "$T3_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T3_DIR/err" || true
grep -q '^RC=1$' "$T3_CALL_LOG" \
  || smoke_fail "T3 expected RC=1 (roster miss → fail-closed defer), got: $(tr '\n' '|' <"$T3_CALL_LOG")"
smoke_log "T3 PASS: roster lookup empty (expected_owner empty) → return 1 (fail-closed defer)"

# ---------- T4 — owner != expected (Step A pending) → return 1 (defer) ----------
T4_DIR="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_DIR"
T4_CALL_LOG="$T4_DIR/calls.log"
T4_WORKDIR="$T4_DIR/workdir-exists"
mkdir -p "$T4_WORKDIR"
# Workdir owned by controller (awfmanager-style); expected is agent-bridge-
# smoke-agent. This is the canonical pre-Step-A v2 fresh-create shape.
SMOKE_FAKE_STAT_OWNER="awfmanager" \
  SMOKE_FAKE_OS_USER="agent-bridge-smoke-agent" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$T4_CALL_LOG" "$T4_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T4_DIR/err" || true
grep -q '^RC=1$' "$T4_CALL_LOG" \
  || smoke_fail "T4 expected RC=1 (owner=controller != expected agent → defer), got: $(tr '\n' '|' <"$T4_CALL_LOG")"
smoke_log "T4 PASS: owner=controller != expected agent-bridge-<a> → return 1 (Step A pending defer)"

# ---------- T5 — owner == expected (default agent-bridge-<a>) → return 0 ----------
T5_DIR="$SMOKE_TMP_ROOT/t5"
mkdir -p "$T5_DIR"
T5_CALL_LOG="$T5_DIR/calls.log"
T5_WORKDIR="$T5_DIR/workdir-exists"
mkdir -p "$T5_WORKDIR"
SMOKE_FAKE_STAT_OWNER="agent-bridge-smoke-agent" \
  SMOKE_FAKE_OS_USER="agent-bridge-smoke-agent" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$T5_CALL_LOG" "$T5_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T5_DIR/err" || true
grep -q '^RC=0$' "$T5_CALL_LOG" \
  || smoke_fail "T5 expected RC=0 (owner == expected, Step A complete), got: $(tr '\n' '|' <"$T5_CALL_LOG")"
smoke_log "T5 PASS: owner == expected default (agent-bridge-<a>) → return 0 (Step A complete)"

# ---------- T6 — owner == expected (custom --os-user svc-foo) → return 0 ----------
#
# Explicit regression contract from PR #1149 r3: the helper must exact-match
# against `bridge_agent_os_user "$agent"` (the roster value Step A passes to
# chown), NOT a `agent-bridge-*` prefix glob. An agent created with
# `--os-user svc-foo` has a valid post-Step-A workdir owned by `svc-foo` —
# a prefix glob would defer forever; exact-match against the roster value
# succeeds.
T6_DIR="$SMOKE_TMP_ROOT/t6"
mkdir -p "$T6_DIR"
T6_CALL_LOG="$T6_DIR/calls.log"
T6_WORKDIR="$T6_DIR/workdir-exists"
mkdir -p "$T6_WORKDIR"
SMOKE_FAKE_STAT_OWNER="svc-foo" \
  SMOKE_FAKE_OS_USER="svc-foo" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$T6_CALL_LOG" "$T6_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T6_DIR/err" || true
grep -q '^RC=0$' "$T6_CALL_LOG" \
  || smoke_fail "T6 expected RC=0 (owner=svc-foo == expected svc-foo via --os-user override), got: $(tr '\n' '|' <"$T6_CALL_LOG")"
smoke_log "T6 PASS: owner == expected custom (--os-user svc-foo) → return 0 (Step A complete, prefix-glob anti-regression)"

smoke_log "all 6 tests PASS (#1151 bridge_agent_workdir_step_a_complete contract)"
