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
# This smoke is the ADVERSARIAL MATRIX for both verbs. It drives two real
# surfaces end-to-end in an isolated BRIDGE_HOME:
#   (A) the wrapper bridge-config.py — every env-spoof shape (direct literal,
#       $V/$P var-expanded argv, direct `python3 bridge-config.py`, `env -i`
#       with only spoofed trust vars, ambient env) DENIES and leaves the target
#       file unchanged; only a matching admin pane-binding (process ancestry) or
#       a real operator-TTY+--from writes.
#   (B) the real PreToolUse hook hooks/tool-policy.py — the interim
#       defense-in-depth gate denies a config mutation reached through eval /
#       bash -c / sh -c / unresolved $var around the verb, for BOTH verbs.
#
# Teeth: against origin/main (env-trust model) the spoof shapes ALLOW + write
# the target — so this smoke FAILS on main and PASSES only with the #1738 fix.
#
# Footgun #11 / lint-heredoc-ban: all fixtures + JSON payloads are built with
# printf and `>` file-redirect; the hook payload is piped from a file with
# `< file`. No heredoc / here-string operator anywhere (incl. comments).
#
# macOS: pure policy-decision + file-write smoke; no sudo / multi-UID needed.
# Runs under /opt/homebrew/bin/bash 5.x and Linux CI bash alike.

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

# --- fake tmux (match-time liveness stub, #1738 r2 BLOCKER 2) ----------------
#
# bridge-config.py re-resolves the live `#{pane_pid}` of a matched binding's
# session via an ABSOLUTE tmux and requires it to equal the bound pane_pid; a
# dead session / mismatch denies. There is no real tmux server in this smoke, so
# we point BRIDGE_CONFIG_TMUX_BIN at this stub. It prints the pane_pid the test
# wants for the queried session:
#   * `display-message -t <SESSION_LIVE> -p '#{pane_pid}'` -> $FAKE_LIVE_PID
#     (the smoke sets this to $$, the bound pane_pid, so the session is "live").
#   * any other session (the stale / dead case) -> exit 1 (session gone).
# Setting FAKE_LIVE_PID to a different value simulates pid-reuse (mismatch).
SESSION_LIVE="sess-live"
FAKE_TMUX="$SMOKE_TMP_ROOT/fake-tmux"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# fake tmux for #1738 liveness smoke. Honors only display-message #{pane_pid}.'
  printf '%s\n' 'want_session=""'
  printf '%s\n' 'while [[ $# -gt 0 ]]; do'
  printf '%s\n' '  case "$1" in'
  printf '%s\n' '    -t) want_session="$2"; shift 2 ;;'
  printf '%s\n' '    *) shift ;;'
  printf '%s\n' '  esac'
  printf '%s\n' 'done'
  printf '%s\n' 'if [[ "$want_session" == "'"$SESSION_LIVE"'" && -n "${FAKE_LIVE_PID:-}" ]]; then'
  printf '%s\n' '  printf "%s\\n" "$FAKE_LIVE_PID"; exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'exit 1'
} >"$FAKE_TMUX"
chmod 0755 "$FAKE_TMUX"
# The override is ONLY honored under the explicit test sentinel — in normal
# operation bridge-config.py resolves tmux from fixed absolute paths only, so an
# agent cannot point the liveness probe at a lying stub via env.
export BRIDGE_CONFIG_ALLOW_TEST_TMUX="1"
export BRIDGE_CONFIG_TMUX_BIN="$FAKE_TMUX"
# Default: the live session resolves to THIS shell's pid (the bound pane_pid).
export FAKE_LIVE_PID="$$"

# --- binding helpers --------------------------------------------------------

# Publish a binding for $1=agent $2=admin with pane_pid == THIS smoke shell ($$)
# so the wrapper subprocess (a descendant of this shell) matches it on ancestry.
# session defaults to the live session ($3, default SESSION_LIVE) so the
# match-time liveness check (BLOCKER 2) passes for the positive cases; pass a
# different session to seed a stale (dead-session) binding.
seed_binding() {
  local agent="$1" admin="$2" session="${3:-$SESSION_LIVE}"
  printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":%s,"engine":"claude","updated_at":"now"}\n' \
    "$agent" "$admin" "$session" "$$" >"$BINDINGS_DIR/$agent.json"
}

