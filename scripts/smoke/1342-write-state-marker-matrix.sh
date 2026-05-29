#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1342-write-state-marker-matrix.sh — Issue #1342 (Track L).
#
# beta5-1 regression: every iso v2 agent stop emitted
#   [경고] write_agent_state_marker: ensure_matrix_path failed for
#          agent=<X> marker=idle-since
#
# #1165 Gap 6 (r2/r3) addressed the Stop-hook-from-isolated-session case by
# routing through Path A0 (euid==target os_user → direct write) and Path A
# (sudo-as-iso helper). Both gates, however, depended on the ROSTER-resolved
# `bridge_agent_os_user "$agent"`:
#   - Path A0's equality check consulted only `bridge_agent_os_user`.
#   - Path A's `bridge_agent_linux_user_isolation_effective` requires a
#     non-empty `bridge_agent_os_user` (lib/bridge-agents.sh:1028).
# When the Stop hook runs inside the iso UID but its scoped roster snapshot
# did not populate `BRIDGE_AGENT_OS_USER[<X>]` — or `bridge_agent_isolation_
# mode` came back indeterminate (#1048) — both isolation paths fall through
# to Path B, whose `ensure_matrix_path` then tries a chown/chmod the iso UID
# cannot perform → the per-stop warning. The marker (which the iso UID CAN
# write, as a member of the 2770 `ab-agent-<X>` leaf) was never recorded.
#
# Track L fix (lib/bridge-isolation-v2.sh::write_agent_state_marker):
#   1. Path A0 derives the EXPECTED iso UID from the canonical
#      `${BRIDGE_AGENT_OS_USER_PREFIX:-agent-bridge-}${agent}` construction
#      (same string matrix_rows_for_agent uses) when the roster lookup is
#      empty — euid==target equality is then runtime-context driven, not
#      roster-snapshot driven. The cross-agent guard is unchanged in
#      strength (A0 still fires only when `id -un` IS this agent's own iso
#      UID).
#   2. Path B disambiguates an ensure_matrix_path failure: WITH root/sudo it
#      is a genuine matrix-apply error → preserve the pre-#1342 hard-fail
#      (controller-context drift surfaces loudly); WITHOUT a privileged path
#      (iso UID, no sudoers chown grant) the only missing capability is
#      chown of a controller-owned leaf, so drop the spurious per-stop
#      warning and continue best-effort to the direct write (idle-since /
#      manual-stop markers are best-effort; callers invoke with `|| true`).
#      The direct write + its own chmod remain the authoritative hard-fail.
#   3. Opt-in trace (`BRIDGE_ISOLATION_STATE_MARKER_DEBUG=1`) records which
#      Path (A0/A/B) fired and each fall-through rc — diagnostic only, never
#      alters control flow, stderr (matches bridge_warn).
#
# This smoke is HOST-AGNOSTIC: it stubs `id`, the sudo-as-iso helper,
# isolation-effective, os_user resolution, and ensure_matrix_path. No real
# `agent-bridge-*` users / `ab-agent-*` groups / sudo on the host required.
#
# Tests:
#   T1: iso v2 + euid==agent's own os_user (roster RESOLVES os_user) →
#       Path A0 direct write succeeds; matrix_path (leaf) exists with the
#       marker; sudo-as-iso helper + ensure_matrix_path NOT invoked.
#   T2 (#1342 root cause): iso v2 + euid==DERIVED iso UID but roster
#       os_user EMPTY (#1048 indeterminate reproducer) → Path A0 STILL
#       fires via the canonical-construction fallback; marker written; NO
#       ensure_matrix_path warning; sudo helper NOT invoked.
#   T3: manual-stop marker via the SAME writer + same A0-derived path →
#       identical success (every marker shares the fix).
#   T4 (regression): non-iso agent → Path B controller direct write
#       (ensure_matrix_path succeeds, direct write) — legacy path intact.
#   T5 (teeth, #1342 best-effort): iso UID context, Path A0/A skipped,
#       ensure_matrix_path FAILS, no root/sudo → marker STILL written via
#       best-effort direct write and NO ensure_matrix_path warning. The
#       teeth: a stub `_bridge_isolation_v2_state_marker_can_repair_as_root`
#       returning 0 (the pre-#1342 hard-fail shape) re-emits the warning and
#       drops the marker.
#   T6 (regression — adjacent functions, Track A/J preservation): the
#       Track A (#1353) `bridge_agent_mark_setup_pending` and Track J
#       (#1370) `bridge_resolve_agent_claude_config_dir` functions in
#       lib/bridge-state.sh still parse + run (no adjacent-function damage
#       from the isolation-v2 edit).
#
# Footgun #11 (heredoc_write deadlock class): every driver is built with
# `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash functions; no
# `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1342-write-state-marker-matrix"
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

