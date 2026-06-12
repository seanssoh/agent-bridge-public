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
#   Tooth 9 — (r2) NON-admin Bash append spelled through the EXPORTED v2 env-var
#             anchors `$BRIDGE_DATA_ROOT/agents/<other>/home/…` AND
#             `$BRIDGE_AGENT_ROOT_V2/<other>/home/…` (bare + brace) → DENIED. v2
#             EXPORTS both vars into the agent runtime so bash expands them to
#             the exact peer v2 home; before the r2 fix the hook's path expander
#             left the `$`-token intact and the word fell through to ALLOW (the
#             residual bypass codex proved on head 45b2520f). Mirrors Tooth 2,
#             but the LITERAL env-var token reaches the hook (the smoke escapes
#             the `$` so the test shell does not pre-expand it).
#  Tooth 10 — (r2) TRUSTED-ADMIN with the SAME two env-var-spelled peer-home
#             writes → ALLOWED (the #1806 admin carve-out is spelling-agnostic;
#             only NON-admin denies). Admin behavior is unchanged.
#  Tooth 11 — (r3) TRUSTED-ADMIN Bash write to a SPLIT-ROOT v2 peer home
#             (BRIDGE_DATA_ROOT OUTSIDE BRIDGE_HOME — this smoke's default
#             layout) → ALLOWED **and emits EXACTLY ONE `admin_cross_agent_write`
#             audit row** with the correct `target_agent` (the peer). Before the
#             r3 fix `_resolved_write_target_containment` required the target
#             under `bridge_home_dir()`; a split-root peer home is OUTSIDE it, so
#             the helper returned None, the admin write fell through to ALLOW, and
#             ZERO audit rows were emitted — an UNAUDITED cross-agent write. This
#             assertion FAILS on the pre-fix head (0 rows) and PASSES after (1).
#  Tooth 12 — (r3) CO-LOCATED control: the SAME admin write on a layout where the
#             v2 data root lives INSIDE the bridge home (BRIDGE_DATA_ROOT under
#             BRIDGE_HOME) → ALLOWED and STILL emits exactly one row. Proves the
#             r3 fix is a pure ADDITION of the v2-data-root containment root and
#             did not regress the co-located audit path.
#  Tooth 13 — (r3) NEGATIVE: a NON-admin write to the split-root peer v2 home →
#             DENIED and emits ZERO `admin_cross_agent_write` rows (the audit path
#             is admin-only; r3 changed no non-admin behavior).
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

# --- #1806 admin-write AUDIT helpers (r3) -----------------------------------
#
# The #1806 admin peer-write carve-out ALLOWS a trusted-admin to write a peer's
# home; the accountability mechanism is the `admin_cross_agent_write` audit row.
# Issue #1823 (r3) closes the gap where a SPLIT-ROOT v2 peer home (BRIDGE_DATA_ROOT
# outside BRIDGE_HOME) was allowed with ZERO rows. These helpers run the real
# hook with a fresh audit log and count the emitted rows for a given target_agent.
#
# `run_hook_audit`: like run_hook but pins BRIDGE_AUDIT_LOG to $1 so a tooth can
# assert the emitted audit rows in isolation. The default split-root layout is
# inherited from lib.sh; the co-located control (Tooth 12) supplies its own
# `env` invocation with the co-located BRIDGE_DATA_ROOT overrides.
run_hook_audit() {
  local audit_log="$1" agent="$2" admin_id="$3" payload_file="$4"
  env \
    HOME="$FAKE_HOME" \
    BRIDGE_AGENT_ID="$agent" \
    BRIDGE_ADMIN_AGENT_ID="$admin_id" \
    BRIDGE_GUARD_ADMIN_ROSTER_JSON="$ROSTER_JSON" \
    BRIDGE_AUDIT_LOG="$audit_log" \
    "$PYTHON_BIN" "$REAL_HOOK" <"$payload_file"
}

