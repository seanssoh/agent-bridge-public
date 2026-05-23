#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1145-option1-deferral-guard.sh — Issue #1145 Option 1 (r2).
#
# Beta9 follow-up to #1145. PR #1146 added try/except OSError wrapping in
# `cmd_link_shared_settings` (containment). The deeper diagnostic identified
# the ROOT cause as a flow-ordering race between two mkdir authorities on
# `<v2-root>/<agent>/`:
#
#   Step A — `bridge_linux_prepare_agent_isolation`, runs as root via sudo,
#            materializes `<v2-root>/<agent>/workdir/` with ownership
#            `agent-bridge-<a>:ab-agent-<a> mode 2750`.
#   Step B — `cmd_link_shared_settings`, controller-side hook running as the
#            controller user (awfmanager), attempts to mkdir
#            `<v2-root>/<agent>/workdir/.claude/`.
#
# On a fresh `agent create` Step B fires BEFORE Step A. The controller has
# write on `<v2-root>/agents/` (it owns the dir) so `Path.mkdir(parents=True)`
# silently creates the entire chain as `awfmanager:awfmanager 0755`. Step A
# later finds the dir already owned by awfmanager and the cascade of
# PermissionErrors begins.
#
# Fix (Option 1 — `lib/bridge-hooks.sh:192`):
#   When v2 isolation is effective for the agent AND the workdir has not yet
#   been NORMALIZED by Step A (owner != `agent-bridge-*`),
#   `bridge_link_claude_settings_to_shared` returns 0 without invoking
#   `bridge_hooks_python link-shared-settings`. Agent start re-triggers the
#   hook after Step A runs, so the deferral is correct (NOT permanently
#   skipped). Legacy non-isolated callers + post-Step-A callers keep the
#   existing behavior.
#
# r2 (codex BLOCKING — 2026-05-24):
#   The r1 fixer's existence-based guard (`[[ ! -d "$workdir" ]]`) did NOT
#   fire in the canonical v2 fresh-create path because
#   `_scaffold_v2_sibling` pre-creates the workdir as the controller user
#   BEFORE `bridge_linux_prepare_agent_isolation` runs. Step-A completion
#   must be detected by OWNERSHIP, not existence. Pre-r2 T2 asserted
#   "workdir present → proceed", which masked exactly the failing
#   production shape. T2 is now split into T2a (owner = agent-bridge-*,
#   Step A complete, proceed) + T2b (owner = controller-style, pre-Step-A,
#   defer). T5 adds an integration-style assertion that
#   `bridge_hooks_python link-shared-settings` is NOT invoked when the
#   guard fires. T2b + T5 catch the r1 gap — they FAIL against the
#   existence-only implementation.
#
# Companion (Sub-B — `lib/bridge-agents.sh:4395`):
#   When `bridge_agent_onboarding_markers_complete` rc=2 (controller blind +
#   iso-UID probe unavailable, the v2 isolation shape), the onboarding state
#   downgrades to `unverifiable` instead of inheriting the SESSION-TYPE.md
#   `complete` reading. This matches the `agent list` `[unreadable]` text and
#   the `watchdog scan` `scan_error/permission_denied` signal so the three
#   diagnostics agree.
#
# This smoke is HOST-AGNOSTIC: every driver runs in a fixture tree with
# stubs for the bridge-side functions plus a PATH-prepended fake `stat`
# wrapper that returns a chosen owner string for the test workdir. No
# sudo, no python invocation, no real workdir provisioning, no
# `agent-bridge-*` user creation on the host.
#
# Footgun #11 (heredoc_write deadlock class): every driver is built with
# `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash functions; no
# `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1145-option1-deferral-guard"
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
# The r2 guard calls `stat -c %U "$workdir"` (GNU/Linux) with `stat -f %Su`
# (BSD/macOS) as a fallback. Both flavors return the owner-name string. The
# smoke runs as the test user; `agent-bridge-*` accounts do not exist, so
# we cannot chown a real fixture to that owner without sudo.
#
# Workaround: prepend a wrapper directory to `$PATH` that contains a `stat`
# shim. The shim only handles the `-c %U` and `-f %Su` invocations the
# guard makes; everything else falls through to the real `stat` so the
# rest of the bridge code (which we don't actually call here, but might
# in future T5 expansions) still sees real behavior.
#
# The shim reads the chosen owner from $SMOKE_FAKE_STAT_OWNER. An empty
# value (or "FAIL") makes both flavors exit non-zero, exercising the
# `|| true` fallback in the guard (T5).
FAKE_BIN="$SMOKE_TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
FAKE_STAT="$FAKE_BIN/stat"
# Resolve the real stat at smoke-construction time so the shim can dispatch
# unrelated calls without re-running command lookup.
REAL_STAT="$(command -v stat 2>/dev/null || true)"
[[ -n "$REAL_STAT" ]] || smoke_fail "host has no stat in PATH — smoke needs a real stat to fall back to for non-owner calls"
printf '%s\n' '#!/usr/bin/env bash' >"$FAKE_STAT"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' '# Fake stat shim for 1145-option1-deferral-guard.' >>"$FAKE_STAT"
printf '%s\n' 'set -u' >>"$FAKE_STAT"
printf '%s\n' "REAL_STAT='$REAL_STAT'" >>"$FAKE_STAT"
printf '%s\n' 'owner="${SMOKE_FAKE_STAT_OWNER:-}"' >>"$FAKE_STAT"
printf '%s\n' '# Match the exact argv shapes the guard uses.' >>"$FAKE_STAT"
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
printf '%s\n' '# Fall through to the real stat for anything else.' >>"$FAKE_STAT"
printf '%s\n' 'exec "$REAL_STAT" "$@"' >>"$FAKE_STAT"
chmod +x "$FAKE_STAT"

