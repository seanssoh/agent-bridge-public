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
#   --- #18849 Part 1b (identity-sync) ---
#   T15 verified probe (displayed != account) -> ~/.claude.json PATCHed, projects/
#       mcpServers/unknown/mode preserved, registry records verified identity
#   T16 probe fail (transport/429)            -> NO write, displayed unchanged, row stale (gate: probe-verified)
#   T17 probe no user:profile scope (403)     -> unknown, NO write
#   T18 probe 200 but no account email        -> unknown, NO write
#   T19 keychain-exists guard                 -> identity sync skipped + warn (no JSON/keychain divergence)
#   T20 .claude.json parent-swap after lock   -> write stays in LOCKED dir (single-dir_fd discriminator)
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
# Credential PATCH unchanged from Part 1a; Part 1b: the probe verifies the SAME
# account the config already displays, so identity CONVERGES with no write and
# the Part 1a stale WARNING is flipped to the quiet converged state.
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
  smoke_assert_eq "True" "$(printf '%s' "$out" | field identity_shadow.converged)" \
    "T3 identity CONVERGED (displayed == verified account)"
  smoke_assert_not_contains "$(cat "$err")" "does not match" \
    "T3 NO stale-identity warning when displayed already matches the verified account"
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
    "T8 status reports the displayed oauthAccount identity"
  # Part 1b: T8's sync verified DISPLAY_EMAIL → identity converged + recorded.
  smoke_assert_eq "True" "$(printf '%s' "$out" | field identity_converged)" \
    "T8 status reports identity_converged=True after a verified sync"
  smoke_assert_eq "$DISPLAY_EMAIL" "$(printf '%s' "$out" | field identity_shadow.verified_email)" \
    "T8 status reports the verified account email from the registry row"
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

# ── T15 (Part 1b) ─────────────────────────────────────────────────────
# A verified probe whose account differs from the displayed identity PATCHes
# ~/.claude.json's emailAddress (+ accountUuid) and PRESERVES projects /
# mcpServers / unknown keys / mode (PATCH-not-overwrite).
test_identity_sync_patches_and_preserves() {
  reset_state
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
  local fix="$SMOKE_TMP_ROOT/verified-new.json"
  python3 "$HELPER" write-fixture "$fix" verified "newuser@example.com"
  local out
  out="$(PROFILE_FIX="$fix" run_py 1 sync-global --global-credentials "$OP_CRED" \
        --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "synced" "$(printf '%s' "$out" | field identity_shadow.status)" \
    "T15 identity_shadow.status=synced (displayed != verified)"
  smoke_assert_eq "True" "$(printf '%s' "$out" | field identity_shadow.converged)" \
    "T15 identity_shadow.converged=True"
  python3 "$HELPER" assert-identity-patched "$OP_CFG" "newuser@example.com" >/dev/null \
    || smoke_fail "T15 identity PATCH lost projects/mcpServers/unknown or wrong mode"
  smoke_assert_eq "newuser@example.com" "$(python3 "$HELPER" reg-identity "$REGISTRY" account_email)" \
    "T15 registry row records the verified account_email"
  smoke_assert_eq "verified" "$(python3 "$HELPER" reg-identity "$REGISTRY" account_email_probe_status)" \
    "T15 registry probe_status=verified"
}

# ── T16 (Part 1b) ─────────────────────────────────────────────────────
# Probe FAILS (transport error) -> NO ~/.claude.json write, displayed identity
# unchanged, registry row marked stale (last-verified kept, never guessed).
test_identity_probe_fail_stale_not_guess() {
  reset_state
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
  local fix="$SMOKE_TMP_ROOT/transport.json"
  python3 "$HELPER" write-fixture "$fix" transport_error
  local out
  out="$(PROFILE_FIX="$fix" run_py 1 sync-global --global-credentials "$OP_CRED" \
        --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "synced" "$(printf '%s' "$out" | field status)" "T16 token sync still succeeds"
  smoke_assert_eq "unverified" "$(printf '%s' "$out" | field identity_shadow.status)" \
    "T16 identity_shadow.status=unverified on probe failure"
  smoke_assert_eq "stale" "$(printf '%s' "$out" | field identity_shadow.probe_status)" \
    "T16 probe_status=stale (network/429) — NOT a guess"
  python3 "$HELPER" assert-config-email "$OP_CFG" "$DISPLAY_EMAIL" >/dev/null \
    || smoke_fail "T16 displayed identity was WRITTEN on a failed probe (must stay unchanged)"
  smoke_assert_eq "stale" "$(python3 "$HELPER" reg-identity "$REGISTRY" account_email_probe_status)" \
    "T16 registry row marked stale"
}

