#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1492-admin-dev-pair-workspace-v2.sh — Issue #1492.
#
# On a v2 install the static admin agent's effective workdir is rewritten to
# its v2 workspace (`<admin>/workdir`), but the co-located `<admin>-dev` codex
# pair — whose RAW roster workdir was captured at provisioning time from the
# admin's THEN (old/base) shared cwd (`<admin>` base dir) — was treated as a
# *custom* shared cwd and did NOT follow. The pair then ran against the admin's
# pre-v2 base while the admin ran under `<admin>/workdir`, breaking the
# documented "admin + <admin>-dev share one workspace so codex pair-review sees
# the same tree" contract.
#
# This smoke pins the fix in `bridge_agent_workdir`:
#
#   T1  the `<admin>-dev` pair (raw workdir = admin base dir) RESOLVES to the
#       admin's EFFECTIVE workdir (`<admin>/workdir`) — i.e. it follows the
#       admin, never its own `<admin>-dev/workdir`.
#   T2  home/identity stay DISTINCT — the pair's default home is
#       `<admin>-dev/home`, the admin's is `<admin>/home`; only the cwd is
#       shared. (We assert the resolver does not collapse the pair onto the
#       admin's home.)
#   T3  TEETH — an UNRELATED static `*-dev` agent that is NOT the admin's pair
#       (its base is not the configured admin) keeps its own custom shared cwd;
#       it is NOT realigned onto the admin's workdir.
#   T4  TEETH — a `<admin>-dev` whose raw workdir is a GENUINELY custom path
#       (not the admin's base/old shared cwd) is preserved, not realigned.
#   T5  fresh-install scenario — a freshly-provisioned pair whose raw workdir
#       is the admin's base lands aligned to `<admin>/workdir` from the start.
#   T6  TEETH (revert detector) — when the admin-pair alignment predicate is
#       neutralized, the pair re-drifts to the admin base, proving the assert
#       has teeth.
#
# Footgun #11: driver emitted via printf-to-file, no heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1492-admin-dev-pair-workspace-v2"
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

DRIVER_DIR="$SMOKE_TMP_ROOT/driver"
mkdir -p "$DRIVER_DIR"
DRIVER="$DRIVER_DIR/driver.sh"

