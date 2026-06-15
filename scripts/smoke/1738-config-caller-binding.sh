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

trap smoke_cleanup_temp_root EXIT

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
bridge_daemon_helper_python() { "$PYTHON_BIN" "$REPO_ROOT/lib/daemon-helpers/config-binding-list.py" "$2"; }
bridge_remove_config_caller_binding() { rm -f "$PRUNE_BD/$1.json" 2>/dev/null || true; }
bridge_publish_config_caller_binding() { :; }
bridge_agent_session() { :; }
bridge_agent_engine() { :; }
bridge_tmux_session_pane_pid() { :; }
bridge_audit_log() { :; }
daemon_info() { :; }
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
  printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":%s,"engine":"%s","updated_at":"healed"}\n' \
    "$1" "$1" "$PRUNE_LIVE_SESSION" "$2" "$3" >"$PRUNE_BD/$1.json"
}
# Binding is MISSING (live session, but no record) — self-heal must re-create it.
run_prune "server-up"
if [[ -f "$PRUNE_BD/$ADMIN_AGENT.json" ]] && grep -q '"updated_at":"healed"' "$PRUNE_BD/$ADMIN_AGENT.json"; then
  smoke_log "ok: prune SELF-HEAL re-published the missing binding for a live agent"
else
  smoke_fail "prune SELF-HEAL did not re-publish a missing binding for a live-session agent"
fi
# A persistent publish FAILURE must NOT churn (binding stays absent, no false heal).
clear_bindings
bridge_publish_config_caller_binding() { :; }   # publish that writes nothing
run_prune "server-up"
if [[ -f "$PRUNE_BD/$ADMIN_AGENT.json" ]]; then
  smoke_fail "prune SELF-HEAL logged success despite a publish that wrote nothing"
fi
smoke_log "ok: prune SELF-HEAL no-op on a publish failure (no churn)"

unset -f tmux bridge_agent_session bridge_tmux_session_pane_pid bridge_agent_engine bridge_publish_config_caller_binding
# Restore a clean, writable, empty store before exit.
clear_bindings

smoke_log "PASS: all #1738 config-caller-binding wrapper + hook + prune cases held"
