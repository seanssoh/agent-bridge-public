#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/18849-dynamic-global-auth-sync.sh — Issue #18849 Part 1 (HIGH-RISK auth).
#
# File-based seamless token rotation for dynamic-vanilla Claude agents. A
# rotation now ALSO PATCHes the operator-global ~/.claude/.credentials.json (the
# file a dynamic-vanilla Claude agent reads: HOME=operator-global, no
# CLAUDE_CONFIG_DIR), so a running dynamic agent re-reads the rotated token
# seamlessly. Because the target is the operator's PERSONAL login file, the
# write is fenced by 7 non-negotiable gates — this smoke pins every one with
# FAKE files only (the real-Claude canary, rotate while a live dynamic session
# runs, is patch's post-PR live gate; a fake file cannot prove the in-process
# re-read).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home + a FAKE operator home
# under $SMOKE_TMP_ROOT. NEVER touches the real ~/.claude or ~/.agent-bridge.
#
# Cases:
#   T1  double-gate OFF (opt-in unset)        -> skipped, NO write             (gate 2)
#   T2  double-gate OFF (auto_rotate false)   -> skipped, NO write             (gate 2)
#   T3  double-gate ON                        -> PATCH: accessToken updated,
#       refreshToken + unknown fields preserved, 0600, identity WARN           (gates 3,7)
#   T4  idempotent re-run (same token)        -> converged, changed=false      (idempotency)
#   T5  forced-root                           -> fail-closed, NO write         (gate 4)
#   T6  absent global file + gate ON          -> created (no refreshToken)     (gate 3)
#   T7  write failure (allowed-root mismatch) -> fail-closed, original preserved (gates 4,5)
#   T8  read-only status surface              -> enabled, converged, identity DETECTED (gate 7)
#   T9  bash wrapper plumbing                 -> bridge-auth.sh -> bridge-auth.py PATCH
#   T10 ci-select routing                     -> bridge-auth.py + this smoke selected
#
# Footgun #11 (heredoc_write deadlock class): this driver and its helper avoid
# heredoc-stdin into a footgun-#11 target file (bridge-daemon.sh ceiling is 0 —
# the daemon parses sync-global JSON via the existing sync-status-parse helper).

set -uo pipefail

SMOKE_NAME="18849-dynamic-global-auth-sync"
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
HELPER="$SCRIPT_DIR/18849-dynamic-global-auth-sync-helper.py"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing bridge-auth.py: $AUTH_PY"
[[ -f "$AUTH_SH" ]] || smoke_fail "missing bridge-auth.sh: $AUTH_SH"
[[ -f "$HELPER" ]] || smoke_fail "missing helper: $HELPER"

REGISTRY="$SMOKE_TMP_ROOT/registry.json"
OP_HOME="$SMOKE_TMP_ROOT/op-home"
OP_CRED="$OP_HOME/.claude/.credentials.json"
OP_CFG="$OP_HOME/.claude.json"
DISPLAY_EMAIL="olduser@example.com"
# Benign, non-credential-shaped token (validate_token only requires len>=20 and
# no whitespace/quotes) so nothing here resembles a real Anthropic credential.
ACTIVE_TOKEN="ZZZactive-token-aaaaaaaaaaaaaaaaaaaa"

mkdir -p "$OP_HOME/.claude" "$SMOKE_TMP_ROOT/elsewhere"
smoke_assert_path_in_temp "$OP_CRED" "fake operator credential path"

reset_state() {
  python3 "$HELPER" seed-registry "$REGISTRY" "$ACTIVE_TOKEN" true
  python3 "$HELPER" seed-cred "$OP_CRED"
  python3 "$HELPER" seed-config "$OP_CFG" "$DISPLAY_EMAIL"
}

# Run bridge-auth.py sync-global / global-auth-status directly. $1=opt_in(0|1),
# remaining args appended. Honors a FORCE_ROOT override via the FORCE_ROOT env.
run_py() {
  local optin="$1"; shift
  # `pre` always carries at least `env`, so its expansion is never an empty
  # array under `set -u` (the bash 3.2 empty-array footgun).
  local -a pre=(env)
  [[ "$optin" == "1" ]] && pre+=("BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1")
  [[ "${FORCE_ROOT:-0}" == "1" ]] && pre+=("BRIDGE_AUTH_GLOBAL_SYNC_FORCE_ROOT=1")
  "${pre[@]}" python3 "$AUTH_PY" --registry "$REGISTRY" "$@"
}

cred_cksum() { cksum <"$OP_CRED" 2>/dev/null || printf 'ABSENT'; }
field() { python3 "$HELPER" json-field "$1"; }