clear_bindings() {
  # Restore writability first: a prior store_make_nonwritable may have dropped
  # the dir/file write bits, which would otherwise block the rm.
  chmod 0755 "$BINDINGS_DIR" 2>/dev/null || true
  chmod 0644 "$BINDINGS_DIR"/*.json 2>/dev/null || true
  rm -f "$BINDINGS_DIR"/*.json 2>/dev/null || true
}

# --- store-writability toggle (#1738 r2 BLOCKER 1, Option 1) -----------------
#
# Option 1 fails closed when the bindings store is writable by the caller (a
# shared-UID install: the agent owns the store and could forge a record). The
# smoke's BRIDGE_STATE_DIR is caller-writable by construction (single UID), so
# the DEFAULT here IS the shared-UID/forgeable shape. To exercise the legit iso
# positive path (controller-owned, non-writable store) we drop the caller's
# write bit on the dir + each record (os.access(W_OK) then returns False for the
# owner, just as an iso agent UID cannot write the controller's 0711/0644 store).
store_make_nonwritable() {
  chmod 0555 "$BINDINGS_DIR" 2>/dev/null || true
  chmod 0444 "$BINDINGS_DIR"/*.json 2>/dev/null || true
}
store_make_writable() {
  chmod 0755 "$BINDINGS_DIR" 2>/dev/null || true
  chmod 0644 "$BINDINGS_DIR"/*.json 2>/dev/null || true
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

# --- wrapper plumbing -------------------------------------------------------

# Run the wrapper verbatim from argv ($@), capturing rc + stdout/stderr. Caller
# controls the env (so we can drive the env-spoof shapes explicitly).
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
# SECTION 3 — WRAPPER: matching ADMIN binding (non-writable store) -> WRITE.
#
# This is the legit iso admin-agent path: process ancestry matches the
# controller binding, the bound session is LIVE (the tmux stub resolves it to
# the bound pane_pid), and the store is NOT writable by the caller (controller-
# owned on iso) so Option 1 trusts it. NO TTY and NO trusted BRIDGE_CALLER_SOURCE.
# ===========================================================================

clear_bindings
seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"
store_make_nonwritable

: >"$BRIDGE_AUDIT_LOG"
BEFORE_JSON="$(sha_of "$PROTECTED_JSON")"
rc="$(run_wrapper_raw set --path "$PROTECTED_JSON" --change "groups.append=12345" --from "$ADMIN_AGENT")"
smoke_assert_eq "0" "$rc" "set: admin-binding apply rc"
AFTER_JSON="$(sha_of "$PROTECTED_JSON")"
[[ "$BEFORE_JSON" != "$AFTER_JSON" ]] || smoke_fail "set: admin-binding did not change the JSON"
smoke_assert_contains "$(cat "$PROTECTED_JSON")" "12345" "set: admin-binding wrote value"
smoke_log "ok: set admin-binding -> WROTE protected JSON"

rc="$(run_wrapper_raw set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT")"
smoke_assert_eq "0" "$rc" "set-env: admin-binding apply rc"
smoke_assert_file_exists "$ENV_FILE" "set-env: admin-binding wrote managed file"
smoke_assert_contains "$(cat "$ENV_FILE")" \
  "export BRIDGE_A2A_RECONCILE_INTERVAL='60'" "set-env: admin-binding export line"
smoke_log "ok: set-env admin-binding -> WROTE managed env file"

# Audit rows carry before+after hashes for an apply (forensic anchor intact).
AUDIT="$(cat "$BRIDGE_AUDIT_LOG")"
smoke_assert_contains "$AUDIT" '"before_sha256"' "admin-binding: audit before hash"
smoke_assert_contains "$AUDIT" '"after_sha256"' "admin-binding: audit after hash"

# --from that DISAGREES with the binding is an identity spoof -> deny.
clear_bindings
seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"
assert_wrapper_deny_unchanged \
  "set: --from mismatch vs binding" "$PROTECTED_JSON" \
  set --path "$PROTECTED_JSON" --change "spoof=5" --from "$USER_AGENT"

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
#     braces. Drive the bash-expanded argv straight at the wrapper (with an
#     admin binding seeded) and assert it does NOT write the managed file.
clear_bindings
seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"
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

# Assert a wrapper invocation DENIES (rc!=0, target unchanged) AND the deny
# stderr carries a specific reason substring (the r2 fail-closed reasons).
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

# ===========================================================================
# SECTION 6 — WRAPPER: #1738 r2 BLOCKER 1 (Option 1 store-writability gate).
#
# TEETH: round 1 authorizes a forged admin binding on a self-writable
# (shared-UID) store. r2 fails closed there and ONLY trusts the binding when the
# store is NOT writable by the caller (iso, controller-owned). This proves the
# gate keys on writability, not a blanket disable.
# ===========================================================================

# 6a. Forgery on a WRITABLE store: the smoke's bindings dir is caller-writable
#     by construction (single UID = shared-UID), exactly the forgeable shape. A
#     "forged" admin binding (agent_id==admin, pane_pid==our ancestor, live
#     session) now DENIES with the store-writable reason. (r1: this WRITES.)
clear_bindings
seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"   # writable store (default)
store_make_writable
assert_wrapper_deny_reason \
  "set: forged admin binding on writable store" "$PROTECTED_JSON" \
  "agent-binding-store-writable" \
  set --path "$PROTECTED_JSON" --change "forge=1" --from "$ADMIN_AGENT"
assert_wrapper_deny_reason \
  "set-env: forged admin binding on writable store" "$ENV_FILE" \
  "agent-binding-store-writable" \
  set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT"

# 6b. SAME binding, store made NON-writable (controller-owned / iso shape):
#     the binding is now trusted and WRITES. This is the positive control that
#     proves 6a is the writability gate, not a blanket agent-binding disable.
clear_bindings
seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"
store_make_nonwritable
rm -f "$ENV_FILE"
rc="$(run_wrapper_raw set-env "BRIDGE_A2A_RECONCILE_INTERVAL=60" --from "$ADMIN_AGENT")"
smoke_assert_eq "0" "$rc" "set-env: non-writable store admin-binding apply rc"
smoke_assert_file_exists "$ENV_FILE" "set-env: non-writable store wrote managed file"
smoke_log "ok: non-writable-store admin binding -> WROTE (gate keys on writability)"

# ===========================================================================
# SECTION 7 — WRAPPER: #1738 r2 BLOCKER 2 (match-time liveness / PID-reuse).
#
# TEETH: round 1 authorizes a binding purely on `pane_pid in ancestry`, never
# checking pane liveness, so an orphan binding whose pane is dead (its pid later
# reused) still matches. r2 re-resolves the live #{pane_pid} of the recorded
# session and denies on a dead session / pid mismatch.
# ===========================================================================

# 7a. Stale binding: bound to a session the tmux stub reports as GONE (any
#     session != SESSION_LIVE exits 1). pane_pid is still in ancestry ($$), so
#     r1 would authorize; r2 denies because the session no longer resolves to
#     the bound pane_pid. Store made non-writable so the ONLY thing under test
#     is liveness (the writability gate would otherwise also deny).
clear_bindings
seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT" "sess-dead"
store_make_nonwritable
assert_wrapper_deny_unchanged \
  "set: stale binding (dead session) denies despite ancestry" "$PROTECTED_JSON" \
  set --path "$PROTECTED_JSON" --change "stale=1" --from "$ADMIN_AGENT"

# 7b. PID-reuse: live session, but the live pane_pid now resolves to a DIFFERENT
#     pid than the bound one (the pane exited and a new process took the pid).
#     The bound pane_pid is still in ancestry ($$); r2 denies on the mismatch.
clear_bindings
seed_binding "$ADMIN_AGENT" "$ADMIN_AGENT"   # session=SESSION_LIVE, pane_pid=$$
store_make_nonwritable
FAKE_LIVE_PID="999999" \
  assert_wrapper_deny_unchanged \
    "set: pid-reuse (live pane_pid != bound) denies" "$PROTECTED_JSON" \
    set --path "$PROTECTED_JSON" --change "reuse=1" --from "$ADMIN_AGENT"

# Restore a clean, writable, empty store before exit so temp-root cleanup and
# any later harness step is unobstructed.
clear_bindings

smoke_log "PASS: all #1738 config-caller-binding wrapper + hook cases held"
