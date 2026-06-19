#!/usr/bin/env bash
# 1971-macos-group-create-gate.sh — regression smoke for #1971:
# gate ab-* OS-group CREATE to Linux (macOS has no real UID isolation),
# and clean up the inert macOS ab-* groups a pre-#1971 install left behind.
#
# Root cause (#1971): group CREATE (`bridge_isolation_v2_ensure_group`)
# was ungated while v2 ENFORCE (chgrp/setgid/ACL) is Linux-only, so a
# macOS install eagerly provisioned ab-shared / ab-controller /
# ab-agent-<a> groups that were never load-bearing (0 files owned) —
# inert cruft in "Users & Groups".
#
# Coverage:
#   T1 — Darwin platform → bridge_isolation_v2_ensure_group is a success
#        no-op: returns 0 AND the darwin create helper is NEVER invoked.
#   T2 — Linux platform → the create path is NOT gated off: the platform
#        gate passes and the (Linux) creation primitive is attempted
#        (no regression to Linux iso-v2 provisioning).
#   T3 — Cleanup removes an inert bridge group: ab-shared with the
#        "Agent Bridge" RealName marker and only the operator as member
#        is deleted.
#   T4 — Cleanup safety (provenance): a group whose NAME matches but
#        whose RealName lacks the "Agent Bridge" marker (operator-created)
#        is NEVER removed.
#   T5 — Cleanup safety (real member): ab-shared with a non-operator
#        member is NEVER removed.
#   T6 — Cleanup is idempotent / non-Darwin no-op: a Linux platform
#        removes nothing, and a Darwin run with no groups present removes
#        nothing — both return 0.
#
# All scripted shell is emitted via printf-to-file (no heredocs /
# here-strings) per the Bash 5.3.9 heredoc_write deadlock class
# (footgun #11).

set -uo pipefail

SMOKE_NAME="1971-macos-group-create-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# Bash 4+ interpreter (system bash on macOS is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Emit a driver script line-by-line (no heredocs).
write_driver_script() {
  local out="$1"
  shift
  : >"$out"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

# A driver sources ONLY lib/bridge-isolation-v2.sh standalone (which
# auto-sources the discriminator). bridge_warn / bridge_info / bridge_die
# come from bridge-core.sh — stub them so the module runs without the
# full bridge-lib flow. The darwin probe helpers (group_exists /
# realname / members / delete) are overridden after sourcing to drive an
# in-memory group fixture, and `uname` is forced to Darwin via a shell
# function so the cleanup orchestrator's `[[ "$(uname)" == Darwin ]]`
# guard engages on any CI runner.
common_prelude() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'cd "$REPO_ROOT"' \
    'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }' \
    'bridge_info() { printf "[info] %s\n" "$*" >&2; }' \
    'bridge_die() { printf "[die] %s\n" "$*" >&2; exit 1; }' \
    'bridge_current_user() { printf "%s" "operator"; }' \
    'source "$REPO_ROOT/lib/bridge-isolation-v2.sh" >/dev/null 2>&1 || { echo "SOURCE_FAILED"; exit 1; }'
}

run_driver() {
  local driver="$1"
  REPO_ROOT="$REPO_ROOT" "$BRIDGE_BASH" "$driver" 2>&1 || true
}

# ---------------------------------------------------------------------------
# T1 — Darwin: ensure_group is a success no-op; create helper not invoked
# ---------------------------------------------------------------------------
smoke_log "T1: Darwin platform → ensure_group success no-op, no darwin create call"

T1_DRIVER="$SMOKE_TMP_ROOT/t1.sh"
{
  common_prelude
  printf '%s\n' \
    'export BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin' \
    'bridge_isolation_discriminator_clear_cache' \
    '# Tripwire: the darwin create helper must never run under the gate.' \
    'bridge_isolation_v2_darwin_ensure_group() { echo "CREATE_CALLED:$1"; return 0; }' \
    'bridge_isolation_v2_group_exists() { return 1; }  # pretend group absent' \
    'rc=0; bridge_isolation_v2_ensure_group "ab-shared" || rc=$?' \
    'echo "rc=$rc"'
} >"$T1_DRIVER"
chmod +x "$T1_DRIVER"

T1_OUT="$(run_driver "$T1_DRIVER")"
smoke_assert_contains "$T1_OUT" "rc=0" "T1 (ensure_group returns success no-op on Darwin)"
smoke_assert_not_contains "$T1_OUT" "CREATE_CALLED" "T1 (darwin create helper must NOT run on Darwin)"
smoke_log "T1 PASS: Darwin create gated off (no-op success, no dseditgroup create)"

