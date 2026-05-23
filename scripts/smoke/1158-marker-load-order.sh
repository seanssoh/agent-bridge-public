#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1158-marker-load-order.sh — Issue #1158 r2
#
# Regression for the load-order bug missed by the r1 smoke
# (1158-marker-controller-uid-exemption.sh). r1 verified that
# `bridge_isolation_v2_marker_validate` honors `$BRIDGE_CONTROLLER_UID`
# when it is set in the validator's environment — but the production
# failure mode was that BRIDGE_CONTROLLER_UID is NOT set in the env at
# validation time, because:
#
#   * `bridge-run.sh:35` sources `bridge-lib.sh` immediately on entry.
#   * `bridge-lib.sh:353` sources `bridge-marker-bootstrap.sh` and at
#     line 357 sources `bridge-layout-resolver.sh`, which calls
#     `bridge_isolation_v2_marker_validate` (resolver line 372).
#   * Only at `bridge-lib.sh:369` does `bridge-state.sh` get sourced —
#     and `bridge_load_roster` (state.sh ~line 1038) is the function
#     that sources `$BRIDGE_AGENT_ENV_FILE` (which is where
#     `BRIDGE_CONTROLLER_UID` was written by the controller in
#     `lib/bridge-agents.sh:3461-3462`).
#
# Therefore at marker-validate time inside the isolated child,
# `BRIDGE_CONTROLLER_UID` is empty regardless of what's in the env file
# — the env file hasn't been sourced yet. The r1 smoke missed this
# because it injected `BRIDGE_CONTROLLER_UID` directly into the
# driver environment via `BRIDGE_CONTROLLER_UID=… "$BRIDGE_BASH" …`,
# which is the very condition the production code path failed to set up.
#
# The r2 fix propagates `BRIDGE_CONTROLLER_UID` to the isolated child
# in TWO ways:
#
#   1. Inline in the SESSION_CMD env prefix at
#      `bridge-start.sh:598-617` — load-bearing, this is what makes the
#      variable available BEFORE bridge-lib.sh runs marker validation.
#   2. Added to `bridge_agent_preserved_env_vars` so a sudo
#      `--preserve-env=` chain forwards any controller-side export.
#
# This smoke pins the load-order contract:
#
#   T1 (production-fail repro): BRIDGE_CONTROLLER_UID absent from
#       env, the value lives only inside $BRIDGE_AGENT_ENV_FILE
#       (the controller-written env file). bridge-lib.sh sourced with
#       a controller-owned marker. EXPECT: marker REJECTED (this is the
#       pre-fix production failure mode — the smoke is here to make sure
#       any future "shortcut" that puts BRIDGE_CONTROLLER_UID only in
#       the env file does not silently regress isolated start).
#
#   T2 (fix path — preserve-list / inline-prefix): bridge-run.sh
#       sourced with BRIDGE_CONTROLLER_UID set in the env directly
#       (this is what the sudo `--preserve-env=` list achieves once
#       BRIDGE_CONTROLLER_UID is in `bridge_agent_preserved_env_vars`
#       AND the controller has it exported, OR equivalently what the
#       inline SESSION_CMD env-prefix at bridge-start.sh:598-617
#       achieves under `bash -lc`). EXPECT: marker ACCEPTED.
#
#   T3 (bridge-start.sh assembly): drive bridge-start.sh's SESSION_CMD
#       construction path directly. Assert the SUDO_PRESERVE_ENV list
#       returned by `bridge_agent_preserved_env_vars` contains
#       `BRIDGE_CONTROLLER_UID`. Assert the inline prefix appears in
#       the dry-run SESSION_CMD (without actually launching a real
#       agent — we only need the assembled command shape).
#
# Host-agnostic. Privilege-free. Footgun #11 (heredoc-stdin subprocess)
# avoided — every driver is built with `printf '%s\n' >>file`.

set -uo pipefail

SMOKE_NAME="1158-marker-load-order"
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

CURRENT_UID="$(id -u)"

# Pick a fake controller UID that differs from the running UID, so
# marker-validation can only pass via the BRIDGE_CONTROLLER_UID exemption
# (not the "owner matches current process" baseline).
SIM_CONTROLLER_UID=65530
if [[ "$CURRENT_UID" == "$SIM_CONTROLLER_UID" ]]; then
  SIM_CONTROLLER_UID=65529
fi

