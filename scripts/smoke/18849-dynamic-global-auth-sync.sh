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
#   T11 existing file lacking claudeAiOauth   -> fail-closed, untouched (PATCH-only)
#   T12 symlinked parent (#18887 finding 1)   -> fail-closed, NO .lock leak outside root
#   T13 containment reject (#18887 finding 2) -> credential INODE unchanged (no rollback-rewrite)
#   T14 parent-swap after lock (#18887 r3)    -> write stays in LOCKED dir (lock-dir == write-dir)
#   --- #18849 Part 1b-v2 (operator-email identity source, closes #2145) ---
#   T3b no operator account_email             -> identity unconfigured, NO ~/.claude.json write
#   T15 operator account_email set            -> ~/.claude.json PATCHed (emailAddress only),
#       projects/mcpServers/unknown/mode preserved, registry records source=operator
#   T19 keychain-exists guard                 -> identity sync skipped + warn (no JSON/keychain divergence)
#   T20 .claude.json parent-swap after lock   -> write stays in LOCKED dir (single-dir_fd discriminator)
#   T21 token-replace race before write       -> fingerprint recheck skips the .claude.json write (no stale identity)
#   T22 write under registry lock             -> operator-identity .claude.json write holds the registry lock (window closed)
#   (operator-source capture/validation, optional verify-probe + scope change live in
#    scripts/smoke/18849-operator-account-email.sh)
#   T23 flag_one literal-"1"-only (#19234 r2) -> opt-in env override + set-env validator
#       reject/OFF a whitespace-padded " 1 " (no .strip()); ROOM_AUTOJOIN "1" un-regressed
#   T24 daemon early-skip literal-"1" (#19234 r2) -> bridge_daemon_global_auth_sync_tick
#       skips "true"/"yes"/"on"/" 1 " (strict raw == "1"), never spawns sync-global
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
# #18849 Part 1b: a default `user:profile` probe fixture so identity-sync is
# DETERMINISTIC and NEVER touches the network. The default verifies the SAME
# account the config already displays, so the existing token-sync cases converge
# with NO identity write (the steady state). Per-test overrides set $PROFILE_FIX.
DEFAULT_FIX="$SMOKE_TMP_ROOT/profile-default.json"

mkdir -p "$OP_HOME/.claude" "$SMOKE_TMP_ROOT/elsewhere"
smoke_assert_path_in_temp "$OP_CRED" "fake operator credential path"
python3 "$HELPER" write-fixture "$DEFAULT_FIX" verified "$DISPLAY_EMAIL"

reset_state() {
  python3 "$HELPER" seed-registry "$REGISTRY" "$ACTIVE_TOKEN" true
  python3 "$HELPER" seed-cred "$OP_CRED"
  python3 "$HELPER" seed-config "$OP_CFG" "$DISPLAY_EMAIL"
}

# Run bridge-auth.py sync-global / global-auth-status directly. $1=opt_in(0|1),
# remaining args appended. Honors a FORCE_ROOT override (FORCE_ROOT env), a
# per-test profile fixture ($PROFILE_FIX, defaults to the converged fixture), and
# a forced keychain-present detection ($KEYCHAIN=1).
run_py() {
  local optin="$1"; shift
  # `pre` always carries at least `env`, so its expansion is never an empty
  # array under `set -u` (the bash 3.2 empty-array footgun).
  local -a pre=(env "BRIDGE_CLAUDE_PROFILE_PROBE_FIXTURE=${PROFILE_FIX:-$DEFAULT_FIX}")
  [[ "$optin" == "1" ]] && pre+=("BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1")
  [[ "${FORCE_ROOT:-0}" == "1" ]] && pre+=("BRIDGE_AUTH_GLOBAL_SYNC_FORCE_ROOT=1")
  [[ "${KEYCHAIN:-0}" == "1" ]] && pre+=("BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT=1")
  "${pre[@]}" python3 "$AUTH_PY" --registry "$REGISTRY" "$@"
}

