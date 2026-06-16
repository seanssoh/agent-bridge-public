#!/usr/bin/env bash
# scripts/smoke/1738-config-caller-binding.sh — Issue #1738 (SECURITY).
#
# The #341 `config set` / `config set-env` write gate used to derive admin /
# operator trust from PROCESS ENV (BRIDGE_AGENT_ID / BRIDGE_ADMIN_AGENT_ID /
# BRIDGE_CALLER_SOURCE), which a sibling shell stage in the same agent-issued
# Bash command can seed and then hide behind eval / bash -c / sh -c / $var
# indirection a static hook cannot resolve. The durable fix: the controller
# publishes a per-agent tmux pane-pid binding and `bridge-config.py` matches its
# OWN process ancestry against `pane_pid` (a shell cannot set its parent pid);
# env identity no longer drives a positive authorization.
#
# This smoke is the ADVERSARIAL MATRIX for both verbs. It drives the real
# surfaces end-to-end in an isolated BRIDGE_HOME:
#   (A) the wrapper bridge-config.py — every env-spoof shape DENIES + leaves the
#       target file unchanged; only a NON-forgeable admin pane-binding (iso,
#       controller-owned store) or a real operator-TTY+--from writes.
#   (B) the real PreToolUse hook hooks/tool-policy.py — the interim
#       defense-in-depth gate denies a config mutation reached through eval /
#       bash -c / sh -c / unresolved $var around the verb, for BOTH verbs.
#
# #1738 r3 security closure (this round, both reviewers + adversarial sweep):
#   * FIX 1 (B1): the writability gate keys on OWNERSHIP, not os.access(W_OK)
#     mode bits — a same-UID owner who chmod-camouflages a forged record
#     (0444/0555) is STILL the owner and can re-chmod, so a caller-OWNED store
#     ALWAYS fail-closes (shared-UID -> operator-TTY-only). Only a foreign-owned
#     (iso, controller-owned) store trusts the binding.
#   * FIX 2 (B2): the env-settable liveness seam (BRIDGE_CONFIG_TMUX_BIN /
#     BRIDGE_CONFIG_ALLOW_TEST_TMUX) is REMOVED. Liveness uses a REAL tmux
#     session — the wrapper runs INSIDE a real pane, with the binding seeded from
#     the real session + real pane_pid.
#
# Teeth: against `5a82e4e1` (r2) the chmod-camouflage forgery AUTHORIZES + writes
# the target, and the env-stub liveness seam authorizes a stub-faked dead session
# — so this smoke FAILS on r2 and PASSES only with the r3 fix.
#
# Footgun #11 / lint-heredoc-ban: all fixtures + JSON payloads are built with
# printf and `>` file-redirect; the hook payload is piped from a file with
# `< file`. No heredoc / here-string operator anywhere (incl. comments).
#
# macOS: the deny-side teeth (chmod-camouflage DENY, shared-UID DENY, dead/stale
# liveness DENY) run single-UID with a real tmux. The iso POSITIVE-WRITE path
# needs a foreign-owned store (sudo chown) — skipped with a clear log when
# passwordless sudo is unavailable (CI / Linux runs it). Runs under
# /opt/homebrew/bin/bash 5.x and Linux CI bash alike.

set -euo pipefail

SMOKE_NAME="1738-config-caller-binding"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# #1738 r3 FIX 2 — false-green guard. The r3 smoke returned rc=0 after only the
# SERVER-DOWN prune tooth on at least one host (codex review: execution stopped
# after `run_prune "server-up"` yet the script still exited 0), so the SERVER-UP
# prune + self-heal teeth + the final PASS marker silently never ran. A green
# exit code WITHOUT the final marker is the exact false-pass we must make
# impossible. SMOKE_REACHED_END is set ONLY on the line that prints the PASS
# marker; this EXIT trap forces a non-zero exit whenever the script is about to
# exit 0 without having set it (early `return`/`exit`/`set -e` abort, a swallowed
# failure, anything). It still always runs temp-root cleanup.
SMOKE_REACHED_END=0
smoke_1738_exit_guard() {
  local rc=$?
  smoke_cleanup_temp_root
  if [[ "$rc" == "0" && "$SMOKE_REACHED_END" != "1" ]]; then
    printf '[smoke:%s][error] %s\n' "$SMOKE_NAME" \
      "exiting rc=0 WITHOUT the final PASS marker — teeth were skipped (the #1738 r3 false-green). Failing." >&2
    exit 1
  fi
  exit "$rc"
}
trap smoke_1738_exit_guard EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
WRAPPER="$REPO_ROOT/bridge-config.py"
HOOK="$REPO_ROOT/hooks/tool-policy.py"
ENV_FILE="$BRIDGE_HOME/agent-env.local.sh"
export BRIDGE_AGENT_ENV_LOCAL_FILE="$ENV_FILE"

ADMIN_AGENT="patch"
USER_AGENT="worker"
export BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT"

# Admin + non-admin agent homes (SESSION-TYPE drives is_admin_agent in the hook).
ADMIN_HOME="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
USER_HOME="$BRIDGE_AGENT_HOME_ROOT/$USER_AGENT"
mkdir -p "$ADMIN_HOME" "$USER_HOME"
printf -- '- session type: admin\n' >"$ADMIN_HOME/SESSION-TYPE.md"
printf -- '- session type: static\n' >"$USER_HOME/SESSION-TYPE.md"

# A protected JSON target for `config set` — a channel access.json that matches
# the `agents/*/.discord/access.json` glob in PROTECTED_GLOBS so the path-gate
# does not deny before the caller-trust gate is even reached.
PROTECTED_JSON="$BRIDGE_HOME/agents/$ADMIN_AGENT/.discord/access.json"
mkdir -p "$(dirname "$PROTECTED_JSON")"
printf '{"existing":"value"}\n' >"$PROTECTED_JSON"

BINDINGS_DIR="$BRIDGE_STATE_DIR/config-caller-bindings"
mkdir -p "$BINDINGS_DIR"

# --- real tmux live session (#1738 r3 FIX 2 — no env stub) -------------------
#
# The wrapper resolves tmux ONLY from fixed absolute paths and re-resolves the
# LIVE #{pane_pid} of the bound session on the DEFAULT tmux server (the wrapper
# strips $TMUX from its probe). We start a REAL detached session on the default
# server and run the positive-path wrapper INSIDE its pane so the pane process is
# a genuine ancestor of the wrapper (pane_pid in ancestry) and the liveness
# re-resolve matches.
#
# HARD REQUIREMENT (no silent false-pass): if tmux IS available but the live
# session cannot start, FAIL — the FIX 1 ownership teeth + liveness teeth depend
# on a real session, and a silent skip would let the security cases pass
# vacuously on CI. Only a genuinely tmux-less host (rare for bridge, which
# requires tmux) skips those sections, and that skip is loud.
smoke_config_caller_start_live_session || true
if [[ "${SMOKE_CONFIG_CALLER_LIVE_OK:-0}" != "1" ]] && command -v tmux >/dev/null 2>&1; then
  smoke_fail "tmux is available but the live session could not start — the FIX 1 ownership + liveness teeth cannot run (refusing to PASS vacuously). See the config-caller start logs above."
fi

# --- binding helpers --------------------------------------------------------

# Seed a binding for $1=agent $2=admin using the REAL live session + REAL
# pane_pid (so the in-pane wrapper's ancestry + liveness both match). Pass $3 to
# override the session (e.g. a dead-session name for the stale liveness case).
seed_binding() {
  local agent="$1" admin="$2" session="${3:-${SMOKE_LIVE_SESSION:-sess-live}}"
  smoke_seed_trusted_admin_binding "$BINDINGS_DIR" "$agent" "$admin" "$session"
}

