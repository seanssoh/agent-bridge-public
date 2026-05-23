#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1076-create-atomicity-and-purge.sh — Issue #1076.
#
# Pins two contracts:
#
#  1. `agent create` is atomic. When a mid-flow step raises (here: a
#     root-owned `agents/<a>/.claude` residue from a prior failed isolated
#     create that the controller cannot mkdir under), the create flow
#     unwinds the roster registration AND removes the partially-scaffolded
#     home tree. End state: agent is NOT in the local roster, no
#     half-scaffolded identity tree under `data/agents/<a>/`.
#
#  2. `agent delete --purge-home` removes ALL residue — the v2 per-agent
#     root (`$BRIDGE_AGENT_ROOT_V2/<a>/`) AND the tracked-profile-source
#     location (`$BRIDGE_HOME/agents/<a>/`). A subsequent
#     `agent create <same-name>` succeeds.
#
# Both contracts were the literal user repro on Linux v0.14.5-beta5 in
# the issue body. Smoke runs the create + delete via bridge-agent.sh
# directly with BRIDGE_CALLER_SOURCE armed so the typed-write trust gate
# admits the smoke invocation (same pattern as the in-tree smoke create
# block).

set -uo pipefail

SMOKE_NAME="1076-create-atomicity-and-purge"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# The typed-create gate (issue #1047) requires an operator-trusted source.
# Smoke is non-interactive, so arm the trusted-id env var the way smoke-
# test.sh's main create block does.
export BRIDGE_CALLER_SOURCE="operator-trusted-id"

# `agent delete` requires an admin caller (`bridge_agent_update_caller_is_
# admin`) and BRIDGE_ADMIN_AGENT_ID set. Seed an admin in the roster file
# so delete --from <admin> passes the trust gate.
ADMIN_AGENT="admin-1076"
export BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT"
# Lightweight admin registration: append a stub managed-role block so
# bridge_roster_local_mentions_agent + bridge_admin_agent_id resolve.
# `bridge_load_roster` calls `bridge_reset_roster_maps` which unsets
# BRIDGE_ADMIN_AGENT_ID, so the variable must be set INSIDE the roster
# file (every bridge subprocess re-loads). Same shape as a real install
# (see lib/bridge-agents.sh:3224 in the launch_cmd render block).
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT"
# BEGIN AGENT BRIDGE MANAGED ROLE: $ADMIN_AGENT
bridge_add_agent_id_if_missing $ADMIN_AGENT
BRIDGE_AGENT_DESC[$ADMIN_AGENT]="probe-1076 admin"
BRIDGE_AGENT_ENGINE[$ADMIN_AGENT]=claude
BRIDGE_AGENT_SESSION[$ADMIN_AGENT]=$ADMIN_AGENT
BRIDGE_AGENT_WORKDIR[$ADMIN_AGENT]=$BRIDGE_AGENT_ROOT_V2/$ADMIN_AGENT/workdir
BRIDGE_AGENT_SOURCE[$ADMIN_AGENT]="static"
BRIDGE_AGENT_LAUNCH_CMD[$ADMIN_AGENT]="claude --dangerously-skip-permissions"
BRIDGE_AGENT_CONTINUE[$ADMIN_AGENT]="1"
BRIDGE_AGENT_ISOLATION_MODE[$ADMIN_AGENT]="shared"
# END AGENT BRIDGE MANAGED ROLE: $ADMIN_AGENT
EOF

AGENT_ID="probe-1076"
ROSTER_FILE="$BRIDGE_ROSTER_LOCAL_FILE"

run_create() {
  # shellcheck disable=SC2317  # invoked indirectly via $()
  BRIDGE_AGENT_ID="$ADMIN_AGENT" \
    "$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" create "$AGENT_ID" \
    --engine claude --session "$AGENT_ID" 2>&1
}

run_delete_purge() {
  BRIDGE_AGENT_ID="$ADMIN_AGENT" \
    "$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" delete "$AGENT_ID" \
    --from "$ADMIN_AGENT" --force --purge-home --orphan-tasks 2>&1
}

assert_not_in_roster() {
  local context="$1"
  # Anchor with $ to avoid prefix-matching probe-1076-admin against probe-1076.
  if grep -Eq "AGENT BRIDGE MANAGED ROLE: $AGENT_ID\$" "$ROSTER_FILE" 2>/dev/null; then
    smoke_fail "$context: agent '$AGENT_ID' still present in roster $ROSTER_FILE"
  fi
}

assert_in_roster() {
  local context="$1"
  grep -Eq "AGENT BRIDGE MANAGED ROLE: $AGENT_ID\$" "$ROSTER_FILE" 2>/dev/null \
    || smoke_fail "$context: agent '$AGENT_ID' is NOT in roster $ROSTER_FILE"
}

# ---- T1: mid-create failure leaves NO registered agent and NO residue ----
smoke_log "T1: mid-create failure rolls back (no half-create)"

