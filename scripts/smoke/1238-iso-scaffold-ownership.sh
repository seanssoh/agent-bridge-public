#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1238-iso-scaffold-ownership.sh — Issue #1238 + companion bug.
#
# v0.15.0-beta1 fresh-install regression: `agent-bridge agent create
# <name> --isolate --engine claude` scaffolded the per-agent home tree
# (`SOUL.md`, `CLAUDE.md`, `MEMORY*.md`, `SESSION-TYPE.md`, `TOOLS.md`,
# `.claude/`, `memory/`, ...) under the controller `umask 077` (mode
# 0600 / 0700), but `bridge_linux_prepare_agent_isolation` only
# recursive-chowned `$workdir` to the iso UID and the top-level
# `$_v2_agent_root/home` chown was non-recursive. Net effect: the iso
# UID owned the `home/` directory but NONE of the files inside it, so a
# claude session running under the iso UID could not read its own
# SOUL.md / CLAUDE.md / `.claude/.credentials.json` and boot was
# structurally impossible.
#
# Companion bug (same issue): `bridge_auth_update_legacy_claude_config_
# env` in `bridge-auth.sh` ran `python3 - "$file" "$config_dir" <<'PY'`
# directly as the controller. On a fresh install the controller's
# supplementary-group cache may not yet include `ab-agent-<a>` (KNOWN_
# ISSUES §28 — login-cached `id -G`), so the child Python's
# `path.exists()` on `<v2-root>/credentials/launch-secrets.env` raised
# `PermissionError` and the unhandled exception aborted
# `bridge_auth_sync_agents` mid-walk. Patch routes the invocation
# through `bridge_auth_run_privileged` (direct first, sudo fallback)
# mirroring the pattern at `bridge_auth_sync_agent_python:353-355`.
#
# Coverage matrix (host-agnostic — static-source greps; no sudo/root
# needed, runs on macOS dev hosts and Linux CI alike):
#
#   T1 — `bridge_linux_prepare_agent_isolation` includes a
#        `chown -R "$os_user" "$_v2_agent_root/home"` step. Mirrors
#        the existing `chown -R "$os_user" "$workdir"` pattern for the
#        same function. A revert that drops the home-subtree recursive
#        chown immediately fails T1.
#
#   T2 — the chown step does NOT cover the per-agent root
#        (`$_v2_agent_root`) recursively, nor `credentials/`,
#        nor `runtime/`, nor `logs/`, nor `requests/`, nor
#        `responses/`. The v2 contract at lib/bridge-agents.sh:4031-
#        4053 requires `credentials/` to stay controller-owned and the
#        per-agent root to stay `root:ab-agent-<a> 2750`. A regression
#        that broadens the scope (e.g. `chown -R "$os_user" "$_v2_
#        agent_root"`) breaks the credential boundary and trips T2.
#
#   T3 — `bridge_auth_update_legacy_claude_config_env` invokes the
#        Python heredoc via `bridge_auth_run_privileged python3 - ...`,
#        not bare `python3 - ...`. A revert that drops the privileged
#        wrapper immediately fails T3.
#
#   T4 — `bridge_auth_update_legacy_claude_config_env` does NOT
#        contain the anti-pattern `except PermissionError: return
#        False` (the codex r1 spec explicitly rejects converting an
#        inaccessible existing secret into "absent" — that risks
#        clobbering a controller-owned credential file with a fresh
#        write thinking it doesn't exist).
#
# Static-source coverage is sufficient because the runtime invariants
# (file ownership after `agent create --isolate` on a Linux host with
# passwordless sudo and a real iso user) need a full system-level
# fixture — group provisioning, useradd, passwordless sudoers — that
# is out of scope for a smoke. The promotion-verify Phase E flow on
# the operator's actual cm-prod-AgentWorkflow-vm01 verifies the
# byte-level invariant per the issue's repro steps.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every
# assertion uses direct `grep -n` against the source files; no
# heredoc-stdin to a bash function or `$(...)` capture of one.

set -uo pipefail

SMOKE_NAME="1238-iso-scaffold-ownership"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"

[[ -f "$AGENTS_LIB" ]] || smoke_fail "missing $AGENTS_LIB"
[[ -f "$AUTH_SH" ]]   || smoke_fail "missing $AUTH_SH"

# ---------------------------------------------------------------------
# T1 — `bridge_linux_prepare_agent_isolation` recursive-chowns
# `$_v2_agent_root/home` to `$os_user`.
# ---------------------------------------------------------------------

smoke_log "T1: bridge_linux_prepare_agent_isolation includes recursive chown of v2 home/ subtree"