WRITER_SOURCE="$REPO_ROOT/lib/bridge-isolation-v2.sh"

# Shared driver-prelude emitter. Writes the common stub header into the
# named driver file: PATH-prepend stub bin, the writer + its two new helper
# functions extracted from source, and a visible bridge_warn. Each test
# layers its own stubs on top before sourcing.
emit_common_prelude() {
  local f="$1"
  printf '%s\n' '#!/usr/bin/env bash' >"$f"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  printf '%s\n' 'set -uo pipefail' >>"$f"
  printf '%s\n' 'REPO_ROOT="$1"' >>"$f"
  printf '%s\n' 'AGENT_DIR="$2"' >>"$f"
  printf '%s\n' 'CALL_LOG="$3"' >>"$f"
  printf '%s\n' 'STUB_BIN="${4:-}"' >>"$f"
  printf '%s\n' '[[ -n "$STUB_BIN" ]] && export PATH="$STUB_BIN:$PATH"' >>"$f"
}

# Emit the writer + the two #1342 helper functions, extracted by awk so the
# smoke tracks the real source (not a copy). Must be called AFTER the test's
# own stubs are in place (so eval'd defs see them) and AFTER sourcing
# bridge-core.sh.
emit_writer_extract() {
  local f="$1"
  # shellcheck disable=SC2129
  printf '%s\n' 'TRACE_DEF="$(awk "/^_bridge_isolation_v2_state_marker_trace\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-isolation-v2.sh")"' >>"$f"
  printf '%s\n' 'eval "$TRACE_DEF"' >>"$f"
  printf '%s\n' 'WRITER_DEF="$(awk "/^bridge_isolation_v2_write_agent_state_marker\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-isolation-v2.sh")"' >>"$f"
  printf '%s\n' 'eval "$WRITER_DEF"' >>"$f"
}

# ---------- T1 — iso v2 + euid==target os_user (roster resolves) → Path A0 ----------
T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR"
T1_CALL_LOG="$T1_DIR/calls.log"
T1_AGENT_DIR="$T1_DIR/state/agents/alpha"
mkdir -p "$T1_AGENT_DIR"
T1_BIN="$T1_DIR/bin"
mkdir -p "$T1_BIN"
printf '%s\n' '#!/usr/bin/env bash' >"$T1_BIN/id"
# shellcheck disable=SC2129
printf '%s\n' 'if [[ "${1:-}" == "-un" ]]; then printf "agent-bridge-alpha\n"; exit 0; fi' >>"$T1_BIN/id"
printf '%s\n' 'exec /usr/bin/env -u PATH /usr/bin/id "$@" 2>/dev/null || command id "$@"' >>"$T1_BIN/id"
chmod +x "$T1_BIN/id"