# Count `admin_cross_agent_write` rows whose detail.target_agent == $2 in the
# JSONL audit log $1. Pure-python parse (no jq dependency); 0 when the file is
# absent (the pre-fix split-root behavior: allowed, never audited).
#
# Footgun #11: the counter is a STANDALONE python file invoked file-as-argv
# (`python3 FILE …`), NOT a `<<'PY'` heredoc-stdin to a subprocess inside a
# command-substitution — that pattern deadlocks under Bash 5.3.9. Matches the
# smoke header's "printf + `< file`, no heredoc-to-subprocess" contract.
AUDIT_COUNTER_PY="$SMOKE_TMP_ROOT/count_admin_write_rows.py"
printf '%s\n' \
  'import json' \
  'import sys' \
  '' \
  'path, want = sys.argv[1], sys.argv[2]' \
  'n = 0' \
  'try:' \
  '    fh = open(path, encoding="utf-8")' \
  'except OSError:' \
  '    print(0)' \
  '    sys.exit(0)' \
  'with fh:' \
  '    for line in fh:' \
  '        line = line.strip()' \
  '        if not line:' \
  '            continue' \
  '        try:' \
  '            rec = json.loads(line)' \
  '        except ValueError:' \
  '            continue' \
  '        if rec.get("action") != "admin_cross_agent_write":' \
  '            continue' \
  '        if rec.get("detail", {}).get("target_agent") == want:' \
  '            n += 1' \
  'print(n)' \
  >"$AUDIT_COUNTER_PY"

count_admin_write_rows() {
  local audit_log="$1" want_target="$2"
  [[ -f "$audit_log" ]] || { printf '0'; return; }
  "$PYTHON_BIN" "$AUDIT_COUNTER_PY" "$audit_log" "$want_target"
}

# Assert exactly $4 `admin_cross_agent_write` rows for target_agent $3 in $2,
# labeled $1.
assert_audit_rows() {
  local label="$1" audit_log="$2" target="$3" want="$4" got
  got="$(count_admin_write_rows "$audit_log" "$target")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got} admin_cross_agent_write row(s) for ${target}"
  else
    smoke_log "FAIL: ${label} -> ${got} rows for ${target}, want ${want}"
    smoke_fail "${label}: expected ${want} audit row(s), got ${got}"
  fi
}

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

# ---------------------------------------------------------------------------
# Tooth 9 (r2) — NON-admin Bash append spelled through the EXPORTED v2 env-var
# anchors → DENIED. The LITERAL `$BRIDGE_DATA_ROOT` / `$BRIDGE_AGENT_ROOT_V2`
# token must reach the hook, so the `$` is escaped here (single-quoted command
# string) — bash in the test shell must NOT pre-expand it. The hook receives
# both vars in its env (lib.sh exports them, run_hook inherits) and expands them
# to the peer v2 home itself. Before the r2 fix these were ALLOW (the bypass).
#
# Both depths are exercised:
#   $BRIDGE_DATA_ROOT      → <data_root>            → tail /agents/<peer>/home
#   $BRIDGE_AGENT_ROOT_V2  → <data_root>/agents     → tail /<peer>/home
# ---------------------------------------------------------------------------
assert_bash "Tooth9 non-admin Bash append peer home via \$BRIDGE_DATA_ROOT DENIED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  'echo pwned >> $BRIDGE_DATA_ROOT/agents/'"$PEER_AGENT"'/home/MEMORY.md' "DENY"
assert_bash "Tooth9 non-admin Bash append peer home via \${BRIDGE_DATA_ROOT} DENIED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  'echo pwned >> ${BRIDGE_DATA_ROOT}/agents/'"$PEER_AGENT"'/home/MEMORY.md' "DENY"
assert_bash "Tooth9 non-admin Bash append peer home via \$BRIDGE_AGENT_ROOT_V2 DENIED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  'echo pwned >> $BRIDGE_AGENT_ROOT_V2/'"$PEER_AGENT"'/home/MEMORY.md' "DENY"
assert_bash "Tooth9 non-admin Bash append peer home via \${BRIDGE_AGENT_ROOT_V2} DENIED" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  'echo pwned >> ${BRIDGE_AGENT_ROOT_V2}/'"$PEER_AGENT"'/home/MEMORY.md' "DENY"