cred_cksum() { cksum <"$OP_CRED" 2>/dev/null || printf 'ABSENT'; }
# Portable inode of a path (BSD/macOS `stat -f %i`, GNU/Linux `stat -c %i`).
# Inode (not checksum) is the discriminating signal for finding-2: a rollback
# that re-writes the SAME bytes via the unhardened writer keeps the checksum
# identical but CHANGES the inode (unlink+recreate). "untouched" must mean the
# original inode survives, not just matching content.
path_inode() { stat -f %i "$1" 2>/dev/null || stat -c %i "$1" 2>/dev/null || printf 'ABSENT'; }
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
# Credential PATCH unchanged from Part 1a. Part 1b-v2: with NO operator
# account_email configured the identity sync is a fail-safe no-op (unconfigured),
# the displayed ~/.claude.json identity is NOT written, and no warning fires.
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
  smoke_assert_eq "unconfigured" "$(printf '%s' "$out" | field identity_shadow.status)" \
    "T3 identity unconfigured (no operator account_email)"
  smoke_assert_eq "False" "$(printf '%s' "$out" | field identity_shadow.converged)" \
    "T3 identity NOT converged without an operator email"
  python3 "$HELPER" assert-config-email "$OP_CFG" "$DISPLAY_EMAIL" >/dev/null \
    || smoke_fail "T3 displayed identity was WRITTEN with no operator account_email configured"
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
  # Part 1b-v2: the operator configures the displayed-identity source.
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id t1 --account-email "$DISPLAY_EMAIL" --json >/dev/null
  # converge first so the global fingerprint matches the active token
  run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json >/dev/null
  local out
  out="$(run_py 1 global-auth-status --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --json)"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field enabled)" "T8 status enabled=True"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field converged)" "T8 status converged=True"
  smoke_assert_eq "$DISPLAY_EMAIL" "$(printf '%s' "$out" | field identity_shadow.displayed_email)" \
    "T8 status reports the displayed oauthAccount identity"
  # Part 1b-v2: displayed == operator-configured → identity converged + reported.
  smoke_assert_eq "True" "$(printf '%s' "$out" | field identity_converged)" \
    "T8 status reports identity_converged=True after an operator-sourced sync"
  smoke_assert_eq "$DISPLAY_EMAIL" "$(printf '%s' "$out" | field identity_shadow.configured_email)" \
    "T8 status reports the operator-configured account email from the registry row"
  smoke_assert_eq "operator" "$(printf '%s' "$out" | field identity_shadow.source)" \
    "T8 status reports the identity source=operator"
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
        BRIDGE_CLAUDE_PROFILE_PROBE_FIXTURE="$DEFAULT_FIX" \
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

# ── T12 ───────────────────────────────────────────────────────────────
# #18887 finding 1 (adversarial): a SYMLINKED parent must never let the lock
# leak a .lock file outside the allowed root. The old code created the lock via
# a string-path os.open() that FOLLOWED the symlinked ~/.claude BEFORE any
# symlink/allowed-root validation, dropping a .credentials.json.lock at the
# symlink target outside the operator home. The dirfd-pinned lock opens the
# parent O_DIRECTORY|O_NOFOLLOW (ELOOP on a symlinked final component) so it
# fails closed with ZERO filesystem writes — no .lock anywhere.
test_symlinked_parent_no_lock_leak() {
  local evil="$SMOKE_TMP_ROOT/evil-claude"
  rm -rf "$evil" "$OP_HOME/.claude"
  mkdir -p "$evil"
  # ~/.claude is now a symlink pointing OUT of the allowed root ($OP_HOME).
  ln -s "$evil" "$OP_HOME/.claude"
  # Seed a credential + config through the symlink so a follow-the-link writer
  # would have a plausible file to patch (and a place to drop the .lock).
  python3 "$HELPER" seed-registry "$REGISTRY" "$ACTIVE_TOKEN" true
  python3 "$HELPER" seed-cred "$OP_CRED"
  python3 "$HELPER" seed-config "$OP_CFG" "$DISPLAY_EMAIL"
  local leak="$evil/.credentials.json.lock"
  rm -f "$leak"
  local out rc
  set +e
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T12 sync-global returned rc=0 under a symlinked parent (must fail closed)"
  smoke_assert_eq "error" "$(printf '%s' "$out" | field status)" "T12 status=error under symlinked parent"
  [[ ! -e "$leak" ]] || smoke_fail "T12 LOCK LEAK: .lock created at the symlink target outside allowed root: $leak"
  # Restore a real ~/.claude dir for any later case / reset_state.
  rm -f "$OP_HOME/.claude"
  mkdir -p "$OP_HOME/.claude"
}

