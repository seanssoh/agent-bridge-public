#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1750-admin-workdir-identity-not-pair-template.sh
#
# Issue #1750 — fresh-install admin workdir identity must NOT be overwritten by
# the codex sibling-pair (`<admin>-dev`) template.
#
# Topology (managed-project single-admin install, isolation=shared, macOS):
#   * admin `patch`     — engine=claude, source=static, home != workdir, the
#                         WORKDIR identity copies (SOUL/SESSION-TYPE/CLAUDE.md)
#                         were materialized correct at create-time (admin /
#                         claude / Session Type: admin).
#   * pair  `patch-dev` — engine=codex, source=static, auto-provisioned with
#                         `--workdir <admin-workdir> --allow-shared-workdir`
#                         (bridge-init-codex-pair.sh). Its OWN home identity is
#                         the codex pair template (patch-dev / Pair programmer /
#                         Session Type: static-codex). The pair RESOLVES its
#                         workdir to the ADMIN's workdir (shared workspace).
#
# Root cause this smoke pins: `bridge_layout_sync_identity_from_home` (the
# #1417 start-time HOME->WORKDIR reconcile, called from bridge-start.sh) carries
# the create-time-only shared-workspace guards (marker text + the
# BRIDGE_LAYOUT_WORKSPACE_SHARED env flag), NEITHER of which fires on the pair's
# START: the admin's correct workdir CLAUDE.md holds no marker text, and the env
# flag is unset on the start path. So the pair's start copies its codex home
# identity OVER the admin's workdir copies — the admin then boots (reads identity
# from the workdir cwd) as the codex pair. The fix adds a fail-safe roster-aware
# guard (`bridge_layout_workspace_foreign_owned`): when the workdir is shared
# with another agent and the identity there is not this agent's, decline.
#
# Assertions (all on a temp BRIDGE_HOME — operator's live tree never touched):
#   T1 — Pair start does NOT overwrite the admin's WORKDIR identity. After
#        `bridge_layout_sync_identity_from_home patch-dev codex <shared-workdir>`
#        the workdir SOUL/SESSION-TYPE/CLAUDE.md still name the ADMIN (admin /
#        claude / Session Type: admin), byte-identical to the admin's HOME copy,
#        and NOT the patch-dev codex-pair template.
#   T2 — Admin's OWN start still reconciles its workdir from HOME (#1417 intact):
#        a HOME edit on the admin propagates to the shared workdir (the owner is
#        allowed to refresh its own identity copy).
#   TEETH — With the guard disabled (BRIDGE_LAYOUT_DISABLE_FOREIGN_GUARD_1750=1,
#        i.e. the pre-fix behavior), the pair's start DOES overwrite the admin's
#        workdir with the codex-pair template — reproducing the #1750 divergence.
#        This proves the guard, not the fixture, is what holds the invariant.
#
# Footgun #11 (Bash 5.3.9 heredoc-stdin deadlock): every subprocess driver body
# is emitted to a file via printf and invoked file-as-argv; no `<<'PY'`/`<<EOF`
# stdin heredocs into a subprocess.

set -uo pipefail

SMOKE_NAME="1750-admin-workdir-identity-not-pair-template"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

ADMIN="patch"
PAIR="patch-dev"

# Identity sources (layer 2 — agent_home) for each agent.
ADMIN_HOME="$BRIDGE_AGENT_ROOT_V2/$ADMIN/home"
PAIR_HOME="$BRIDGE_AGENT_ROOT_V2/$PAIR/home"
# The shared managed-project workspace (layer 3) both agents resolve to. Use a
# custom path (NOT the v2 default) so bridge_agent_workdir returns it verbatim
# for both rows and the test isolates the layout guard, not workdir resolution.
SHARED_WORKDIR="$BRIDGE_DATA_ROOT/managed-project"
mkdir -p "$ADMIN_HOME" "$PAIR_HOME" "$SHARED_WORKDIR"

# --- identity body factories ------------------------------------------------

write_admin_identity() {
  local dir="$1"
  {
    printf '%s\n' '# patch Soul'
    printf '%s\n' '너는 patch다. 역할은 Manager/admin role이다.'
  } >"$dir/SOUL.md"
  {
    printf '%s\n' '# Session Type'
    printf '%s\n' ''
    printf '%s\n' '- Session Type: admin'
    printf '%s\n' '- Onboarding State: complete'
    printf '%s\n' '- Engine: claude'
  } >"$dir/SESSION-TYPE.md"
  {
    printf '%s\n' '# patch — Manager/admin role  (런타임: Claude Code CLI)'
  } >"$dir/CLAUDE.md"
}