T1_DRIVER="$T1_DIR/driver.sh"
emit_common_prelude "$T1_DRIVER"
# shellcheck disable=SC2129
# Roster RESOLVES os_user for alpha.
printf '%s\n' 'bridge_agent_os_user() { if [[ "${1:-}" == "alpha" ]]; then printf "agent-bridge-alpha"; fi; }' >>"$T1_DRIVER"
# sudo-as-iso helper MUST NOT be invoked.
printf '%s\n' 'bridge_isolation_write_file_as_agent_user_via_bash() { printf "UNEXPECTED sudo-as-iso: %s\n" "$*" >>"$CALL_LOG"; cat - >/dev/null; return 0; }' >>"$T1_DRIVER"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T1_DRIVER"
printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$T1_DRIVER"
printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { printf "UNEXPECTED ensure_matrix_path: %s\n" "$*" >>"$CALL_LOG"; return 99; }' >>"$T1_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$T1_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T1_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T1_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$T1_DRIVER"
emit_writer_extract "$T1_DRIVER"
printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "alpha" "idle-since" "1700001000"' >>"$T1_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T1_DRIVER"
chmod +x "$T1_DRIVER"

T1_LOG="$T1_DIR/log"
"$BRIDGE_BASH" "$T1_DRIVER" "$REPO_ROOT" "$T1_AGENT_DIR" "$T1_CALL_LOG" "$T1_BIN" >"$T1_LOG" 2>&1 || true

grep -q '^RC=0$' "$T1_LOG" \
  || smoke_fail "T1: writer did not return 0. log: $(tr '\n' '|' <"$T1_LOG" | tail -c 800)"
[[ -f "$T1_AGENT_DIR/idle-since" ]] \
  || smoke_fail "T1: matrix_path leaf marker $T1_AGENT_DIR/idle-since not created. log: $(tr '\n' '|' <"$T1_LOG" | tail -c 800)"
T1_CONTENT="$(<"$T1_AGENT_DIR/idle-since")"
[[ "$T1_CONTENT" == "1700001000" ]] \
  || smoke_fail "T1: idle-since content mismatch. want '1700001000', got '$T1_CONTENT'"
if [[ -s "$T1_CALL_LOG" ]]; then
  smoke_fail "T1: Path A0 should short-circuit; sudo-as-iso/ensure_matrix_path was invoked. calls: $(cat "$T1_CALL_LOG")"
fi
smoke_log "T1 PASS: iso v2 euid==resolved os_user → Path A0 direct write; matrix_path leaf + marker present; no sudo/ensure_matrix_path"

# ---------- T2 — #1342 root cause: roster os_user EMPTY → Path A0 derived ----------
#
# Reproduce the Stop-hook-inside-iso-UID case where the scoped roster did
# NOT populate os_user (or isolation_mode came back indeterminate, #1048).
# `bridge_agent_os_user` returns empty; the writer must DERIVE the expected
# iso UID from `agent-bridge-<agent>` and STILL fire Path A0. Before the
# Track L fix, A0 was skipped (empty os_user), Path A's iso-effective gate
# also failed (requires non-empty os_user), and Path B's ensure_matrix_path
# emitted the per-stop warning + dropped the marker.
T2_DIR="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_DIR"
T2_CALL_LOG="$T2_DIR/calls.log"
T2_AGENT_DIR="$T2_DIR/state/agents/test_clean"
mkdir -p "$T2_AGENT_DIR"
T2_BIN="$T2_DIR/bin"
mkdir -p "$T2_BIN"
printf '%s\n' '#!/usr/bin/env bash' >"$T2_BIN/id"
# shellcheck disable=SC2129
printf '%s\n' 'if [[ "${1:-}" == "-un" ]]; then printf "agent-bridge-test_clean\n"; exit 0; fi' >>"$T2_BIN/id"
printf '%s\n' 'exec /usr/bin/env -u PATH /usr/bin/id "$@" 2>/dev/null || command id "$@"' >>"$T2_BIN/id"
chmod +x "$T2_BIN/id"