# ── T13 ───────────────────────────────────────────────────────────────
# #18887 finding 2 (adversarial): on a containment-failure the operator's
# credential INODE must be unchanged — proving the file was never touched, not
# rewritten-with-identical-bytes. T7's checksum-only assertion false-greened the
# old rollback path (which re-wrote the preimage through the unhardened
# string-path writer: same checksum, NEW inode). The atomic dirfd writer raises
# before any rename, so the original inode survives byte-for-byte.
test_containment_failure_inode_unchanged() {
  reset_state
  local before_ck before_ino out rc after_ck after_ino
  before_ck="$(cred_cksum)"
  before_ino="$(path_inode "$OP_CRED")"
  [[ "$before_ino" != "ABSENT" ]] || smoke_fail "T13 precondition: seeded credential missing"
  set +e
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" --claude-config "$OP_CFG" --allowed-root "$SMOKE_TMP_ROOT/elsewhere" --json)"
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -ne 0 ]] || smoke_fail "T13 sync-global returned rc=0 on containment reject (must fail closed)"
  smoke_assert_eq "error" "$(printf '%s' "$out" | field status)" "T13 status=error on containment reject"
  after_ck="$(cred_cksum)"
  after_ino="$(path_inode "$OP_CRED")"
  smoke_assert_eq "$before_ck" "$after_ck" "T13 credential bytes unchanged on containment reject"
  smoke_assert_eq "$before_ino" "$after_ino" \
    "T13 credential INODE unchanged on containment reject (no rollback-rewrite — finding 2)"
}

# ── T14 ───────────────────────────────────────────────────────────────
# #18887 r3 (adversarial): a parent-swap AFTER lock acquisition must not
# redirect the write to an unlocked directory. The helper monkeypatches
# fcntl.flock so that the instant the global-credentials lock flocks its fd, the
# locked .claude is renamed away and a decoy dir is renamed into .claude (both
# under allowed_root — containment alone cannot catch it). It then asserts the
# rotated token landed in the LOCKED dir (now .claude-old) and the swapped-in
# decoy is untouched — i.e. lock-dir == write-dir. Proven discriminator: FAILS
# against the r2 string-path writer (re-resolves str(path.parent)), PASSES with
# the single-dir_fd r3 fix (lock yields the fd; read+write are dir_fd-relative).
test_parent_swap_after_lock_no_redirect() {
  local swaproot="$SMOKE_TMP_ROOT/race-op"
  rm -rf "$swaproot"; mkdir -p "$swaproot"
  # Assert on the dir we create; the helper builds .claude/.claude-decoy under
  # it (smoke_assert_path_in_temp resolves the parent, which must exist).
  smoke_assert_path_in_temp "$swaproot" "race op-home root"
  local out
  out="$(python3 "$HELPER" race-parent-swap "$REGISTRY" "$swaproot" "ZZZrotated-race-token-ffffffffffff" 2>&1)"
  smoke_assert_contains "$out" "OK race-parent-swap" \
    "T14 parent-swap-after-lock: rotated token stays in the LOCKED dir, decoy untouched (lock-dir == write-dir)"
}

# ── T15 (Part 1b-v2) ───────────────────────────────────────────────────
# An operator-configured account_email that differs from the displayed identity
# PATCHes ~/.claude.json's emailAddress (only) and PRESERVES projects /
# mcpServers / unknown keys / mode (PATCH-not-overwrite).
test_identity_sync_patches_and_preserves() {
  reset_state
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id t1 --account-email "newuser@example.com" --json >/dev/null
  local out
  out="$(run_py 1 sync-global --global-credentials "$OP_CRED" \
        --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "synced" "$(printf '%s' "$out" | field identity_shadow.status)" \
    "T15 identity_shadow.status=synced (displayed != operator-configured)"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field identity_shadow.converged)" \
    "T15 identity_shadow.converged=True"
  smoke_assert_eq "operator" "$(printf '%s' "$out" | field identity_shadow.source)" \
    "T15 identity source=operator"
  python3 "$HELPER" assert-identity-patched "$OP_CFG" "newuser@example.com" >/dev/null \
    || smoke_fail "T15 identity PATCH lost projects/mcpServers/unknown or wrong mode"
  smoke_assert_eq "newuser@example.com" "$(python3 "$HELPER" reg-identity "$REGISTRY" account_email)" \
    "T15 registry row records the operator account_email"
  smoke_assert_eq "operator" "$(python3 "$HELPER" reg-identity "$REGISTRY" account_email_source)" \
    "T15 registry account_email_source=operator"
}

