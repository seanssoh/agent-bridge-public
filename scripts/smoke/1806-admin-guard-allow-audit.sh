#!/usr/bin/env bash
# scripts/smoke/1806-admin-guard-allow-audit.sh — Issue #1806 (+ #1711) closure.
#
# Operator policy (2026-06-12): "patch is admin; the guard must not block
# admin." The Bash tool-policy gate now ALLOWS+AUDITS, for a STRICT trusted
# admin only, four operations it used to deny, while every hard invariant
# (shared/private + shared/secrets denied for everyone incl admin; #341
# protected-config write routing) stays in force.
#
# This smoke drives the REAL PreToolUse hook (hooks/tool-policy.py) end to end
# and proves all 8 codex security teeth:
#
#   Tooth 1 — spoofed SESSION-TYPE.md alone → treated as NON-admin. An agent
#     that writes "session type: admin" into its own home (and even exports
#     BRIDGE_ADMIN_AGENT_ID=<self>) is NOT trusted-admin because the
#     controller-published roster (`agent list --json`, here a fixture)
#     disagrees. Its peer-write stays DENIED.
#   Tooth 2 — env/roster mismatch → NON-admin, fail-closed (env names a
#     non-admin agent; roster admin=False).
#   Tooth 3 — admin Bash read AND non-Bash Read of shared/private +
#     shared/secrets → DENIED on both surfaces (#1711 harmonization).
#   Tooth 4 — non-admin 3a/3b/3c/3e → still DENIED.
#   Tooth 5 — trusted-admin 3a/3b/3c/3e allowed cases each emit the expected
#     audit row (admin_cross_agent_write / system_cross_agent_read /
#     admin_sqlite3_task_db).
#   Tooth 6 — shared/secrets + protected-config NEGATIVE control for every new
#     admin allowance (mv into shared/secrets DENIED; mkdir into shared/private
#     DENIED; sqlite3 with a forbidden sibling DENIED).
#   Tooth 7 — symlink / `..` escape: an admin peer-write whose resolved target
#     escapes the peer home / bridge home into a denied tree → DENIED.
#   Tooth 8 — tilde / glob / sqlite3 sibling attempts → DENIED when containment
#     is unprovable (glob over secrets, tilde + forbidden sibling, sqlite3
#     against a non-task-db path).
#
# The strict admin predicate (`is_trusted_admin_agent_for_guard`) reads the
# controller roster via `agent list --json`. The smoke injects a deterministic
# controller-roster snapshot through BRIDGE_GUARD_ADMIN_ROSTER_JSON (the read-
# only test seam) so the predicate's env+roster-agreement is exercised without
# a live bridge.
#
# Footgun #11: every JSON stdin payload is built with `printf` and piped via
# `< file`, matching the sibling guard smokes. macOS: pure policy-decision
# smoke; runs under Homebrew bash 5.x and Linux CI bash alike.

set -euo pipefail

SMOKE_NAME="1806-admin-guard-allow-audit"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

REAL_HOOK="$SMOKE_REPO_ROOT/hooks/tool-policy.py"

# --- Fixtures ---------------------------------------------------------------

ADMIN_AGENT="patch-1806"
PEER_AGENT="retired-1806"
SPOOFER_AGENT="spoofer-1806"

ADMIN_HOME="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
PEER_HOME="$BRIDGE_AGENT_HOME_ROOT/$PEER_AGENT"
SPOOFER_HOME="$BRIDGE_AGENT_HOME_ROOT/$SPOOFER_AGENT"
mkdir -p "$ADMIN_HOME" "$PEER_HOME/logs" "$PEER_HOME/memory/shared" "$SPOOFER_HOME"
printf -- '- session type: admin\n' >"$ADMIN_HOME/SESSION-TYPE.md"
printf -- '- session type: static\n' >"$PEER_HOME/SESSION-TYPE.md"
printf -- '# peer memory\n' >"$PEER_HOME/MEMORY.md"
# The spoofer writes its OWN SESSION-TYPE.md claiming admin (Tooth 1).
printf -- '- session type: admin\n' >"$SPOOFER_HOME/SESSION-TYPE.md"

