#!/usr/bin/env bash
# scripts/smoke/dynamic-agent-shared-mode-workdir.sh — issue #895 regression.
#
# Asserts that `bridge_agent_workdir` resolves the v2 anchor only for
# `linux-user`-isolated agents and falls through to the operator's
# explicit `BRIDGE_AGENT_WORKDIR[<agent>]` for `shared`-mode agents.
#
# Before the fix (v0.13.9 and earlier): the v2 anchor branch fired
# unconditionally whenever `$BRIDGE_AGENT_ROOT_V2` was set, regardless
# of the agent's isolation mode. `agb --claude --name <agent>` from a
# project directory captured the operator's cwd into
# `BRIDGE_AGENT_WORKDIR[<agent>]` (agent-bridge:1199), but
# `bridge_agent_workdir` silently rewrote it to
# `$BRIDGE_AGENT_ROOT_V2/<agent>/workdir` — leaving the agent in an
# empty stub with the operator's project invisible. The whole dynamic
# ad-hoc spawn UX was broken for fresh projects, since `--prefer new`
# is gated on `STATIC_CANDIDATES > 0` and offers no escape hatch.
#
# After the fix: linux-user keeps the v2 anchor (privacy invariant —
# the per-agent group / mode-2750 layout IS the isolation contract),
# while shared (and any other non-linux-user mode) falls through to
# the explicit-then-default resolution.
#
# Coverage:
#   1. shared mode + explicit cwd → resolver returns the explicit cwd
#      (the bug-fix path).
#   2. linux-user mode + explicit cwd → resolver returns the v2 anchor
#      (the privacy-preserving path, must NOT regress).
#   3. NO isolation mode entry at all + explicit cwd → resolver returns
#      the explicit cwd. `bridge_agent_isolation_mode` normalizes the
#      missing/empty roster value to `shared` (lib/bridge-agents.sh:799-
#      802), so the default-fallback contract must behave identically
#      to case 1. Without this case, a future edit that special-cases
#      "explicit shared" but forgets the unset path could silently
#      regress dynamic spawn for fresh-install agents.
#   4. static shared legacy row + default-home workdir + existing v2
#      workdir → resolver returns the v2 workdir, preserving pre-#895
#      static agent state/cwd layout.
#   5. static shared custom explicit cwd + existing v2 workdir → resolver
#      still returns the custom cwd, so the legacy alignment does not
#      blanket-rewrite explicit project overrides.
#
# All cases are asserted because one-sided coverage would let any
# direction silently break the other.

set -uo pipefail

SMOKE_NAME="dynamic-agent-shared-mode-workdir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ binary. The library re-execs itself on Bash 3, but
# routing through the right interpreter up front gives clearer failure
# output and matches the pattern used by `agent-registry.sh`.
BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

# Synthetic cwds the launcher would normally capture from $PWD. Each
# lives under the smoke's TMP root so cleanup reaps them.
SHARED_CWD="$SMOKE_TMP_ROOT/fake-project-shared"
LU_CWD="$SMOKE_TMP_ROOT/fake-project-lu"
UNSET_CWD="$SMOKE_TMP_ROOT/fake-project-unset"
STATIC_CUSTOM_CWD="$SMOKE_TMP_ROOT/fake-project-static-custom"
mkdir -p "$SHARED_CWD" "$LU_CWD" "$UNSET_CWD" "$STATIC_CUSTOM_CWD"

# Drive the resolver inside a fresh Bash 4+ shell that sources the full
# library tree. We deliberately keep the controller-shell scope free of
# the BRIDGE_AGENT_* assoc arrays so the source step owns the type
# declarations (`declare -g -A`) — re-declaring them in the outer scope
# would risk type drift across smoke runs.
#
# isolation_mode argument semantics:
#   * "shared" / "linux-user"  — set BRIDGE_AGENT_ISOLATION_MODE[<agent>]
#     to that literal value.
#   * ""  (empty)              — do NOT set BRIDGE_AGENT_ISOLATION_MODE
#     at all. Exercises the no-mode roster default which
#     `bridge_agent_isolation_mode` normalizes to "shared" per
#     lib/bridge-agents.sh:799-802. This is the case a roster row that
#     omits `isolation_mode=` would hit at runtime.
run_resolver() {
  local agent="$1"
  local isolation_mode="$2"
  local explicit_workdir="$3"

  local isolation_line=""
  if [[ -n "$isolation_mode" ]]; then
    isolation_line="BRIDGE_AGENT_ISOLATION_MODE[$agent]=$isolation_mode"
  fi

  "$BASH4_BIN" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1

    # Wipe any roster state the library auto-loaded (BRIDGE_HOME is
    # empty in this smoke but bridge-lib still seeds the maps).
    bridge_reset_roster_maps

    # Inject the fixture agent. Keys are unquoted on purpose under
    # \`set -u\` (quoted single-token assoc-array keys are evaluated as
    # variable references by Bash 5).
    BRIDGE_AGENT_IDS+=($agent)
    BRIDGE_AGENT_ENGINE[$agent]=claude
    BRIDGE_AGENT_SESSION[$agent]=$agent
    BRIDGE_AGENT_WORKDIR[$agent]='$explicit_workdir'
    $isolation_line

    bridge_agent_workdir '$agent'
  "
}

# ----------------------------------------------------------------------
# Case 1 — shared mode honors the explicit cwd (issue #895 fix).
# ----------------------------------------------------------------------