# ---------------------------------------------------------------------------
# T1b — Darwin + BRIDGE_ISOLATION_REQUIRED=yes: STILL gated off.
# Regression for codex r1 catch: `_bridge_isolation_v2_cred_platform_ok`
# resolves "yes" for an explicit `=yes` on ANY platform (operator opt-in
# is OS-agnostic), so the explicit Linux-platform assertion is required
# so a forced `=yes` on macOS does NOT provision the still-inert groups.
# ---------------------------------------------------------------------------
smoke_log "T1b: Darwin + BRIDGE_ISOLATION_REQUIRED=yes → STILL gated off (no create)"

T1B_DRIVER="$SMOKE_TMP_ROOT/t1b.sh"
{
  common_prelude
  printf '%s\n' \
    'export BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin' \
    'export BRIDGE_ISOLATION_REQUIRED=yes' \
    'bridge_isolation_discriminator_clear_cache' \
    'bridge_isolation_v2_darwin_ensure_group() { echo "CREATE_CALLED:$1"; return 0; }' \
    'bridge_isolation_v2_group_exists() { return 1; }  # pretend group absent' \
    'rc=0; bridge_isolation_v2_ensure_group "ab-shared" || rc=$?' \
    'echo "rc=$rc"'
} >"$T1B_DRIVER"
chmod +x "$T1B_DRIVER"

T1B_OUT="$(run_driver "$T1B_DRIVER")"
smoke_assert_contains "$T1B_OUT" "rc=0" "T1b (ensure_group success no-op on Darwin+yes)"
smoke_assert_not_contains "$T1B_OUT" "CREATE_CALLED" "T1b (Darwin+yes must STILL NOT create — no macOS UID isolation)"
smoke_log "T1b PASS: explicit =yes on macOS does not defeat the Linux-only CREATE gate"

# ---------------------------------------------------------------------------
# T2 — Linux: create path NOT gated off (no regression)
# ---------------------------------------------------------------------------
smoke_log "T2: Linux platform → create path proceeds past the gate"

T2_DRIVER="$SMOKE_TMP_ROOT/t2.sh"
{
  common_prelude
  printf '%s\n' \
    'export BRIDGE_HOST_PLATFORM_OVERRIDE=Linux' \
    'bridge_isolation_discriminator_clear_cache' \
    '# Force uname=Linux so ensure_group takes the groupadd branch (not the' \
    '# darwin branch) regardless of the real CI/host kernel.' \
    'uname() { if [[ $# -eq 0 || "${1:-}" == "-s" ]]; then printf "Linux\n"; else command uname "$@"; fi; }' \
    'bridge_isolation_v2_group_exists() { return 1; }  # pretend group absent' \
    '# Force the Linux create primitive to a recordable stub by shadowing' \
    '# the privileged tools. id -u != 0 path uses `sudo groupadd`.' \
    'id() { if [[ "${1:-}" == "-u" ]]; then echo 1000; else command id "$@"; fi; }' \
    'sudo() { echo "GROUPADD_CALLED:$*"; return 0; }' \
    'rc=0; bridge_isolation_v2_ensure_group "ab-shared" || rc=$?' \
    'echo "rc=$rc"'
} >"$T2_DRIVER"
chmod +x "$T2_DRIVER"

T2_OUT="$(run_driver "$T2_DRIVER")"
smoke_assert_contains "$T2_OUT" "GROUPADD_CALLED" "T2 (Linux create primitive IS attempted — gate passes)"
smoke_assert_contains "$T2_OUT" "groupadd" "T2 (groupadd invoked on Linux)"
smoke_log "T2 PASS: Linux create path unchanged (gate passes, groupadd attempted)"

# ---------------------------------------------------------------------------
# Cleanup fixture: an in-memory group registry the overridden darwin
# probe helpers read. Each driver seeds GROUP_<name>_REALNAME and
# GROUP_<name>_MEMBERS (space-separated) for the groups that "exist".
# ---------------------------------------------------------------------------
cleanup_prelude() {
  common_prelude
  printf '%s\n' \
    'export BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin' \
    'bridge_isolation_discriminator_clear_cache' \
    '# Force uname=Darwin so the cleanup orchestrator engages on Linux CI.' \
    'uname() { if [[ $# -eq 0 || "${1:-}" == "-s" ]]; then printf "Darwin\n"; else command uname "$@"; fi; }' \
    '# In-memory group registry. _EXISTING lists the group names present.' \
    'declare -A _REALNAME=()' \
    'declare -A _MEMBERS=()' \
    'declare -A _EXISTING=()' \
    'bridge_isolation_v2_darwin_group_exists() { [[ -n "${_EXISTING[$1]:-}" ]]; }' \
    'bridge_isolation_v2_darwin_group_realname() { printf "%s" "${_REALNAME[$1]:-}"; }' \
    'bridge_isolation_v2_darwin_group_members() { local m; for m in ${_MEMBERS[$1]:-}; do printf "%s\n" "$m"; done; }' \
    'bridge_isolation_v2_darwin_delete_group() { echo "DELETE_CALLED:$1"; unset "_EXISTING[$1]"; return 0; }'
}