T2_DRIVER="$T2_DIR/driver.sh"
emit_common_prelude "$T2_DRIVER"
# shellcheck disable=SC2129
# Roster lookup returns EMPTY (the #1342 / #1048 condition).
printf '%s\n' 'bridge_agent_os_user() { printf ""; }' >>"$T2_DRIVER"
# sudo-as-iso helper MUST NOT be invoked (A0 derived fallback fires first).
printf '%s\n' 'bridge_isolation_write_file_as_agent_user_via_bash() { printf "UNEXPECTED sudo-as-iso: %s\n" "$*" >>"$CALL_LOG"; cat - >/dev/null; return 0; }' >>"$T2_DRIVER"
# Iso-effective would return 1 in the real failure (empty os_user); mirror
# that so we prove A0 fires WITHOUT relying on Path A.
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$T2_DRIVER"
printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$T2_DRIVER"
# ensure_matrix_path MUST NOT be reached (would emit the #1342 warning).
printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { printf "UNEXPECTED ensure_matrix_path: %s\n" "$*" >>"$CALL_LOG"; return 99; }' >>"$T2_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$T2_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T2_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T2_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$T2_DRIVER"
emit_writer_extract "$T2_DRIVER"
printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "test_clean" "idle-since" "1700002000"' >>"$T2_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T2_DRIVER"
chmod +x "$T2_DRIVER"

T2_LOG="$T2_DIR/log"
"$BRIDGE_BASH" "$T2_DRIVER" "$REPO_ROOT" "$T2_AGENT_DIR" "$T2_CALL_LOG" "$T2_BIN" >"$T2_LOG" 2>&1 || true

grep -q '^RC=0$' "$T2_LOG" \
  || smoke_fail "T2: writer did not return 0 with empty roster os_user (Path A0 derived fallback broken — #1342 regression). log: $(tr '\n' '|' <"$T2_LOG" | tail -c 800)"
[[ -f "$T2_AGENT_DIR/idle-since" ]] \
  || smoke_fail "T2: marker not written via Path A0 derived fallback. log: $(tr '\n' '|' <"$T2_LOG" | tail -c 800)"
# The hallmark #1342 warning MUST NOT appear.
if grep -q 'ensure_matrix_path failed' "$T2_LOG"; then
  smoke_fail "T2: #1342 'ensure_matrix_path failed' warning re-emitted (root cause not closed). log: $(tr '\n' '|' <"$T2_LOG" | tail -c 800)"
fi
if [[ -s "$T2_CALL_LOG" ]]; then
  smoke_fail "T2: Path A0 derived fallback should short-circuit; sudo-as-iso/ensure_matrix_path invoked. calls: $(cat "$T2_CALL_LOG")"
fi
smoke_log "T2 PASS: empty roster os_user → Path A0 derives agent-bridge-<X> and writes marker; no ensure_matrix_path warning (#1342 closed)"

# ---------- T3 — manual-stop marker shares the same A0 path ----------
T3_DIR="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_DIR"
T3_CALL_LOG="$T3_DIR/calls.log"
T3_AGENT_DIR="$T3_DIR/state/agents/test_clean"
mkdir -p "$T3_AGENT_DIR"
T3_BIN="$T3_DIR/bin"
mkdir -p "$T3_BIN"
printf '%s\n' '#!/usr/bin/env bash' >"$T3_BIN/id"
# shellcheck disable=SC2129
printf '%s\n' 'if [[ "${1:-}" == "-un" ]]; then printf "agent-bridge-test_clean\n"; exit 0; fi' >>"$T3_BIN/id"
printf '%s\n' 'exec /usr/bin/env -u PATH /usr/bin/id "$@" 2>/dev/null || command id "$@"' >>"$T3_BIN/id"
chmod +x "$T3_BIN/id"