write_driver() {
  local out="$1"
  : >"$out"
  local line
  for line in \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'cd "$REPO_ROOT"' \
    'SCRIPT_DIR="$REPO_ROOT"' \
    'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1' \
    'declare -F bridge_agent_workdir >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_agent_workdir not loaded"; exit 91; }' \
    'declare -A BRIDGE_AGENT_WORKDIR 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_ISOLATION_MODE 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_OS_USER 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_SOURCE 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_SESSION 2>/dev/null || true' \
    '# Configured admin (drives the <admin>-dev pair detection).' \
    'BRIDGE_ADMIN_AGENT_ID="$ADMIN_ID"' \
    '# Admin: shared-mode static. Its raw roster workdir is the admin OLD/base' \
    '# shared cwd — on a real v2 install the legacy home-root base' \
    '# ($BRIDGE_AGENT_HOME_ROOT/<admin>), the value bridge_agent_workdir <admin>' \
    '# returned PRE the v2 anchor split. The generic v2 alignment then rewrites' \
    '# the admin to $BRIDGE_AGENT_ROOT_V2/<admin>/workdir once that dir exists.' \
    'BRIDGE_AGENT_SOURCE["$ADMIN_ID"]="static"' \
    'BRIDGE_AGENT_ISOLATION_MODE["$ADMIN_ID"]="shared"' \
    'BRIDGE_AGENT_WORKDIR["$ADMIN_ID"]="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_ID"' \
    '# The admin scaffold creates <admin>/workdir on disk under the v2 root.' \
    'mkdir -p "$BRIDGE_AGENT_ROOT_V2/$ADMIN_ID/workdir"' \
    '# Pair: shared-mode static, raw workdir = the admin OLD/base shared cwd' \
    '# (captured at provisioning time). It must follow the admin to' \
    '# <admin>/workdir, NOT stay at the admin base and NOT use its own dir.' \
    'BRIDGE_AGENT_SOURCE["$PAIR_ID"]="static"' \
    'BRIDGE_AGENT_ISOLATION_MODE["$PAIR_ID"]="shared"' \
    'BRIDGE_AGENT_WORKDIR["$PAIR_ID"]="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_ID"' \
    '# Unrelated static *-dev whose base is NOT the admin — custom shared cwd.' \
    'BRIDGE_AGENT_SOURCE["$OTHER_ID"]="static"' \
    'BRIDGE_AGENT_ISOLATION_MODE["$OTHER_ID"]="shared"' \
    'BRIDGE_AGENT_WORKDIR["$OTHER_ID"]="$CUSTOM_WS"' \
    'mkdir -p "$CUSTOM_WS"' \
    '' \
    'ADMIN_WD="$(bridge_agent_workdir "$ADMIN_ID")"' \
    'PAIR_WD="$(bridge_agent_workdir "$PAIR_ID")"' \
    'OTHER_WD="$(bridge_agent_workdir "$OTHER_ID")"' \
    'ADMIN_HOME="$(bridge_agent_default_home "$ADMIN_ID")"' \
    'PAIR_HOME="$(bridge_agent_default_home "$PAIR_ID")"' \
    'echo "ADMIN_WD: $ADMIN_WD"' \
    'echo "PAIR_WD: $PAIR_WD"' \
    'echo "OTHER_WD: $OTHER_WD"' \
    'echo "ADMIN_HOME: $ADMIN_HOME"' \
    'echo "PAIR_HOME: $PAIR_HOME"' \
    'echo "ADMIN_EFFECTIVE: $BRIDGE_AGENT_ROOT_V2/$ADMIN_ID/workdir"' \
    'echo "ADMIN_OLD_BASE: $BRIDGE_AGENT_HOME_ROOT/$ADMIN_ID"' \
    'echo "PAIR_OWN_WORKDIR: $BRIDGE_AGENT_ROOT_V2/$PAIR_ID/workdir"' \
    'echo "CUSTOM_WS_OUT: $CUSTOM_WS"' \
    '' \
    '# T4 TEETH: the GENUINE <admin>-dev pair ($PAIR_ID, ends in -dev) pointed at' \
    '# a custom path (not the admin base/old shared cwd) must be PRESERVED — the' \
    '# predicate only follows the admin when explicit == an admin base/old cwd.' \
    '# Reuse $PAIR_ID (real pair name) so this exercises the predicate *-dev arm,' \
    '# then restore the drifted raw workdir for T5/T6.' \
    'BRIDGE_AGENT_WORKDIR["$PAIR_ID"]="$CUSTOM_WS"' \
    'PAIR_CUSTOM_WD="$(bridge_agent_workdir "$PAIR_ID")"' \
    'echo "PAIR_CUSTOM_WD: $PAIR_CUSTOM_WD"' \
    '' \
    '# T5 fresh-install: a freshly-provisioned pair records the admin EFFECTIVE' \
    '# workdir directly (bridge-init-codex-pair.sh captures bridge_agent_workdir' \
    '# <admin> = <admin>/workdir once the v2 anchor exists). Already aligned —' \
    '# the predicate leaves it untouched and it must stay at <admin>/workdir,' \
    '# never double-resolve into <admin>/workdir/workdir.' \
    'BRIDGE_AGENT_WORKDIR["$PAIR_ID"]="$BRIDGE_AGENT_ROOT_V2/$ADMIN_ID/workdir"' \
    'PAIR_WD_FRESH="$(bridge_agent_workdir "$PAIR_ID")"' \
    'echo "PAIR_WD_FRESH: $PAIR_WD_FRESH"' \
    '# Restore the drifted (migrated-install) raw workdir for the T6 revert.' \
    'BRIDGE_AGENT_WORKDIR["$PAIR_ID"]="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_ID"' \
    '' \
    '# T6 revert detector: neutralize the admin-pair predicate and re-resolve.' \
    '_bridge_agent_workdir_admin_pair_aligns() { return 1; }' \
    'PAIR_WD_REVERTED="$(bridge_agent_workdir "$PAIR_ID")"' \
    'echo "PAIR_WD_REVERTED: $PAIR_WD_REVERTED"'
  do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

extract_line() {
  local out="$1"
  local key="$2"
  printf '%s\n' "$out" | sed -n "s/^$key: //p" | head -n 1
}

write_driver "$DRIVER"

ADMIN_ID="probe_admin"
PAIR_ID="probe_admin-dev"
# An unrelated static *-dev whose base ("probe_worker") is NOT the configured
# admin — must keep its own custom shared cwd (T3).
OTHER_ID="probe_worker-dev"
# A genuinely custom workspace path used by T3 (the unrelated *-dev) and by T4
# (the real <admin>-dev pair temporarily pointed at a custom, non-admin-base cwd).
CUSTOM_WS="$BRIDGE_DATA_ROOT/custom-project"

smoke_log "T1-T6: v2 <admin>-dev pair follows admin effective workdir; identity/home distinct; teeth"

OUT="$(
  REPO_ROOT="$REPO_ROOT" \
  DRIVER_TMP_DIR="$DRIVER_DIR" \
  ADMIN_ID="$ADMIN_ID" \
  PAIR_ID="$PAIR_ID" \
  OTHER_ID="$OTHER_ID" \
  CUSTOM_WS="$CUSTOM_WS" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
  BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
  BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
  BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
  BRIDGE_LAYOUT="v2" \
  BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT" \
  BRIDGE_SHARED_ROOT="$BRIDGE_SHARED_ROOT" \
  BRIDGE_AGENT_ROOT_V2="$BRIDGE_AGENT_ROOT_V2" \
  BRIDGE_CONTROLLER_STATE_ROOT="$BRIDGE_CONTROLLER_STATE_ROOT" \
  BRIDGE_RUNTIME_ROOT="$BRIDGE_RUNTIME_ROOT" \
  BRIDGE_HOOKS_DIR="$BRIDGE_HOOKS_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  "$BRIDGE_BASH" "$DRIVER" 2>&1
)"
RC=$?