write_pair_identity() {
  local dir="$1"
  {
    printf '%s\n' '# patch-dev Soul'
    printf '%s\n' '너는 patch-dev다. 역할은 Pair programmer for patch (codex)이다.'
  } >"$dir/SOUL.md"
  {
    printf '%s\n' '# Session Type'
    printf '%s\n' ''
    printf '%s\n' '- Session Type: static-codex'
    printf '%s\n' '- Onboarding State: complete'
    printf '%s\n' '- Engine: codex'
  } >"$dir/SESSION-TYPE.md"
  {
    printf '%s\n' '# patch-dev — Pair programmer for patch (codex)  (런타임: Codex CLI)'
  } >"$dir/AGENTS.md"
  # Codex wants a CLAUDE.md compat copy alongside AGENTS.md.
  {
    printf '%s\n' '# patch-dev — Pair programmer for patch (codex)  (런타임: Codex CLI)'
  } >"$dir/CLAUDE.md"
}

# Seed HOME identities: admin (correct), pair (codex template).
write_admin_identity "$ADMIN_HOME"
write_pair_identity  "$PAIR_HOME"

# Seed the WORKDIR (shared) with the ADMIN's correct identity — this is what the
# admin's create-time materialize legitimately produced (home @T0, workdir @T0).
write_admin_identity "$SHARED_WORKDIR"

# --- roster -----------------------------------------------------------------
# Both agents are static; both resolve their workdir to the SAME shared path via
# an explicit BRIDGE_AGENT_WORKDIR row. Shared isolation mode (the #1750 macOS
# case) so bridge_agent_workdir honors the explicit value.
: >"$BRIDGE_ROSTER_FILE"
{
  printf '%s\n' '# Smoke roster — issue #1750'
  printf 'BRIDGE_AGENT_IDS=("%s" "%s")\n' "$ADMIN" "$PAIR"
  printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$ADMIN"
  printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$PAIR"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$ADMIN"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="codex"\n' "$PAIR"
  printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$ADMIN" "$ADMIN"
  printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$PAIR" "$PAIR"
  printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$ADMIN"
  printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$PAIR"
  printf 'BRIDGE_AGENT_ISOLATION_MODE["%s"]="shared"\n' "$ADMIN"
  printf 'BRIDGE_AGENT_ISOLATION_MODE["%s"]="shared"\n' "$PAIR"
  printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$ADMIN" "$SHARED_WORKDIR"
  printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$PAIR" "$SHARED_WORKDIR"
} >>"$BRIDGE_ROSTER_FILE"

# ---------------------------------------------------------------------------
# Driver: source bridge-lib.sh + call bridge_layout_sync_identity_from_home with
# an explicit target, exactly the way bridge-start.sh invokes it on start.
# ---------------------------------------------------------------------------
SYNC_DRIVER="$SMOKE_TMP_ROOT/run-sync.sh"
: >"$SYNC_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"; AGENT="$2"; ENGINE="$3"; TARGET="$4"'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' 'bridge_load_roster'
  printf '%s\n' '# Confirm the pair resolves its workdir to the shared (admin) workspace.'
  printf '%s\n' 'printf "resolved_workdir=%s\\n" "$(bridge_agent_workdir "$AGENT")"'
  printf '%s\n' 'bridge_layout_sync_identity_from_home "$AGENT" "$ENGINE" "$TARGET" || true'
}  >"$SYNC_DRIVER"
chmod +x "$SYNC_DRIVER"

run_sync() {
  local agent="$1" engine="$2" target="$3"
  shift 3
  env "$@" \
    "$BRIDGE_BASH" "$SYNC_DRIVER" "$REPO_ROOT" "$agent" "$engine" "$target" \
    2>"$SMOKE_TMP_ROOT/sync.stderr"
}

workdir_soul_head() {
  head -n1 "$SHARED_WORKDIR/SOUL.md" 2>/dev/null
}
workdir_session_type() {
  grep -E 'Session Type:[[:space:]]*[A-Za-z0-9._-]+' "$SHARED_WORKDIR/SESSION-TYPE.md" \
    2>/dev/null | head -n1
}

# ===========================================================================
# T1 — pair start must NOT overwrite the admin's workdir identity.
# ===========================================================================
# Make the pair's HOME copies strictly newer than the admin's workdir copies so
# the #1417 mtime guard (HOME-newer) would, absent the #1750 guard, propagate.
touch -t 200001010000 "$SHARED_WORKDIR/SOUL.md" "$SHARED_WORKDIR/SESSION-TYPE.md" "$SHARED_WORKDIR/CLAUDE.md"
# (PAIR_HOME files keep their fresh mtime from the seed above.)

T1_OUT="$(run_sync "$PAIR" codex "$SHARED_WORKDIR")" \
  || smoke_fail "T1: sync driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/sync.stderr"))"

smoke_assert_contains "$T1_OUT" "resolved_workdir=$SHARED_WORKDIR" \
  "T1: pair did not resolve its workdir to the shared admin workspace"