T3_DRIVER="$T3_DIR/driver.sh"
emit_common_prelude "$T3_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'bridge_agent_os_user() { printf ""; }' >>"$T3_DRIVER"
printf '%s\n' 'bridge_isolation_write_file_as_agent_user_via_bash() { printf "UNEXPECTED sudo-as-iso: %s\n" "$*" >>"$CALL_LOG"; cat - >/dev/null; return 0; }' >>"$T3_DRIVER"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$T3_DRIVER"
printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$T3_DRIVER"
printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { printf "UNEXPECTED ensure_matrix_path: %s\n" "$*" >>"$CALL_LOG"; return 99; }' >>"$T3_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$T3_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T3_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T3_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$T3_DRIVER"
emit_writer_extract "$T3_DRIVER"
printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "test_clean" "manual-stop" "1700003000"' >>"$T3_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T3_DRIVER"
chmod +x "$T3_DRIVER"

T3_LOG="$T3_DIR/log"
"$BRIDGE_BASH" "$T3_DRIVER" "$REPO_ROOT" "$T3_AGENT_DIR" "$T3_CALL_LOG" "$T3_BIN" >"$T3_LOG" 2>&1 || true

grep -q '^RC=0$' "$T3_LOG" \
  || smoke_fail "T3: manual-stop writer did not return 0 (shared helper fix did not reach manual-stop). log: $(tr '\n' '|' <"$T3_LOG" | tail -c 800)"
[[ -f "$T3_AGENT_DIR/manual-stop" ]] \
  || smoke_fail "T3: manual-stop marker not written. log: $(tr '\n' '|' <"$T3_LOG" | tail -c 800)"
if grep -q 'ensure_matrix_path failed' "$T3_LOG"; then
  smoke_fail "T3: manual-stop re-emitted ensure_matrix_path warning. log: $(tr '\n' '|' <"$T3_LOG" | tail -c 800)"
fi
smoke_log "T3 PASS: manual-stop marker uses the same A0-derived path → identical success (fix is in the shared writer)"

# ---------- T4 — regression: non-iso agent → Path B controller direct write ----------
T4_DIR="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_DIR"
T4_CALL_LOG="$T4_DIR/calls.log"
T4_AGENT_DIR="$T4_DIR/state/agents/beta"
mkdir -p "$T4_AGENT_DIR"
T4_BIN="$T4_DIR/bin"
mkdir -p "$T4_BIN"
# `id -un` returns the controller (operator) user — never matches the
# derived agent-bridge-beta, so Path A0 falls through.
printf '%s\n' '#!/usr/bin/env bash' >"$T4_BIN/id"
# shellcheck disable=SC2129
printf '%s\n' 'if [[ "${1:-}" == "-un" ]]; then printf "ci-operator\n"; exit 0; fi' >>"$T4_BIN/id"
printf '%s\n' 'exec /usr/bin/env -u PATH /usr/bin/id "$@" 2>/dev/null || command id "$@"' >>"$T4_BIN/id"
chmod +x "$T4_BIN/id"

T4_DRIVER="$T4_DIR/driver.sh"
emit_common_prelude "$T4_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'bridge_agent_os_user() { printf ""; }' >>"$T4_DRIVER"
# Helper MUST NOT be called on the non-iso path.
printf '%s\n' 'bridge_isolation_write_file_as_agent_user_via_bash() { printf "UNEXPECTED sudo-as-iso: %s\n" "$*" >>"$CALL_LOG"; cat - >/dev/null; return 0; }' >>"$T4_DRIVER"
# Non-iso.
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$T4_DRIVER"
printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$T4_DRIVER"
# Path B reachable: ensure_matrix_path succeeds (non-iso / shared).
printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { printf "ensure_matrix_path: %s\n" "$*" >>"$CALL_LOG"; return 0; }' >>"$T4_DRIVER"
printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() { "$@"; }' >>"$T4_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$T4_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T4_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T4_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$T4_DRIVER"
emit_writer_extract "$T4_DRIVER"
printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "beta" "idle-since" "1700004000"' >>"$T4_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T4_DRIVER"
chmod +x "$T4_DRIVER"

T4_LOG="$T4_DIR/log"
"$BRIDGE_BASH" "$T4_DRIVER" "$REPO_ROOT" "$T4_AGENT_DIR" "$T4_CALL_LOG" "$T4_BIN" >"$T4_LOG" 2>&1 || true

