#!/usr/bin/env bash
# scripts/smoke/1823-v2-peer-home-containment.sh — Issue #1823 (SECURITY) closure.
#
# On a v2-layout install (the current default) the tool-policy peer-home
# containment enumerated the LEGACY v1 tree only (`agent_home_root()`), so a
# NON-ADMIN agent could Edit / Write / Bash-append a PEER's v2 home under
# `data/agents/<other>/home/…` with NO denial — the legacy `agents/<other>/`
# tree stayed correctly blocked, which masked the gap. The fix has
# `other_agent_homes()` enumerate BOTH roots (v1 + v2 `<peer>/home`), so the
# documented per-agent containment now covers the homes sessions actually run
# from.
#
# This smoke drives the REAL PreToolUse hook (hooks/tool-policy.py) end to end
# on a v2-layout bridge home (lib.sh sets BRIDGE_DATA_ROOT / BRIDGE_AGENT_ROOT_V2
# to a tree OUTSIDE the bridge home — exactly the layout that exposes the hole).
# It asserts the security teeth and the must-NOT-break invariants:
#
#   Tooth 1 — NON-admin Edit to a peer v2 home `data/agents/<other>/home/…`
#             → DENIED (this is the proof the #1823 hole is closed; it was
#             ALLOWED before the fix).
#   Tooth 2 — NON-admin Bash append (`echo >> …`) to the same v2 peer home
#             → DENIED (the Bash surface of the same hole).
#   Tooth 3 — NON-admin Edit/append to the peer's LEGACY v1 home
#             `agents/<other>/…` → still DENIED (no regression of the v1 path).
#   Tooth 4 — NON-admin Edit to its OWN v2 home → never self-denied (ALLOW).
#   Tooth 5 — NON-admin Edit/Bash to a peer v2 WORKDIR
#             `data/agents/<other>/workdir/…` → ALLOWED. The v2 workdir is
#             SCOPED OUT (the #1492 shared `<admin>-dev` pair-review workspace
#             would be false-denied otherwise — only the cwd is shared; homes
#             stay distinct).
#   Tooth 6 — TRUSTED-ADMIN keeps its #1806 carve-outs: Edit + Read of a peer
#             v2 home → ALLOWED, and a Bash mkdir into a peer v2 home is NOT
#             newly denied by the v2 enumeration (admin behavior unchanged).
#   Tooth 7 — Invariant: shared/private + shared/secrets stay DENIED for the
#             NON-admin on both the Bash and non-Bash surfaces.
#   Tooth 8 — Invariant: admin's OWN v2 home is never self-denied.
#
# The strict admin predicate reads the controller roster via `agent list
# --json`; the smoke injects a deterministic roster snapshot through the
# read-only BRIDGE_GUARD_ADMIN_ROSTER_JSON test seam (honored only under a
# temp/test bridge home).
#
# Footgun #11: every JSON payload is built with `printf` and piped via `< file`.
# macOS: pure policy-decision smoke; runs under Homebrew bash 5.x and Linux CI
# bash alike.

set -euo pipefail

SMOKE_NAME="1823-v2-peer-home-containment"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

REAL_HOOK="$SMOKE_REPO_ROOT/hooks/tool-policy.py"

# --- Fixtures ---------------------------------------------------------------

ADMIN_AGENT="patch-1823"
PEER_AGENT="peer-1823"
ACTOR_AGENT="actor-1823"   # a NON-admin agent acting against the peer

# v2 per-agent trees (the default layout). BRIDGE_AGENT_ROOT_V2 is set by lib.sh
# to "$BRIDGE_DATA_ROOT/agents", which is OUTSIDE the bridge home — the exact
# shape that exposed the hole.
PEER_V2_HOME="$BRIDGE_AGENT_ROOT_V2/$PEER_AGENT/home"
PEER_V2_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$PEER_AGENT/workdir"
ACTOR_V2_HOME="$BRIDGE_AGENT_ROOT_V2/$ACTOR_AGENT/home"
ADMIN_V2_HOME="$BRIDGE_AGENT_ROOT_V2/$ADMIN_AGENT/home"
mkdir -p "$PEER_V2_HOME" "$PEER_V2_WORKDIR" "$ACTOR_V2_HOME" "$ADMIN_V2_HOME"
printf -- '# peer v2 memory\n' >"$PEER_V2_HOME/MEMORY.md"
printf -- '# peer v2 shared workspace\n' >"$PEER_V2_WORKDIR/NOTES.md"