# ---------- shared driver template ----------
#
# Each T1/T2a/T2b/T3/T5 case builds a tiny bash driver that:
#   1. Sources the extracted `bridge_link_claude_settings_to_shared` function.
#   2. Pins stub implementations of every bridge-side function the body
#      reaches (settings mode, render path, bridge_hooks_python, isolation
#      check, etc.). Stubs append a one-line tag to `$CALL_LOG` so the test
#      can assert which branches fired.
#   3. Invokes the function under test with controlled inputs.
#   4. Prepends $FAKE_BIN to $PATH so the guard's `stat -c %U` / `stat -f %Su`
#      calls hit the shim instead of the real stat.
#
# The function body itself is extracted verbatim from
# `lib/bridge-hooks.sh` via awk between the `^bridge_link_claude_settings_to_shared() {`
# header and the next top-level `^}`. That keeps the smoke aligned to the
# actual source — any future drift in the function body still exercises the
# guard contract.

build_driver() {
  # $1 = driver path
  # $2 = stubs file path (case-specific) — sourced AFTER the extracted fn
  local driver="$1"
  local stubs="$2"
  printf '%s\n' '#!/usr/bin/env bash' >"$driver"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  printf '%s\n' 'set -uo pipefail' >>"$driver"
  printf '%s\n' 'REPO_ROOT="$1"' >>"$driver"
  printf '%s\n' 'STUBS="$2"' >>"$driver"
  printf '%s\n' 'CALL_LOG="$3"' >>"$driver"
  printf '%s\n' 'WORKDIR="$4"' >>"$driver"
  printf '%s\n' 'AGENT="$5"' >>"$driver"
  printf '%s\n' 'FAKE_BIN="$6"' >>"$driver"
  printf '%s\n' 'export PATH="$FAKE_BIN:$PATH"' >>"$driver"
  printf '%s\n' ': >"$CALL_LOG"' >>"$driver"
  printf '%s\n' '# Extract the function under test (verbatim from source).' >>"$driver"
  printf '%s\n' 'EXTRACT="$(dirname "$CALL_LOG")/link-fn.sh"' >>"$driver"
  printf '%s\n' 'awk "/^bridge_link_claude_settings_to_shared\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-hooks.sh" >"$EXTRACT"' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1090' >>"$driver"
  printf '%s\n' 'source "$STUBS"' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1090' >>"$driver"
  printf '%s\n' 'source "$EXTRACT"' >>"$driver"
  printf '%s\n' 'bridge_link_claude_settings_to_shared "$WORKDIR" "" "$AGENT"' >>"$driver"
  printf '%s\n' 'echo "RC=$?" >>"$CALL_LOG"' >>"$driver"
  chmod +x "$driver"
  : "$stubs"  # silence "unused" lint — caller writes it
}

