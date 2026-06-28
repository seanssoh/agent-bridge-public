#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2164-rotate-global-sync.sh — Issue #2164 (HIGH-RISK auth).
#
# Rotation must SYNCHRONOUSLY converge the operator-global credential. Before
# #2164 only the daemon's post-rotation / periodic ticks (and an opt-in daemon
# gate) wrote the operator-global ~/.claude/.credentials.json; a reactive
# rotation (cron-runner `rotate --if-auto-enabled --sync`, the daemon usage
# monitor, or a manual `claude-token rotate/activate --sync`) changed the active
# pool token but did NOT converge the operator-global file inline — so a
# dynamic-vanilla Claude agent (HOME=operator-global, no CLAUDE_CONFIG_DIR)
# stayed wedged on the stale exhausted token until the ~3600s periodic tick.
#
# The fix adds `_converge_operator_global_inline`, invoked from cmd_rotate AND
# cmd_activate when the caller passes `--sync`. It is DOUBLE-GATED default-OFF
# (registry `auto_rotate_enabled` AND the `global-auth-sync` opt-in) and
# FAIL-SAFE: a converge hiccup NEVER rolls back the active-token change that
# already committed. This smoke pins that NEW wiring with FAKE files only — the
# converge primitive's containment/race internals are exhaustively covered by
# scripts/smoke/18849-dynamic-global-auth-sync.sh; here we prove the rotate /
# activate `--sync` PATH invokes it, the double gate, the no-`--sync` legacy
# no-op, and the rotation-never-rolled-back fail-safe.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home + a FAKE operator home
# under $SMOKE_TMP_ROOT pointed at via BRIDGE_CONTROLLER_HOME. NEVER touches the
# real ~/.claude or ~/.agent-bridge. Tokens are handled FINGERPRINT-only at this
# layer (the synthetic raw values live solely in the helper).
#
# Cases:
#   T1  rotate --sync, double-gate ON   -> operator-global converges to the new
#       active token fp; payload.global_sync synced+converged; refresh/unknown
#       preserved; rotation status=rotated                                (CORE)
#   T2  rotate --sync, opt-in OFF        -> operator-global UNCHANGED; rotation
#       still rotated; global_sync skipped (opt_in_disabled)        (gate 2 / fail-safe)
#   T3  rotate --sync, auto_rotate OFF   -> operator-global UNCHANGED; rotation
#       still rotated; global_sync skipped (auto_rotate_disabled)   (gate 1)
#   T4  rotate WITHOUT --sync            -> operator-global UNCHANGED; payload
#       carries NO global_sync key (legacy stale-safe behavior)
#   T5  activate --sync, double-gate ON  -> operator-global converges to the
#       activated token fp; global_sync converged
#   T6  activate WITHOUT --sync          -> operator-global UNCHANGED; no global_sync
#   T7  converge ERROR (symlinked .claude out of root) -> global_sync error,
#       NO .lock leak, operator credential byte-identical, BUT rotation still
#       committed (status=rotated) — the converge never rolls back the rotation (FAIL-SAFE)
#   T8  bash wrapper plumbing            -> bridge-auth.sh rotate --sync reaches
#       the inline converge through the wrapper's raw `"$@"` passthrough
#   T9  ci-select routing                -> bridge-auth.py + this smoke selected

set -uo pipefail

SMOKE_NAME="2164-rotate-global-sync"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"
CI_SELECT="$REPO_ROOT/scripts/ci-select-smoke.sh"
HELPER="$SCRIPT_DIR/2164-rotate-global-sync-helper.py"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing bridge-auth.py: $AUTH_PY"
[[ -f "$AUTH_SH" ]] || smoke_fail "missing bridge-auth.sh: $AUTH_SH"
[[ -f "$HELPER" ]] || smoke_fail "missing helper: $HELPER"

REGISTRY="$SMOKE_TMP_ROOT/registry.json"
OP_HOME="$SMOKE_TMP_ROOT/op-home"
OP_CRED="$OP_HOME/.claude/.credentials.json"

mkdir -p "$OP_HOME/.claude"
smoke_assert_path_in_temp "$OP_CRED" "fake operator credential path"