# A backups/ quarantine destination (the #1803 case-1 shape) and a core lib
# dir the admin triages.
mkdir -p "$BRIDGE_HOME/backups" "$BRIDGE_HOME/lib" "$BRIDGE_HOME/state"
printf -- 'x\n' >"$BRIDGE_HOME/lib/bridge-core.sh"
: >"$BRIDGE_HOME/state/tasks.db"
: >"$BRIDGE_HOME/agent-roster.local.sh"

# Forbidden trees: shared/private + shared/secrets.
mkdir -p "$BRIDGE_SHARED_DIR/private" "$BRIDGE_SHARED_DIR/secrets"
printf -- '# ops-only\n' >"$BRIDGE_SHARED_DIR/private/ops.md"
printf -- '# key blob\n' >"$BRIDGE_SHARED_DIR/secrets/key.md"

# A #341 protected-config path (hooks settings).
mkdir -p "$BRIDGE_HOME/hooks"
printf -- '{}\n' >"$BRIDGE_HOME/hooks/settings.json"

# Symlink escapes inside the peer home (Tooth 7): one that points OUT of the
# bridge home, one that points INTO shared/secrets.
OUTSIDE_DIR="$SMOKE_TMP_ROOT/OUTSIDE"
mkdir -p "$OUTSIDE_DIR"
ln -snf "$OUTSIDE_DIR" "$PEER_HOME/out-link"
ln -snf "$BRIDGE_SHARED_DIR/secrets" "$PEER_HOME/secrets-link"

# Make the `~/.agent-bridge/...` tilde spelling resolve onto THIS smoke's
# bridge home (over-block #2 is specifically the `~` spelling). The hook's
# `_expand_bridge_prefixes` expands `~` to $HOME, so we point a fake $HOME at a
# dir whose `.agent-bridge` symlinks to BRIDGE_HOME; Path.resolve() then folds
# the link back to the real bridge home for the containment proof.
FAKE_HOME="$SMOKE_TMP_ROOT/fakehome"
mkdir -p "$FAKE_HOME"
ln -snf "$BRIDGE_HOME" "$FAKE_HOME/.agent-bridge"

# Controller-published roster snapshot (the strict-predicate test seam).
# patch-1806 = admin static; the others are non-admin. Note: the spoofer's row
# is admin=False even though its SESSION-TYPE.md says admin — the roster is the
# authority.
ROSTER_JSON="$SMOKE_TMP_ROOT/controller-roster.json"
printf -- '%s\n' \
  '[' \
  "  {\"agent\": \"${ADMIN_AGENT}\", \"admin\": true, \"source\": \"static\"}," \
  "  {\"agent\": \"${PEER_AGENT}\", \"admin\": false, \"source\": \"static\"}," \
  "  {\"agent\": \"${SPOOFER_AGENT}\", \"admin\": false, \"source\": \"dynamic\"}" \
  ']' \
  >"$ROSTER_JSON"

# --- Payload + hook plumbing (printf only; footgun #11) ---------------------

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
    '  "tool_use_id": "smoke-1806",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