# Stubs common to all cases. Every bridge-side helper that the function
# under test calls returns a deterministic value AND records its call into
# $CALL_LOG. The case-specific stub file sources this then overrides
# `bridge_agent_linux_user_isolation_effective` to flip behavior.
write_common_stubs() {
  # $1 = stubs file path
  local stubs="$1"
  printf '%s\n' '# Common stubs for 1145-option1-deferral-guard cases.' >"$stubs"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  printf '%s\n' '# CALL_LOG is exported by the driver above.' >>"$stubs"
  printf '%s\n' 'bridge_claude_settings_mode() { echo "shared"; }' >>"$stubs"
  printf '%s\n' 'bridge_hook_shared_settings_base_file() { echo "$WORKDIR/.base.json"; }' >>"$stubs"
  printf '%s\n' 'bridge_hook_shared_settings_overlay_file() { echo "$WORKDIR/.overlay.json"; }' >>"$stubs"
  printf '%s\n' 'bridge_hook_shared_settings_effective_file() { echo "$WORKDIR/.effective.json"; }' >>"$stubs"
  printf '%s\n' 'bridge_hook_per_agent_settings_effective_file() { echo "$WORKDIR/.per-agent.json"; }' >>"$stubs"
  printf '%s\n' 'bridge_agent_source() { echo ""; }' >>"$stubs"
  printf '%s\n' 'bridge_agent_claude_config_dir() { echo ""; }' >>"$stubs"
  printf '%s\n' 'bridge_hook_paths_equal() { echo "1"; }' >>"$stubs"
  printf '%s\n' 'bridge_hooks_python() {' >>"$stubs"
  printf '%s\n' '  # Record the verb (first arg) — render-shared-settings vs link-shared-settings.' >>"$stubs"
  printf '%s\n' '  echo "bridge_hooks_python:$1" >>"$CALL_LOG"' >>"$stubs"
  printf '%s\n' '  return 0' >>"$stubs"
  printf '%s\n' '}' >>"$stubs"
}

# ---------- T1 — isolation effective + workdir missing → deferral ----------
#
# When isolation is effective AND the workdir does NOT yet exist (the
# earliest-possible pre-Step-A shape), the function must return 0 WITHOUT
# calling `bridge_hooks_python link-shared-settings`. The render call
# (which writes to a separate `effective_file` controller-owned path) is
# allowed to run — it's the link step that races Step A.
#
# Pre-r2 contract: existence-based guard fires here. Post-r2: ownership-
# based guard also fires here (workdir doesn't exist → owner empty →
# `[[ -z "$_wd_owner" ]]` branch defers). Same observable outcome.
T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR"
T1_STUBS="$T1_DIR/stubs.sh"
write_common_stubs "$T1_STUBS"
printf '%s\n' '# T1: isolation EFFECTIVE.' >>"$T1_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T1_STUBS"
T1_DRIVER="$T1_DIR/driver.sh"
build_driver "$T1_DRIVER" "$T1_STUBS"

T1_CALL_LOG="$T1_DIR/calls.log"
# Deliberately point at a path that does NOT exist — the deferral guard's
# original trigger condition (and still a valid pre-Step-A shape for r2).
T1_WORKDIR="$T1_DIR/workdir-does-not-exist"
SMOKE_FAKE_STAT_OWNER="" \
  "$BRIDGE_BASH" "$T1_DRIVER" "$REPO_ROOT" "$T1_STUBS" "$T1_CALL_LOG" "$T1_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T1_DIR/err" \
  || smoke_fail "T1 driver rc=$? — see $T1_DIR/err"

T1_LINK_CALLED=0
if grep -q '^bridge_hooks_python:link-shared-settings$' "$T1_CALL_LOG"; then
  T1_LINK_CALLED=1
fi
if [[ $T1_LINK_CALLED -ne 0 ]]; then
  smoke_fail "T1 expected NO bridge_hooks_python:link-shared-settings call (deferral guard should short-circuit). calls: $(tr '\n' '|' <"$T1_CALL_LOG")"
fi
grep -q '^RC=0$' "$T1_CALL_LOG" \
  || smoke_fail "T1 expected RC=0 (deferral returns 0). calls: $(tr '\n' '|' <"$T1_CALL_LOG")"
smoke_log "T1 PASS: isolation-effective + workdir-missing → link-shared-settings deferred, return 0"