grep -q '^RC=0$' "$T4_LOG" \
  || smoke_fail "T4: non-iso writer did not return 0. log: $(tr '\n' '|' <"$T4_LOG" | tail -c 800)"
[[ -f "$T4_AGENT_DIR/idle-since" ]] \
  || smoke_fail "T4: Path B did not create $T4_AGENT_DIR/idle-since. log: $(tr '\n' '|' <"$T4_LOG" | tail -c 800)"
grep -q '^ensure_matrix_path: state-agent-dir beta$' "$T4_CALL_LOG" \
  || smoke_fail "T4: Path B did not call ensure_matrix_path with (state-agent-dir, beta). calls: $(cat "$T4_CALL_LOG")"
# sudo-as-iso must NOT have fired on the non-iso path.
if grep -q '^UNEXPECTED sudo-as-iso' "$T4_CALL_LOG"; then
  smoke_fail "T4: sudo-as-iso helper invoked on non-iso path. calls: $(cat "$T4_CALL_LOG")"
fi
smoke_log "T4 PASS: non-iso agent → Path B controller direct write via ensure_matrix_path (legacy path intact)"

# ---------- T5 — teeth: ensure_matrix_path fails + no root/sudo → best-effort write, no warning ----------
#
# Iso UID context (Path A0/A skipped), ensure_matrix_path FAILS, and the
# privilege probe reports no root/sudo. The #1342 fix continues best-effort:
# the iso UID writes the 0660 marker into the group-writable 2770 leaf and
# emits NO ensure_matrix_path warning. The teeth: override
# `_bridge_isolation_v2_state_marker_can_repair_as_root` to return 0 (the
# pre-#1342 "privileged → hard-fail" classification) — the writer then
# re-emits the warning and drops the marker (rc != 0).
T5_DIR="$SMOKE_TMP_ROOT/t5"
mkdir -p "$T5_DIR"
T5_CALL_LOG="$T5_DIR/calls.log"
T5_AGENT_DIR="$T5_DIR/state/agents/test_clean"
mkdir -p "$T5_AGENT_DIR"
T5_BIN="$T5_DIR/bin"
mkdir -p "$T5_BIN"
# `id -un` returns a DIFFERENT user (not the derived os_user) so Path A0
# falls through into Path B — mirrors a daemon-context controller write
# whose leaf still needs repair the controller cannot perform without sudo.
printf '%s\n' '#!/usr/bin/env bash' >"$T5_BIN/id"
# shellcheck disable=SC2129
printf '%s\n' 'if [[ "${1:-}" == "-un" ]]; then printf "ci-operator\n"; exit 0; fi' >>"$T5_BIN/id"
printf '%s\n' 'if [[ "${1:-}" == "-u" ]]; then printf "1000\n"; exit 0; fi' >>"$T5_BIN/id"
printf '%s\n' 'exec /usr/bin/env -u PATH /usr/bin/id "$@" 2>/dev/null || command id "$@"' >>"$T5_BIN/id"
chmod +x "$T5_BIN/id"