shared_agent="shared_test"
shared_resolved="$(run_resolver "$shared_agent" "shared" "$SHARED_CWD")" \
  || smoke_fail "shared-mode resolver invocation failed (resolved='$shared_resolved')"

smoke_assert_eq "$SHARED_CWD" "$shared_resolved" \
  "shared-mode + explicit cwd: resolver returns the operator's cwd (issue #895 fix)"

# Defense-in-depth: explicit must NOT have been rewritten to the v2 anchor.
shared_anchor="$BRIDGE_AGENT_ROOT_V2/$shared_agent/workdir"
smoke_assert_not_contains "$shared_resolved" "$BRIDGE_AGENT_ROOT_V2" \
  "shared-mode resolver must not return any path under \$BRIDGE_AGENT_ROOT_V2 ($shared_anchor)"

smoke_log "case 1: shared mode → explicit cwd honored (resolved=$shared_resolved)"

# ----------------------------------------------------------------------
# Case 2 — linux-user mode keeps the v2 anchor (privacy invariant).
# ----------------------------------------------------------------------

lu_agent="lu_test"
lu_resolved="$(run_resolver "$lu_agent" "linux-user" "$LU_CWD")" \
  || smoke_fail "linux-user resolver invocation failed (resolved='$lu_resolved')"

lu_expected="$BRIDGE_AGENT_ROOT_V2/$lu_agent/workdir"
smoke_assert_eq "$lu_expected" "$lu_resolved" \
  "linux-user + explicit cwd: resolver returns the v2 anchor (privacy invariant preserved)"

# Defense-in-depth: explicit cwd must NOT have leaked through.
smoke_assert_not_contains "$lu_resolved" "$LU_CWD" \
  "linux-user resolver must not return the operator's cwd ($LU_CWD); v2 anchor wins"

smoke_log "case 2: linux-user mode → v2 anchor preserved (resolved=$lu_resolved)"

# ----------------------------------------------------------------------
# Case 3 — no isolation_mode entry → default-fallback honors explicit cwd.
#
# `bridge_agent_isolation_mode` (lib/bridge-agents.sh:799-802) normalizes
# empty / missing roster values to `shared`, so the resolver must behave
# identically to Case 1 even when `BRIDGE_AGENT_ISOLATION_MODE[<agent>]`
# is never set. This pins the default-fallback contract so a future
# special-case for an explicitly-set `shared` literal cannot silently
# regress dynamic spawn for fresh-install agents whose roster row omits
# `isolation_mode=`.
# ----------------------------------------------------------------------

unset_agent="unset_test"
unset_resolved="$(run_resolver "$unset_agent" "" "$UNSET_CWD")" \
  || smoke_fail "no-mode resolver invocation failed (resolved='$unset_resolved')"

smoke_assert_eq "$UNSET_CWD" "$unset_resolved" \
  "no isolation_mode entry + explicit cwd: resolver returns the operator's cwd (normalized to shared per bridge_agent_isolation_mode)"

# Defense-in-depth: explicit must NOT have been rewritten to the v2 anchor.
unset_anchor="$BRIDGE_AGENT_ROOT_V2/$unset_agent/workdir"
smoke_assert_not_contains "$unset_resolved" "$BRIDGE_AGENT_ROOT_V2" \
  "no-mode resolver must not return any path under \$BRIDGE_AGENT_ROOT_V2 ($unset_anchor)"

smoke_log "case 3: no isolation_mode entry → explicit cwd honored (resolved=$unset_resolved)"

# ----------------------------------------------------------------------
# Case 4 — static shared legacy rows with default-home workdir align back
# to the existing v2 workdir. This is the static-agent exception to the
# dynamic shared-mode behavior pinned above.
# ----------------------------------------------------------------------

legacy_agent="static_legacy"
legacy_default_home="$BRIDGE_AGENT_HOME_ROOT/$legacy_agent"
legacy_expected="$BRIDGE_AGENT_ROOT_V2/$legacy_agent/workdir"
mkdir -p "$legacy_default_home" "$legacy_expected"

legacy_resolved="$(run_resolver "$legacy_agent" "shared" "$legacy_default_home")" \
  || smoke_fail "static legacy shared resolver invocation failed (resolved='$legacy_resolved')"

smoke_assert_eq "$legacy_expected" "$legacy_resolved" \
  "static shared legacy default-home row: resolver returns existing v2 workdir"

smoke_log "case 4: static shared legacy default-home row → v2 workdir aligned (resolved=$legacy_resolved)"

# ----------------------------------------------------------------------
# Case 5 — static shared custom explicit cwd remains explicit even when a
# v2 workdir exists. This keeps the #895 fix from turning into a blanket
# rollback for shared-mode agents with project-specific cwd.
# ----------------------------------------------------------------------

custom_agent="static_custom"
custom_expected="$BRIDGE_AGENT_ROOT_V2/$custom_agent/workdir"
mkdir -p "$custom_expected"

custom_resolved="$(run_resolver "$custom_agent" "shared" "$STATIC_CUSTOM_CWD")" \
  || smoke_fail "static custom shared resolver invocation failed (resolved='$custom_resolved')"

smoke_assert_eq "$STATIC_CUSTOM_CWD" "$custom_resolved" \
  "static shared custom explicit cwd: resolver keeps project override despite existing v2 workdir"

smoke_log "case 5: static shared custom explicit cwd → explicit cwd honored (resolved=$custom_resolved)"

# ----------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------

smoke_log "PASS — bridge_agent_workdir branches correctly on isolation mode (issue #895)"