smoke_assert_eq "# patch Soul" "$(workdir_soul_head)" \
  "T1: pair start OVERWROTE the admin workdir SOUL.md with the codex-pair template (#1750)"
smoke_assert_contains "$(workdir_session_type)" "Session Type: admin" \
  "T1: pair start OVERWROTE the admin workdir SESSION-TYPE.md (got non-admin type) (#1750)"
smoke_assert_contains "$(head -n1 "$SHARED_WORKDIR/CLAUDE.md")" "# patch — Manager/admin role" \
  "T1: pair start OVERWROTE the admin workdir CLAUDE.md with the codex-pair role line (#1750)"
# Byte-identical to the admin's authoritative HOME copy.
if ! cmp -s -- "$ADMIN_HOME/SOUL.md" "$SHARED_WORKDIR/SOUL.md"; then
  smoke_fail "T1: admin workdir SOUL.md diverged from the admin HOME copy after the pair start (#1750)"
fi
if ! cmp -s -- "$ADMIN_HOME/SESSION-TYPE.md" "$SHARED_WORKDIR/SESSION-TYPE.md"; then
  smoke_fail "T1: admin workdir SESSION-TYPE.md diverged from the admin HOME copy after the pair start (#1750)"
fi
# And the codex-pair tokens must be ABSENT from the workdir copies.
if grep -q "patch-dev" "$SHARED_WORKDIR/SOUL.md" "$SHARED_WORKDIR/SESSION-TYPE.md" "$SHARED_WORKDIR/CLAUDE.md" 2>/dev/null; then
  smoke_fail "T1: the codex-pair (patch-dev) identity leaked into the admin workdir copies (#1750)"
fi

smoke_log "T1 PASS — pair start left the admin workdir identity intact"

# ===========================================================================
# T2 — admin's OWN start still reconciles workdir from HOME (#1417 preserved).
# The owner is allowed to refresh its own identity copy on the shared workdir.
# ===========================================================================
# Edit the admin HOME onboarding line and make HOME strictly newer.
{
  printf '%s\n' '# Session Type'
  printf '%s\n' ''
  printf '%s\n' '- Session Type: admin'
  printf '%s\n' '- Onboarding State: pending'
  printf '%s\n' '- Engine: claude'
} >"$ADMIN_HOME/SESSION-TYPE.md"
touch -t 200001010000 "$SHARED_WORKDIR/SESSION-TYPE.md"   # workdir older than HOME

run_sync "$ADMIN" claude "$SHARED_WORKDIR" >/dev/null \
  || smoke_fail "T2: admin sync driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/sync.stderr"))"

smoke_assert_contains "$(workdir_session_type)" "Session Type: admin" \
  "T2: admin self-sync corrupted the workdir SESSION-TYPE (must stay admin)"
smoke_assert_contains "$(grep 'Onboarding State' "$SHARED_WORKDIR/SESSION-TYPE.md" 2>/dev/null)" "pending" \
  "T2: admin's own HOME edit did not propagate to its workdir copy (#1417 regressed)"

smoke_log "T2 PASS — admin self-sync still propagates HOME edits to its own workdir (#1417 intact)"

# ===========================================================================
# TEETH — disable the #1750 guard and confirm the pre-fix divergence returns.
# ===========================================================================
# Reset the workdir to the admin's correct identity, then run the pair start
# with the guard disabled. The pair's codex template MUST now clobber the admin.
write_admin_identity "$SHARED_WORKDIR"
touch -t 200001010000 "$SHARED_WORKDIR/SOUL.md" "$SHARED_WORKDIR/SESSION-TYPE.md" "$SHARED_WORKDIR/CLAUDE.md"

run_sync "$PAIR" codex "$SHARED_WORKDIR" BRIDGE_LAYOUT_DISABLE_FOREIGN_GUARD_1750=1 >/dev/null \
  || smoke_fail "TEETH: guard-disabled sync driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/sync.stderr"))"

TEETH_SOUL="$(workdir_soul_head)"
TEETH_STYPE="$(workdir_session_type)"
if [[ "$TEETH_SOUL" != "# patch-dev Soul" ]] \
    || [[ "$TEETH_STYPE" != *"static-codex"* ]]; then
  smoke_fail "TEETH: with the #1750 guard disabled the pre-fix divergence did NOT reproduce — the smoke would pass even if the guard were removed (got SOUL='$TEETH_SOUL' SESSION-TYPE='$TEETH_STYPE'). The test has no teeth."
fi

smoke_log "TEETH PASS — disabling the #1750 guard reproduces the codex-pair divergence (the guard is load-bearing)"

smoke_log "PASS: $SMOKE_NAME (T1, T2, TEETH)"