# Build the body of the driver once; the can_repair stub differs between the
# fix-mode run and the teeth (regression) run.
emit_t5_driver() {
  local f="$1" can_repair_body="$2"
  emit_common_prelude "$f"
  # shellcheck disable=SC2129
  printf '%s\n' 'bridge_agent_os_user() { printf ""; }' >>"$f"
  # iso effective false + os_user empty → both A0 (different user) and A skip.
  printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$f"
  printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$f"
  # ensure_matrix_path FAILS (iso UID cannot chown the controller leaf).
  printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { printf "ensure_matrix_path: %s\n" "$*" >>"$CALL_LOG"; return 1; }' >>"$f"
  # Direct write succeeds (the test runner owns the tmp leaf — models the iso
  # UID writing into its own group-writable 2770 leaf).
  printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() { "$@"; }' >>"$f"
  # The privilege classifier under test. (Source defines it outside the
  # writer; stub it here so the smoke is host-agnostic — no real sudo.)
  printf '%s\n' "$can_repair_body" >>"$f"
  printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$f"
  printf '%s\n' '# shellcheck disable=SC1090' >>"$f"
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$f"
  printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*"; printf "warn: %s\n" "$*" >&2; }' >>"$f"
  emit_writer_extract "$f"
  # Re-stub can_repair AFTER the writer extract (eval of source defs does not
  # touch it, but keep deterministic).
  # shellcheck disable=SC2129
  printf '%s\n' "$can_repair_body" >>"$f"
  printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "test_clean" "idle-since" "1700005000"' >>"$f"
  printf '%s\n' 'echo "RC=$?"' >>"$f"
  chmod +x "$f"
}

# Fix-mode run: no root/sudo → best-effort continue.
T5_DRIVER="$T5_DIR/driver-fix.sh"
emit_t5_driver "$T5_DRIVER" '_bridge_isolation_v2_state_marker_can_repair_as_root() { return 1; }'
T5_LOG="$T5_DIR/log-fix"
"$BRIDGE_BASH" "$T5_DRIVER" "$REPO_ROOT" "$T5_AGENT_DIR" "$T5_CALL_LOG" "$T5_BIN" >"$T5_LOG" 2>&1 || true

grep -q '^RC=0$' "$T5_LOG" \
  || smoke_fail "T5: best-effort write did not return 0 when ensure_matrix_path failed + no root/sudo. log: $(tr '\n' '|' <"$T5_LOG" | tail -c 800)"
[[ -f "$T5_AGENT_DIR/idle-since" ]] \
  || smoke_fail "T5: best-effort direct write did not produce the marker. log: $(tr '\n' '|' <"$T5_LOG" | tail -c 800)"
if grep -q 'ensure_matrix_path failed' "$T5_LOG"; then
  smoke_fail "T5: #1342 warning emitted in the no-sudo best-effort case (should be suppressed). log: $(tr '\n' '|' <"$T5_LOG" | tail -c 800)"
fi
smoke_log "T5 PASS (fix): ensure_matrix_path fail + no root/sudo → best-effort marker write, no warning"

# Teeth run: classifier reports privileged (the pre-#1342 hard-fail shape) →
# warning re-emitted + marker dropped.
T5_TEETH_DIR="$SMOKE_TMP_ROOT/t5-teeth"
mkdir -p "$T5_TEETH_DIR"
T5_TEETH_CALL_LOG="$T5_TEETH_DIR/calls.log"
T5_TEETH_AGENT_DIR="$T5_TEETH_DIR/state/agents/test_clean"
mkdir -p "$T5_TEETH_AGENT_DIR"
T5_TEETH_DRIVER="$T5_TEETH_DIR/driver-teeth.sh"
emit_t5_driver "$T5_TEETH_DRIVER" '_bridge_isolation_v2_state_marker_can_repair_as_root() { return 0; }'
T5_TEETH_LOG="$T5_TEETH_DIR/log-teeth"
"$BRIDGE_BASH" "$T5_TEETH_DRIVER" "$REPO_ROOT" "$T5_TEETH_AGENT_DIR" "$T5_TEETH_CALL_LOG" "$T5_BIN" >"$T5_TEETH_LOG" 2>&1 || true

grep -q '^RC=0$' "$T5_TEETH_LOG" \
  && smoke_fail "T5-teeth: writer returned 0 when classifier reports privileged + ensure_matrix_path failed (hard-fail branch did not fire — teeth missing). log: $(tr '\n' '|' <"$T5_TEETH_LOG" | tail -c 800)"
grep -q 'ensure_matrix_path failed' "$T5_TEETH_LOG" \
  || smoke_fail "T5-teeth: expected the genuine-drift warning when classifier reports privileged. log: $(tr '\n' '|' <"$T5_TEETH_LOG" | tail -c 800)"
