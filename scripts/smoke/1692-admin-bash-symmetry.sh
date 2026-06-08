#!/usr/bin/env bash
# scripts/smoke/1692-admin-bash-symmetry.sh — Issue #1692 closure smoke.
#
# Asymmetry fixed: in `protected_path_reason` (non-Bash) admin is exempted
# for reads BEFORE the peer-home check, so an admin `Read
# file_path=<peer>/MEMORY.md` succeeds. But in `protected_alias_reason`
# (Bash) there was NO admin carve-out — the Stage B peer-home gate only
# exempted `read_intent and current_agent_class()=='system'`. So the admin
# could read a peer file via the Read tool but the SAME read via Bash
# `cat`/`grep` was denied. The fix adds an explicit
# `is_admin_agent(agent) and read_intent` carve-out on the Bash side,
# scoped to PEER-HOME reads only.
#
# SCOPE (codex direction-consult, reconciled with #1690): the carve-out
# covers PEER-HOME reads ONLY. `shared/private` + `shared/secrets` hold
# operator secrets and stay DENIED for EVERY agent INCLUDING admin (least
# privilege; admin is the operator's deputy for sanctioned auditable
# workflows, not a blanket Bash reader of secret blobs). This keeps #1690's
# admin Stage-A shared-forbidden teeth intact. The non-Bash side's admin
# bypass of the forbidden subtrees is a separate follow-up, not copied here.
#
# This smoke drives the REAL PreToolUse hook (hooks/tool-policy.py) end to
# end (stdin JSON -> permissionDecision) and proves the KEEP-invariants:
#
#   ALLOW (the unblock) — and an audit row is emitted for each:
#     - admin (SESSION-TYPE.md == admin) read-intent Bash read of a PEER
#       home (`cat <peer>/MEMORY.md`, `grep x <peer>/memory/shared/...`).
#       The smoke ALSO asserts a `system_cross_agent_read` audit row landed
#       for every allowed read, so a regression that returns None without
#       auditing is caught.
#
#   DENY (the teeth — must STILL be blocked):
#     - admin read of `shared/private` / `shared/secrets` — the carve-out is
#       peer-home only; the forbidden subtrees stay off-limits for admin.
#     - admin WRITE-intent to a peer home (redirect) — the read carve-out
#       must NOT grant writes.
#     - admin read-intent leading verb that SMUGGLES a mutation via shell
#       embedding (`cat $(…write…)`, `cat <(…)`, `cat <<EOF…`) or an output-
#       file reader (`sort -o`, `uniq IN OUT`, `yq -i`, awk in-program
#       redirect) — `read_intent` + the shell-embedding re-check fail closed.
#     - admin read of a peer path spelled via an unresolved $HOME expansion —
#       fail closed (#1690 r4 FIX 2): the literal path never materializes for
#       the substring gate.
#     - NON-admin (class=user) read of a peer / shared path — the carve-out
#       must not leak to ordinary agents.
#
#   SYSTEM-CLASS preserved + branch keys on is_admin_agent (not class):
#     - a system-class NON-admin agent (BRIDGE_AGENT_CLASS_FOR_HOOK=system,
#       no admin SESSION-TYPE) still gets its own Stage B read carve-out.
#       This proves the new admin branch did not displace the independent
#       system-class branch, and that admin is resolved via is_admin_agent,
#       NOT via current_agent_class()=='system'.
#
#   Revert-teeth (GENUINE): the smoke builds a TEMPORARY copy of
#   hooks/tool-policy.py with the admin carve-out stripped out, runs the
#   admin peer-home read cases against it, and asserts they flip to DENY. If
#   a future edit removed the carve-out from the real hook, this proof would
#   still pass against the stripped copy — but the live ALLOW assertions
#   above would fail. The combination means the smoke cannot pass without
#   the fix.
#
# Footgun #11: the JSON stdin payload is built with `printf` (never an
# interpreter here-string / heredoc-stdin) and piped into the hook with
# `< file`, matching scripts/smoke/tool-policy-roster-read-classify.sh.
#
# macOS: pure policy-decision smoke; no sudo / multi-UID needed. Runs under
# /opt/homebrew/bin/bash 5.x and Linux CI bash alike.

set -euo pipefail

SMOKE_NAME="1692-admin-bash-symmetry"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