# Force a mid-create failure by pre-creating the v2 per-agent root with
# an unwritable child the scaffold path would touch. The repro from the
# issue uses a root-owned `data/agents/<a>/` from a prior aborted
# isolated create — we simulate with an unwritable tracked-profile parent
# (the controller can't mkdir `agents/<a>/.claude` for shared-settings
# render even when the v2 home/ is freely owned).
#
# `bridge_ensure_auto_memory_isolation` runs before write_role_block and
# calls `mkdir -p "$workdir/.claude"`. If the v2 workdir is pre-created
# with mode 0500 (controller r-x but no write), that mkdir fails with
# PermissionError and the create dies BEFORE writing the role block.
# Rollback should still rm the scaffold target (the identity source under
# `data/agents/<a>/home/`) that bridge_scaffold_agent_home authored just
# before the failure point.
PRE_BLOCK_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$AGENT_ID/workdir"
mkdir -p "$PRE_BLOCK_WORKDIR"
# Drop write permission so $workdir/.claude mkdir fails for the
# controller; keep r-x so the bridge_die's `[[ -e $workdir ]]` empty-dir
# probe still works.
chmod 0500 "$PRE_BLOCK_WORKDIR"

T1_OUT="$(run_create || true)"

# Restore write so cleanup can rm.
chmod 0700 "$PRE_BLOCK_WORKDIR" 2>/dev/null || true

# Agent must NOT be in the roster after a failed create.
assert_not_in_roster "T1"

# The identity-source scaffold under data/agents/<a>/home/ must NOT
# remain after rollback. (The rollback rmtree guard removes it.)
if [[ -d "$BRIDGE_AGENT_ROOT_V2/$AGENT_ID/home" ]]; then
  smoke_fail "T1: identity-source residue remains under $BRIDGE_AGENT_ROOT_V2/$AGENT_ID/home after failed create — rollback did not unwind scaffold. create_out=$T1_OUT"
fi

# The v2 per-agent root parent may remain if the operator pre-created it
# (we did, here), but bridge_scaffold_agent_home pre-creates the home/
# sibling inside the parent — that sibling MUST be gone.
smoke_log "ok: T1 — failed create did not leave a registered agent or scaffold residue"

# Clean the simulated pre-existing residue so T2 starts from a clean slate.
rm -rf "${BRIDGE_AGENT_ROOT_V2:?}/${AGENT_ID:?}" 2>/dev/null || true

# ---- T2: create → delete --purge-home → create succeeds ----
smoke_log "T2: create / delete --purge-home / re-create cycle"

# Fresh create (no pre-block this time) must succeed.
T2_CREATE_OUT="$(run_create)" || smoke_fail "T2: initial create failed.
$T2_CREATE_OUT"
smoke_assert_contains "$T2_CREATE_OUT" "create: ok" "T2: first create"
assert_in_roster "T2 after initial create"

# Identity source + workspace + tracked-profile dir must exist after a
# successful create (proves we have residue to test the purge against).
smoke_assert_file_exists "$BRIDGE_AGENT_ROOT_V2/$AGENT_ID/home/CLAUDE.md" \
  "T2 after create: identity source CLAUDE.md"

# Delete with --purge-home must clear ALL residue.
T2_DELETE_OUT="$(run_delete_purge)" || smoke_fail "T2: agent delete failed.
$T2_DELETE_OUT"
smoke_assert_contains "$T2_DELETE_OUT" "deleted: yes" "T2: delete"
assert_not_in_roster "T2 after delete"

# Residue assertions: no per-agent v2 root, no tracked-profile dir.
if [[ -d "$BRIDGE_AGENT_ROOT_V2/$AGENT_ID" ]]; then
  smoke_fail "T2: --purge-home left v2 per-agent root: $BRIDGE_AGENT_ROOT_V2/$AGENT_ID"
fi
if [[ -d "$BRIDGE_AGENT_HOME_ROOT/$AGENT_ID" ]]; then
  smoke_fail "T2: --purge-home left tracked-profile residue: $BRIDGE_AGENT_HOME_ROOT/$AGENT_ID"
fi

# Re-create must succeed — this is the specific bug the user hit (the
# second create re-tripped the PermissionError chain because residue
# was still owned/locked from the first round).
T2_RECREATE_OUT="$(run_create)" || smoke_fail "T2: re-create after --purge-home failed (issue #1076 regression).
$T2_RECREATE_OUT"
smoke_assert_contains "$T2_RECREATE_OUT" "create: ok" "T2: re-create"
assert_in_roster "T2 after re-create"
smoke_assert_file_exists "$BRIDGE_AGENT_ROOT_V2/$AGENT_ID/home/CLAUDE.md" \
  "T2 after re-create: identity source CLAUDE.md re-authored"

smoke_log "ok: T2 — create / delete --purge-home / re-create cycle succeeded"

# Cleanup roster + state for any sibling smokes.
run_delete_purge >/dev/null 2>&1 || true

smoke_log "all tests PASS — issue #1076: atomic create + complete --purge-home"