helper() { python3 "$HELPER" "$@"; }
field() { python3 "$HELPER" json-field "$1"; }
cred_cksum() { cksum <"$OP_CRED" 2>/dev/null || printf 'ABSENT'; }

# Run bridge-auth.py with the operator-global converge plumbed at the FAKE home.
#   $1 = opt_in (0|1) -> BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 when 1
#   remaining args appended after `--registry <reg>`.
# BRIDGE_CONTROLLER_HOME pins resolve_controller_claude_credentials_path() at the
# fake operator home; BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT=0 keeps the identity
# sub-step deterministic on a macOS test host (it never sources the credential
# PATCH this smoke asserts).
run_py() {
  local optin="$1"; shift
  local -a pre=(
    env
    "BRIDGE_CONTROLLER_HOME=$OP_HOME"
    "BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT=0"
  )
  [[ "$optin" == "1" ]] && pre+=("BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1")
  "${pre[@]}" python3 "$AUTH_PY" --registry "$REGISTRY" "$@"
}

# ── T1 ────────────────────────────────────────────────────────────────
# rotate --sync with the double gate ON converges the operator-global file from
# the stale (old active) token to the NEW active token — inline, no periodic
# tick. The dynamic-vanilla agent re-reads the new token at its next prompt.
test_rotate_sync_converges() {
  helper seed-registry "$REGISTRY" "ta" true
  helper seed-cred "$OP_CRED" "ta"           # operator-global holds the OLD active token
  local before_fp out
  before_fp="$(helper cred-fp "$OP_CRED")"
  out="$(run_py 1 rotate --sync --json)"
  smoke_assert_eq "rotated" "$(printf '%s' "$out" | field status)" "T1 rotation committed"
  smoke_assert_eq "synced"  "$(printf '%s' "$out" | field global_sync.status)" "T1 global_sync status=synced"
  smoke_assert_eq "True"    "$(printf '%s' "$out" | field global_sync.converged)" "T1 global_sync converged=True"
  local active_fp payload_fp after_fp
  active_fp="$(helper active-fp "$REGISTRY")"
  payload_fp="$(printf '%s' "$out" | field global_sync.fingerprint)"
  after_fp="$(helper cred-fp "$OP_CRED")"
  smoke_assert_eq "$active_fp" "$payload_fp" "T1 payload fingerprint == new active token fp"
  smoke_assert_eq "$active_fp" "$after_fp"   "T1 operator-global converged to the new active token fp"
  [[ "$after_fp" != "$before_fp" ]] || smoke_fail "T1 operator-global fp did not change (no converge)"
  helper assert-cred-preserved "$OP_CRED" >/dev/null \
    || smoke_fail "T1 converge PATCH lost refreshToken/unknown fields or wrong mode"
}

# ── T2 ────────────────────────────────────────────────────────────────
# Gate 2 (opt-in OFF): the rotation still commits, but the operator-global file
# is NEVER touched and the converge reports a skip — not an error.
test_rotate_sync_optin_off_skips() {
  helper seed-registry "$REGISTRY" "ta" true
  helper seed-cred "$OP_CRED" "ta"
  local before out
  before="$(cred_cksum)"
  out="$(run_py 0 rotate --sync --json)"
  smoke_assert_eq "rotated" "$(printf '%s' "$out" | field status)" "T2 rotation still committed (opt-in OFF)"
  smoke_assert_eq "skipped" "$(printf '%s' "$out" | field global_sync.status)" "T2 global_sync skipped"
  smoke_assert_eq "global_auth_sync_opt_in_disabled" "$(printf '%s' "$out" | field global_sync.reason)" \
    "T2 reason=global_auth_sync_opt_in_disabled"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field global_sync.converged)" "T2 converged=False"
  smoke_assert_eq "$before" "$(cred_cksum)" "T2 operator credential byte-identical (NO write)"
}