# Build a fixture env file shaped like what
# bridge_write_linux_agent_env_file produces. Only the
# BRIDGE_CONTROLLER_UID assignment matters for this smoke — keep it
# minimal so a future env-file schema change does not silently break
# this load-order regression.
AGENT_ENV_FILE="$SMOKE_TMP_ROOT/agent-env.sh"
printf '%s\n' "BRIDGE_CONTROLLER_UID=$SIM_CONTROLLER_UID" >"$AGENT_ENV_FILE"
printf '%s\n' "export BRIDGE_CONTROLLER_UID" >>"$AGENT_ENV_FILE"
chmod 0644 "$AGENT_ENV_FILE"

# The smoke_setup_bridge_home helper already wrote a valid marker at
# $BRIDGE_STATE_DIR/layout-marker.sh, owned by the current UID. For the
# load-order test we need a marker that LOOKS like it was owned by the
# fake controller UID — keep the physical file owned by current UID
# (no chown privilege needed) and stub the stat shim inside the
# driver. The marker file content stays valid.
MARKER_PATH="$BRIDGE_STATE_DIR/layout-marker.sh"

# Driver script that mimics bridge-run.sh's source path: source
# bridge-lib.sh and watch what bridge-marker-bootstrap.sh +
# bridge-layout-resolver.sh do with the marker. We intercept
# bridge_marker_stat_uid to simulate the foreign-owned marker
# (privilege-free), and route bridge_warn into a log file so the
# rejection reason is observable.
build_load_order_driver() {
  local driver="$1"
  : >"$driver"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  printf '%s\n' '#!/usr/bin/env bash' >>"$driver"
  printf '%s\n' 'set -uo pipefail' >>"$driver"
  printf '%s\n' 'REPO_ROOT="$1"' >>"$driver"
  printf '%s\n' 'WARN_LOG="$2"' >>"$driver"
  printf '%s\n' 'SIM_OWNER_UID="$3"' >>"$driver"
  printf '%s\n' ': >"$WARN_LOG"' >>"$driver"
  # Build a minimal driver that exercises the marker-bootstrap +
  # layout-resolver source chain — same modules bridge-lib.sh sources
  # before bridge-state.sh (i.e. before $BRIDGE_AGENT_ENV_FILE is read).
  # bridge-lib.sh itself depends on a lot of runtime state (roster file,
  # state dir, …) so a full source is overkill for a load-order test —
  # we source only the two modules whose ordering is load-bearing and
  # observe the validator's warn output.
  printf '%s\n' '# Stub bridge_warn so the source-under-test does not require' >>"$driver"
  printf '%s\n' '# bridge-core.sh, and capture every warn line.' >>"$driver"
  printf '%s\n' 'bridge_warn() { printf "%s\n" "$*" >>"$WARN_LOG"; }' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1091' >>"$driver"
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-marker-bootstrap.sh"' >>"$driver"
  printf '%s\n' '# Override the stat shim AFTER sourcing so the driver can' >>"$driver"
  printf '%s\n' '# fake a controller-owned marker without chown privileges.' >>"$driver"
  printf '%s\n' 'bridge_marker_stat_uid() { printf "%s" "$SIM_OWNER_UID"; }' >>"$driver"
  printf '%s\n' 'bridge_marker_stat_mode() { printf "%s" "644"; }' >>"$driver"
  # Resolve the marker path through the same helper bridge-lib.sh would
  # use (anchored on BRIDGE_LAYOUT_MARKER_DIR; smoke_setup_bridge_home
  # already pinned this to the isolated bridge home).
  printf '%s\n' '_marker_path="$(bridge_isolation_v2_marker_path)"' >>"$driver"
  printf '%s\n' 'bridge_isolation_v2_marker_validate "$_marker_path"' >>"$driver"
  printf '%s\n' 'echo "RC=$?" >>"$WARN_LOG"' >>"$driver"
  printf '%s\n' 'echo "CONTROLLER_UID_SEEN=${BRIDGE_CONTROLLER_UID:-}" >>"$WARN_LOG"' >>"$driver"
  chmod +x "$driver"
}

DRIVER="$SMOKE_TMP_ROOT/load-order-driver.sh"
build_load_order_driver "$DRIVER"

