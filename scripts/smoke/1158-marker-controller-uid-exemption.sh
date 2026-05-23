#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1158-marker-controller-uid-exemption.sh — Issue #1158
#
# `bridge_isolation_v2_marker_validate` (lib/bridge-marker-bootstrap.sh)
# previously accepted markers owned by ONLY root OR the current process
# UID. That broke v2 isolated-agent start on Linux: the controller (e.g.
# `awfmanager`, UID 1003) writes `state/layout-marker.sh`, but the
# isolated agent reads it from a different UID context (sudo -u
# bridge-<agent>) — same physical file, different `id -u` — and the
# validator rejected the marker as "owner UID 1003 is neither root nor
# current controller", which then fired `bridge_die` because v2
# isolation requires a valid marker.
#
# The fix exempts $BRIDGE_CONTROLLER_UID (already exported by
# lib/bridge-agents.sh:3460-3462 for every isolated launch) as a third
# accepted owner. The mode check (no group/world write bit) stays
# intact — owner-exemption only loosens the IDENTITY check, never the
# PERMISSION check.
#
# This smoke pins the matrix:
#
#   T1: marker owned by current process UID → accepted (baseline)
#   T2: marker owned by root (UID 0)        → accepted (baseline)
#   T3: marker owned by exported controller (BRIDGE_CONTROLLER_UID,
#       different from current process UID) → accepted ← the fix
#   T4: marker owned by an unrelated UID (not root, not current,
#       not exported controller)            → rejected (gate intact)
#   T5: marker has group write bit (g+w) set with current-UID owner
#                                            → rejected (mode check intact)
#
# Host-agnostic: every case stubs `bridge_marker_stat_uid` /
# `bridge_marker_stat_mode` so the smoke does not require chown
# privileges to fake foreign ownership. Footgun #11 (heredoc-stdin
# subprocess) is avoided — every driver is built with `printf '%s\n'
# >>file`.

set -uo pipefail

SMOKE_NAME="1158-marker-controller-uid-exemption"
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

# ---------- shared driver template ----------
#
# Each case builds a tiny bash driver that:
#   1. Sources `lib/bridge-marker-bootstrap.sh` from the worktree.
#   2. Overrides `bridge_marker_stat_uid` to return the simulated owner
#      UID (case-specific via $SIM_OWNER_UID env) — keeps the smoke
#      privilege-free.
#   3. Overrides `bridge_marker_stat_mode` to return the simulated mode
#      (default 0644; T5 uses 0664 to flip the g+w bit).
#   4. Stubs `bridge_warn` to record rejection reasons into $WARN_LOG.
#   5. Calls `bridge_isolation_v2_marker_validate $marker` and writes
#      RC=$? + the warn log.

build_driver() {
  local driver="$1"
  printf '%s\n' '#!/usr/bin/env bash' >"$driver"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  printf '%s\n' 'set -uo pipefail' >>"$driver"
  printf '%s\n' 'REPO_ROOT="$1"' >>"$driver"
  printf '%s\n' 'MARKER_PATH="$2"' >>"$driver"
  printf '%s\n' 'WARN_LOG="$3"' >>"$driver"
  printf '%s\n' 'SIM_OWNER_UID="$4"' >>"$driver"
  printf '%s\n' 'SIM_MODE="$5"' >>"$driver"
  printf '%s\n' ': >"$WARN_LOG"' >>"$driver"
  printf '%s\n' '# Stub bridge_warn so the source-under-test does not require' >>"$driver"
  printf '%s\n' '# bridge-core.sh; record every warn line into $WARN_LOG.' >>"$driver"
  printf '%s\n' 'bridge_warn() { printf "%s\n" "$*" >>"$WARN_LOG"; }' >>"$driver"
  printf '%s\n' '# shellcheck disable=SC1091' >>"$driver"
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-marker-bootstrap.sh"' >>"$driver"
  printf '%s\n' '# Override the stat shims to return the simulated values' >>"$driver"
  printf '%s\n' '# AFTER sourcing (function defs in the lib file would otherwise' >>"$driver"
  printf '%s\n' '# clobber ours on Bash). Privilege-free fake-ownership.' >>"$driver"
  printf '%s\n' 'bridge_marker_stat_uid() { printf "%s" "$SIM_OWNER_UID"; }' >>"$driver"
  printf '%s\n' 'bridge_marker_stat_mode() { printf "%s" "$SIM_MODE"; }' >>"$driver"
  printf '%s\n' 'bridge_isolation_v2_marker_validate "$MARKER_PATH"' >>"$driver"
  printf '%s\n' 'echo "RC=$?" >>"$WARN_LOG"' >>"$driver"
  chmod +x "$driver"
}

# All cases share a single physical marker file with valid content.
# Owner/mode are simulated via stat-shim overrides per case.
MARKER_BASE_DIR="$SMOKE_TMP_ROOT/marker"
mkdir -p "$MARKER_BASE_DIR"
MARKER_PATH="$MARKER_BASE_DIR/layout-marker.sh"
printf '%s\n' 'BRIDGE_LAYOUT=v2' >"$MARKER_PATH"
printf '%s\n' "BRIDGE_DATA_ROOT=$SMOKE_TMP_ROOT/data" >>"$MARKER_PATH"
chmod 0644 "$MARKER_PATH"