# ── T21 (Part 1b-v2) ───────────────────────────────────────────────────
# Token-replace race: a concurrent cmd_add --replace swaps the active token
# (same id, new value) BEFORE the operator-identity write lands. The write path
# must recheck the row's CURRENT token fingerprint under the registry lock and
# SKIP the ~/.claude.json write — never write the configured email onto a row
# whose token is no longer the one the sync was based on. Proven discriminator:
# FAILS if the fingerprint recheck is removed (configured email written despite
# the mid-sync token replace).
test_identity_token_replace_race() {
  local raceroot="$SMOKE_TMP_ROOT/race-token-replace"
  rm -rf "$raceroot"; mkdir -p "$raceroot"
  smoke_assert_path_in_temp "$raceroot" "token-replace race op-home"
  local racereg="$raceroot/registry.json"
  local out
  out="$(python3 "$HELPER" race-token-replace-before-write "$racereg" "$raceroot" \
        "$DISPLAY_EMAIL" "swapped-victim@example.com" 2>&1)"
  smoke_assert_contains "$out" "OK race-token-replace-before-write" \
    "T21 token-replace race: no ~/.claude.json write on a mid-sync token swap"
}

# ── T22 (Part 1b-v2) ───────────────────────────────────────────────────
# The operator-identity ~/.claude.json write must run while the registry lock is
# HELD, so a concurrent cmd_add --replace (which also needs the registry lock)
# cannot land between the fingerprint/source recheck and the displayed-identity
# write. The helper wraps patch_global_claude_identity and asserts a non-blocking
# registry_lock grab BLOCKS at write time. Discriminator: FAILS if the write is
# moved outside the registry lock (the non-blocking grab would then succeed).
test_identity_post_persist_write_under_lock() {
  local raceroot="$SMOKE_TMP_ROOT/race-post-persist"
  rm -rf "$raceroot"; mkdir -p "$raceroot"
  smoke_assert_path_in_temp "$raceroot" "post-persist race op-home"
  local racereg="$raceroot/registry.json"
  local out
  out="$(python3 "$HELPER" race-post-persist-write-under-lock "$racereg" "$raceroot" \
        "$DISPLAY_EMAIL" "newverified@example.com" 2>&1)"
  smoke_assert_contains "$out" "OK race-post-persist" \
    "T22 operator-identity ~/.claude.json write runs under the registry lock (window closed)"
}

# ── T19 (Part 1b-v2) ───────────────────────────────────────────────────
# keychain-exists guard: when the operator auth is keychain-backed, identity
# sync is SKIPPED + warned (do not diverge the JSON from the keychain identity)
# EVEN with an operator account_email configured — the keychain owns the display.
test_identity_keychain_guard() {
  reset_state
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
  python3 "$AUTH_PY" --registry "$REGISTRY" set --id t1 --account-email "newuser@example.com" --json >/dev/null
  local err out
  err="$SMOKE_TMP_ROOT/t19.err"
  out="$(KEYCHAIN=1 run_py 1 sync-global --global-credentials "$OP_CRED" \
        --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json 2>"$err")"
  smoke_assert_eq "skipped" "$(printf '%s' "$out" | field identity_shadow.status)" \
    "T19 identity sync skipped under keychain-backed auth"
  smoke_assert_eq "keychain_present" "$(printf '%s' "$out" | field identity_shadow.reason)" \
    "T19 reason=keychain_present"
  smoke_assert_contains "$(cat "$err")" "keychain-backed" "T19 keychain divergence warning emitted"
  python3 "$HELPER" assert-config-email "$OP_CFG" "$DISPLAY_EMAIL" >/dev/null \
    || smoke_fail "T19 keychain guard did not prevent the ~/.claude.json identity write"
}

# ── T20 (Part 1b) ─────────────────────────────────────────────────────
# T14-style parent-swap-after-lock for the ~/.claude.json identity writer: the
# write must land in the LOCKED dir, proving lock-dir == write-dir (discriminator
# against a string-path re-resolution of the parent).
test_identity_parent_swap_after_lock() {
  local swaproot="$SMOKE_TMP_ROOT/race-cfg"
  rm -rf "$swaproot"; mkdir -p "$swaproot"
  smoke_assert_path_in_temp "$swaproot" "race cfg-home root"
  local out
  out="$(python3 "$HELPER" race-parent-swap-config "$REGISTRY" "$swaproot" "race-new@example.com" 2>&1)"
  smoke_assert_contains "$out" "OK race-parent-swap-config" \
    "T20 .claude.json parent-swap-after-lock: identity stays in the LOCKED dir"
}