# The peer's LEGACY v1 home (proves the v1 path stays denied; not a regression).
PEER_V1_HOME="$BRIDGE_AGENT_HOME_ROOT/$PEER_AGENT"
mkdir -p "$PEER_V1_HOME"
printf -- '# peer v1 memory\n' >"$PEER_V1_HOME/MEMORY.md"

# SESSION-TYPE.md for the admin (the strict predicate also reads the roster).
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
printf -- '- session type: admin\n' >"$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT/SESSION-TYPE.md"

# Forbidden trees: shared/private + shared/secrets.
mkdir -p "$BRIDGE_SHARED_DIR/private" "$BRIDGE_SHARED_DIR/secrets"
printf -- '# ops-only\n' >"$BRIDGE_SHARED_DIR/private/ops.md"
printf -- '# key blob\n' >"$BRIDGE_SHARED_DIR/secrets/key.md"

# Make the `~/.agent-bridge/...` tilde spelling resolve onto THIS smoke's bridge
# home (the hook's `_expand_bridge_prefixes` expands `~` to $HOME).
FAKE_HOME="$SMOKE_TMP_ROOT/fakehome"
mkdir -p "$FAKE_HOME"
ln -snf "$BRIDGE_HOME" "$FAKE_HOME/.agent-bridge"

# Controller-published roster snapshot (the strict-predicate test seam).
ROSTER_JSON="$SMOKE_TMP_ROOT/controller-roster.json"
printf -- '%s\n' \
  '[' \
  "  {\"agent\": \"${ADMIN_AGENT}\", \"admin\": true, \"source\": \"static\"}," \
  "  {\"agent\": \"${PEER_AGENT}\", \"admin\": false, \"source\": \"static\"}," \
  "  {\"agent\": \"${ACTOR_AGENT}\", \"admin\": false, \"source\": \"static\"}" \
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