# ── T17 (Part 1b) ─────────────────────────────────────────────────────
# Probe lacks the user:profile scope (403) -> unknown, NO write.
test_identity_probe_no_scope_unknown() {
  reset_state
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
  local fix="$SMOKE_TMP_ROOT/noscope.json"
  python3 "$HELPER" write-fixture "$fix" no_scope
  local out
  out="$(PROFILE_FIX="$fix" run_py 1 sync-global --global-credentials "$OP_CRED" \
        --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "no_scope" "$(printf '%s' "$out" | field identity_shadow.reason)" \
    "T17 identity reason=no_scope (token lacks user:profile)"
  smoke_assert_eq "unknown" "$(printf '%s' "$out" | field identity_shadow.probe_status)" \
    "T17 probe_status=unknown"
  python3 "$HELPER" assert-config-email "$OP_CFG" "$DISPLAY_EMAIL" >/dev/null \
    || smoke_fail "T17 displayed identity was WRITTEN despite missing scope"
}

# ── T18 (Part 1b) ─────────────────────────────────────────────────────
# Probe returns 200 but carries NO account email -> unknown, NO write.
test_identity_probe_no_email_unknown() {
  reset_state
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
  local fix="$SMOKE_TMP_ROOT/noemail.json"
  python3 "$HELPER" write-fixture "$fix" no_email
  local out
  out="$(PROFILE_FIX="$fix" run_py 1 sync-global --global-credentials "$OP_CRED" \
        --claude-config "$OP_CFG" --allowed-root "$OP_HOME" --json)"
  smoke_assert_eq "no_email" "$(printf '%s' "$out" | field identity_shadow.reason)" \
    "T18 identity reason=no_email"
  python3 "$HELPER" assert-config-email "$OP_CFG" "$DISPLAY_EMAIL" >/dev/null \
    || smoke_fail "T18 displayed identity was WRITTEN with no verified email"
}

# ── T19 (Part 1b) ─────────────────────────────────────────────────────
# keychain-exists guard: when the operator auth is keychain-backed, identity
# sync is SKIPPED + warned (do not diverge the JSON from the keychain identity).
test_identity_keychain_guard() {
  reset_state
  python3 "$HELPER" seed-config-full "$OP_CFG" "$DISPLAY_EMAIL"
  local fix="$SMOKE_TMP_ROOT/verified-new2.json" err out
  python3 "$HELPER" write-fixture "$fix" verified "newuser@example.com"
  err="$SMOKE_TMP_ROOT/t19.err"
  out="$(PROFILE_FIX="$fix" KEYCHAIN=1 run_py 1 sync-global --global-credentials "$OP_CRED" \
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
smoke_run "T15 identity sync PATCHes ~/.claude.json + preserves load-bearing"  test_identity_sync_patches_and_preserves
smoke_run "T16 probe fail -> stale, NO write (never a guess)"                  test_identity_probe_fail_stale_not_guess
smoke_run "T17 probe no-scope (403) -> unknown, NO write"                      test_identity_probe_no_scope_unknown
smoke_run "T18 probe no-email (200) -> unknown, NO write"                      test_identity_probe_no_email_unknown
smoke_run "T19 keychain-exists guard -> identity sync skipped + warn"          test_identity_keychain_guard
smoke_run "T20 .claude.json parent-swap-after-lock -> write in LOCKED dir"     test_identity_parent_swap_after_lock
smoke_run "T10 ci-select routing -> bridge-auth.py + smoke selected"          test_ci_select_routing

smoke_log "all checks passed"