# ---------------------------------------------------------------------------
# T3 — Cleanup removes an inert bridge group
# ---------------------------------------------------------------------------
smoke_log "T3: cleanup removes inert bridge ab-shared (marker + operator-only member)"

T3_DRIVER="$SMOKE_TMP_ROOT/t3.sh"
{
  cleanup_prelude
  printf '%s\n' \
    '_EXISTING[ab-shared]=1' \
    '_REALNAME[ab-shared]="Agent Bridge group ab-shared"' \
    '_MEMBERS[ab-shared]="operator"' \
    'BRIDGE_AGENT_IDS=()' \
    'bridge_isolation_v2_darwin_cleanup_inert_groups'
} >"$T3_DRIVER"
chmod +x "$T3_DRIVER"

T3_OUT="$(run_driver "$T3_DRIVER")"
smoke_assert_contains "$T3_OUT" "DELETE_CALLED:ab-shared" "T3 (inert bridge group removed)"
smoke_log "T3 PASS: inert bridge group with provenance marker + operator-only member removed"

# ---------------------------------------------------------------------------
# T4 — Cleanup safety: missing provenance marker → NOT removed
# ---------------------------------------------------------------------------
smoke_log "T4: cleanup leaves a bridge-named group lacking the 'Agent Bridge' RealName marker"

T4_DRIVER="$SMOKE_TMP_ROOT/t4.sh"
{
  cleanup_prelude
  printf '%s\n' \
    '_EXISTING[ab-shared]=1' \
    '_REALNAME[ab-shared]="My Custom Operator Group"' \
    '_MEMBERS[ab-shared]="operator"' \
    'BRIDGE_AGENT_IDS=()' \
    'bridge_isolation_v2_darwin_cleanup_inert_groups'
} >"$T4_DRIVER"
chmod +x "$T4_DRIVER"

T4_OUT="$(run_driver "$T4_DRIVER")"
smoke_assert_not_contains "$T4_OUT" "DELETE_CALLED" "T4 (no-provenance group must NOT be removed)"
smoke_log "T4 PASS: group without 'Agent Bridge' provenance marker preserved"

# ---------------------------------------------------------------------------
# T5 — Cleanup safety: real (non-operator) member → NOT removed
# ---------------------------------------------------------------------------
smoke_log "T5: cleanup leaves a bridge group that has a non-operator member"

T5_DRIVER="$SMOKE_TMP_ROOT/t5.sh"
{
  cleanup_prelude
  printf '%s\n' \
    '_EXISTING[ab-shared]=1' \
    '_REALNAME[ab-shared]="Agent Bridge group ab-shared"' \
    '_MEMBERS[ab-shared]="operator someone_else"' \
    'BRIDGE_AGENT_IDS=()' \
    'bridge_isolation_v2_darwin_cleanup_inert_groups'
} >"$T5_DRIVER"
chmod +x "$T5_DRIVER"

T5_OUT="$(run_driver "$T5_DRIVER")"
smoke_assert_not_contains "$T5_OUT" "DELETE_CALLED" "T5 (group with a real member must NOT be removed)"
smoke_log "T5 PASS: group with a non-operator member preserved (not provably inert)"

# ---------------------------------------------------------------------------
# T6 — non-Darwin no-op + idempotent missing-group no-op
# ---------------------------------------------------------------------------
smoke_log "T6: cleanup is a no-op on non-Darwin and idempotent when groups are absent"

# T6a — non-Darwin: orchestrator must early-return without touching groups.
T6A_DRIVER="$SMOKE_TMP_ROOT/t6a.sh"
{
  common_prelude
  printf '%s\n' \
    'uname() { if [[ $# -eq 0 || "${1:-}" == "-s" ]]; then printf "Linux\n"; else command uname "$@"; fi; }' \
    'bridge_isolation_v2_darwin_delete_group() { echo "DELETE_CALLED:$1"; return 0; }' \
    'BRIDGE_AGENT_IDS=()' \
    'rc=0; bridge_isolation_v2_darwin_cleanup_inert_groups || rc=$?' \
    'echo "rc=$rc"'
} >"$T6A_DRIVER"
chmod +x "$T6A_DRIVER"