DRIVER="$SMOKE_TMP_ROOT/driver.sh"
build_driver "$DRIVER"

# ---------- T1 — marker owned by current process UID → accepted ----------
T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR"
T1_WARN_LOG="$T1_DIR/warn.log"
unset BRIDGE_CONTROLLER_UID
"$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$MARKER_PATH" "$T1_WARN_LOG" "$CURRENT_UID" "644" \
  2>"$T1_DIR/err" \
  || true
grep -q '^RC=0$' "$T1_WARN_LOG" \
  || smoke_fail "T1 expected RC=0 (current-UID owner accepted). log: $(tr '\n' '|' <"$T1_WARN_LOG") err: $(cat "$T1_DIR/err")"
if grep -q 'layout-marker.sh ignored:' "$T1_WARN_LOG"; then
  smoke_fail "T1 expected NO rejection warn for current-UID owner. log: $(tr '\n' '|' <"$T1_WARN_LOG")"
fi
smoke_log "T1 PASS: marker owned by current process UID ($CURRENT_UID) → accepted"

# ---------- T2 — marker owned by root (UID 0) → accepted (baseline) ----------
T2_DIR="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_DIR"
T2_WARN_LOG="$T2_DIR/warn.log"
unset BRIDGE_CONTROLLER_UID
"$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$MARKER_PATH" "$T2_WARN_LOG" "0" "644" \
  2>"$T2_DIR/err" \
  || true
grep -q '^RC=0$' "$T2_WARN_LOG" \
  || smoke_fail "T2 expected RC=0 (root-owned marker accepted). log: $(tr '\n' '|' <"$T2_WARN_LOG") err: $(cat "$T2_DIR/err")"
if grep -q 'layout-marker.sh ignored:' "$T2_WARN_LOG"; then
  smoke_fail "T2 expected NO rejection warn for root owner. log: $(tr '\n' '|' <"$T2_WARN_LOG")"
fi
smoke_log "T2 PASS: marker owned by root (UID 0) → accepted (baseline)"

# ---------- T3 — marker owned by exported BRIDGE_CONTROLLER_UID → accepted ← THE FIX ----------
#
# Simulate the isolated-agent context: current process UID is the
# isolated agent's UID (e.g. 1099), but the marker was written by the
# controller (e.g. UID 1003). The controller exported BRIDGE_CONTROLLER_UID=1003
# into the agent's env (lib/bridge-agents.sh:3461). Pre-fix this case
# was rejected; post-fix it must be accepted.
#
# Strategy: pick a fake controller UID that differs from $CURRENT_UID
# AND from 0. UID 65530 is a safe pick (within standard 16-bit unsigned
# range, never collides with a real user on stock distros, and not 0).
SIM_CONTROLLER_UID=65530
if [[ "$CURRENT_UID" == "$SIM_CONTROLLER_UID" ]]; then
  # Vanishingly unlikely, but be deterministic.
  SIM_CONTROLLER_UID=65529
fi
T3_DIR="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_DIR"
T3_WARN_LOG="$T3_DIR/warn.log"
BRIDGE_CONTROLLER_UID="$SIM_CONTROLLER_UID" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$MARKER_PATH" "$T3_WARN_LOG" "$SIM_CONTROLLER_UID" "644" \
  2>"$T3_DIR/err" \
  || true
grep -q '^RC=0$' "$T3_WARN_LOG" \
  || smoke_fail "T3 expected RC=0 (exported-controller owner accepted). log: $(tr '\n' '|' <"$T3_WARN_LOG") err: $(cat "$T3_DIR/err")"
if grep -q 'layout-marker.sh ignored:' "$T3_WARN_LOG"; then
  smoke_fail "T3 expected NO rejection warn (the fix). log: $(tr '\n' '|' <"$T3_WARN_LOG")"
fi
smoke_log "T3 PASS: marker owned by exported BRIDGE_CONTROLLER_UID ($SIM_CONTROLLER_UID, ≠ current $CURRENT_UID) → accepted (the fix)"

# ---------- T3b — quoted exported value still matched (defensive unquote path) ----------
#
# `lib/bridge-agents.sh` writes `BRIDGE_CONTROLLER_UID=$(printf '%q' ...)`.
# For numeric UIDs `%q` is a no-op, but the validator strips surrounding
# single/double quotes defensively against future drift. Pin that path
# by passing a single-quoted value through env.
T3B_DIR="$SMOKE_TMP_ROOT/t3b"
mkdir -p "$T3B_DIR"
T3B_WARN_LOG="$T3B_DIR/warn.log"
BRIDGE_CONTROLLER_UID="'$SIM_CONTROLLER_UID'" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$MARKER_PATH" "$T3B_WARN_LOG" "$SIM_CONTROLLER_UID" "644" \
  2>"$T3B_DIR/err" \
  || true