# Look for the literal line. We want a tight match so a future refactor
# that moves the chown elsewhere is still caught by the count check
# below.
T1_MATCH="$(grep -nF 'chown -R "$os_user" "$_v2_agent_root/home"' "$AGENTS_LIB" || true)"
if [[ -z "$T1_MATCH" ]]; then
  smoke_fail "T1: lib/bridge-agents.sh does not contain the recursive chown of \$_v2_agent_root/home — issue #1238 fix regressed (claude session under iso UID cannot read its own SOUL.md / CLAUDE.md)"
fi
smoke_log "T1 PASS — found recursive chown of v2 home subtree: $T1_MATCH"

# ---------------------------------------------------------------------
# T2 — the chown does NOT target the per-agent root recursively, nor
# any of the controller-protected subtrees.
# ---------------------------------------------------------------------

smoke_log "T2: recursive chown scope excludes per-agent root, credentials/, runtime/, logs/, requests/, responses/"

# Forbidden patterns (any one of these would broaden the iso ownership
# to a subtree the v2 contract requires the controller to keep).
T2_BAD_PATTERNS=(
  'chown -R "$os_user" "$_v2_agent_root"$'
  'chown -R "$os_user" "$_v2_agent_root" '
  'chown -R "$os_user" "$_v2_credentials_dir"'
  'chown -R "$os_user" "$_v2_agent_root/credentials"'
)

# Allowed patterns (these subtrees ARE intentionally recursive-chowned
# to iso UID — workdir and home — and the existing prepare path already
# chowns runtime_state_dir + log_dir).
for _bad in "${T2_BAD_PATTERNS[@]}"; do
  if grep -nE "$_bad" "$AGENTS_LIB" >/dev/null 2>&1; then
    smoke_fail "T2: lib/bridge-agents.sh contains forbidden broadening chown matching /$_bad/ — would break v2 credentials boundary or per-agent root contract"
  fi
done

# Specifically the per-agent root: `chown -R "$os_user" "$_v2_agent_
# root"` (no trailing path component) must not appear. A grep with
# end-of-line $ anchor catches `chown -R "$os_user" "$_v2_agent_root"`
# but not `chown -R "$os_user" "$_v2_agent_root/home"` (the T1
# target). The two-pattern split above already enforces both shapes.
smoke_log "T2 PASS — chown scope stays inside home/ and workdir/"

# ---------------------------------------------------------------------
# T3 — `bridge_auth_update_legacy_claude_config_env` routes the Python
# heredoc through `bridge_auth_run_privileged`.
# ---------------------------------------------------------------------

smoke_log "T3: bridge_auth_update_legacy_claude_config_env invokes python3 via bridge_auth_run_privileged"

T3_MATCH="$(grep -nF 'bridge_auth_run_privileged python3 - "$file" "$config_dir" <<' "$AUTH_SH" || true)"
if [[ -z "$T3_MATCH" ]]; then
  smoke_fail "T3: bridge-auth.sh does not route the legacy-launch-env Python heredoc through bridge_auth_run_privileged — companion #1238 bug regressed (controller without ab-agent-<a> group membership trips PermissionError on launch-secrets.env)"
fi
smoke_log "T3 PASS — privileged wrapper present: $T3_MATCH"

# T3b — sanity check that there's no remaining bare `python3 - "$file"
# "$config_dir"` invocation in the same function. (A future refactor
# might add a second call site and forget the wrapper.)
T3B_BAD="$(grep -nE '^[[:space:]]*python3 - "\$file" "\$config_dir" <<' "$AUTH_SH" || true)"
if [[ -n "$T3B_BAD" ]]; then
  smoke_fail "T3b: bridge-auth.sh has a bare python3 heredoc invocation without bridge_auth_run_privileged: $T3B_BAD"
fi

# ---------------------------------------------------------------------
# T4 — the codex r1 anti-pattern (`except PermissionError: return
# False`) is NOT present in bridge-auth.sh. The fix uses privileged
# invocation, not a swallowed exception.
# ---------------------------------------------------------------------

smoke_log "T4: bridge-auth.sh does not swallow PermissionError as 'absent' (codex r1 anti-pattern)"

T4_BAD="$(grep -nE 'except PermissionError:[[:space:]]*$|except PermissionError:[[:space:]]+(return False|pass)' "$AUTH_SH" || true)"
if [[ -n "$T4_BAD" ]]; then
  smoke_fail "T4: bridge-auth.sh contains the codex-rejected anti-pattern (PermissionError swallowed as absent): $T4_BAD"
fi
smoke_log "T4 PASS — no PermissionError swallow"

smoke_log "all tests PASS — issue #1238 + companion bug verified at current main"