# Negative-control: the env-var-spelled peer WORKDIR stays scoped out (ALLOW),
# so the new anchor expansion did not over-block the #1492 shared workspace.
assert_bash "Tooth9 non-admin Bash append peer WORKDIR via \$BRIDGE_DATA_ROOT ALLOWED (scoped out)" \
  "$ACTOR_AGENT" "$ADMIN_AGENT" \
  'echo note >> $BRIDGE_DATA_ROOT/agents/'"$PEER_AGENT"'/workdir/NOTES.md' "ALLOW"

# ---------------------------------------------------------------------------
# Tooth 10 (r2) — TRUSTED-ADMIN with the SAME env-var-spelled peer-home writes
# → ALLOWED (admin carve-out is spelling-agnostic; only non-admin denies).
# ---------------------------------------------------------------------------
assert_bash "Tooth10 admin Bash append peer home via \$BRIDGE_DATA_ROOT ALLOWED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  'echo note >> $BRIDGE_DATA_ROOT/agents/'"$PEER_AGENT"'/home/MEMORY.md' "ALLOW"
assert_bash "Tooth10 admin Bash append peer home via \$BRIDGE_AGENT_ROOT_V2 ALLOWED" \
  "$ADMIN_AGENT" "$ADMIN_AGENT" \
  'echo note >> $BRIDGE_AGENT_ROOT_V2/'"$PEER_AGENT"'/home/MEMORY.md' "ALLOW"

# ---------------------------------------------------------------------------
# Tooth 11 (r3) — SPLIT-ROOT admin v2 peer-home write → ALLOW + EXACTLY ONE
# `admin_cross_agent_write` audit row (correct target_agent). This smoke's
# default layout is split-root (lib.sh: BRIDGE_DATA_ROOT="$SMOKE_TMP_ROOT/data",
# OUTSIDE BRIDGE_HOME), so we just run an admin write against the peer v2 home
# with a FRESH audit log and assert verdict + row count. Pre-fix head: ALLOW but
# 0 rows (the unaudited gap). Post-fix: ALLOW + 1 row.
# ---------------------------------------------------------------------------
AUDIT_SPLIT="$SMOKE_TMP_ROOT/audit-split.jsonl"
: >"$AUDIT_SPLIT"
PAYLOAD_SPLIT="$SMOKE_TMP_ROOT/payload-split.json"
write_payload "$PAYLOAD_SPLIT" "Bash" "command" "mkdir -p $PEER_V2_HOME/sub11"
SPLIT_OUT="$(run_hook_audit "$AUDIT_SPLIT" "$ADMIN_AGENT" "$ADMIN_AGENT" "$PAYLOAD_SPLIT")"
if [[ "$SPLIT_OUT" == *'"permissionDecision": "deny"'* ]]; then
  smoke_fail "Tooth11 split-root admin v2 peer write should ALLOW, got DENY"
fi
smoke_log "ok: Tooth11 split-root admin v2 peer write -> ALLOW"
assert_audit_rows "Tooth11 split-root admin v2 peer write emits one audit row" \
  "$AUDIT_SPLIT" "$PEER_AGENT" "1"

# ---------------------------------------------------------------------------
# Tooth 12 (r3) — CO-LOCATED control: same admin write on a layout where the v2
# data root lives INSIDE the bridge home → ALLOW + exactly one row. Built under a
# second tree (CO_HOME) whose BRIDGE_DATA_ROOT == "$CO_HOME/data". Run via
# run_hook_audit env overrides so the whole resolver chain (agent_root_v2,
# other_agent_homes, containment) sees the co-located layout.
# ---------------------------------------------------------------------------
CO_HOME="$SMOKE_TMP_ROOT/colocated-home"
CO_DATA="$CO_HOME/data"
CO_AGENT_ROOT_V2="$CO_DATA/agents"
CO_PEER_V2_HOME="$CO_AGENT_ROOT_V2/$PEER_AGENT/home"
CO_ADMIN_V1="$CO_HOME/agents/$ADMIN_AGENT"
mkdir -p "$CO_PEER_V2_HOME" "$CO_AGENT_ROOT_V2/$ADMIN_AGENT/home" "$CO_ADMIN_V1" \
  "$CO_HOME/logs" "$CO_HOME/shared"