# ── T3 ────────────────────────────────────────────────────────────────
# Gate 1 (auto_rotate OFF): opt-in ON but the registry auto_rotate flag is OFF.
# A plain `rotate` (no --if-auto-enabled) still rotates the pool, but the
# converge's double gate skips with the OTHER reason — operator-global untouched.
test_rotate_sync_autorotate_off_skips() {
  helper seed-registry "$REGISTRY" "ta" false
  helper seed-cred "$OP_CRED" "ta"
  local before out
  before="$(cred_cksum)"
  out="$(run_py 1 rotate --sync --json)"
  smoke_assert_eq "rotated" "$(printf '%s' "$out" | field status)" "T3 rotation still committed (auto_rotate OFF)"
  smoke_assert_eq "skipped" "$(printf '%s' "$out" | field global_sync.status)" "T3 global_sync skipped"
  smoke_assert_eq "auto_rotate_disabled" "$(printf '%s' "$out" | field global_sync.reason)" \
    "T3 reason=auto_rotate_disabled"
  smoke_assert_eq "$before" "$(cred_cksum)" "T3 operator credential unchanged when auto_rotate OFF"
}

# ── T4 ────────────────────────────────────────────────────────────────
# Stale-safety: a rotation WITHOUT --sync must keep the legacy behavior — the
# operator-global file is never touched and the payload carries no global_sync.
test_rotate_no_sync_legacy_noop() {
  helper seed-registry "$REGISTRY" "ta" true
  helper seed-cred "$OP_CRED" "ta"
  local before out
  before="$(cred_cksum)"
  out="$(run_py 1 rotate --json)"
  smoke_assert_eq "rotated" "$(printf '%s' "$out" | field status)" "T4 rotation committed"
  smoke_assert_eq "" "$(printf '%s' "$out" | field global_sync.status)" "T4 NO global_sync key without --sync"
  smoke_assert_eq "$before" "$(cred_cksum)" "T4 operator credential unchanged without --sync"
}

# ── T5 ────────────────────────────────────────────────────────────────
# The fix covers BOTH active-token mutation sources: an explicit `activate
# --sync` converges the operator-global file to the activated token, too.
test_activate_sync_converges() {
  helper seed-registry "$REGISTRY" "ta" true
  helper seed-cred "$OP_CRED" "ta"
  local out
  out="$(run_py 1 activate tb --sync --json)"
  smoke_assert_eq "activated" "$(printf '%s' "$out" | field status)" "T5 activation committed"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field global_sync.converged)" "T5 global_sync converged=True"
  local active_fp after_fp
  active_fp="$(helper active-fp "$REGISTRY")"
  after_fp="$(helper cred-fp "$OP_CRED")"
  smoke_assert_eq "$active_fp" "$after_fp" "T5 operator-global converged to the activated token fp"
}

# ── T6 ────────────────────────────────────────────────────────────────
test_activate_no_sync_legacy_noop() {
  helper seed-registry "$REGISTRY" "ta" true
  helper seed-cred "$OP_CRED" "ta"
  local before out
  before="$(cred_cksum)"
  out="$(run_py 1 activate tb --json)"
  smoke_assert_eq "activated" "$(printf '%s' "$out" | field status)" "T6 activation committed"
  smoke_assert_eq "" "$(printf '%s' "$out" | field global_sync.status)" "T6 NO global_sync key without --sync"
  smoke_assert_eq "$before" "$(cred_cksum)" "T6 operator credential unchanged without --sync"
}

# ── T7 ────────────────────────────────────────────────────────────────
# FAIL-SAFE: a converge that RAISES (symlinked ~/.claude pointing out of the
# allowed root — the writer fails closed with no .lock leak) must be caught and
# reported as global_sync.status=error, but the rotation that already committed
# is NEVER rolled back (status stays "rotated"). Rotation success > converge hiccup.
test_converge_error_never_rolls_back_rotation() {
  helper seed-registry "$REGISTRY" "ta" true
  local evil="$SMOKE_TMP_ROOT/evil-claude"
  rm -rf "$evil" "$OP_HOME/.claude"
  mkdir -p "$evil"
  # ~/.claude becomes a symlink OUT of the allowed root ($OP_HOME) — the
  # dirfd-pinned O_NOFOLLOW lock refuses it and raises before any write.
  ln -s "$evil" "$OP_HOME/.claude"
  helper seed-cred "$OP_CRED" "ta"            # seeds through the symlink at $evil/.credentials.json
  local leak="$evil/.credentials.json.lock"
  rm -f "$leak"
  local before out
  before="$(cred_cksum)"
  out="$(run_py 1 rotate --sync --json)"
  smoke_assert_eq "rotated" "$(printf '%s' "$out" | field status)" \
    "T7 rotation NOT rolled back by a converge failure (still rotated)"
  smoke_assert_eq "error" "$(printf '%s' "$out" | field global_sync.status)" "T7 global_sync status=error"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field global_sync.converged)" "T7 converged=False"
  [[ ! -e "$leak" ]] || smoke_fail "T7 LOCK LEAK: .lock created at the symlink target outside allowed root: $leak"
  smoke_assert_eq "$before" "$(cred_cksum)" "T7 operator credential byte-identical on converge error"
  # Restore a real ~/.claude dir for any later case.
  rm -f "$OP_HOME/.claude"
  mkdir -p "$OP_HOME/.claude"
}