# ── T23 (#19234 r2) ────────────────────────────────────────────────────
# The opt-in env override AND the flag_one set-env validator are LITERAL "1"
# only — neither .strip()s, so a whitespace-padded " 1 " is OFF / rejected, not
# silently normalized. Also proves the shared flag_one tightening does NOT
# regress BRIDGE_A2A_ROOM_AUTOJOIN (exact "1" still accepted).
test_flag_one_literal_strict() {
  local out
  out="$(python3 "$HELPER" flag-strict-probes 2>&1)" \
    || smoke_fail "T23 flag-strict-probes failed: $out"
  smoke_assert_contains "$out" "OK flag-strict-probes" \
    "T23 env override + flag_one validator are literal-1-only (no strip); ROOM_AUTOJOIN un-regressed"
}

# ── T24 (#19234 r2) ─────────────────────────────────────────────────────
# The daemon's opt-in EARLY-SKIP (bridge_daemon_global_auth_sync_tick) is
# literal-"1"-only too: a value like "true"/"yes"/"on"/" 1 " must early-skip and
# NOT spawn sync-global, matching the python env override's strict raw == "1".
# Unit-tests the real extracted function with shimmed deps; the sentinel is
# touched ONLY if the guard let execution reach the sync-global spawn.
test_daemon_gate_literal_strict() {
  local daemon_src="$REPO_ROOT/bridge-daemon.sh"
  local funcs="$SMOKE_TMP_ROOT/global-sync-tick.sh"
  awk '/^bridge_daemon_global_auth_sync_tick\(\) \{/,/^}/' "$daemon_src" >"$funcs"
  grep -q "^bridge_daemon_global_auth_sync_tick() {" "$funcs" \
    || smoke_fail "T24 could not extract bridge_daemon_global_auth_sync_tick (rename in bridge-daemon.sh?)"

  local sentinel="$SMOKE_TMP_ROOT/t24-spawned"
  run_daemon_gate() {
    rm -f "$sentinel"
    # env -i so no outer smoke state (set -e, BRIDGE_*) leaks in; the inner shell
    # sets its own flags. bridge_with_timeout is shimmed to TOUCH the sentinel —
    # reaching it means the early-skip guard did NOT fire.
    env -i PATH="$PATH" \
      FUNCS="$funcs" SENTINEL="$sentinel" \
      BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC="$1" \
      BRIDGE_BASH_BIN="bash" SCRIPT_DIR="/nonexistent" \
      BRIDGE_ADMIN_AGENT_ID="daemon" \
      bash -c '
        set -uo pipefail
        bridge_with_timeout() { : >"$SENTINEL"; return 1; }
        daemon_info() { :; }
        daemon_warn() { :; }
        bridge_audit_log() { :; }
        # shellcheck disable=SC1090
        source "$FUNCS"
        bridge_daemon_global_auth_sync_tick periodic >/dev/null 2>&1 || true
      '
  }

  local v
  for v in " 1 " "1 " " 1" "true" "yes" "on" "On" "True" "0" ""; do
    run_daemon_gate "$v"
    [[ -e "$sentinel" ]] && smoke_fail "T24 daemon early-skip SPAWNED sync for non-literal '$v' (must skip)"
  done
  run_daemon_gate "1"
  [[ -e "$sentinel" ]] || smoke_fail "T24 daemon early-skip did NOT proceed for the literal '1'"
  smoke_log "ok: daemon early-skip is literal-1-only (no true/yes/on/whitespace spawn)"
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
smoke_run "T12 symlinked parent -> fail-closed, NO .lock leak outside root"   test_symlinked_parent_no_lock_leak
smoke_run "T13 containment reject -> credential INODE unchanged (no rewrite)" test_containment_failure_inode_unchanged
smoke_run "T14 parent-swap-after-lock -> write stays in LOCKED dir"           test_parent_swap_after_lock_no_redirect
smoke_run "T15 operator-email identity PATCHes ~/.claude.json + preserves"      test_identity_sync_patches_and_preserves
smoke_run "T19 keychain-exists guard -> identity sync skipped + warn"          test_identity_keychain_guard
smoke_run "T20 .claude.json parent-swap-after-lock -> write in LOCKED dir"     test_identity_parent_swap_after_lock
smoke_run "T21 token-replace race -> no ~/.claude.json write"                  test_identity_token_replace_race
smoke_run "T22 identity write under registry lock (window closed)"             test_identity_post_persist_write_under_lock
smoke_run "T23 opt-in env + flag_one validator literal-1-only (no strip)"      test_flag_one_literal_strict
smoke_run "T24 daemon opt-in early-skip literal-1-only (no true/yes/on)"        test_daemon_gate_literal_strict
smoke_run "T10 ci-select routing -> bridge-auth.py + smoke selected"          test_ci_select_routing

smoke_log "all checks passed"