if [[ $RC -ne 0 ]]; then
  smoke_fail "driver exited rc=$RC. output:
$OUT"
fi

ADMIN_WD="$(extract_line "$OUT" "ADMIN_WD")"
PAIR_WD="$(extract_line "$OUT" "PAIR_WD")"
OTHER_WD="$(extract_line "$OUT" "OTHER_WD")"
PAIR_CUSTOM_WD="$(extract_line "$OUT" "PAIR_CUSTOM_WD")"
ADMIN_HOME="$(extract_line "$OUT" "ADMIN_HOME")"
PAIR_HOME="$(extract_line "$OUT" "PAIR_HOME")"
ADMIN_EFFECTIVE="$(extract_line "$OUT" "ADMIN_EFFECTIVE")"
ADMIN_OLD_BASE="$(extract_line "$OUT" "ADMIN_OLD_BASE")"
PAIR_OWN_WORKDIR="$(extract_line "$OUT" "PAIR_OWN_WORKDIR")"
CUSTOM_WS_OUT="$(extract_line "$OUT" "CUSTOM_WS_OUT")"
PAIR_WD_FRESH="$(extract_line "$OUT" "PAIR_WD_FRESH")"
PAIR_WD_REVERTED="$(extract_line "$OUT" "PAIR_WD_REVERTED")"

# Sanity: the admin itself resolves to its v2 effective workdir.
smoke_assert_eq "$ADMIN_EFFECTIVE" "$ADMIN_WD" \
  "admin resolves to its v2 effective workdir (<admin>/workdir)"

# T1: the pair follows the admin's EFFECTIVE workdir, not its own.
smoke_assert_eq "$ADMIN_WD" "$PAIR_WD" \
  "T1: <admin>-dev pair RESOLVES to the admin's effective workdir (shared workspace)"
if [[ "$PAIR_WD" == "$PAIR_OWN_WORKDIR" ]]; then
  smoke_fail "T1: pair must NOT resolve to its own <admin>-dev/workdir ('$PAIR_OWN_WORKDIR'); it must follow the admin"
fi
if [[ "$PAIR_WD" == "$ADMIN_OLD_BASE" ]]; then
  smoke_fail "T1: pair must NOT stay drifted at the admin's old/base shared cwd ('$ADMIN_OLD_BASE')"
fi

# T2: identity / home stay DISTINCT — only the cwd is shared.
if [[ "$ADMIN_HOME" == "$PAIR_HOME" ]]; then
  smoke_fail "T2: pair home must stay DISTINCT from the admin home; both resolved to '$ADMIN_HOME'"
fi
smoke_assert_match "$ADMIN_HOME" "/${ADMIN_ID}/home\$" \
  "T2: admin default home is <admin>/home (its own identity source)"
smoke_assert_match "$PAIR_HOME" "/${PAIR_ID}/home\$" \
  "T2: pair default home is <admin>-dev/home (distinct identity preserved)"

# T3 TEETH: unrelated static *-dev with a custom shared cwd is NOT realigned.
smoke_assert_eq "$CUSTOM_WS_OUT" "$OTHER_WD" \
  "T3: unrelated *-dev (base != admin) keeps its custom shared cwd (NOT realigned)"

# T4 TEETH: the REAL <admin>-dev pair (probe_admin-dev — exercises the predicate
# *-dev arm) pointed at a genuinely custom path (not the admin base) is preserved.
smoke_assert_eq "$CUSTOM_WS_OUT" "$PAIR_CUSTOM_WD" \
  "T4: <admin>-dev with a genuinely custom workdir is preserved (NOT realigned)"

# T5 fresh-install: a pair already recording the admin effective workdir stays
# aligned (no double-resolve into <admin>/workdir/workdir).
smoke_assert_eq "$ADMIN_EFFECTIVE" "$PAIR_WD_FRESH" \
  "T5: freshly-provisioned pair (raw workdir = admin effective) lands aligned from the start"

# T6 TEETH: reverting the predicate re-drifts the pair to the admin old base.
smoke_assert_eq "$ADMIN_OLD_BASE" "$PAIR_WD_REVERTED" \
  "T6: neutralizing the admin-pair predicate re-drifts the pair (assert has teeth)"
if [[ "$PAIR_WD_REVERTED" == "$PAIR_WD" ]]; then
  smoke_fail "T6: revert produced the same result as the fix — the assert is toothless"
fi

smoke_log "all tests PASS — issue #1492: v2 <admin>-dev pair workspace aligns to admin effective workdir; identity/home distinct; teeth verified"