write_read_payload() {
  local target="$1" path="$2" esc
  esc="$(json_escape "$path")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Read",' \
    "  \"tool_input\": {\"file_path\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1806",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# Run a PreToolUse hook with a chosen acting-admin env. $1 agent, $2 admin-id
# env (BRIDGE_ADMIN_AGENT_ID), $3 payload file.
run_hook() {
  local agent="$1" admin_id="$2" payload_file="$3"
  HOME="$FAKE_HOME" \
  BRIDGE_AGENT_ID="$agent" \
  BRIDGE_ADMIN_AGENT_ID="$admin_id" \
  BRIDGE_GUARD_ADMIN_ROSTER_JSON="$ROSTER_JSON" \
    "$PYTHON_BIN" "$REAL_HOOK" <"$payload_file"
}

# Bash verdict. $1 agent, $2 admin-id env, $3 command. echoes ALLOW|DENY.
bash_verdict() {
  local agent="$1" admin_id="$2" command="$3" payload out
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM-$RANDOM.json"
  write_bash_payload "$payload" "$command"
  out="$(run_hook "$agent" "$admin_id" "$payload")"
  [[ "$out" == *'"permissionDecision": "deny"'* ]] && printf 'DENY' || printf 'ALLOW'
}

# Read-tool verdict. $1 agent, $2 admin-id env, $3 path.
read_verdict() {
  local agent="$1" admin_id="$2" path="$3" payload out
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM-$RANDOM.json"
  write_read_payload "$payload" "$path"
  out="$(run_hook "$agent" "$admin_id" "$payload")"
  [[ "$out" == *'"permissionDecision": "deny"'* ]] && printf 'DENY' || printf 'ALLOW'
}

assert_bash() {
  local label="$1" agent="$2" admin_id="$3" command="$4" want="$5" got
  got="$(bash_verdict "$agent" "$admin_id" "$command")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      agent=${agent} admin_id=${admin_id}"
    smoke_log "      command: ${command}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

assert_read() {
  local label="$1" agent="$2" admin_id="$3" path="$4" want="$5" got
  got="$(read_verdict "$agent" "$admin_id" "$path")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

# Assert a trusted-admin ALLOW that ALSO emits a specific audit action. Scopes
# the audit log to the single decision by truncating first.
assert_allow_audited() {
  local label="$1" command="$2" want_action="$3" got
  : >"$BRIDGE_AUDIT_LOG"
  got="$(bash_verdict "$ADMIN_AGENT" "$ADMIN_AGENT" "$command")"
  if [[ "$got" != "ALLOW" ]]; then
    smoke_log "FAIL: ${label}: verdict ${got}, want ALLOW"
    smoke_log "      command: ${command}"
    smoke_fail "${label}: expected ALLOW, got ${got}"
  fi
  if ! grep -q "\"action\": \"${want_action}\"" "$BRIDGE_AUDIT_LOG" 2>/dev/null; then
    smoke_log "FAIL: ${label}: ALLOW but no '${want_action}' audit row"
    smoke_log "      audit log: $(cat "$BRIDGE_AUDIT_LOG" 2>/dev/null || echo '<empty>')"
    smoke_fail "${label}: missing audit row '${want_action}'"
  fi
  smoke_log "ok: ${label} -> ALLOW + audited (${want_action})"
}

echo "[smoke:${SMOKE_NAME}] real PreToolUse hook end-to-end"

# ---------------------------------------------------------------------------
# Tooth 1 — spoofed SESSION-TYPE.md (+ self env) is NOT trusted-admin.
# ---------------------------------------------------------------------------
# The spoofer exports BRIDGE_ADMIN_AGENT_ID=<self> AND wrote its own
# SESSION-TYPE.md=admin, but the controller roster says admin=False → strict
# predicate fails closed → its peer-write stays DENIED.
assert_bash \
  "Tooth1 spoofer (self-admin env + spoofed SESSION-TYPE) peer mkdir DENIED" \
  "$SPOOFER_AGENT" "$SPOOFER_AGENT" \
  "mkdir -p $PEER_HOME/workdir" "DENY"

# ---------------------------------------------------------------------------
# Tooth 2 — env/roster mismatch → NON-admin, fail-closed.
# ---------------------------------------------------------------------------
# The peer agent acts with BRIDGE_ADMIN_AGENT_ID=<self> (env says it is admin),
# but the roster says admin=False → not trusted → DENIED.
assert_bash \
  "Tooth2 env=self-admin but roster admin=False peer mkdir DENIED" \
  "$PEER_AGENT" "$PEER_AGENT" \
  "mkdir -p $ADMIN_HOME/workdir" "DENY"

# ---------------------------------------------------------------------------
# Tooth 3 — admin Bash read AND non-Bash Read of shared/private + secrets DENY.
# ---------------------------------------------------------------------------
assert_bash \
  "Tooth3 admin Bash cat shared/secrets DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "cat $BRIDGE_SHARED_DIR/secrets/key.md" "DENY"
assert_bash \
  "Tooth3 admin Bash cat shared/private DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "cat $BRIDGE_SHARED_DIR/private/ops.md" "DENY"
assert_read \
  "Tooth3 admin Read shared/secrets DENIED (#1711)" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "$BRIDGE_SHARED_DIR/secrets/key.md" "DENY"
assert_read \
  "Tooth3 admin Read shared/private DENIED (#1711)" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "$BRIDGE_SHARED_DIR/private/ops.md" "DENY"

# ---------------------------------------------------------------------------
# Tooth 4 — non-admin 3a/3b/3c/3e still DENIED.
# ---------------------------------------------------------------------------
assert_bash "Tooth4 non-admin 3a mv peer->backup DENIED" \
  "$PEER_AGENT" "$ADMIN_AGENT" \
  "mv $ADMIN_HOME/x $BRIDGE_HOME/backups/x" "DENY"
assert_bash "Tooth4 non-admin 3a mkdir peer workdir DENIED" \
  "$PEER_AGENT" "$ADMIN_AGENT" \
  "mkdir -p $ADMIN_HOME/workdir" "DENY"
assert_bash "Tooth4 non-admin 3b ls ~ peer logs DENIED" \
  "$PEER_AGENT" "$ADMIN_AGENT" \
  "ls ~/.agent-bridge/agents/${ADMIN_AGENT}/logs/" "DENY"
assert_bash "Tooth4 non-admin 3e sqlite3 task_db DENIED" \
  "$PEER_AGENT" "$ADMIN_AGENT" \
  "sqlite3 $BRIDGE_HOME/state/tasks.db \"SELECT 1\"" "DENY"

# ---------------------------------------------------------------------------
# Tooth 5 — trusted-admin 3a/3b/3c/3e ALLOWED, each with its audit row.
# ---------------------------------------------------------------------------
# 3a peer-home quarantine WRITE (mv peer -> backups): admin_cross_agent_write.
assert_allow_audited \
  "Tooth5 3a mv peer-home -> backups quarantine" \
  "mv $PEER_HOME $BRIDGE_HOME/backups/${PEER_AGENT}" \
  "admin_cross_agent_write"
# 3a scaffold a peer workdir (mkdir into peer home): admin_cross_agent_write.
assert_allow_audited \
  "Tooth5 3a mkdir peer workdir" \
  "mkdir -p $PEER_HOME/workdir" \
  "admin_cross_agent_write"
# 3b tilde-spelled peer read: system_cross_agent_read.
assert_allow_audited \
  "Tooth5 3b ls ~ peer logs" \
  "ls ~/.agent-bridge/agents/${PEER_AGENT}/logs/" \
  "system_cross_agent_read"
# 3c glob read of a peer home file: system_cross_agent_read.
assert_allow_audited \
  "Tooth5 3c grep glob over peer memory" \
  "grep -n x $PEER_HOME/memory/*" \
  "system_cross_agent_read"
# 3e sqlite3 SELECT on the queue DB: admin_sqlite3_task_db.
assert_allow_audited \
  "Tooth5 3e sqlite3 task_db SELECT" \
  "sqlite3 $BRIDGE_HOME/state/tasks.db \"SELECT * FROM tasks\"" \
  "admin_sqlite3_task_db"

# ---------------------------------------------------------------------------
# Tooth 6 — shared/secrets + protected-config NEGATIVE control per allowance.
# ---------------------------------------------------------------------------
assert_bash "Tooth6 admin mv peer -> shared/secrets DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "mv $PEER_HOME $BRIDGE_SHARED_DIR/secrets/${PEER_AGENT}" "DENY"
assert_bash "Tooth6 admin mkdir into shared/private DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "mkdir -p $BRIDGE_SHARED_DIR/private/x" "DENY"
assert_bash "Tooth6 admin sqlite3 + forbidden secrets sibling DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "sqlite3 $BRIDGE_HOME/state/tasks.db \"SELECT 1\"; cat $BRIDGE_SHARED_DIR/secrets/key.md" "DENY"
# Admin mv whose destination is a #341 protected-config path stays denied (the
# resolved target is a protected-config file).
assert_bash "Tooth6 admin mv into #341 protected-config DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "mv $PEER_HOME/MEMORY.md $BRIDGE_HOME/hooks/settings.json" "DENY"

# ---------------------------------------------------------------------------
# Tooth 7 — symlink / `..` escape from a peer write target → DENIED.
# ---------------------------------------------------------------------------
assert_bash "Tooth7 admin mv via .. escape outside bridge home DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "mv $PEER_HOME $PEER_HOME/../../../../OUTSIDE/x" "DENY"
assert_bash "Tooth7 admin mkdir via symlink escaping bridge home DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "mkdir -p $PEER_HOME/out-link/x" "DENY"
assert_bash "Tooth7 admin mkdir via symlink into shared/secrets DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "mkdir -p $PEER_HOME/secrets-link/x" "DENY"

# ---------------------------------------------------------------------------
# Tooth 8 — tilde / glob / sqlite3 sibling attempts → DENIED.
# ---------------------------------------------------------------------------
assert_bash "Tooth8 admin tilde read + forbidden secrets sibling DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "cat ~/.agent-bridge/agents/${PEER_AGENT}/MEMORY.md $BRIDGE_SHARED_DIR/secrets/key.md" "DENY"
assert_bash "Tooth8 admin glob over shared/secrets DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "cat $BRIDGE_SHARED_DIR/secrets/*" "DENY"
assert_bash "Tooth8 admin sqlite3 against NON-task-db path DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "sqlite3 $PEER_HOME/x.db \"SELECT 1\"" "DENY"
# A sqlite3 with a trailing shell-operator sibling must not ride the carve-out.
assert_bash "Tooth8 admin sqlite3 task_db with ;-sibling write DENIED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "sqlite3 $BRIDGE_HOME/state/tasks.db \"SELECT 1\"; rm -rf $PEER_HOME" "DENY"

# ---------------------------------------------------------------------------
# Keep-invariant: #341 protected-config READ stays allowed for all (only writes
# route through the wrapper) — the #1711 change must not over-deny config reads.
# ---------------------------------------------------------------------------
assert_read \
  "config-read: admin Read hooks/settings.json ALLOWED (read-intent)" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "$BRIDGE_HOME/hooks/settings.json" "ALLOW"

# ---------------------------------------------------------------------------
# Security hardening: the BRIDGE_GUARD_ADMIN_ROSTER_JSON test seam is HONORED
# only under a temp/test bridge home. Prove `_bridge_home_is_test_temp` gates
# it: under a NON-temp bridge home a forged self-admin roster JSON must be
# IGNORED, so an agent cannot grant itself trusted-admin by exporting a forged
# roster path in production (the predicate then consults only the real CLI).
#
# We monkeypatch `bridge_home_dir` to a fixed NON-temp path so the gate logic
# is exercised deterministically without depending on where the temp root
# happens to live (the smoke's own temp root IS under a temp prefix).
# ---------------------------------------------------------------------------
SEAM_PROBE="$SMOKE_TMP_ROOT/seam-probe.py"
FORGED_ROSTER="$SMOKE_TMP_ROOT/forged-roster.json"
printf -- '%s\n' \
  '[' \
  '  {"agent": "attacker", "admin": true, "source": "static"}' \
  ']' \
  >"$FORGED_ROSTER"
cat >"$SEAM_PROBE" <<'PYSEAM'
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_file_location("tp", sys.argv[1])
tp = importlib.util.module_from_spec(spec); sys.modules["tp"] = tp
spec.loader.exec_module(tp)

# 1) Temp home → seam HONORED (the gate returns True for a /tmp-rooted home).
tp.bridge_home_dir = lambda: pathlib.Path("/tmp/agb-seam-temp/.agent-bridge")
assert tp._bridge_home_is_test_temp() is True, "temp home must classify test-temp"

# 2) Non-temp home → seam IGNORED. With a forged roster JSON naming "attacker"
#    as admin static AND env BRIDGE_ADMIN_AGENT_ID=attacker, the predicate must
#    STILL be False because the seam is inert and the real CLI does not know
#    "attacker". This is the production anti-forge proof.
tp.bridge_home_dir = lambda: pathlib.Path("/home/operator/.agent-bridge")
assert tp._bridge_home_is_test_temp() is False, "non-temp home must NOT classify test-temp"
import os
os.environ["BRIDGE_ADMIN_AGENT_ID"] = "attacker"
os.environ["BRIDGE_GUARD_ADMIN_ROSTER_JSON"] = sys.argv[2]
got = tp.is_trusted_admin_agent_for_guard("attacker")
assert got is False, f"forged roster seam must be inert under non-temp home: trusted={got}"
print("[ok] seam honored under temp home, inert under non-temp home (forged roster cannot grant admin)")
PYSEAM
SEAM_OUT="$("$PYTHON_BIN" "$SEAM_PROBE" "$REAL_HOOK" "$FORGED_ROSTER" 2>&1)" \
  || { smoke_log "FAIL: seam-gate probe: $SEAM_OUT"; smoke_fail "seam-inert security check failed"; }
smoke_log "ok: ${SEAM_OUT}"

smoke_log "passed"
echo "[smoke:${SMOKE_NAME}] passed"