# ── T1 ────────────────────────────────────────────────────────────────
test_gate_off_optin_unset() {
  reset_state
  local before out
  before="$(cred_cksum)"
  out="$(run_py 0 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "skipped" "$(printf '%s' "$out" | field status)" "T1 status=skipped"
  smoke_assert_eq "global_auth_sync_opt_in_disabled" "$(printf '%s' "$out" | field reason)" "T1 reason=opt_in_disabled"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field converged)" "T1 converged=False"
  smoke_assert_eq "$before" "$(cred_cksum)" "T1 operator credential is byte-identical (NO write)"
}

# ── T2 ────────────────────────────────────────────────────────────────
test_gate_off_auto_rotate_false() {
  reset_state
  python3 "$HELPER" set-rotate "$REGISTRY" false
  local before out
  before="$(cred_cksum)"
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "skipped" "$(printf '%s' "$out" | field status)" "T2 status=skipped"
  smoke_assert_eq "auto_rotate_disabled" "$(printf '%s' "$out" | field reason)" "T2 reason=auto_rotate_disabled"
  smoke_assert_eq "$before" "$(cred_cksum)" "T2 operator credential unchanged when auto_rotate OFF"
}

# ── T3 ────────────────────────────────────────────────────────────────
test_gate_on_patches_and_preserves() {
  reset_state
  local out err
  err="$SMOKE_TMP_ROOT/t3.err"
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json 2>"$err")"
  smoke_assert_eq "synced" "$(printf '%s' "$out" | field status)" "T3 status=synced"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field changed)" "T3 changed=True"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field converged)" "T3 converged=True"
  python3 "$HELPER" assert-patched "$OP_CRED" "$ACTIVE_TOKEN" >/dev/null \
    || smoke_fail "T3 PATCH did not preserve refreshToken/unknown fields or wrong mode"
  smoke_assert_contains "$(cat "$err")" "displayed identity" "T3 identity-shadow warning emitted (detection)"
  smoke_assert_contains "$(cat "$err")" "$DISPLAY_EMAIL" "T3 warning names the stale displayed identity"
}

# ── T4 ────────────────────────────────────────────────────────────────
test_idempotent_converged() {
  # T3 already wrote the active token; a re-run must be a converged no-op.
  local out
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "converged" "$(printf '%s' "$out" | field status)" "T4 status=converged"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field changed)" "T4 changed=False (idempotent)"
}

# ── T5 ────────────────────────────────────────────────────────────────
test_root_fail_closed() {
  reset_state
  local before out rc
  before="$(cred_cksum)"
  set +e
  out="$(FORCE_ROOT=1 run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T5 forced-root sync-global returned rc=0 (must fail closed)"
  smoke_assert_eq "error" "$(printf '%s' "$out" | field status)" "T5 status=error under forced-root"
  smoke_assert_eq "$before" "$(cred_cksum)" "T5 operator credential unchanged under forced-root (gate 4)"
}

# ── T6 ────────────────────────────────────────────────────────────────
test_absent_file_creates_minimal() {
  reset_state
  rm -f "$OP_CRED"
  local out
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "synced" "$(printf '%s' "$out" | field status)" "T6 status=synced (created)"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field created)" "T6 created=True"
  python3 "$HELPER" assert-created "$OP_CRED" "$ACTIVE_TOKEN" >/dev/null \
    || smoke_fail "T6 created credential missing active token, carries refreshToken, or wrong mode"
}

# ── T7 ────────────────────────────────────────────────────────────────
test_write_failure_preserves_original() {
  reset_state
  local before out rc
  before="$(cred_cksum)"
  set +e
  # allowed-root points at a sibling dir that does NOT contain the credential —
  # the fd-identity containment check rejects the write before any replace.
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$SMOKE_TMP_ROOT/elsewhere" --json)"
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T7 write-failure sync-global returned rc=0 (must fail closed)"
  smoke_assert_eq "error" "$(printf '%s' "$out" | field status)" "T7 status=error on containment reject"
  smoke_assert_eq "$before" "$(cred_cksum)" "T7 original operator credential preserved on write failure (gate 5)"
}