smoke_log "T5-teeth PASS: privileged classification preserves the genuine-drift hard-fail + warning"

# ---------- T6 — regression: Track A/J adjacent functions intact ----------
#
# The Track L edit lives in lib/bridge-isolation-v2.sh. Track J (#1370)
# bridge_resolve_agent_claude_config_dir lives in lib/bridge-state.sh on this
# integration base. Track A (#1353) bridge_agent_mark_setup_pending is a
# SIBLING lane that may merge onto the integration branch later in the wave,
# so it is asserted CONDITIONALLY (present → must parse; absent → skip — its
# arrival is a future integration event, not a Track L regression). Confirm
# every function present still parses + is declared after sourcing the state
# lib via bridge-lib.sh — proves the isolation-v2 edit caused no
# adjacent-function or cross-lib breakage. Uses the smoke's isolated
# BRIDGE_HOME so no live runtime is touched.
T6_STATE_SRC="$REPO_ROOT/lib/bridge-state.sh"
grep -q '^bridge_resolve_agent_claude_config_dir()' "$T6_STATE_SRC" \
  || smoke_fail "T6: Track J bridge_resolve_agent_claude_config_dir() definition missing from lib/bridge-state.sh"

# Detect whether Track A has landed on this base yet (sibling-lane gate).
T6_TRACK_A_PRESENT=0
if grep -q '^bridge_agent_mark_setup_pending()' "$T6_STATE_SRC"; then
  T6_TRACK_A_PRESENT=1
fi

T6_DIR="$SMOKE_TMP_ROOT/t6"
mkdir -p "$T6_DIR"
T6_DRIVER="$T6_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T6_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'set -uo pipefail' >>"$T6_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T6_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T6_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1 || true' >>"$T6_DRIVER"
printf '%s\n' 'declare -F bridge_agent_mark_setup_pending >/dev/null 2>&1 && printf "HAVE_A=1\n"' >>"$T6_DRIVER"
printf '%s\n' 'declare -F bridge_resolve_agent_claude_config_dir >/dev/null 2>&1 && printf "HAVE_J=1\n"' >>"$T6_DRIVER"
printf '%s\n' 'declare -F bridge_isolation_v2_write_agent_state_marker >/dev/null 2>&1 && printf "HAVE_L=1\n"' >>"$T6_DRIVER"
chmod +x "$T6_DRIVER"

T6_LOG="$T6_DIR/log"
"$BRIDGE_BASH" "$T6_DRIVER" "$REPO_ROOT" >"$T6_LOG" 2>&1 || true

if [[ "$T6_TRACK_A_PRESENT" == "1" ]]; then
  grep -q '^HAVE_A=1$' "$T6_LOG" \
    || smoke_fail "T6: Track A bridge_agent_mark_setup_pending present in source but not defined after bridge-lib source (adjacent-function damage). log: $(tr '\n' '|' <"$T6_LOG" | tail -c 800)"
  smoke_log "T6: Track A (#1353) present on this base — asserted defined"
else
  smoke_log "T6: Track A (#1353) not yet merged onto this integration base — sibling-lane gate (skip)"
fi
grep -q '^HAVE_J=1$' "$T6_LOG" \
  || smoke_fail "T6: Track J bridge_resolve_agent_claude_config_dir not defined after bridge-lib source (adjacent-function damage). log: $(tr '\n' '|' <"$T6_LOG" | tail -c 800)"
grep -q '^HAVE_L=1$' "$T6_LOG" \
  || smoke_fail "T6: the edited writer bridge_isolation_v2_write_agent_state_marker not defined after bridge-lib source (Track L parse break). log: $(tr '\n' '|' <"$T6_LOG" | tail -c 800)"
smoke_log "T6 PASS: Track J (#1370) + Track L (#1342) defined; Track A (#1353) gated — no adjacent-function damage"

smoke_log "ALL 6 PASS"