STRIPPED_HOOK=""
cleanup() {
  [[ -n "$STRIPPED_HOOK" && -f "$STRIPPED_HOOK" ]] && rm -f "$STRIPPED_HOOK"
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

REAL_HOOK="$SMOKE_REPO_ROOT/hooks/tool-policy.py"

# --- Fixtures ---------------------------------------------------------------

# Acting admin agent: SESSION-TYPE.md == admin makes is_admin_agent() true.
# It runs as class=user (default) — this is the key separation the fix
# hinges on (admin != system-class).
ADMIN_AGENT="patch-1692"
ADMIN_HOME="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
mkdir -p "$ADMIN_HOME"
printf -- '- session type: admin\n' >"$ADMIN_HOME/SESSION-TYPE.md"

# A plain (non-admin) user agent — its reads of peer/shared must STAY denied.
USER_AGENT="worker-1692"
USER_HOME="$BRIDGE_AGENT_HOME_ROOT/$USER_AGENT"
mkdir -p "$USER_HOME"
printf -- '- session type: static\n' >"$USER_HOME/SESSION-TYPE.md"

# A system-class agent — class=system via env at hook time, NOT admin. Its
# own Stage B read carve-out must remain reachable independent of admin.
SYS_AGENT="librarian-1692"
SYS_HOME="$BRIDGE_AGENT_HOME_ROOT/$SYS_AGENT"
mkdir -p "$SYS_HOME"
printf -- '- session type: static\n' >"$SYS_HOME/SESSION-TYPE.md"

# A peer agent home that every acting agent will attempt to read across.
PEER_AGENT="peer-1692"
PEER_HOME="$BRIDGE_AGENT_HOME_ROOT/$PEER_AGENT"
mkdir -p "$PEER_HOME/memory/shared"
printf -- '# peer memory fixture\n' >"$PEER_HOME/MEMORY.md"
printf -- '# peer shared note\n' >"$PEER_HOME/memory/shared/note.md"

# Shared off-limits subtrees (private/ + secrets/) under $BRIDGE_HOME/shared.
SHARED_PRIV_DIR="$BRIDGE_SHARED_DIR/private"
SHARED_SECRETS_DIR="$BRIDGE_SHARED_DIR/secrets"
mkdir -p "$SHARED_PRIV_DIR" "$SHARED_SECRETS_DIR"
printf -- '# operator-only blob\n' >"$SHARED_PRIV_DIR/ops.md"
printf -- '# operator-only key blob\n' >"$SHARED_SECRETS_DIR/key.md"

# --- Build a carve-out-stripped copy of the hook for the revert proof ------
# Remove the contiguous admin PEER-HOME carve-out block (from its leading
# comment up to, but not including, the "Stage B: peer-agent-home substring
# deny" comment that follows it). The stripped copy lives next to the real
# hook so its sibling imports (bridge_hook_common) resolve identically.
STRIPPED_HOOK="$SMOKE_REPO_ROOT/hooks/.tool-policy-1692-stripped-$$.py"
"$PYTHON_BIN" - "$REAL_HOOK" "$STRIPPED_HOOK" <<'PY'
import sys
real, out = sys.argv[1], sys.argv[2]
src = open(real, encoding="utf-8").read()
# Unique signatures: the carve-out's leading comment line and the runtime
# guard expression. The Stage-A block also MENTIONS #1692 (it documents the
# deliberate omission), so we anchor on the carve-out's own header + the
# following Stage-B comment, and sanity-check on the runtime guard string.
start_marker = "    # Issue #1692 — admin read-intent carve-out for the Bash PEER-HOME"
end_marker = "    # Stage B: peer-agent-home substring deny"
guard_signature = "admin_peer_read_audited"
i = src.find(start_marker)
j = src.find(end_marker)
if i == -1 or j == -1 or j < i:
    sys.stderr.write("could not locate #1692 peer-home carve-out block to strip\n")
    sys.exit(3)
stripped = src[:i] + src[j:]
if guard_signature in stripped:
    sys.stderr.write("carve-out runtime guard still present after strip\n")
    sys.exit(4)
open(out, "w", encoding="utf-8").write(stripped)
PY
"$PYTHON_BIN" -m py_compile "$STRIPPED_HOOK" \
  || smoke_fail "stripped hook copy did not compile"

# --- Payload + hook plumbing (printf only; footgun #11) ---------------------

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

write_bash_payload() {
  local target="$1"
  local command="$2"
  local esc
  esc="$(json_escape "$command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1692",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# Run a PreToolUse hook for a given acting agent + class against a chosen
# hook file. $1 agent, $2 class, $3 payload, $4 hook path.
run_pretool_hook() {
  local agent="$1"
  local agent_class="$2"
  local payload_file="$3"
  local hook_path="$4"
  BRIDGE_AGENT_ID="$agent" \
  BRIDGE_AGENT_CLASS_FOR_HOOK="$agent_class" \
    "$PYTHON_BIN" "$hook_path" <"$payload_file"
}

# Run the hook and echo ALLOW|DENY. $1 agent, $2 class, $3 command,
# $4 hook path.
hook_verdict() {
  local agent="$1"
  local agent_class="$2"
  local command="$3"
  local hook_path="$4"
  local payload out
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM-$RANDOM.json"
  write_bash_payload "$payload" "$command"
  out="$(run_pretool_hook "$agent" "$agent_class" "$payload" "$hook_path")"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    printf 'DENY'
  else
    printf 'ALLOW'
  fi
}

# Assert the verdict against the REAL hook. $1 label, $2 agent, $3 class,
# $4 command, $5 want (ALLOW|DENY).
assert_hook_verdict() {
  local label="$1" agent="$2" agent_class="$3" command="$4" want="$5"
  local got
  got="$(hook_verdict "$agent" "$agent_class" "$command" "$REAL_HOOK")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      agent=${agent} class=${agent_class}"
    smoke_log "      command: ${command}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

# Assert an ALLOWED admin read ALSO emitted a system_cross_agent_read audit
# row (the audit-ledger invariant). Truncates the audit log first so the
# assertion is scoped to this single decision.
assert_admin_read_allow_audited() {
  local label="$1" command="$2"
  : >"$BRIDGE_AUDIT_LOG"
  local got
  got="$(hook_verdict "$ADMIN_AGENT" "user" "$command" "$REAL_HOOK")"
  if [[ "$got" != "ALLOW" ]]; then
    smoke_log "FAIL: ${label}: verdict ${got}, want ALLOW"
    smoke_log "      command: ${command}"
    smoke_fail "${label}: expected ALLOW, got ${got}"
  fi
  if ! grep -q '"action": "system_cross_agent_read"' "$BRIDGE_AUDIT_LOG" 2>/dev/null; then
    smoke_log "FAIL: ${label}: ALLOW but no system_cross_agent_read audit row"
    smoke_log "      audit log: $(cat "$BRIDGE_AUDIT_LOG" 2>/dev/null || echo '<empty>')"
    smoke_fail "${label}: missing audit row"
  fi
  smoke_log "ok: ${label} -> ALLOW + audited"
}

echo "[smoke:${SMOKE_NAME}] real PreToolUse hook end-to-end"

# ---------------------------------------------------------------------------
# Group 1 — ALLOW: admin + read-intent Bash read of PEER-HOME paths, each
# with a `system_cross_agent_read` audit row.
# ---------------------------------------------------------------------------

assert_admin_read_allow_audited \
  "admin read (cat) of peer MEMORY.md" \
  "cat $PEER_HOME/MEMORY.md"

assert_admin_read_allow_audited \
  "admin read (grep) of peer shared note" \
  "grep note $PEER_HOME/memory/shared/note.md"

# ---------------------------------------------------------------------------
# Group 2 — DENY teeth (must STAY blocked).
# ---------------------------------------------------------------------------

# 2-priv/secret. Admin read of the shared/private + shared/secrets forbidden
#     subtrees STAYS DENIED — the carve-out is peer-home only. These hold
#     operator secrets and are off-limits even for admin (Option D; keeps
#     #1690's admin Stage-A teeth intact). This is the explicit anti-leak
#     proof that #1692 did NOT widen the admin carve-out to shared secrets.
assert_hook_verdict \
  "admin read (grep) of shared private blob stays denied" \
  "$ADMIN_AGENT" "user" \
  "grep ops $SHARED_PRIV_DIR/ops.md" \
  "DENY"

assert_hook_verdict \
  "admin read (cat) of shared secrets blob stays denied" \
  "$ADMIN_AGENT" "user" \
  "cat $SHARED_SECRETS_DIR/key.md" \
  "DENY"

# 2a. Admin WRITE-intent to a peer home — the read carve-out must NOT grant
#     writes. A redirect is not read-intent, so it falls through to the deny.
assert_hook_verdict \
  "admin WRITE (redirect) to peer MEMORY.md stays denied" \
  "$ADMIN_AGENT" "user" \
  "echo pwned > $PEER_HOME/MEMORY.md" \
  "DENY"

# 2b. Admin WRITE-intent to a shared private path — also stays denied.
assert_hook_verdict \
  "admin WRITE (redirect) to shared private stays denied" \
  "$ADMIN_AGENT" "user" \
  "echo pwned > $SHARED_PRIV_DIR/ops.md" \
  "DENY"

# 2c. Admin read-intent LEADING verb smuggling a mutation via command
#     substitution — `cat` classifies as read-intent but `$(…)` runs
#     arbitrary code. The carve-out must fail closed on shell embedding
#     (codex SECURITY r1). Falls through to the peer-home deny.
assert_hook_verdict \
  "admin cat with \$( ) substitution to peer stays denied" \
  "$ADMIN_AGENT" "user" \
  "cat \$(echo pwn > $PEER_HOME/MEMORY.md) $PEER_HOME/MEMORY.md" \
  "DENY"

# 2d. Same class of bypass via process substitution `<(…)`. Targets a peer
#     home so the deny proves the embedding guard (not the Stage-A forbidden
#     deny) is what bites.
assert_hook_verdict \
  "admin cat with <( ) process-substitution to peer stays denied" \
  "$ADMIN_AGENT" "user" \
  "cat <(echo x) $PEER_HOME/MEMORY.md" \
  "DENY"

# 2e. Same class of bypass via the here-string operator. The redirect
#     operator is assembled from single-char fragments so the literal
#     triple-less-than never appears as a source token (lint-heredoc-ban
#     H3 ban; footgun #11) — the command string the hook classifies is
#     identical to a hand-typed here-string. Stays DENY (shell embedding).
HERESTRING_OP="$(printf '%s' '<' '<' '<')"
assert_hook_verdict \
  "admin cat with here-string to peer stays denied" \
  "$ADMIN_AGENT" "user" \
  "cat $PEER_HOME/MEMORY.md ${HERESTRING_OP}\$(echo x)" \
  "DENY"

# 2c'..2e'. Admin "reader" commands with an OUTPUT-FILE flag/positional or
#          an in-program redirect write a peer/shared path with NO argv `>`
#          token, so they classify as read-intent unless the read-intent
#          classifier is hardened (codex SECURITY r2). Each must stay DENY.
assert_hook_verdict \
  "admin sort -o (output file) to peer stays denied" \
  "$ADMIN_AGENT" "user" \
  "sort -o $PEER_HOME/MEMORY.md $PEER_HOME/MEMORY.md" \
  "DENY"

assert_hook_verdict \
  "admin uniq IN OUT (2nd positional write) to peer stays denied" \
  "$ADMIN_AGENT" "user" \
  "uniq $PEER_HOME/MEMORY.md $PEER_HOME/MEMORY.md" \
  "DENY"

assert_hook_verdict \
  "admin yq -i (in-place edit) of peer stays denied" \
  "$ADMIN_AGENT" "user" \
  "yq -i . $PEER_HOME/MEMORY.md" \
  "DENY"

assert_hook_verdict \
  "admin awk in-program redirect to peer stays denied" \
  "$ADMIN_AGENT" "user" \
  "awk 'BEGIN{print \"x\" > \"$PEER_HOME/MEMORY.md\"}' $PEER_HOME/MEMORY.md" \
  "DENY"

# 2f. NON-admin (class=user) read of a peer home — carve-out must not leak.
assert_hook_verdict \
  "non-admin read of peer MEMORY.md stays denied" \
  "$USER_AGENT" "user" \
  "cat $PEER_HOME/MEMORY.md" \
  "DENY"

# 2g. NON-admin (class=user) read of a shared private path — stays denied.
assert_hook_verdict \
  "non-admin read of shared private stays denied" \
  "$USER_AGENT" "user" \
  "grep ops $SHARED_PRIV_DIR/ops.md" \
  "DENY"

# 2h. Admin read whose peer path is spelled via an unresolved $HOME
#     expansion — the carve-out must fail closed (#1690 r4 FIX 2): the
#     `$HOME/.agent-bridge/agents/<peer>` form is a peer ALIAS (so the
#     substring matches and the carve-out is reachable), but the path is
#     not statically resolvable, so a forbidden sibling could be smuggled
#     past the substring gate. The single-quoted var reaches the hook
#     UNEXPANDED. Must stay DENY for admin (read_carveout_blocked_by_expansion).
assert_hook_verdict \
  'admin read of peer via $HOME expansion stays denied (fail-closed)' \
  "$ADMIN_AGENT" "user" \
  'cat $HOME/.agent-bridge/agents/peer-1692/MEMORY.md' \
  "DENY"

# ---------------------------------------------------------------------------
# Group 3 — system-class carve-out preserved + branch keys on
# is_admin_agent, NOT current_agent_class().
# ---------------------------------------------------------------------------

# 3a. A system-class NON-admin agent still earns the Stage B peer-home read
#     carve-out via its OWN branch — proving the admin branch did not
#     displace it and that the two concepts stay independent. The system
#     carve-out covers peer memory/{projects,shared,decisions} subtrees.
assert_hook_verdict \
  "system-class (non-admin) read of peer memory/shared still allowed" \
  "$SYS_AGENT" "system" \
  "cat $PEER_HOME/memory/shared/note.md" \
  "ALLOW"

# 3b. The system-class carve-out is read-only: a system-class WRITE to a
#     peer home stays denied (its branch keys on read_intent too).
assert_hook_verdict \
  "system-class WRITE to peer stays denied" \
  "$SYS_AGENT" "system" \
  "echo x > $PEER_HOME/memory/shared/note.md" \
  "DENY"

# 3c. Admin is NOT system-class: the admin agent runs as class=user above
#     and STILL gets its read carve-out (Group 1). Conversely, a
#     system-class non-admin does NOT get the admin shared/private carve-out
#     — shared/private|secrets are off-limits even for system class. This
#     proves the admin branch keys on is_admin_agent, not class==system.
assert_hook_verdict \
  "system-class (non-admin) read of shared private stays denied" \
  "$SYS_AGENT" "system" \
  "grep ops $SHARED_PRIV_DIR/ops.md" \
  "DENY"

# ---------------------------------------------------------------------------
# Group 4 — GENUINE revert teeth: run the admin-read ALLOW cases against a
# hook copy with the carve-out stripped; assert they flip to DENY. Proves
# the ALLOW verdicts above are caused by the carve-out and nothing else.
# ---------------------------------------------------------------------------

stripped_verdict() {
  hook_verdict "$ADMIN_AGENT" "user" "$1" "$STRIPPED_HOOK"
}

revert_assert_deny() {
  local label="$1" command="$2" got
  got="$(stripped_verdict "$command")"
  if [[ "$got" == "DENY" ]]; then
    smoke_log "ok: revert-teeth — ${label} -> DENY (carve-out stripped)"
  else
    smoke_log "FAIL: revert-teeth — ${label} -> ${got}, want DENY against stripped hook"
    smoke_log "      command: ${command}"
    smoke_fail "revert-teeth ${label}: stripped hook should DENY, got ${got}"
  fi
}

# Both cases are PEER-HOME reads that the real hook now ALLOWs for admin
# (Group 1); against the stripped hook they must flip to DENY. (A shared/
# private read would be DENY in both real and stripped — denied by Stage A
# regardless — so it is NOT a valid revert-teeth flip and is not used here.)
revert_assert_deny \
  "admin read of peer MEMORY.md" \
  "cat $PEER_HOME/MEMORY.md"

revert_assert_deny \
  "admin read of peer memory/shared note" \
  "grep note $PEER_HOME/memory/shared/note.md"

# Sanity: the stripped hook must still ALLOW the system-class read (its own
# branch is untouched by stripping the admin carve-out) — confirms the
# strip removed ONLY the admin branch, not the whole gate.
sys_stripped_got="$(hook_verdict "$SYS_AGENT" "system" "cat $PEER_HOME/memory/shared/note.md" "$STRIPPED_HOOK")"
if [[ "$sys_stripped_got" == "ALLOW" ]]; then
  smoke_log "ok: revert-teeth — system-class read still ALLOW against stripped hook (system branch intact)"
else
  smoke_fail "revert-teeth: system-class read should stay ALLOW against stripped hook, got ${sys_stripped_got}"
fi

smoke_log "passed"