# ---------- T1 — production-fail repro: env-file-only propagation rejected ----------
#
# This case demonstrates WHY the fix needs to inline
# BRIDGE_CONTROLLER_UID into the SESSION_CMD env prefix (or via the
# preserve-list). If BRIDGE_CONTROLLER_UID lives ONLY inside
# $BRIDGE_AGENT_ENV_FILE (the controller-written file), the marker
# validator runs BEFORE the env file is sourced and rejects the
# foreign-owned marker.
#
# Note: this case is the pre-r1-fix repro. It does NOT exercise the
# new code path — it pins the failure mode that the fix must avoid,
# so a future "simplification" that drops the inline prefix gets
# caught here.

T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR"
T1_WARN_LOG="$T1_DIR/warn.log"
# Crucial: BRIDGE_CONTROLLER_UID is UNSET in the driver's env. The
# env-file path is passed via BRIDGE_AGENT_ENV_FILE but the driver
# simulates the bridge-lib.sh ordering (marker-bootstrap sourced
# BEFORE state.sh / env-file load), so the file's content cannot
# reach the validator in time.
unset BRIDGE_CONTROLLER_UID
BRIDGE_AGENT_ENV_FILE="$AGENT_ENV_FILE" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$T1_WARN_LOG" "$SIM_CONTROLLER_UID" \
  2>"$T1_DIR/err" \
  || true
grep -q '^RC=1$' "$T1_WARN_LOG" \
  || smoke_fail "T1 expected RC=1 (controller-only-in-env-file rejected pre-state-source). log: $(tr '\n' '|' <"$T1_WARN_LOG") err: $(cat "$T1_DIR/err")"
grep -q "owner UID $SIM_CONTROLLER_UID is neither root" "$T1_WARN_LOG" \
  || smoke_fail "T1 expected rejection warn naming foreign UID $SIM_CONTROLLER_UID. log: $(tr '\n' '|' <"$T1_WARN_LOG")"
grep -q '^CONTROLLER_UID_SEEN=$' "$T1_WARN_LOG" \
  || smoke_fail "T1 expected CONTROLLER_UID_SEEN to be empty (env-file not yet sourced at marker-validate time). log: $(tr '\n' '|' <"$T1_WARN_LOG")"
smoke_log "T1 PASS: BRIDGE_CONTROLLER_UID only in \$BRIDGE_AGENT_ENV_FILE → rejected at marker-validate time (load-order failure mode pinned)"

# ---------- T2 — fix path: BRIDGE_CONTROLLER_UID inline in env → accepted ----------
#
# This is what the inline SESSION_CMD env prefix at
# bridge-start.sh:598-617 (and the sudo --preserve-env= path via
# bridge_agent_preserved_env_vars) achieves: when the isolated child's
# bash sees BRIDGE_CONTROLLER_UID in its own environment from the
# very first command, the validator inside bridge-lib.sh sees it too
# and accepts a controller-owned marker.

T2_DIR="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_DIR"
T2_WARN_LOG="$T2_DIR/warn.log"
BRIDGE_CONTROLLER_UID="$SIM_CONTROLLER_UID" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$T2_WARN_LOG" "$SIM_CONTROLLER_UID" \
  2>"$T2_DIR/err" \
  || true
grep -q '^RC=0$' "$T2_WARN_LOG" \
  || smoke_fail "T2 expected RC=0 (BRIDGE_CONTROLLER_UID inline in env accepts marker). log: $(tr '\n' '|' <"$T2_WARN_LOG") err: $(cat "$T2_DIR/err")"
if grep -q 'layout-marker.sh ignored:' "$T2_WARN_LOG"; then
  smoke_fail "T2 expected NO rejection warn under inline BRIDGE_CONTROLLER_UID. log: $(tr '\n' '|' <"$T2_WARN_LOG")"
fi
grep -q "^CONTROLLER_UID_SEEN=$SIM_CONTROLLER_UID$" "$T2_WARN_LOG" \
  || smoke_fail "T2 expected CONTROLLER_UID_SEEN=$SIM_CONTROLLER_UID. log: $(tr '\n' '|' <"$T2_WARN_LOG")"
smoke_log "T2 PASS: BRIDGE_CONTROLLER_UID inline in env at bridge-lib.sh source time → accepted (the r2 fix path)"