write_payload() {
  local target="$1" tool="$2" key="$3" value="$4" esc
  esc="$(json_escape "$value")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    "  \"tool_name\": \"${tool}\"," \
    "  \"tool_input\": {\"${key}\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1823",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# Run the real hook with a chosen acting identity. $1 agent, $2 admin-id env,
# $3 payload file. Echoes the raw hook stdout.
run_hook() {
  local agent="$1" admin_id="$2" payload_file="$3"
  HOME="$FAKE_HOME" \
  BRIDGE_AGENT_ID="$agent" \
  BRIDGE_ADMIN_AGENT_ID="$admin_id" \
  BRIDGE_GUARD_ADMIN_ROSTER_JSON="$ROSTER_JSON" \
    "$PYTHON_BIN" "$REAL_HOOK" <"$payload_file"
}

# Verdict for a tool call. $1 agent, $2 admin-id, $3 tool, $4 key, $5 value.
verdict() {
  local agent="$1" admin_id="$2" tool="$3" key="$4" value="$5" payload out
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM-$RANDOM.json"
  write_payload "$payload" "$tool" "$key" "$value"
  out="$(run_hook "$agent" "$admin_id" "$payload")"
  [[ "$out" == *'"permissionDecision": "deny"'* ]] && printf 'DENY' || printf 'ALLOW'
}

assert_verdict() {
  local label="$1" agent="$2" admin_id="$3" tool="$4" key="$5" value="$6" want="$7" got
  got="$(verdict "$agent" "$admin_id" "$tool" "$key" "$value")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      agent=${agent} admin_id=${admin_id} tool=${tool} ${key}=${value}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

# Convenience wrappers.
assert_edit() { assert_verdict "$1" "$2" "$3" "Edit" "file_path" "$4" "$5"; }
assert_read() { assert_verdict "$1" "$2" "$3" "Read" "file_path" "$4" "$5"; }
assert_bash() { assert_verdict "$1" "$2" "$3" "Bash" "command" "$4" "$5"; }

echo "[smoke:${SMOKE_NAME}] real PreToolUse hook end-to-end (v2 layout)"

# ---------------------------------------------------------------------------
# Tooth 1 — NON-admin Edit to a peer v2 home → DENIED (the #1823 hole closed).
# ---------------------------------------------------------------------------
assert_edit "Tooth1 non-admin Edit peer v2 home DENIED (#1823 closed)" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "$PEER_V2_HOME/MEMORY.md" "DENY"

# ---------------------------------------------------------------------------
# Tooth 2 — NON-admin Bash append to the same peer v2 home → DENIED.
# ---------------------------------------------------------------------------
assert_bash "Tooth2 non-admin Bash append peer v2 home DENIED (#1823 closed)" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "echo pwned >> $PEER_V2_HOME/MEMORY.md" "DENY"

# ---------------------------------------------------------------------------
# Tooth 3 — NON-admin Edit/append to the peer's LEGACY v1 home → still DENIED.
# ---------------------------------------------------------------------------
assert_edit "Tooth3 non-admin Edit peer v1 home still DENIED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "$PEER_V1_HOME/MEMORY.md" "DENY"
assert_bash "Tooth3 non-admin Bash append peer v1 home still DENIED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "echo pwned >> $PEER_V1_HOME/MEMORY.md" "DENY"

# ---------------------------------------------------------------------------
# Tooth 4 — NON-admin Edit to its OWN v2 home → never self-denied.
# ---------------------------------------------------------------------------
assert_edit "Tooth4 non-admin Edit OWN v2 home ALLOWED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "$ACTOR_V2_HOME/NOTES.md" "ALLOW"

# ---------------------------------------------------------------------------
# Tooth 5 — peer v2 WORKDIR is SCOPED OUT (shared-pair workspace, #1492).
# ---------------------------------------------------------------------------
assert_edit "Tooth5 non-admin Edit peer v2 WORKDIR ALLOWED (workdir scoped out)" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "$PEER_V2_WORKDIR/NOTES.md" "ALLOW"
assert_bash "Tooth5 non-admin Bash append peer v2 WORKDIR ALLOWED (workdir scoped out)" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "echo note >> $PEER_V2_WORKDIR/NOTES.md" "ALLOW"

# ---------------------------------------------------------------------------
# Tooth 6 — TRUSTED-ADMIN keeps its #1806 carve-outs (admin behavior unchanged).
# ---------------------------------------------------------------------------
assert_edit "Tooth6 admin Edit peer v2 home ALLOWED (admin not denied)" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "$PEER_V2_HOME/MEMORY.md" "ALLOW"
assert_read "Tooth6 admin Read peer v2 home ALLOWED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "$PEER_V2_HOME/MEMORY.md" "ALLOW"
assert_bash "Tooth6 admin Bash mkdir peer v2 home not newly DENIED by v2 enum" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "mkdir -p $PEER_V2_HOME/sub" "ALLOW"

# ---------------------------------------------------------------------------
# Tooth 7 — Invariant: shared/private + shared/secrets stay DENIED (non-admin).
# ---------------------------------------------------------------------------
assert_bash "Tooth7 non-admin Bash cat shared/secrets DENIED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "cat $BRIDGE_SHARED_DIR/secrets/key.md" "DENY"
assert_read "Tooth7 non-admin Read shared/private DENIED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  "$BRIDGE_SHARED_DIR/private/ops.md" "DENY"

# ---------------------------------------------------------------------------
# Tooth 8 — Invariant: admin's OWN v2 home is never self-denied.
# ---------------------------------------------------------------------------
assert_edit "Tooth8 admin Edit OWN v2 home ALLOWED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  "$ADMIN_V2_HOME/NOTES.md" "ALLOW"

smoke_log "passed"
echo "[smoke:${SMOKE_NAME}] passed"