grep -q '^RC=0$' "$T3B_WARN_LOG" \
  || smoke_fail "T3b expected RC=0 (quoted exported controller still accepted). log: $(tr '\n' '|' <"$T3B_WARN_LOG") err: $(cat "$T3B_DIR/err")"
if grep -q 'layout-marker.sh ignored:' "$T3B_WARN_LOG"; then
  smoke_fail "T3b expected NO rejection warn for quoted exported controller. log: $(tr '\n' '|' <"$T3B_WARN_LOG")"
fi
smoke_log "T3b PASS: quoted BRIDGE_CONTROLLER_UID value still matched (unquote path)"

# ---------- T4 — marker owned by unrelated UID (not root, not current, not exported) → rejected ----------
#
# Security gate intact. The validator must reject a marker owned by an
# arbitrary UID even when BRIDGE_CONTROLLER_UID is set — the exemption
# only lifts identity for the exported controller, not for "any UID".
SIM_FOREIGN_UID=65531
if [[ "$CURRENT_UID" == "$SIM_FOREIGN_UID" ]]; then
  SIM_FOREIGN_UID=65528
fi
T4_DIR="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_DIR"
T4_WARN_LOG="$T4_DIR/warn.log"
BRIDGE_CONTROLLER_UID="$SIM_CONTROLLER_UID" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$MARKER_PATH" "$T4_WARN_LOG" "$SIM_FOREIGN_UID" "644" \
  2>"$T4_DIR/err" \
  || true
grep -q '^RC=1$' "$T4_WARN_LOG" \
  || smoke_fail "T4 expected RC=1 (foreign-UID owner rejected). log: $(tr '\n' '|' <"$T4_WARN_LOG") err: $(cat "$T4_DIR/err")"
grep -q "owner UID $SIM_FOREIGN_UID is neither root" "$T4_WARN_LOG" \
  || smoke_fail "T4 expected explicit rejection warn naming foreign UID $SIM_FOREIGN_UID. log: $(tr '\n' '|' <"$T4_WARN_LOG")"
smoke_log "T4 PASS: marker owned by foreign UID ($SIM_FOREIGN_UID) → rejected (gate intact)"

# ---------- T5 — marker has group write bit → rejected REGARDLESS of owner ----------
#
# Mode check must remain intact for the broadened owner set. Owner is
# current process UID (T1's accepted shape), but mode 0664 has g+w set.
# Validator must reject regardless of any owner-exemption path.
T5_DIR="$SMOKE_TMP_ROOT/t5"
mkdir -p "$T5_DIR"
T5_WARN_LOG="$T5_DIR/warn.log"
unset BRIDGE_CONTROLLER_UID
"$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$MARKER_PATH" "$T5_WARN_LOG" "$CURRENT_UID" "664" \
  2>"$T5_DIR/err" \
  || true
grep -q '^RC=1$' "$T5_WARN_LOG" \
  || smoke_fail "T5 expected RC=1 (group-write mode rejected). log: $(tr '\n' '|' <"$T5_WARN_LOG") err: $(cat "$T5_DIR/err")"
grep -q 'mode 664 has group or world write bit' "$T5_WARN_LOG" \
  || smoke_fail "T5 expected explicit rejection warn naming the mode bits. log: $(tr '\n' '|' <"$T5_WARN_LOG")"
smoke_log "T5 PASS: marker with g+w mode → rejected regardless of owner (mode check intact)"

# ---------- T5b — group-write rejected even under exported-controller owner ----------
#
# The fix's identity exemption must not bypass the mode check. Owner is
# the exported controller (the path that newly accepts identity-wise),
# but mode flips g+w → must still reject.
T5B_DIR="$SMOKE_TMP_ROOT/t5b"
mkdir -p "$T5B_DIR"
T5B_WARN_LOG="$T5B_DIR/warn.log"
BRIDGE_CONTROLLER_UID="$SIM_CONTROLLER_UID" \
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$MARKER_PATH" "$T5B_WARN_LOG" "$SIM_CONTROLLER_UID" "664" \
  2>"$T5B_DIR/err" \
  || true
grep -q '^RC=1$' "$T5B_WARN_LOG" \
  || smoke_fail "T5b expected RC=1 (g+w + exported-controller owner still rejected on mode). log: $(tr '\n' '|' <"$T5B_WARN_LOG") err: $(cat "$T5B_DIR/err")"
grep -q 'mode 664 has group or world write bit' "$T5B_WARN_LOG" \
  || smoke_fail "T5b expected mode-bit rejection warn under exported-controller owner. log: $(tr '\n' '|' <"$T5B_WARN_LOG")"
smoke_log "T5b PASS: g+w mode rejected even when owner matches BRIDGE_CONTROLLER_UID (mode gate cannot be bypassed via owner-exemption)"

smoke_log "all 5 tests PASS (#1158 BRIDGE_CONTROLLER_UID owner exemption: T1 current-UID, T2 root, T3 exported-controller, T4 foreign-rejected, T5 mode-rejected; plus T3b quoted-controller + T5b mode-rejected-under-controller)"