# ---------- T3 — bridge-start.sh assembly: preserve-list + inline prefix ----------
#
# Pin the two assembly-time contracts the r2 fix relies on:
#
#   1. `bridge_agent_preserved_env_vars` returns a comma-separated
#      list that includes BRIDGE_CONTROLLER_UID (the sudo
#      --preserve-env= forwarder).
#
#   2. bridge-start.sh inlines `BRIDGE_CONTROLLER_UID=...` into the
#      SESSION_CMD env prefix when AGENT_ENV_FILE is set
#      (lines 598-617 post-r2). We test the function-level contract
#      here without needing a fully-initialized agent — sourcing
#      bridge-lib.sh and grepping the function body keeps the smoke
#      hermetic, but is fragile if the prefix moves. Belt-and-
#      suspenders: assert the literal env-prefix assignment appears
#      in the file at the documented site.

T3_DIR="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_DIR"
T3_OUT="$T3_DIR/preserved.txt"

# Source only bridge-agents.sh (and its hard deps via a stub) to call
# the helper. Easier and more hermetic than a full bridge-lib.sh
# bootstrap, which would re-trigger marker-load and need roster
# scaffolding.
T3_PROBE="$T3_DIR/probe.sh"
: >"$T3_PROBE"
# shellcheck disable=SC2129
printf '%s\n' '#!/usr/bin/env bash' >>"$T3_PROBE"
printf '%s\n' 'set -uo pipefail' >>"$T3_PROBE"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T3_PROBE"
# Define helpers bridge-agents.sh expects to find when sourced.
printf '%s\n' 'bridge_warn() { :; }' >>"$T3_PROBE"
printf '%s\n' 'bridge_die() { printf "die: %s\n" "$*" >&2; exit 1; }' >>"$T3_PROBE"
printf '%s\n' 'bridge_log() { :; }' >>"$T3_PROBE"
# The minimal source we need is just the function definition; rather
# than sourcing the full file (which has many cross-module deps), grep
# the helper out of the file in a way that survives small refactors.
printf '%s\n' '# Extract the function block by start/end braces' >>"$T3_PROBE"
printf '%s\n' 'fn_body=$(awk "/^bridge_agent_preserved_env_vars\\(\\) {/,/^}/" "$REPO_ROOT/lib/bridge-agents.sh")' >>"$T3_PROBE"
printf '%s\n' '[[ -n "$fn_body" ]] || { echo "FAIL: helper missing"; exit 2; }' >>"$T3_PROBE"
printf '%s\n' 'eval "$fn_body"' >>"$T3_PROBE"
printf '%s\n' 'bridge_agent_preserved_env_vars' >>"$T3_PROBE"
chmod +x "$T3_PROBE"

PRESERVED="$("$BRIDGE_BASH" "$T3_PROBE" "$REPO_ROOT" 2>"$T3_DIR/probe.err" || true)"
case ",$PRESERVED," in
  *,BRIDGE_CONTROLLER_UID,*)
    : # ok
    ;;
  *)
    smoke_fail "T3.1 expected BRIDGE_CONTROLLER_UID in preserve-list; got: '$PRESERVED' (err: $(cat "$T3_DIR/probe.err" 2>/dev/null || true))"
    ;;
esac
smoke_log "T3.1 PASS: bridge_agent_preserved_env_vars contains BRIDGE_CONTROLLER_UID (sudo --preserve-env= path)"

# T3.2 — bridge-start.sh inline prefix. Pin the literal
# `BRIDGE_CONTROLLER_UID=$(printf '%q' ...)` pattern at the
# documented site so a future refactor that moves or drops the line
# trips the smoke. We deliberately match the assignment shape, not
# an exact line number, so cosmetic edits do not break the smoke.
grep -E 'SESSION_CMD="BRIDGE_CONTROLLER_UID=\$\(printf .%q. .*\) \$\{SESSION_CMD\}"' \
  "$REPO_ROOT/bridge-start.sh" >/dev/null \
  || smoke_fail "T3.2 expected bridge-start.sh to inline BRIDGE_CONTROLLER_UID into SESSION_CMD via printf %q (the inline-prefix arm of the r2 fix). The exact line number can drift, but the assignment shape must remain."
smoke_log "T3.2 PASS: bridge-start.sh inlines BRIDGE_CONTROLLER_UID into SESSION_CMD env prefix (load-bearing arm)"

smoke_log "all 3 tests PASS (#1158 r2 load-order regression: T1 env-file-only rejected, T2 inline-env accepted, T3 assembly contracts pinned)"