printf -- '- session type: admin\n' >"$CO_ADMIN_V1/SESSION-TYPE.md"
# Point the `~/.agent-bridge` tilde alias at the co-located home for this run.
CO_FAKE_HOME="$SMOKE_TMP_ROOT/colocated-fakehome"
mkdir -p "$CO_FAKE_HOME"
ln -snf "$CO_HOME" "$CO_FAKE_HOME/.agent-bridge"
AUDIT_CO="$SMOKE_TMP_ROOT/audit-colocated.jsonl"
: >"$AUDIT_CO"
PAYLOAD_CO="$SMOKE_TMP_ROOT/payload-colocated.json"
write_payload "$PAYLOAD_CO" "Bash" "command" "mkdir -p $CO_PEER_V2_HOME/sub12"
CO_OUT="$(env \
  HOME="$CO_FAKE_HOME" \
  BRIDGE_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
  BRIDGE_GUARD_ADMIN_ROSTER_JSON="$ROSTER_JSON" \
  BRIDGE_AUDIT_LOG="$AUDIT_CO" \
  BRIDGE_HOME="$CO_HOME" \
  BRIDGE_AGENT_HOME_ROOT="$CO_HOME/agents" \
  BRIDGE_SHARED_DIR="$CO_HOME/shared" \
  BRIDGE_DATA_ROOT="$CO_DATA" \
  BRIDGE_AGENT_ROOT_V2="$CO_AGENT_ROOT_V2" \
  "$PYTHON_BIN" "$REAL_HOOK" <"$PAYLOAD_CO")"
if [[ "$CO_OUT" == *'"permissionDecision": "deny"'* ]]; then
  smoke_fail "Tooth12 co-located admin v2 peer write should ALLOW, got DENY"
fi
smoke_log "ok: Tooth12 co-located admin v2 peer write -> ALLOW"
assert_audit_rows "Tooth12 co-located admin v2 peer write emits one audit row" \
  "$AUDIT_CO" "$PEER_AGENT" "1"

# ---------------------------------------------------------------------------
# Tooth 13 (r3) — NEGATIVE: NON-admin write to the split-root peer v2 home →
# DENIED and ZERO admin_cross_agent_write rows (the audit path is admin-only;
# r3 did not change non-admin behavior).
# ---------------------------------------------------------------------------
AUDIT_NONADMIN="$SMOKE_TMP_ROOT/audit-nonadmin.jsonl"
: >"$AUDIT_NONADMIN"
PAYLOAD_NONADMIN="$SMOKE_TMP_ROOT/payload-nonadmin.json"
write_payload "$PAYLOAD_NONADMIN" "Bash" "command" "echo pwned >> $PEER_V2_HOME/MEMORY.md"
NONADMIN_OUT="$(run_hook_audit "$AUDIT_NONADMIN" "$ACTOR_AGENT" "$ADMIN_AGENT" "$PAYLOAD_NONADMIN")"
if [[ "$NONADMIN_OUT" != *'"permissionDecision": "deny"'* ]]; then
  smoke_fail "Tooth13 non-admin split-root peer write should DENY, got ALLOW"
fi
smoke_log "ok: Tooth13 non-admin split-root peer write -> DENY"
assert_audit_rows "Tooth13 non-admin split-root peer write emits NO admin audit row" \
  "$AUDIT_NONADMIN" "$PEER_AGENT" "0"

smoke_log "passed"
echo "[smoke:${SMOKE_NAME}] passed"