# ---------- T2a — workdir exists + owner = agent-bridge-* → proceeds ----------
#
# Step A has completed: the workdir directory exists AND ownership has been
# normalized to `agent-bridge-<agent>`. The guard's ownership check finds
# the agent-bridge-* prefix and short-circuits to `false` → link-shared-
# settings fires (the legacy "happy path" after Step A).
T2A_DIR="$SMOKE_TMP_ROOT/t2a"
mkdir -p "$T2A_DIR"
T2A_STUBS="$T2A_DIR/stubs.sh"
write_common_stubs "$T2A_STUBS"
printf '%s\n' '# T2a: isolation EFFECTIVE, workdir present, owner = agent-bridge-<agent> (Step A complete).' >>"$T2A_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T2A_STUBS"
T2A_DRIVER="$T2A_DIR/driver.sh"
build_driver "$T2A_DRIVER" "$T2A_STUBS"

T2A_CALL_LOG="$T2A_DIR/calls.log"
T2A_WORKDIR="$T2A_DIR/workdir-exists"
mkdir -p "$T2A_WORKDIR"
SMOKE_FAKE_STAT_OWNER="agent-bridge-smoke-agent" \
  "$BRIDGE_BASH" "$T2A_DRIVER" "$REPO_ROOT" "$T2A_STUBS" "$T2A_CALL_LOG" "$T2A_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T2A_DIR/err" \
  || smoke_fail "T2a driver rc=$? — see $T2A_DIR/err"

grep -q '^bridge_hooks_python:link-shared-settings$' "$T2A_CALL_LOG" \
  || smoke_fail "T2a expected bridge_hooks_python:link-shared-settings to fire (owner=agent-bridge-*, Step A complete). calls: $(tr '\n' '|' <"$T2A_CALL_LOG")"
smoke_log "T2a PASS: isolation-effective + workdir-present + owner=agent-bridge-* → link-shared-settings proceeds"

# ---------- T2b — workdir exists + owner = controller → defers (codex r1 BLOCKING) ----------
#
# This is the canonical v2 fresh-create shape that the pre-r2 existence-only
# guard missed: `_scaffold_v2_sibling` pre-creates the workdir as the
# controller (e.g. awfmanager) BEFORE `bridge_linux_prepare_agent_isolation`
# runs, so the workdir EXISTS but is NOT owned by `agent-bridge-*`. Pre-r2
# the guard's `[[ ! -d "$workdir" ]]` was false here → link-shared-settings
# proceeded → controller-as-awfmanager mkdir'd `.claude/` with wrong owner
# → Step A later raced and the cascade began.
#
# Post-r2: the ownership-based guard catches this exact shape and defers.
# THIS test FAILS against the r1 implementation — that's the regression
# contract.
T2B_DIR="$SMOKE_TMP_ROOT/t2b"
mkdir -p "$T2B_DIR"
T2B_STUBS="$T2B_DIR/stubs.sh"
write_common_stubs "$T2B_STUBS"
printf '%s\n' '# T2b: isolation EFFECTIVE, workdir present, owner = controller-style (pre-Step-A — codex BLOCKING shape).' >>"$T2B_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T2B_STUBS"
T2B_DRIVER="$T2B_DIR/driver.sh"
build_driver "$T2B_DRIVER" "$T2B_STUBS"

T2B_CALL_LOG="$T2B_DIR/calls.log"
T2B_WORKDIR="$T2B_DIR/workdir-exists"
mkdir -p "$T2B_WORKDIR"
# `awfmanager` is the canonical controller account name on the Linux server
# host; the test value just needs to NOT start with `agent-bridge-`.
SMOKE_FAKE_STAT_OWNER="awfmanager" \
  "$BRIDGE_BASH" "$T2B_DRIVER" "$REPO_ROOT" "$T2B_STUBS" "$T2B_CALL_LOG" "$T2B_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T2B_DIR/err" \
  || smoke_fail "T2b driver rc=$? — see $T2B_DIR/err"

T2B_LINK_CALLED=0
if grep -q '^bridge_hooks_python:link-shared-settings$' "$T2B_CALL_LOG"; then
  T2B_LINK_CALLED=1
fi
if [[ $T2B_LINK_CALLED -ne 0 ]]; then
  smoke_fail "T2b expected NO bridge_hooks_python:link-shared-settings call (workdir present but pre-Step-A, owner=controller — codex BLOCKING shape). calls: $(tr '\n' '|' <"$T2B_CALL_LOG"). NOTE: this test FAILS against the r1 existence-only guard by design."
fi
grep -q '^RC=0$' "$T2B_CALL_LOG" \
  || smoke_fail "T2b expected RC=0 (deferral returns 0). calls: $(tr '\n' '|' <"$T2B_CALL_LOG")"
smoke_log "T2b PASS: isolation-effective + workdir-present + owner=controller → link-shared-settings deferred (codex r1 BLOCKING shape caught)"