# ── T8 ────────────────────────────────────────────────────────────────
test_status_surface_detects_identity() {
  reset_state
  # converge first so the global fingerprint matches the active token
  run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json >/dev/null
  local out
  out="$(run_py 1 global-auth-status --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --json)"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field enabled)" "T8 status enabled=True"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field converged)" "T8 status converged=True"
  smoke_assert_eq "$DISPLAY_EMAIL" "$(printf '%s' "$out" | field identity_shadow.displayed_email)" \
    "T8 status DETECTS the displayed oauthAccount identity (not synced)"
  # status is read-only when disabled: opt-in OFF => enabled False, no write
  local out2 before
  before="$(cred_cksum)"
  out2="$(run_py 0 global-auth-status --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --json)"
  smoke_assert_eq "False" "$(printf '%s' "$out2" | field enabled)" "T8 status enabled=False when opt-in OFF"
  smoke_assert_eq "$before" "$(cred_cksum)" "T8 status surface never writes"
}

# ── T9 ────────────────────────────────────────────────────────────────
test_bash_wrapper_plumbing() {
  local agent="wrapper-dyn"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck shell=bash disable=SC2034\n'
    printf 'BRIDGE_ADMIN_AGENT_ID="%s"\n' "$agent"
    printf 'bridge_add_agent_id_if_missing %s\n' "$agent"
    printf 'BRIDGE_AGENT_DESC["%s"]="wrapper smoke"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]="%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_CONTINUE["%s"]="1"\n' "$agent"
  } >"$BRIDGE_ROSTER_LOCAL_FILE"

  reset_state
  local out
  out="$(BRIDGE_CONTROLLER_HOME="$OP_HOME" \
        BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
        BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 \
        bash "$AUTH_SH" claude-token sync-global --json)"
  smoke_assert_contains "$out" '"status": "synced"' "T9 wrapper: bash->python PATCH synced"
  python3 "$HELPER" assert-patched "$OP_CRED" "$ACTIVE_TOKEN" >/dev/null \
    || smoke_fail "T9 wrapper did not PATCH the operator-global credential through bridge-auth.py"
}

# ── T11 ───────────────────────────────────────────────────────────────
test_existing_no_claudeoauth_fail_closed() {
  python3 "$HELPER" seed-registry "$REGISTRY" "$ACTIVE_TOKEN" true
  python3 "$HELPER" seed-cred-noauth "$OP_CRED"
  python3 "$HELPER" seed-config "$OP_CFG" "$DISPLAY_EMAIL"
  local before out rc
  before="$(cred_cksum)"
  set +e
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T11 sync-global returned rc=0 on unrecognized existing file (must fail closed)"
  smoke_assert_eq "error" "$(printf '%s' "$out" | field status)" "T11 status=error on existing-no-claudeAiOauth"
  smoke_assert_eq "$before" "$(cred_cksum)" "T11 unrecognized existing credential left untouched (PATCH-only)"
}

# ── T10 ───────────────────────────────────────────────────────────────
test_ci_select_routing() {
  [[ -f "$CI_SELECT" ]] || smoke_fail "T10 missing ci-select-smoke.sh: $CI_SELECT"
  local out_py out_self
  out_py="$(bash "$CI_SELECT" --changed-file bridge-auth.py 2>/dev/null || true)"
  smoke_assert_contains "$out_py" "$SMOKE_NAME" \
    "T10 ci-select routes bridge-auth.py -> $SMOKE_NAME"
  out_self="$(bash "$CI_SELECT" --changed-file "scripts/smoke/$SMOKE_NAME.sh" 2>/dev/null || true)"
  smoke_assert_contains "$out_self" "$SMOKE_NAME" \
    "T10 ci-select routes the smoke file -> itself"
}

smoke_run "T1 double-gate OFF (opt-in unset) -> skipped, no write"            test_gate_off_optin_unset
smoke_run "T2 double-gate OFF (auto_rotate false) -> skipped, no write"       test_gate_off_auto_rotate_false
smoke_run "T3 double-gate ON -> PATCH preserves refreshToken/unknown + WARN"  test_gate_on_patches_and_preserves
smoke_run "T4 idempotent re-run -> converged, changed=false"                  test_idempotent_converged
smoke_run "T5 forced-root -> fail-closed, no write"                          test_root_fail_closed
smoke_run "T6 absent global file -> created minimal (no refreshToken)"        test_absent_file_creates_minimal
smoke_run "T7 write failure -> fail-closed, original preserved"              test_write_failure_preserves_original
smoke_run "T8 status surface -> enabled, converged, identity DETECTED"        test_status_surface_detects_identity
smoke_run "T9 bash wrapper plumbing -> sync-global PATCH end-to-end"          test_bash_wrapper_plumbing
smoke_run "T11 existing file lacking claudeAiOauth -> fail-closed, untouched" test_existing_no_claudeoauth_fail_closed
smoke_run "T10 ci-select routing -> bridge-auth.py + smoke selected"          test_ci_select_routing

smoke_log "all checks passed"