T6A_OUT="$(run_driver "$T6A_DRIVER")"
smoke_assert_contains "$T6A_OUT" "rc=0" "T6a (non-Darwin cleanup returns 0)"
smoke_assert_not_contains "$T6A_OUT" "DELETE_CALLED" "T6a (non-Darwin cleanup must not delete)"

# T6b — Darwin, no groups present: nothing deleted, returns 0.
T6B_DRIVER="$SMOKE_TMP_ROOT/t6b.sh"
{
  cleanup_prelude
  printf '%s\n' \
    'BRIDGE_AGENT_IDS=()' \
    'rc=0; bridge_isolation_v2_darwin_cleanup_inert_groups || rc=$?' \
    'echo "rc=$rc"'
} >"$T6B_DRIVER"
chmod +x "$T6B_DRIVER"

T6B_OUT="$(run_driver "$T6B_DRIVER")"
smoke_assert_contains "$T6B_OUT" "rc=0" "T6b (Darwin no-group cleanup returns 0)"
smoke_assert_not_contains "$T6B_OUT" "DELETE_CALLED" "T6b (no groups present → nothing deleted)"
smoke_log "T6 PASS: non-Darwin no-op + idempotent missing-group no-op"

# ---------------------------------------------------------------------------
# T7 — exercise the REAL dscl parsers (not stubs) against the documented
# macOS multi-line `dscl -read` output. Regression for codex r2 catch:
# macOS prints a multi-WORD value ("Agent Bridge group ab-shared", which
# every bridge RealName is) on a CONTINUATION line with a leading space,
# so a naive `sed 's/^RealName: //'` returned empty → provenance check
# failed → cleanup silently skipped every group. Here we shim only `dscl`
# (with the real continuation-line format) and call the actual
# bridge_isolation_v2_darwin_group_realname / _members functions.
# ---------------------------------------------------------------------------
smoke_log "T7: real dscl parsers handle multi-line RealName / GroupMembership"

T7_DRIVER="$SMOKE_TMP_ROOT/t7.sh"
{
  common_prelude
  printf '%s\n' \
    '# Shim `dscl` to emit the documented macOS continuation-line format:' \
    '#   RealName:\n Agent Bridge group ab-shared   (multi-word → continuation)' \
    '#   GroupMembership: operator extra            (single line, space-joined)' \
    'dscl() {' \
    '  # args: . -read /Groups/<name> <Attr>' \
    '  local grp="${3##*/}" attr="${4:-}"' \
    '  case "$grp/$attr" in' \
    '    ab-shared/RealName)         printf "RealName:\n Agent Bridge group ab-shared\n" ;;' \
    '    ab-shared/GroupMembership)  printf "GroupMembership: operator helper_acct\n" ;;' \
    '    ab-controller/RealName)     printf "RealName: AgentBridge\n" ;;       # single-word inline form' \
    '    ab-controller/GroupMembership) printf "GroupMembership:\n operator\n" ;;  # continuation form' \
    '    *) return 1 ;;' \
    '  esac' \
    '}' \
    'rn_shared="$(bridge_isolation_v2_darwin_group_realname ab-shared)"' \
    'echo "rn_shared=[$rn_shared]"' \
    'rn_ctrl="$(bridge_isolation_v2_darwin_group_realname ab-controller)"' \
    'echo "rn_ctrl=[$rn_ctrl]"' \
    'mem_shared="$(bridge_isolation_v2_darwin_group_members ab-shared | tr "\n" "," )"' \
    'echo "mem_shared=[$mem_shared]"' \
    'mem_ctrl="$(bridge_isolation_v2_darwin_group_members ab-controller | tr "\n" "," )"' \
    'echo "mem_ctrl=[$mem_ctrl]"'
} >"$T7_DRIVER"
chmod +x "$T7_DRIVER"

T7_OUT="$(run_driver "$T7_DRIVER")"
# Continuation-form RealName must parse to the full multi-word value.
smoke_assert_contains "$T7_OUT" "rn_shared=[Agent Bridge group ab-shared]" "T7 (multi-word RealName parsed from continuation line)"
# Inline single-word form still parses.
smoke_assert_contains "$T7_OUT" "rn_ctrl=[AgentBridge]" "T7 (inline single-word RealName parsed)"
# Members: both a real (non-operator) member and the operator must appear —
# a dropped member would defeat the safety gate.
smoke_assert_contains "$T7_OUT" "mem_shared=[operator,helper_acct,]" "T7 (single-line multi-member parsed, none dropped)"
smoke_assert_contains "$T7_OUT" "mem_ctrl=[operator,]" "T7 (continuation-form single member parsed)"
smoke_log "T7 PASS: real dscl parsers handle both inline + continuation forms"

smoke_log "ALL PASS"