# ---------- T3 — isolation NOT effective → proceeds regardless ----------
#
# Legacy non-isolated callers (shared-mode or v1 installs) must keep their
# pre-#1145 behavior. The guard's first conjunct
# (`bridge_agent_linux_user_isolation_effective` returns non-zero) short-
# circuits the check, so the link step fires even when the workdir doesn't
# yet exist on disk AND even with a non-agent-bridge owner.
T3_DIR="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_DIR"
T3_STUBS="$T3_DIR/stubs.sh"
write_common_stubs "$T3_STUBS"
printf '%s\n' '# T3: isolation NOT effective.' >>"$T3_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$T3_STUBS"
T3_DRIVER="$T3_DIR/driver.sh"
build_driver "$T3_DRIVER" "$T3_STUBS"

T3_CALL_LOG="$T3_DIR/calls.log"
T3_WORKDIR="$T3_DIR/workdir-not-yet"
# NB: workdir absent — but isolation NOT effective → guard does NOT fire.
# Owner string is irrelevant here because the first conjunct short-circuits;
# pass empty to confirm the legacy non-isolated path doesn't even consult stat.
SMOKE_FAKE_STAT_OWNER="" \
  "$BRIDGE_BASH" "$T3_DRIVER" "$REPO_ROOT" "$T3_STUBS" "$T3_CALL_LOG" "$T3_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T3_DIR/err" \
  || smoke_fail "T3 driver rc=$? — see $T3_DIR/err"

grep -q '^bridge_hooks_python:link-shared-settings$' "$T3_CALL_LOG" \
  || smoke_fail "T3 expected bridge_hooks_python:link-shared-settings to fire (non-isolated legacy path). calls: $(tr '\n' '|' <"$T3_CALL_LOG")"
smoke_log "T3 PASS: isolation-not-effective → link-shared-settings proceeds (legacy preserved)"

# ---------- T4 — agent show: onboarding_state=unverifiable when markers rc=2 ----------
#
# Drives `bridge_agent_onboarding_state` against a fixture where
# SESSION-TYPE.md parses to `complete` but the marker check helper returns
# rc=2 (unverifiable). Pre-fix this path printed `complete` (false-
# positive that motivated #1145 sub-B). Post-fix it prints `unverifiable`
# so `agent show` agrees with `agent list [unreadable]` and
# `watchdog scan scan_error/permission_denied`.
T4_DIR="$SMOKE_TMP_ROOT/t4"
T4_WORKDIR="$T4_DIR/workdir"
mkdir -p "$T4_WORKDIR"
printf '%s\n' '- Onboarding State: complete' >"$T4_WORKDIR/SESSION-TYPE.md"

T4_DRIVER="$T4_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T4_DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'set -uo pipefail' >>"$T4_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"; FIXTURE_DIR="$2"; MARKER_RC="$3"' >>"$T4_DRIVER"
printf '%s\n' 'awk "/^bridge_agent_onboarding_state\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh" >"$FIXTURE_DIR/state-fn.sh"' >>"$T4_DRIVER"
printf '%s\n' 'bridge_agent_workdir() { printf "%s" "$FIXTURE_DIR/workdir"; }' >>"$T4_DRIVER"
printf '%s\n' 'bridge_agent_default_home() { printf "%s" "$FIXTURE_DIR/home"; }' >>"$T4_DRIVER"
printf '%s\n' '# Stub the markers helper to return the requested rc.' >>"$T4_DRIVER"
printf '%s\n' 'bridge_agent_onboarding_markers_complete() { return "$MARKER_RC"; }' >>"$T4_DRIVER"
printf '%s\n' '# shellcheck disable=SC1091' >>"$T4_DRIVER"
printf '%s\n' 'source "$FIXTURE_DIR/state-fn.sh"' >>"$T4_DRIVER"
printf '%s\n' 'bridge_agent_onboarding_state "smoke-agent"' >>"$T4_DRIVER"

# rc=2 → markers unverifiable → state must be `unverifiable` post-fix.
T4_RC2_OUT="$("$BRIDGE_BASH" "$T4_DRIVER" "$REPO_ROOT" "$T4_DIR" 2 2>"$T4_DIR/rc2.err")" \
  || smoke_fail "T4 rc=2 driver rc=$? — see $T4_DIR/rc2.err"
[[ "$T4_RC2_OUT" == "unverifiable" ]] \
  || smoke_fail "T4 expected 'unverifiable' when markers helper rc=2, got '$T4_RC2_OUT' — pre-fix returned 'complete' (false-positive)"