# ── T8 ────────────────────────────────────────────────────────────────
# Wrapper plumbing: `bridge-auth.sh claude-token rotate --sync` forwards `--sync`
# raw via `"$@"`, so the inline converge fires end-to-end through the bash
# wrapper (the rotate path the cron-runner / daemon usage-monitor actually use).
test_bash_wrapper_plumbing() {
  helper seed-registry "$REGISTRY" "ta" true
  helper seed-cred "$OP_CRED" "ta"
  local before_fp out
  before_fp="$(helper cred-fp "$OP_CRED")"
  # The wrapper additionally runs the per-agent settings sync AFTER the python
  # rotate; we only assert the operator-global converge (which the raw `"$@"`
  # passthrough triggers inside bridge-auth.py), so we tolerate the trailing
  # agent-sync's rc.
  out="$(BRIDGE_CONTROLLER_HOME="$OP_HOME" \
        BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
        BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 \
        BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT=0 \
        bash "$AUTH_SH" claude-token rotate --sync --json 2>/dev/null || true)"
  smoke_assert_contains "$out" '"global_sync"' "T8 wrapper rotate --sync reaches the inline converge"
  local active_fp after_fp
  active_fp="$(helper active-fp "$REGISTRY")"
  after_fp="$(helper cred-fp "$OP_CRED")"
  smoke_assert_eq "$active_fp" "$after_fp" "T8 wrapper converged operator-global to the new active token fp"
  [[ "$after_fp" != "$before_fp" ]] || smoke_fail "T8 wrapper did not converge the operator-global credential"
}

# ── T9 ────────────────────────────────────────────────────────────────
test_ci_select_routing() {
  [[ -f "$CI_SELECT" ]] || smoke_fail "T9 missing ci-select-smoke.sh: $CI_SELECT"
  local out_py out_self
  out_py="$(bash "$CI_SELECT" --changed-file bridge-auth.py 2>/dev/null || true)"
  smoke_assert_contains "$out_py" "$SMOKE_NAME" "T9 ci-select routes bridge-auth.py -> $SMOKE_NAME"
  out_self="$(bash "$CI_SELECT" --changed-file "scripts/smoke/$SMOKE_NAME.sh" 2>/dev/null || true)"
  smoke_assert_contains "$out_self" "$SMOKE_NAME" "T9 ci-select routes the smoke file -> itself"
}

smoke_run "T1 rotate --sync, double-gate ON -> operator-global converges"          test_rotate_sync_converges
smoke_run "T2 rotate --sync, opt-in OFF -> skipped, no write, rotation committed"  test_rotate_sync_optin_off_skips
smoke_run "T3 rotate --sync, auto_rotate OFF -> skipped, no write"                 test_rotate_sync_autorotate_off_skips
smoke_run "T4 rotate WITHOUT --sync -> legacy no-op (no global_sync)"              test_rotate_no_sync_legacy_noop
smoke_run "T5 activate --sync -> operator-global converges to activated token"     test_activate_sync_converges
smoke_run "T6 activate WITHOUT --sync -> legacy no-op"                             test_activate_no_sync_legacy_noop
smoke_run "T7 converge error never rolls back the committed rotation (fail-safe)"  test_converge_error_never_rolls_back_rotation
smoke_run "T8 bash wrapper plumbing -> rotate --sync reaches the inline converge"  test_bash_wrapper_plumbing
smoke_run "T9 ci-select routing -> bridge-auth.py + smoke selected"               test_ci_select_routing

smoke_log "all checks passed"