clear_bindings() {
  smoke_clear_config_caller_bindings "$BINDINGS_DIR"
}

# --- target hash plumbing ---------------------------------------------------

sha_of() {
  local f="$1"
  if [[ -f "$f" ]]; then
    "$PYTHON_BIN" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f"
  else
    printf 'MISSING'
  fi
}

# --- wrapper plumbing (direct subprocess — for DENY cases) ------------------
#
# A DENY decision needs no live pane (the binding is rejected before any live
# match matters / there is no binding), so the deny-side cases run the wrapper as
# a direct subprocess of this smoke shell. Caller controls the env (so we can
# drive the env-spoof shapes explicitly).
run_wrapper_raw() {
  set +e
  "$PYTHON_BIN" "$WRAPPER" "$@" >"$SMOKE_TMP_ROOT/wrap.out" 2>"$SMOKE_TMP_ROOT/wrap.err"
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# Assert: a wrapper invocation DENIES (rc != 0, "deny" on stderr) AND leaves the
# named target file's bytes unchanged.
assert_wrapper_deny_unchanged() {
  local label="$1" target="$2"
  shift 2
  local before after rc
  before="$(sha_of "$target")"
  rc="$(run_wrapper_raw "$@")"
  after="$(sha_of "$target")"
  if [[ "$rc" == "0" ]]; then
    smoke_log "FAIL: ${label}: wrapper rc=0 (expected deny)"
    smoke_log "      out: $(cat "$SMOKE_TMP_ROOT/wrap.out")"
    smoke_fail "${label}: expected deny, got apply"
  fi
  smoke_assert_contains "$(cat "$SMOKE_TMP_ROOT/wrap.err")" "deny" "${label}: deny message"
  smoke_assert_eq "$before" "$after" "${label}: target unchanged on deny"
  smoke_log "ok: ${label} -> DENY + target unchanged (rc=${rc})"
}

# Same as above but also asserts a specific deny-reason substring.
assert_wrapper_deny_reason() {
  local label="$1" target="$2" want_reason="$3"
  shift 3
  local before after rc
  before="$(sha_of "$target")"
  rc="$(run_wrapper_raw "$@")"
  after="$(sha_of "$target")"
  if [[ "$rc" == "0" ]]; then
    smoke_log "FAIL: ${label}: wrapper rc=0 (expected deny)"
    smoke_log "      out: $(cat "$SMOKE_TMP_ROOT/wrap.out")"
    smoke_fail "${label}: expected deny, got apply"
  fi
  smoke_assert_contains "$(cat "$SMOKE_TMP_ROOT/wrap.err")" "$want_reason" \
    "${label}: deny reason"
  smoke_assert_eq "$before" "$after" "${label}: target unchanged on deny"
  smoke_log "ok: ${label} -> DENY (reason '${want_reason}', rc=${rc})"
}

# --- wrapper plumbing (in-pane — for the iso positive WRITE path) ------------
#
# The trusted-binding WRITE path needs (a) the wrapper to run inside the live
# pane (real ancestry + liveness) AND (b) a foreign-owned store (#1738 r3: a
# caller-owned store is always forgeable). Runs the wrapper in the pane with
# BRIDGE_* env set; echoes rc; out/err in $SMOKE_TMP_ROOT/wrap.{out,err}.
run_wrapper_in_pane() {
  SMOKE_CC_ENV=(
    "BRIDGE_HOME=$BRIDGE_HOME"
    "BRIDGE_STATE_DIR=$BRIDGE_STATE_DIR"
    "BRIDGE_AGENT_ENV_LOCAL_FILE=$ENV_FILE"
    "BRIDGE_AUDIT_LOG=$BRIDGE_AUDIT_LOG"
    "BRIDGE_ADMIN_AGENT_ID=$ADMIN_AGENT"
    "BRIDGE_AGENT_ID=$ADMIN_AGENT"
  )
  smoke_config_caller_run_in_pane "$WRAPPER" "$@"
}

# Assert: an IN-PANE wrapper invocation DENIES (rc != 0) with a specific
# deny-reason substring AND leaves the named target file's bytes unchanged. Used
# where the deny only triggers AFTER an ancestry match (so the wrapper must run
# inside the live pane — a direct subprocess would deny earlier with
# "no pane binding matches", masking the gate under test).
assert_in_pane_deny_reason() {
  local label="$1" target="$2" want_reason="$3"
  shift 3
  local before after rc
  before="$(sha_of "$target")"
  rc="$(run_wrapper_in_pane "$@")"
  after="$(sha_of "$target")"
  if [[ "$rc" == "0" ]]; then
    smoke_log "FAIL: ${label}: in-pane wrapper rc=0 (expected deny)"
    smoke_log "      out: $(cat "$SMOKE_TMP_ROOT/wrap.out")"
    smoke_fail "${label}: expected deny, got apply"
  fi
  smoke_assert_contains "$(cat "$SMOKE_TMP_ROOT/wrap.err")" "$want_reason" \
    "${label}: deny reason"
  smoke_assert_eq "$before" "$after" "${label}: target unchanged on deny"
  smoke_log "ok: ${label} -> DENY (reason '${want_reason}', rc=${rc})"
}

# --- hook plumbing (printf only) --------------------------------------------

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

write_bash_payload() {
  local target="$1" command="$2" esc
  esc="$(json_escape "$command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1738",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

hook_verdict_file() {
  local agent="$1" payload="$2" out
  out="$(BRIDGE_AGENT_ID="$agent" "$PYTHON_BIN" "$HOOK" <"$payload")"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    printf 'DENY'
  else
    printf 'ALLOW'
  fi
}

assert_bash_verdict() {
  local label="$1" agent="$2" command="$3" want="$4"
  local payload="$SMOKE_TMP_ROOT/p-$RANDOM-$RANDOM.json" got
  write_bash_payload "$payload" "$command"
  got="$(hook_verdict_file "$agent" "$payload")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      agent=${agent} command=${command}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

echo "[smoke:${SMOKE_NAME}] config-caller pane-binding wrapper + hook end-to-end"

# ===========================================================================
# SECTION 1 — WRAPPER: env-spoof shapes DENY + target unchanged (NO binding).
#
# With NO matching binding and no operator TTY, env-declared admin identity is
# untrusted. On origin/main every one of these ALLOWS + writes (teeth).
# ===========================================================================

clear_bindings

# 1a. `config set` — direct literal argv, spoofed admin env, no binding -> deny.
assert_wrapper_deny_unchanged \
  "set: direct-literal spoofed-env no-binding" "$PROTECTED_JSON" \
  set --path "$PROTECTED_JSON" --change "spoof=1" --from "$ADMIN_AGENT"

# 1b. `config set-env` — direct literal argv, spoofed admin env, no binding.
assert_wrapper_deny_unchanged \
  "set-env: direct-literal spoofed-env no-binding" "$ENV_FILE" \
  set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT"

# 1c/1d. ambient BRIDGE_AGENT_ID / BRIDGE_CALLER_SOURCE only (no --from) -> deny.
( export BRIDGE_AGENT_ID="$ADMIN_AGENT" BRIDGE_CALLER_SOURCE="operator-tui"
  assert_wrapper_deny_unchanged \
    "set: ambient env identity no-binding" "$PROTECTED_JSON" \
    set --path "$PROTECTED_JSON" --change "spoof=2" )
( export BRIDGE_AGENT_ID="$ADMIN_AGENT" BRIDGE_CALLER_SOURCE="operator-trusted-id"
  assert_wrapper_deny_unchanged \
    "set-env: ambient env identity no-binding" "$ENV_FILE" \
    set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" )

# 1e. `env -i` with ONLY spoofed trust vars (the Python boundary, no shell
#     wrapper) -> deny. Build the argv so env(1) sets exactly the spoof vars.
run_env_i_wrapper() {
  set +e
  /usr/bin/env -i \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_AGENT_ENV_LOCAL_FILE="$ENV_FILE" \
    BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
    BRIDGE_AGENT_ID="$ADMIN_AGENT" \
    BRIDGE_CALLER_SOURCE="operator-tui" \
    "$PYTHON_BIN" "$WRAPPER" "$@" >"$SMOKE_TMP_ROOT/wrap.out" 2>"$SMOKE_TMP_ROOT/wrap.err"
  local rc=$?
  set -e
  printf '%s' "$rc"
}
assert_env_i_deny_unchanged() {
  local label="$1" target="$2"
  shift 2
  local before after rc
  before="$(sha_of "$target")"
  rc="$(run_env_i_wrapper "$@")"
  after="$(sha_of "$target")"
  [[ "$rc" != "0" ]] || smoke_fail "${label}: expected deny, got apply (rc=0)"
  smoke_assert_contains "$(cat "$SMOKE_TMP_ROOT/wrap.err")" "deny" "${label}: deny message"
  smoke_assert_eq "$before" "$after" "${label}: target unchanged on deny"
  smoke_log "ok: ${label} -> DENY + target unchanged (rc=${rc})"
}
assert_env_i_deny_unchanged \
  "set: env -i spoof-only" "$PROTECTED_JSON" \
  set --path "$PROTECTED_JSON" --change "spoof=3" --from "$ADMIN_AGENT"
assert_env_i_deny_unchanged \
  "set-env: env -i spoof-only" "$ENV_FILE" \
  set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT"

# Confirm the managed env file was never created by any denied attempt.
if [[ -f "$ENV_FILE" ]]; then
  smoke_fail "managed env file exists after only-denied attempts: $ENV_FILE"
fi
smoke_log "ok: no managed file created by any denied wrapper attempt"

# ===========================================================================
# SECTION 2 — WRAPPER: NON-admin binding DENIES even if --from/env claims admin.
# ===========================================================================

clear_bindings
seed_binding "$USER_AGENT" "$ADMIN_AGENT"   # bound agent != admin

( export BRIDGE_AGENT_ID="$ADMIN_AGENT" BRIDGE_CALLER_SOURCE="operator-tui"
  assert_wrapper_deny_unchanged \
    "set: non-admin binding, --from admin" "$PROTECTED_JSON" \
    set --path "$PROTECTED_JSON" --change "spoof=4" --from "$ADMIN_AGENT" )
( export BRIDGE_AGENT_ID="$ADMIN_AGENT" BRIDGE_CALLER_SOURCE="operator-tui"
  assert_wrapper_deny_unchanged \
    "set-env: non-admin binding, --from admin" "$ENV_FILE" \
    set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT" )

# ===========================================================================
# SECTION 3 — WRAPPER: #1738 r3 FIX 1 (ownership-based writability gate).
#
# B1 chmod-camouflage TEETH: on r2 a same-UID owner forges <admin>.json, then
# chmod 0444/0555 it so os.access(W_OK) reads False -> the gate trusts it ->
# forged admin write authorized (rc=0). On r3 the gate keys on OWNERSHIP: the
# caller OWNS the store, so it ALWAYS fail-closes regardless of mode bits.
# ===========================================================================

# 3a. chmod-camouflage forgery on a caller-OWNED store -> DENY (the FIX 1 teeth).
#     The binding must MATCH (live session + ancestry) to reach the ownership
#     gate, so we run the wrapper IN the live pane. We drop the record/dir write
#     bits to mimic the r2 bypass; on r2 os.access(W_OK)=False -> trusted -> WRITE
#     (forged), on r3 ownership wins -> the store is forgeable -> fail-closed.
if [[ "${SMOKE_CONFIG_CALLER_LIVE_OK:-0}" == "1" ]]; then
  clear_bindings
  seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"   # real session + real pane_pid
  chmod 0444 "$BINDINGS_DIR"/*.json 2>/dev/null || true
  chmod 0555 "$BINDINGS_DIR" 2>/dev/null || true
  assert_in_pane_deny_reason \
    "set: chmod-camouflage forgery on caller-owned store" "$PROTECTED_JSON" \
    "agent-binding-store-writable" \
    set --path "$PROTECTED_JSON" --change "forge=1" --from "$ADMIN_AGENT"
  assert_in_pane_deny_reason \
    "set-env: chmod-camouflage forgery on caller-owned store" "$ENV_FILE" \
    "agent-binding-store-writable" \
    set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT"
  clear_bindings

  # 3b. POSITIVE control — iso (foreign-owned) store + REAL live session -> WRITE.
  #     Proves 3a is the OWNERSHIP gate, not a blanket disable: a binding the
  #     caller does NOT own is trusted and writes. Needs a foreign-owned store
  #     (sudo chown) — skipped (logged) where passwordless sudo is unavailable.
  clear_bindings
  seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"   # real session + real pane_pid
  if smoke_config_caller_make_store_foreign "$BINDINGS_DIR"; then
    : >"$BRIDGE_AUDIT_LOG"
    rm -f "$ENV_FILE"
    rc="$(run_wrapper_in_pane set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT")"
    smoke_assert_eq "0" "$rc" "set-env: iso foreign-owned store admin-binding apply rc"
    smoke_assert_file_exists "$ENV_FILE" "set-env: iso foreign-owned store wrote managed file"
    smoke_assert_contains "$(cat "$ENV_FILE")" \
      "export BRIDGE_A2A_RECONCILE_INTERVAL='60'" "set-env: iso admin-binding export line"
    # Audit rows carry before+after hashes for an apply (forensic anchor intact).
    smoke_assert_contains "$(cat "$BRIDGE_AUDIT_LOG")" '"before_sha256"' "iso-binding: audit before hash"
    smoke_assert_contains "$(cat "$BRIDGE_AUDIT_LOG")" '"after_sha256"' "iso-binding: audit after hash"
    smoke_log "ok: iso (foreign-owned) admin binding + real live session -> WROTE"
    clear_bindings
  else
    smoke_log "skip: iso foreign-owned-store WRITE path (no passwordless sudo) — deny-side teeth still ran"
    clear_bindings
  fi

  # 3c. --from that DISAGREES with the binding is an identity spoof -> deny. The
  #     mismatch check fires after the ancestry match (run in-pane), before the
  #     ownership gate, so a caller-owned store is fine here.
  clear_bindings
  seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"
  assert_in_pane_deny_reason \
    "set: --from mismatch vs binding" "$PROTECTED_JSON" \
    "identity-spoof" \
    set --path "$PROTECTED_JSON" --change "spoof=5" --from "$USER_AGENT"
  clear_bindings
else
  smoke_log "skip: FIX 1 ownership-gate cases (3a/3b/3c) — no real tmux live session available"
fi

# ===========================================================================
# SECTION 4 — HOOK: eval / bash -c / sh -c / $var indirection DENY (both verbs).
#
# The interim defense-in-depth gate. On origin/main these reach the wrapper with
# a spoofed identity; here the hook denies them outright (teeth at the hook).
# ===========================================================================

# 4a. eval-wrapped mutation (both verbs).
assert_bash_verdict "hook: eval set-env denied" "$ADMIN_AGENT" \
  "eval 'agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60'" "DENY"
assert_bash_verdict "hook: eval set denied" "$ADMIN_AGENT" \
  "eval 'agb config set --path $PROTECTED_JSON --change a=b'" "DENY"

# 4b. bash -c wrapped (both verbs).
assert_bash_verdict "hook: bash -c set-env denied" "$ADMIN_AGENT" \
  "bash -c 'agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60'" "DENY"
assert_bash_verdict "hook: bash -c set denied" "$ADMIN_AGENT" \
  "bash -c 'agb config set --path $PROTECTED_JSON --change a=b'" "DENY"

# 4c. sh -c wrapped (both verbs).
assert_bash_verdict "hook: sh -c set-env denied" "$ADMIN_AGENT" \
  "sh -c 'agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60'" "DENY"
assert_bash_verdict "hook: sh -c set denied" "$ADMIN_AGENT" \
  "sh -c 'agb config set --path $PROTECTED_JSON --change a=b'" "DENY"

# 4d. unresolved $var around the verb / path (both verbs).
assert_bash_verdict "hook: \$V set-env verb-indirection denied" "$ADMIN_AGENT" \
  'V=set-env; agb config $V BRIDGE_A2A_RECONCILE_INTERVAL=60' "DENY"
assert_bash_verdict "hook: \$P set --path indirection denied" "$ADMIN_AGENT" \
  'P=/x/access.json; agb config set --path $P --change a=b' "DENY"

# 4e. brace forms remain NON-WRITES WITHOUT new brace normalization (issue
#     analysis / PR #1736 r6): bash expands `{set,x}-env` to two words so a
#     sibling word lands in argparse's single positional slot and the wrapper
#     rejects it (rc=2, unrecognized arguments) before any write — it is
#     non-exploitable, so we deliberately do NOT teach the hook to normalize
#     braces. Drive the bash-expanded argv straight at the wrapper (no live
#     binding needed — argparse rejects before any authorization).
clear_bindings
rm -f "$ENV_FILE"
set +e
"$PYTHON_BIN" "$WRAPPER" config set-env x-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT" \
  >"$SMOKE_TMP_ROOT/brace.out" 2>"$SMOKE_TMP_ROOT/brace.err"
brace_rc=$?
set -e
[[ "$brace_rc" != "0" ]] || smoke_fail "brace-expanded set-env unexpectedly succeeded (rc=0)"
[[ ! -f "$ENV_FILE" ]] || smoke_fail "brace-expanded set-env wrote the managed file"
smoke_log "ok: brace-expanded set-env is a non-write (rc=${brace_rc}, no managed file)"
clear_bindings

# ===========================================================================
# SECTION 5 — HOOK: legit literal wrapper shapes still ALLOW (no over-block).
# ===========================================================================

assert_bash_verdict "hook: literal config set allowed" "$ADMIN_AGENT" \
  "agb config set --path $PROTECTED_JSON --change a=b" "ALLOW"
assert_bash_verdict "hook: literal config set-env allowed" "$ADMIN_AGENT" \
  "agb config set-env BRIDGE_A2A_RECONCILE_INTERVAL=60" "ALLOW"
# An unrelated eval/bash -c with no config verb must NOT be hijacked.
assert_bash_verdict "hook: unrelated bash -c not hijacked" "$ADMIN_AGENT" \
  "bash -c 'echo hello'" "ALLOW"
assert_bash_verdict "hook: unrelated \$var cmd not hijacked" "$ADMIN_AGENT" \
  'V=ls; $V -la' "ALLOW"

# ===========================================================================
# SECTION 6 — WRAPPER: #1738 r2/r3 BLOCKER 2 (real-tmux liveness / PID-reuse).
#
# TEETH: round 1 authorizes a binding purely on `pane_pid in ancestry`, never
# checking pane liveness, so an orphan binding whose pane is dead still matches.
# r2/r3 re-resolve the live #{pane_pid} of the recorded session via a REAL tmux
# (no env stub — FIX 2) and deny on a dead session / pid mismatch. These cases
# use a FOREIGN-owned store so the ONLY thing under test is liveness (the
# ownership gate would otherwise also deny); skipped where iso store is
# unavailable, since the dead-session deny is then indistinguishable from the
# shared-UID ownership deny.
# ===========================================================================

if [[ "${SMOKE_CONFIG_CALLER_LIVE_OK:-0}" == "1" ]]; then
  # 6a. Stale binding: bound to a session that does NOT exist on the real server
  #     (so display-message resolves to nothing). pane_pid is still the live
  #     pane's (ancestry would match in-pane), so r1 would authorize; r2/r3 deny
  #     because the recorded session no longer resolves to the bound pane_pid.
  clear_bindings
  seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT" "agb-cc-dead-session"
  if smoke_config_caller_make_store_foreign "$BINDINGS_DIR"; then
    rc="$(run_wrapper_in_pane set --path "$PROTECTED_JSON" --change "stale=1" --from "$ADMIN_AGENT")"
    if [[ "$rc" == "0" ]]; then
      smoke_fail "set: stale (dead-session) binding authorized despite dead session (rc=0)"
    fi
    smoke_assert_contains "$(cat "$SMOKE_TMP_ROOT/wrap.err")" "deny" "stale-binding: deny message"
    smoke_assert_eq "{\"existing\":\"value\"}" "$(tr -d '\n' < "$PROTECTED_JSON")" \
      "stale-binding: target unchanged"
    smoke_log "ok: stale binding (dead session) -> DENY despite ancestry (rc=${rc})"
    clear_bindings
  else
    smoke_log "skip: dead-session liveness DENY (no foreign store; would alias shared-UID deny)"
    clear_bindings
  fi
else
  smoke_log "skip: real-tmux liveness cases (no live session available)"
fi

# ===========================================================================
# SECTION 6b — WRAPPER: #1738 r3 FIX 1 (TMUX_TMPDIR is not a liveness oracle).
#
# TMUX_TMPDIR is the PARENT of tmux's default socket dir, so a caller can stand
# up a PRIVATE default server under a dir it controls, create a same-named
# session carrying a FORGED pane_pid, and (pre-fix) make the wrapper's liveness
# probe resolve that forged pid as "live" — re-opening the orphan-binding match
# the absolute-binary discipline closes (codex r3 proof:
# `_live_with_TMUX_TMPDIR=44062`, `_live_without=None`). FIX 1 strips
# TMUX_TMPDIR (with TMUX/TMUX_PANE) from the probe's child env, forcing it onto
# the controller's real default server. TEETH: build a private TMUX_TMPDIR
# server whose session is ABSENT from the default server, set TMUX_TMPDIR to it,
# and assert `_live_pane_pid_for_session` returns None (the strip ignored the
# caller-pointed server); a sanity probe confirms the private server WOULD have
# resolved the forged pid without the strip (so the tooth is not vacuous).
# ===========================================================================

if command -v tmux >/dev/null 2>&1; then
  # The private TMUX_TMPDIR must live under a SHORT base path: tmux derives its
  # socket as "$TMUX_TMPDIR/tmux-<uid>/default", and a macOS unix-domain socket
  # path caps at ~104 chars — $SMOKE_TMP_ROOT (/private/var/folders/...) blows
  # past that, so we mktemp a short /tmp dir and clean it up explicitly (it sits
  # outside the EXIT-trap's SMOKE_TMP_ROOT teardown).
  TMPDIR_PRIV="$(mktemp -d "${TMPDIR:-/tmp}/agb-cc-tt.XXXXXX" 2>/dev/null || mktemp -d /tmp/agb-cc-tt.XXXXXX)"
  case "$TMPDIR_PRIV" in
    /private/var/folders/*) TMPDIR_PRIV="$(mktemp -d /tmp/agb-cc-tt.XXXXXX)" ;;
  esac
  TMPDIR_SESS="agb-cc-tmpdir-probe-$$"
  # Create the private server with TMUX/TMUX_PANE unset so TMUX_TMPDIR (not an
  # inherited $TMUX) selects the socket dir. Kill ONLY this private server on the
  # way out (never the default server a co-resident operator may be using).
  if ( unset TMUX TMUX_PANE; TMUX_TMPDIR="$TMPDIR_PRIV" tmux new-session -d -s "$TMPDIR_SESS" ) 2>/dev/null; then
    sleep 0.4
    TMPDIR_FORGED_PID="$( ( unset TMUX TMUX_PANE; TMUX_TMPDIR="$TMPDIR_PRIV" tmux display-message -t "$TMPDIR_SESS" -p '#{pane_pid}' ) 2>/dev/null || true)"
    # Precondition: the default server must NOT carry this session, else the
    # tooth would be inconclusive (a default-server hit, not a TMUX_TMPDIR hit).
    if ( unset TMUX TMUX_PANE TMUX_TMPDIR; tmux has-session -t "$TMPDIR_SESS" 2>/dev/null ); then
      smoke_log "skip: TMUX_TMPDIR oracle tooth — default server already has '$TMPDIR_SESS' (inconclusive)"
    elif [[ ! "$TMPDIR_FORGED_PID" =~ ^[0-9]+$ ]]; then
      smoke_log "skip: TMUX_TMPDIR oracle tooth — private server pane_pid did not resolve"
    else
      # Sanity (anti-vacuous): WITHOUT the strip the private server DOES resolve
      # the forged pid — proves the redirect is real on this host.
      TMPDIR_ENV_AWARE="$( ( unset TMUX TMUX_PANE; TMUX_TMPDIR="$TMPDIR_PRIV" tmux display-message -t "$TMPDIR_SESS" -p '#{pane_pid}' ) 2>/dev/null || true)"
      smoke_assert_eq "$TMPDIR_FORGED_PID" "$TMPDIR_ENV_AWARE" \
        "TMUX_TMPDIR tooth: private server resolves the forged pid env-aware (anti-vacuous)"
      # The wrapper's probe WITH caller-set TMUX_TMPDIR must IGNORE the private
      # server (strip → default server → no such session → None).
      TMPDIR_WRAP="$( ( unset TMUX TMUX_PANE; TMUX_TMPDIR="$TMPDIR_PRIV" "$PYTHON_BIN" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m._live_pane_pid_for_session(sys.argv[2]))
' "$WRAPPER" "$TMPDIR_SESS" ) 2>/dev/null || true)"
      if [[ "$TMPDIR_WRAP" != "None" ]]; then
        smoke_fail "TMUX_TMPDIR tooth: wrapper liveness resolved the caller-pointed private server (got '$TMPDIR_WRAP', expected None) — TMUX_TMPDIR is still a liveness oracle"
      fi
      smoke_log "ok: TMUX_TMPDIR caller-pointed private server IGNORED by wrapper liveness (None; forged pid ${TMPDIR_FORGED_PID} not honored)"
    fi
    ( unset TMUX TMUX_PANE; TMUX_TMPDIR="$TMPDIR_PRIV" tmux kill-server ) 2>/dev/null || true
  else
    smoke_log "skip: TMUX_TMPDIR oracle tooth — could not start a private tmux server"
  fi
  rm -rf "$TMPDIR_PRIV" 2>/dev/null || true
else
  smoke_log "skip: TMUX_TMPDIR oracle tooth (no tmux)"
fi

# ===========================================================================
# SECTION 6c — WRAPPER: #1738 r5 FIX B (env ALLOWLIST kills loader injection).
#
# The r3/r4 probe built its child env as a DENYLIST (strip only TMUX*), so the
# dynamic-linker preload hooks DYLD_INSERT_LIBRARIES / DYLD_* (macOS) and
# LD_PRELOAD / LD_* (Linux) PASSED THROUGH — an attacker preloads a
# connect()-interpose library into the ABSOLUTE tmux (homebrew tmux is
# adhoc-signed; /usr/bin/tmux honors LD_PRELOAD) and redirects its socket to a
# private server returning a forged #{pane_pid}. r5 rebuilds the probe env as a
# strict ALLOWLIST (`_clean_probe_env`): only HOME/USER/LOGNAME/LANG/LC_* survive;
# every loader/preload AND TMUX* var is dropped by construction.
#
# TEETH (non-vacuous): export DYLD_INSERT_LIBRARIES + DYLD_LIBRARY_PATH +
# LD_PRELOAD + LD_LIBRARY_PATH + TMUX + TMUX_TMPDIR, then call _clean_probe_env
# and assert NONE of them appear in the returned env while a benign LANG DOES.
# A DENYLIST (old code) would leave every DYLD_*/LD_* var present, failing this.
# ===========================================================================

CLEAN_ENV_DUMP="$(
  DYLD_INSERT_LIBRARIES=/tmp/x.dylib \
  DYLD_LIBRARY_PATH=/tmp/x \
  LD_PRELOAD=/tmp/x.so \
  LD_LIBRARY_PATH=/tmp/x \
  TMUX=/tmp/tmux-9/default,1,0 \
  TMUX_TMPDIR=/tmp/attacker \
  LANG=en_US.UTF-8 \
  "$PYTHON_BIN" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
env = m._clean_probe_env()
for k in sorted(env):
    print(k)
' "$WRAPPER" 2>/dev/null || true
)"
for forbidden in DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH LD_PRELOAD LD_LIBRARY_PATH TMUX TMUX_TMPDIR; do
  if printf '%s\n' "$CLEAN_ENV_DUMP" | grep -qx "$forbidden"; then
    smoke_fail "FIX B: '$forbidden' survived into the probe child env (denylist regression — injection seam open)"
  fi
done
# Anti-vacuous: a benign allowlisted var MUST survive (proves _clean_probe_env is
# not just returning an empty dict, which would also pass the forbidden checks).
if ! printf '%s\n' "$CLEAN_ENV_DUMP" | grep -qx "LANG"; then
  smoke_fail "FIX B: allowlisted LANG did NOT survive — _clean_probe_env is over-stripping (tooth would be vacuous)"
fi
smoke_log "ok: FIX B probe env is an ALLOWLIST — DYLD_*/LD_*/TMUX* dropped, LANG kept"

# ===========================================================================
# SECTION 6d — WRAPPER: #1738 r5 FIX C (live pane must be OWNED by admin UID).
#
# On iso the liveness probe queries the attacker's OWN per-EUID default tmux
# server and can be fed a forged/camped pane_pid that matches the bound
# pane_pid. r5 closes this at the kernel boundary: the live pane PID's process
# OWNER UID must equal the admin agent's expected OS UID (`owner_uid`, recorded
# by the controller in the controller-owned record). An attacker runs as a
# DIFFERENT OS user and cannot own a process as the admin UID.
#
# We unit-test `_binding_session_is_live` directly (it owns both the liveness +
# owner checks): seed a record for the REAL live session + REAL pane_pid (so
# liveness resolves), and vary the recorded `owner_uid`.
#   - owner_uid == the live pane's REAL owner (this caller's uid)  -> live=True
#   - owner_uid == a NON-admin uid (the live pane is NOT owned by it) -> live=False
# TEETH (non-vacuous): without the owner check BOTH cases return True (liveness
# alone passes); the FIX makes the mismatched-owner case return False (DENY).
# ===========================================================================

if [[ "${SMOKE_CONFIG_CALLER_LIVE_OK:-0}" == "1" ]]; then
  SELF_UID="$(id -u)"
  # A uid that is NOT this caller's (so the live pane is provably not owned by
  # it): 0 if we are non-root, else 1.
  if [[ "$SELF_UID" != "0" ]]; then WRONG_UID=0; else WRONG_UID=1; fi
  fixc_is_live() {
    # $1 = owner_uid to record. Prints "True"/"False" from _binding_session_is_live.
    "$PYTHON_BIN" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
rec = {
    "session": sys.argv[2],
    "pane_pid": int(sys.argv[3]),
    "owner_uid": int(sys.argv[4]),
}
print(m._binding_session_is_live(rec))
' "$WRAPPER" "$SMOKE_LIVE_SESSION" "$SMOKE_LIVE_PANE_PID" "$1" 2>/dev/null || printf 'ERR'
  }
  # Positive control: owner_uid matches the live pane's REAL owner -> live.
  fixc_match="$(fixc_is_live "$SELF_UID")"
  smoke_assert_eq "True" "$fixc_match" \
    "FIX C: live pane owned by recorded owner_uid -> session is live (positive control)"
  # Teeth: owner_uid is a uid the live pane is NOT owned by -> NOT live (DENY).
  fixc_mismatch="$(fixc_is_live "$WRONG_UID")"
  smoke_assert_eq "False" "$fixc_mismatch" \
    "FIX C: live pane NOT owned by recorded owner_uid -> session NOT live (forged/camped pid rejected)"
  smoke_log "ok: FIX C owner check — pane owner UID must equal recorded owner_uid (kernel boundary)"

  # FIX C codex-r5 BLOCKER closure: a record MISSING owner_uid must FAIL CLOSED
  # on an iso (foreign-owned) store — the geteuid() fallback would otherwise let
  # an iso attacker pass by parking a PID they own (owner == their euid). The
  # fallback is allowed ONLY on a caller-WRITABLE (shared-UID) store. We unit-test
  # _expected_pane_owner_uid against a record with a _source_path in a store of
  # each ownership shape.
  fixc_expected_uid() {
    # $1 = bindings-dir to use for the store-writability probe (BRIDGE_STATE_DIR
    # selects config_caller_bindings_dir). Prints the resolved expected uid or
    # "None". The record carries NO owner_uid (the legacy/missing case).
    BRIDGE_STATE_DIR="$1" "$PYTHON_BIN" -c '
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("bc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
src = os.path.join(os.environ["BRIDGE_STATE_DIR"], "config-caller-bindings", "patch.json")
rec = {"session": "s", "pane_pid": 1, "_source_path": src}
print(m._expected_pane_owner_uid(rec))
' "$WRAPPER" 2>/dev/null || printf 'ERR'
  }
  # Shared-UID (caller-owned store): missing owner_uid -> geteuid() fallback (our
  # own uid), NOT None (so a legacy shared-UID record is not spuriously denied).
  MISS_SHARED="$(fixc_expected_uid "$BRIDGE_STATE_DIR")"
  smoke_assert_eq "$SELF_UID" "$MISS_SHARED" \
    "FIX C: missing owner_uid on caller-owned (shared-UID) store -> geteuid() fallback"
  # Iso (foreign-owned store): missing owner_uid MUST fail closed (-> None), so an
  # attacker cannot ride a legacy record with a self-owned camped pid. Needs sudo
  # to fabricate a foreign-owned store; skipped (logged) where unavailable.
  FOREIGN_STATE="$SMOKE_TMP_ROOT/fixc-foreign-state"
  mkdir -p "$FOREIGN_STATE/config-caller-bindings"
  printf '{"version":1}\n' >"$FOREIGN_STATE/config-caller-bindings/patch.json"
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    foreign_owner="nobody"; id nobody >/dev/null 2>&1 || foreign_owner="1"
    if sudo -n chown -R "$foreign_owner" "$FOREIGN_STATE/config-caller-bindings" 2>/dev/null; then
      sudo -n chmod 0711 "$FOREIGN_STATE/config-caller-bindings" 2>/dev/null || true
      sudo -n chmod 0644 "$FOREIGN_STATE/config-caller-bindings/patch.json" 2>/dev/null || true
      MISS_ISO="$(fixc_expected_uid "$FOREIGN_STATE")"
      smoke_assert_eq "None" "$MISS_ISO" \
        "FIX C: missing owner_uid on foreign-owned (iso) store -> FAIL CLOSED (None, not geteuid())"
      smoke_log "ok: FIX C missing-owner_uid fails closed on a foreign (iso) store (codex-r5 BLOCKER closed)"
      sudo -n chown -R "$SELF_UID" "$FOREIGN_STATE/config-caller-bindings" 2>/dev/null || true
    else
      smoke_log "skip: FIX C foreign-store missing-owner_uid tooth (sudo chown failed)"
    fi
  else
    smoke_log "skip: FIX C foreign-store missing-owner_uid tooth (no passwordless sudo) — shared-UID fallback tooth still ran"
  fi
else
  smoke_log "skip: FIX C owner-check cases (no real tmux live session available)"
fi

# ===========================================================================
# SECTION 7 — DAEMON PRUNE: #1738 r3 FIX 3 (false-delete / fleet self-DoS).
#
# `bridge_daemon_prune_orphan_config_caller_bindings` r2 deleted a binding
# whenever `tmux has-session` failed — but has-session ALSO fails when the tmux
# SERVER is momentarily unreachable, so a transient outage during one reconcile
# tick deleted EVERY live agent's binding fleet-wide (no recovery until restart).
# r3 adds a precondition guard (probe the server once; skip the whole pass if it
# is unreachable) + a materialized live-session SET membership check + a
# self-heal re-publish. TEETH: on r2 a server-outage prune deletes a live
# binding; on r3 it is preserved.
#
# We exercise the REAL prune function (extracted from bridge-daemon.sh by a small
# slicer, eval'd into THIS shell) with a `tmux` shell FUNCTION that shadows the
# external binary so we can deterministically simulate "server unreachable"
# (list-sessions exits 1) vs "server up, session X live" (list-sessions prints X).
# ===========================================================================

PRUNE_BD="$BRIDGE_STATE_DIR/config-caller-bindings"
mkdir -p "$PRUNE_BD"
PRUNE_LIVE_SESSION="agb-cc-prune-live"

# Slice ONLY the prune function body out of bridge-daemon.sh (no full-daemon
# boot) and eval it here. The committed slicer does a brace-depth walk
# (file-as-argv, no heredoc-stdin) and emits just that one function definition.
PRUNE_SLICER="$SCRIPT_DIR/1738-helpers/extract-shell-fn.py"
eval "$("$PYTHON_BIN" "$PRUNE_SLICER" "$REPO_ROOT/bridge-daemon.sh" \
  "bridge_daemon_prune_orphan_config_caller_bindings()")"

# Minimal shims the prune fn calls (the rest of the daemon is not booted). The
# `tmux` FUNCTION below is the controlled server: PRUNE_TMUX_MODE selects its
# list-sessions behaviour.
bridge_config_caller_bindings_dir() { printf '%s' "$PRUNE_BD"; }
# Dispatch on the helper NAME ($1) so the prune fn can reach BOTH the list helper
# (prune pass) and the record helper (#1738 r3 FIX 3 stale-record self-heal).
bridge_daemon_helper_python() {
  "$PYTHON_BIN" "$REPO_ROOT/lib/daemon-helpers/$1.py" "$2"
}
bridge_remove_config_caller_binding() { rm -f "$PRUNE_BD/$1.json" 2>/dev/null || true; }
bridge_publish_config_caller_binding() { :; }
bridge_agent_session() { :; }
bridge_agent_engine() { :; }
bridge_tmux_session_pane_pid() { :; }
bridge_admin_agent_id() { printf '%s' "$ADMIN_AGENT"; }
# #1738 r5 FIX C: the self-heal resolves the EXPECTED pane-owner UID for the
# agent via this helper (records it into the binding + checks the present
# record's owner_uid against it). Shim it to a fixed test UID so the present-
# record stale-check + the FIX C backfill path are deterministic.
PRUNE_OWNER_UID="12345"
bridge_config_caller_pane_owner_uid() { printf '%s' "$PRUNE_OWNER_UID"; }
# #1738 r5 FIX B: the prune fn calls bridge_daemon_scrub_probe_env (not sliced
# out — the slicer emits only the prune fn). Shim it to the real scrub behaviour
# so the smoke's `tmux` shell-function shadow is still reachable inside the
# subshell (the helper only `unset`s vars, never execs).
bridge_daemon_scrub_probe_env() {
  local _v=""
  unset TMUX TMUX_PANE TMUX_TMPDIR 2>/dev/null || true
  for _v in $(compgen -v 2>/dev/null); do
    case "$_v" in
      DYLD_*|LD_*) unset "$_v" 2>/dev/null || true ;;
    esac
  done
}
# #1738 r5 FIX A tooth: record each daemon audit EVENT + each daemon_info line so
# the self-heal teeth can assert WHICH outcome (healed vs failed) was emitted —
# a bare file-exists check cannot tell a verified heal from a false one.
PRUNE_AUDIT_EVENTS="$SMOKE_TMP_ROOT/prune-audit-events.log"
PRUNE_INFO_LINES="$SMOKE_TMP_ROOT/prune-info-lines.log"
: >"$PRUNE_AUDIT_EVENTS"
: >"$PRUNE_INFO_LINES"
bridge_audit_log() {
  # argv: <actor> <event> <subject> [--detail k=v ...]; record the event name.
  printf '%s\n' "${2:-}" >>"$PRUNE_AUDIT_EVENTS"
}
daemon_info() { printf '%s\n' "${1:-}" >>"$PRUNE_INFO_LINES"; }
BRIDGE_AGENT_IDS=()
PRUNE_TMUX_MODE="server-up"
tmux() {
  if [[ "$1" == "list-sessions" ]]; then
    if [[ "$PRUNE_TMUX_MODE" == "server-down" ]]; then
      printf 'error connecting to server\n' >&2
      return 1
    fi
    printf '%s\n' "$PRUNE_LIVE_SESSION"
    return 0
  fi
  return 1
}

run_prune() {
  PRUNE_TMUX_MODE="$1"
  bridge_daemon_prune_orphan_config_caller_bindings >/dev/null 2>&1 || true
}

# 7a. SERVER DOWN: a live binding must SURVIVE (the precondition guard skips the
#     whole pass). TEETH: on r2 (per-binding has-session, no guard) the binding
#     is deleted; on r3 it survives.
clear_bindings
printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":12345,"engine":"claude","updated_at":"now"}\n' \
  "$ADMIN_AGENT" "$ADMIN_AGENT" "$PRUNE_LIVE_SESSION" >"$PRUNE_BD/$ADMIN_AGENT.json"
run_prune "server-down"
if [[ -f "$PRUNE_BD/$ADMIN_AGENT.json" ]]; then
  smoke_log "ok: prune SERVER-DOWN preserved the live binding (no false-delete)"
else
  smoke_fail "prune SERVER-DOWN false-deleted a live binding (r3 precondition guard regressed)"
fi

# 7b. SERVER UP, session GONE: a genuine orphan (session not in the live set) is
#     pruned. Positive control that 7a is the guard, not a blanket no-op.
clear_bindings
printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":12345,"engine":"claude","updated_at":"now"}\n' \
  "$ADMIN_AGENT" "$ADMIN_AGENT" "agb-cc-prune-dead" >"$PRUNE_BD/$ADMIN_AGENT.json"
run_prune "server-up"
if [[ -f "$PRUNE_BD/$ADMIN_AGENT.json" ]]; then
  smoke_fail "prune SERVER-UP did not remove a genuinely orphaned binding"
fi
smoke_log "ok: prune SERVER-UP removed the genuinely orphaned binding"

# 7c. SERVER UP, session LIVE: a live binding is NOT pruned.
clear_bindings
printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":12345,"engine":"claude","updated_at":"now"}\n' \
  "$ADMIN_AGENT" "$ADMIN_AGENT" "$PRUNE_LIVE_SESSION" >"$PRUNE_BD/$ADMIN_AGENT.json"
run_prune "server-up"
if [[ ! -f "$PRUNE_BD/$ADMIN_AGENT.json" ]]; then
  smoke_fail "prune SERVER-UP deleted a binding whose session IS live"
fi
smoke_log "ok: prune SERVER-UP preserved the binding whose session is live"

# 7d. SELF-HEAL: a roster agent whose session is LIVE but whose binding file is
#     MISSING gets re-published this tick (single-point-of-publish fragility +
#     recovery from a mistaken delete). Override the roster + agent shims so the
#     self-heal loop has a live agent to repair, and make publish actually write
#     the record (mirrors the real publisher's effect).
clear_bindings
BRIDGE_AGENT_IDS=("$ADMIN_AGENT")
bridge_agent_session() { [[ "$1" == "$ADMIN_AGENT" ]] && printf '%s' "$PRUNE_LIVE_SESSION"; }
bridge_tmux_session_pane_pid() { printf '54321'; }
bridge_agent_engine() { printf 'claude'; }
bridge_publish_config_caller_binding() {
  # Mirror the real publisher: record owner_uid (the FIX C field) so the
  # self-heal's post-publish verification (which now also checks owner_uid)
  # sees a CURRENT record.
  printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":%s,"owner_uid":%s,"engine":"%s","updated_at":"healed"}\n' \
    "$1" "$1" "$PRUNE_LIVE_SESSION" "$2" "$PRUNE_OWNER_UID" "$3" >"$PRUNE_BD/$1.json"
}
# Binding is MISSING (live session, but no record) — self-heal must re-create it.
run_prune "server-up"
if [[ -f "$PRUNE_BD/$ADMIN_AGENT.json" ]] && grep -q '"updated_at":"healed"' "$PRUNE_BD/$ADMIN_AGENT.json"; then
  smoke_log "ok: prune SELF-HEAL re-published the missing binding for a live agent"
else
  smoke_fail "prune SELF-HEAL did not re-publish a missing binding for a live-session agent"
fi

# 7e. SELF-HEAL of a PRESENT-but-STALE record (#1738 r3 FIX 3). The r3 pass only
#     repaired a MISSING record; a present record for the live session with a
#     WRONG pane_pid (left over after a restart that recycled the pane) was
#     skipped and kept authorizing against the recycled pid. The fixed pass
#     validates the present record against the live pane_pid (54321 from the
#     shim) + bound agent + admin id and republishes on a mismatch. Seed a
#     present record with a STALE pane_pid (99999) and assert it is rewritten to
#     the live pid with the healed marker.
clear_bindings
printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":99999,"engine":"claude","updated_at":"stale"}\n' \
  "$ADMIN_AGENT" "$ADMIN_AGENT" "$PRUNE_LIVE_SESSION" >"$PRUNE_BD/$ADMIN_AGENT.json"
run_prune "server-up"
if [[ -f "$PRUNE_BD/$ADMIN_AGENT.json" ]] \
   && grep -q '"updated_at":"healed"' "$PRUNE_BD/$ADMIN_AGENT.json" \
   && grep -q '"pane_pid":54321' "$PRUNE_BD/$ADMIN_AGENT.json"; then
  smoke_log "ok: prune SELF-HEAL re-published a PRESENT-but-stale binding (wrong pane_pid -> live pane_pid)"
else
  smoke_fail "prune SELF-HEAL did not repair a present record with a stale pane_pid (FIX 3 regressed)"
fi

# 7f. A PRESENT and CURRENT record (correct pane_pid + agent + admin + owner_uid)
#     must be LEFT UNTOUCHED — no churn, no rewrite. Seed it already-current
#     (pane_pid 54321 = the live shim value, owner_uid = the expected shim value,
#     updated_at sentinel 'current') and assert the self-heal does NOT overwrite
#     it with the 'healed' marker.
clear_bindings
printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":54321,"owner_uid":%s,"engine":"claude","updated_at":"current"}\n' \
  "$ADMIN_AGENT" "$ADMIN_AGENT" "$PRUNE_LIVE_SESSION" "$PRUNE_OWNER_UID" >"$PRUNE_BD/$ADMIN_AGENT.json"
run_prune "server-up"
if grep -q '"updated_at":"current"' "$PRUNE_BD/$ADMIN_AGENT.json" \
   && ! grep -q '"updated_at":"healed"' "$PRUNE_BD/$ADMIN_AGENT.json"; then
  smoke_log "ok: prune SELF-HEAL left a present-and-current binding untouched (no churn)"
else
  smoke_fail "prune SELF-HEAL rewrote a present-and-current binding (false churn)"
fi

# 7f2. #1738 r5 FIX C BACKFILL (codex r5 r2 finding): a PRESENT record that
#      matches pane_pid + agent + admin but LACKS owner_uid (a legacy / pre-r5
#      record) must be treated as stale and REPUBLISHED so owner_uid is backfilled
#      — otherwise the wrapper (which fails closed on a missing owner_uid on iso)
#      would deny the admin's config-set indefinitely until some unrelated
#      republish. Seed a record with the right pane_pid/agent/admin but NO
#      owner_uid and assert the self-heal rewrites it (healed marker + owner_uid
#      now present). Non-vacuous: without the owner_uid arm in the present-record
#      skip, this record matches the 3 legacy fields -> skipped -> never backfilled.
clear_bindings
: >"$PRUNE_AUDIT_EVENTS"
bridge_publish_config_caller_binding() {
  printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":%s,"owner_uid":%s,"engine":"%s","updated_at":"healed"}\n' \
    "$1" "$1" "$PRUNE_LIVE_SESSION" "$2" "$PRUNE_OWNER_UID" "$3" >"$PRUNE_BD/$1.json"
}
printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":54321,"engine":"claude","updated_at":"legacy-no-owner"}\n' \
  "$ADMIN_AGENT" "$ADMIN_AGENT" "$PRUNE_LIVE_SESSION" >"$PRUNE_BD/$ADMIN_AGENT.json"
run_prune "server-up"
if grep -q '"updated_at":"healed"' "$PRUNE_BD/$ADMIN_AGENT.json" \
   && grep -q "\"owner_uid\":$PRUNE_OWNER_UID" "$PRUNE_BD/$ADMIN_AGENT.json" \
   && grep -q '^config_caller_binding_self_healed$' "$PRUNE_AUDIT_EVENTS"; then
  smoke_log "ok: FIX C BACKFILL — legacy record lacking owner_uid is republished with owner_uid (no indefinite fail-closed)"
else
  smoke_fail "FIX C BACKFILL: a present record lacking owner_uid was NOT republished (legacy iso record would stay fail-closed forever)"
fi

# A persistent publish FAILURE (no record at all) must NOT churn (binding stays
# absent, no false heal) and must record a self-heal FAILURE, not a success.
clear_bindings
: >"$PRUNE_AUDIT_EVENTS"
bridge_publish_config_caller_binding() { :; }   # publish that writes nothing
run_prune "server-up"
if [[ -f "$PRUNE_BD/$ADMIN_AGENT.json" ]]; then
  smoke_fail "prune SELF-HEAL logged success despite a publish that wrote nothing"
fi
if grep -q '^config_caller_binding_self_healed$' "$PRUNE_AUDIT_EVENTS"; then
  smoke_fail "prune SELF-HEAL emitted a self_healed audit row despite a publish that wrote NO record"
fi
smoke_log "ok: prune SELF-HEAL no-op on a missing-after-publish failure (no churn, no false self_healed)"

# ===========================================================================
# 7g. #1738 r5 FIX A (codex r4 BLOCKER) — self-heal must VERIFY the heal.
#
# The pre-r5 self-heal logged/counted `config_caller_binding_self_healed` after
# publish on a bare `[[ -f "$dir/$agent.json" ]]`. When a STALE record already
# EXISTS and publish is a NO-OP (or fails to rewrite it), the stale file still
# satisfies `-f`, so the daemon emits a `self_healed` audit row while the record
# is STILL stale (codex reproduced: seed pane_pid:99999, publish writes nothing,
# false `self_healed`). FIX A re-reads the record after publish and requires
# pane_pid == live pane AND agent_id == agent AND admin_agent_id == admin BEFORE
# emitting `self_healed`; a still-stale record emits a
# `config_caller_binding_self_heal_failed` row instead.
#
# TEETH (non-vacuous): seed a PRESENT-but-STALE record (pane_pid 99999, live pane
# is 54321 from the shim) and force publish to a NO-OP (leaves the stale file in
# place). Assert NO `self_healed` row is emitted and a `self_heal_failed` row IS.
# Reverting FIX A (the bare `[[ -f ]]` + unconditional self_healed) makes this
# tooth FAIL: the stale file satisfies `-f` so a false `self_healed` is emitted
# and the `self_heal_failed` row is absent.
# ===========================================================================
clear_bindings
: >"$PRUNE_AUDIT_EVENTS"
printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":99999,"engine":"claude","updated_at":"stale"}\n' \
  "$ADMIN_AGENT" "$ADMIN_AGENT" "$PRUNE_LIVE_SESSION" >"$PRUNE_BD/$ADMIN_AGENT.json"
bridge_publish_config_caller_binding() { :; }   # publish that writes nothing (no-op)
run_prune "server-up"
if grep -q '^config_caller_binding_self_healed$' "$PRUNE_AUDIT_EVENTS"; then
  smoke_fail "prune SELF-HEAL emitted self_healed for a STALE-present record that publish did NOT repair (FIX A regressed)"
fi
if ! grep -q '^config_caller_binding_self_heal_failed$' "$PRUNE_AUDIT_EVENTS"; then
  smoke_fail "prune SELF-HEAL did NOT emit self_heal_failed for a still-stale record after a no-op publish (FIX A regressed)"
fi
# The stale record is still present (publish wrote nothing) — the point is the
# AUDIT row reflects FAILURE, not a false success.
smoke_assert_contains "$(cat "$PRUNE_BD/$ADMIN_AGENT.json")" '"pane_pid":99999' \
  "FIX A: stale record left in place by no-op publish (audit is the signal, not deletion)"
smoke_log "ok: FIX A self-heal VERIFIES — stale-present + no-op publish emits self_heal_failed, NOT self_healed"

unset -f tmux bridge_agent_session bridge_tmux_session_pane_pid bridge_agent_engine bridge_publish_config_caller_binding bridge_daemon_scrub_probe_env bridge_config_caller_pane_owner_uid
# Restore a clean, writable, empty store before exit.
clear_bindings

# Reaching this line means every tooth above ran (no early abort). Set the
# sentinel the EXIT guard checks, THEN print the PASS marker; a rc=0 exit without
# this is treated as a false-green and forced to fail (#1738 r3 FIX 2).
SMOKE_REACHED_END=1
smoke_log "PASS: all #1738 config-caller-binding wrapper + hook + prune cases held"