# rc=0 → markers all present → state stays `complete` (regression guard).
T4_RC0_OUT="$("$BRIDGE_BASH" "$T4_DRIVER" "$REPO_ROOT" "$T4_DIR" 0 2>"$T4_DIR/rc0.err")" \
  || smoke_fail "T4 rc=0 driver rc=$? — see $T4_DIR/rc0.err"
[[ "$T4_RC0_OUT" == "complete" ]] \
  || smoke_fail "T4 expected 'complete' when markers helper rc=0, got '$T4_RC0_OUT' — marker check should not regress"

# rc=1 → markers missing → state stays `partial` (existing #1139 contract).
T4_RC1_OUT="$("$BRIDGE_BASH" "$T4_DRIVER" "$REPO_ROOT" "$T4_DIR" 1 2>"$T4_DIR/rc1.err")" \
  || smoke_fail "T4 rc=1 driver rc=$? — see $T4_DIR/rc1.err"
[[ "$T4_RC1_OUT" == "partial" ]] \
  || smoke_fail "T4 expected 'partial' when markers helper rc=1, got '$T4_RC1_OUT' — #1139 contract should not regress"

smoke_log "T4 PASS: onboarding_state agrees with markers helper (rc=2→unverifiable, rc=0→complete, rc=1→partial)"

# ---------- T5 — defensive: stat both flavors fail → defer ----------
#
# Integration-shaped assertion for the deferral case: workdir exists but
# `stat` itself returns non-zero on both `-c %U` (GNU) and `-f %Su` (BSD)
# flavors. This is the defensive branch — empty owner string flows into
# the `[[ -z "$_wd_owner" ]]` arm of the guard predicate. Realistic when
# the controller process can't read the path (e.g. permission denied on a
# sudo-owned tree it doesn't yet own, or stat-flag mismatch on an exotic
# platform). Same observable outcome as T2b: NO `bridge_hooks_python
# link-shared-settings` call, RC=0.
#
# This case ALSO fails against the r1 existence-only guard if the workdir
# happens to exist on disk — same shape as T2b. T5 codifies the
# "fail-closed on unknown ownership" contract that the r2 guard adds.
T5_DIR="$SMOKE_TMP_ROOT/t5"
mkdir -p "$T5_DIR"
T5_STUBS="$T5_DIR/stubs.sh"
write_common_stubs "$T5_STUBS"
printf '%s\n' '# T5: isolation EFFECTIVE, workdir present, stat returns no owner (defensive defer).' >>"$T5_STUBS"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T5_STUBS"
T5_DRIVER="$T5_DIR/driver.sh"
build_driver "$T5_DRIVER" "$T5_STUBS"

T5_CALL_LOG="$T5_DIR/calls.log"
T5_WORKDIR="$T5_DIR/workdir-exists"
mkdir -p "$T5_WORKDIR"
# Owner = "FAIL" makes the fake stat exit non-zero on both flavors → guard
# sees empty `_wd_owner` → `[[ -z "$_wd_owner" ]]` branch defers.
SMOKE_FAKE_STAT_OWNER="FAIL" \
  "$BRIDGE_BASH" "$T5_DRIVER" "$REPO_ROOT" "$T5_STUBS" "$T5_CALL_LOG" "$T5_WORKDIR" "smoke-agent" "$FAKE_BIN" \
  2>"$T5_DIR/err" \
  || smoke_fail "T5 driver rc=$? — see $T5_DIR/err"

T5_LINK_CALLED=0
if grep -q '^bridge_hooks_python:link-shared-settings$' "$T5_CALL_LOG"; then
  T5_LINK_CALLED=1
fi
if [[ $T5_LINK_CALLED -ne 0 ]]; then
  smoke_fail "T5 expected NO bridge_hooks_python:link-shared-settings call (stat returned no owner → guard must fail-closed). calls: $(tr '\n' '|' <"$T5_CALL_LOG")"
fi
grep -q '^RC=0$' "$T5_CALL_LOG" \
  || smoke_fail "T5 expected RC=0 (deferral returns 0). calls: $(tr '\n' '|' <"$T5_CALL_LOG")"
smoke_log "T5 PASS: isolation-effective + workdir-present + stat-fails → link-shared-settings deferred (defensive fail-closed)"

smoke_log "all 6 tests PASS (#1145 Option 1, r2: T1 + T2a + T2b + T3 + T4 + T5)"
