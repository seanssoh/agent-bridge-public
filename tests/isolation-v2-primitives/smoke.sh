#!/usr/bin/env bash
# tests/isolation-v2-primitives/smoke.sh
#
# PR-A acceptance test for the v2 isolation primitives in
# lib/bridge-isolation-v2.sh. Verifies, without root and without
# touching the live install:
#
#   1. Legacy default (BRIDGE_LAYOUT unset / "legacy") leaves all v2
#      helpers in no-op state.
#   2. With BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT set, layout_summary
#      reports the v2 fields and the path variables derive correctly.
#   3. bridge_with_private_umask runs the wrapped command under umask
#      007 and restores the saved umask on success AND on failure.
#   4. bridge_with_shared_umask runs under umask 027 and restores
#      similarly.
#   5. bridge_isolation_v2_chgrp_setgid_recursive sets dir-mode (with
#      setgid) and file-mode on a tempdir tree, when run with the
#      caller's own primary group (which doesn't need root).
#   6. agent_group_name composition.
#   7. group_exists / user_in_group helpers do not error out and
#      return non-zero for non-existent group/user pairs.
#
# Skipped when bash<4, getfacl/setfacl based assumptions, or when the
# operator's primary group cannot be exercised.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log() { printf '[isolation-v2] %s\n' "$*"; }
die() { printf '[isolation-v2][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[isolation-v2][skip] %s\n' "$*"; exit 0; }
ok() { printf '[isolation-v2] ok: %s\n' "$*"; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required (have ${BASH_VERSION})"
fi

TMP_ROOT="$(mktemp -d -t isolation-v2-primitives.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

# Source the v2 module standalone — no full bridge-lib.sh sourcing so
# we don't pull in roster/agents state that PR-A is not supposed to
# touch yet.
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-isolation-v2.sh" \
  || die "failed to source lib/bridge-isolation-v2.sh"

# bridge_warn comes from bridge-core.sh; provide a stub so this test
# runs without sourcing the rest of the lib.
bridge_warn() { printf '[bridge_warn] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. legacy default: helpers no-op
# ---------------------------------------------------------------------------

unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2
unset BRIDGE_CONTROLLER_STATE_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-isolation-v2.sh"

if bridge_isolation_v2_active; then
  die "v2 should be inactive when BRIDGE_LAYOUT and BRIDGE_DATA_ROOT are unset"
fi
ok "legacy default: bridge_isolation_v2_active returns non-zero"

summary_legacy="$(bridge_isolation_v2_layout_summary)"
[[ "$summary_legacy" == "layout=legacy" ]] \
  || die "legacy layout_summary unexpected: $summary_legacy"
ok "legacy default: layout_summary reports legacy"

# ---------------------------------------------------------------------------
# 2. v2 active: derived path variables + summary
# ---------------------------------------------------------------------------

export BRIDGE_LAYOUT=v2
export BRIDGE_DATA_ROOT="$TMP_ROOT/srv-agent-bridge"
unset BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-isolation-v2.sh"

bridge_isolation_v2_active \
  || die "v2 should be active with BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT set"
ok "v2 active: bridge_isolation_v2_active returns 0"

[[ "$BRIDGE_SHARED_ROOT" == "$BRIDGE_DATA_ROOT/shared" ]] \
  || die "shared root mismatch: $BRIDGE_SHARED_ROOT"
[[ "$BRIDGE_AGENT_ROOT_V2" == "$BRIDGE_DATA_ROOT/agents" ]] \
  || die "agent root mismatch: $BRIDGE_AGENT_ROOT_V2"
[[ "$BRIDGE_CONTROLLER_STATE_ROOT" == "$BRIDGE_DATA_ROOT/state" ]] \
  || die "controller state root mismatch: $BRIDGE_CONTROLLER_STATE_ROOT"
ok "v2 active: derived path variables resolve correctly"

summary_v2="$(bridge_isolation_v2_layout_summary)"
[[ "$summary_v2" == *"layout=v2"* ]] \
  || die "v2 layout_summary missing layout=v2: $summary_v2"
[[ "$summary_v2" == *"data_root=$BRIDGE_DATA_ROOT"* ]] \
  || die "v2 layout_summary missing data_root: $summary_v2"
ok "v2 active: layout_summary reports v2 fields"

# ---------------------------------------------------------------------------
# 3. bridge_with_private_umask: success + failure restore
# ---------------------------------------------------------------------------

saved_before_private="$(umask)"

# Success path.
captured=""
captured="$(bridge_with_private_umask bash -c 'umask')"
[[ "$captured" == "0007" ]] || die "private umask body did not see 007 (got $captured)"
[[ "$(umask)" == "$saved_before_private" ]] \
  || die "private umask not restored after success (now $(umask))"
ok "bridge_with_private_umask: applies 007 + restores on success"

# Failure path: wrapped command exits non-zero.
set +e
captured_failed_private="$(bridge_with_private_umask bash -c 'umask; exit 7')"
rc=$?
set -e
[[ "$rc" == 7 ]] || die "private umask failure rc not propagated (got $rc)"
[[ "$captured_failed_private" == "0007" ]] \
  || die "private umask body did not see 007 on failure path (got $captured_failed_private)"
[[ "$(umask)" == "$saved_before_private" ]] \
  || die "private umask not restored after failure (now $(umask))"
ok "bridge_with_private_umask: restores umask on failure path"

# ---------------------------------------------------------------------------
# 4. bridge_with_shared_umask: success + failure restore
# ---------------------------------------------------------------------------

saved_before_shared="$(umask)"

captured="$(bridge_with_shared_umask bash -c 'umask')"
[[ "$captured" == "0027" ]] || die "shared umask body did not see 027 (got $captured)"
[[ "$(umask)" == "$saved_before_shared" ]] \
  || die "shared umask not restored after success (now $(umask))"
ok "bridge_with_shared_umask: applies 027 + restores on success"

set +e
captured_failed_shared="$(bridge_with_shared_umask bash -c 'umask; exit 13')"
rc=$?
set -e
[[ "$rc" == 13 ]] || die "shared umask failure rc not propagated (got $rc)"
[[ "$captured_failed_shared" == "0027" ]] \
  || die "shared umask body did not see 027 on failure path (got $captured_failed_shared)"
[[ "$(umask)" == "$saved_before_shared" ]] \
  || die "shared umask not restored after failure (now $(umask))"
ok "bridge_with_shared_umask: restores umask on failure path"

# ---------------------------------------------------------------------------
# 5. chgrp_setgid_recursive — uses caller's primary group (no root needed)
# ---------------------------------------------------------------------------

caller_group="$(id -gn 2>/dev/null || true)"
if [[ -n "$caller_group" ]]; then
  tree_root="$TMP_ROOT/setgid-tree"
  mkdir -p "$tree_root/sub"
  : > "$tree_root/file.txt"
  : > "$tree_root/sub/inner.txt"

  # Regression for r1 review #1: when changing to the caller's own
  # primary group on a tempdir tree the caller owns, POSIX permits the
  # operation directly. Run this WITHOUT relying on sudo by stubbing
  # out `sudo` to fail; a passing run proves the helper goes through
  # the direct path first and does not silently require sudo.
  #
  # PR #919 readiness gate: this test exercises the rootless chgrp
  # primitive directly. The discriminator's readiness probe would
  # short-circuit on a fresh CI host without an ab-shared group,
  # so force the cache to "yes" — we're not testing readiness here,
  # we're testing the chgrp/chmod behavior on a tree the caller owns.
  (
    export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=yes
    sudo() { return 127; }
    export -f sudo
    bridge_isolation_v2_chgrp_setgid_recursive \
      "$caller_group" 2750 0640 "$tree_root"
  ) || die "chgrp_setgid_recursive: rootless primary-group path required sudo (regression r1#1)"

  # Dir mode (sticky bit + group rwx). On most Linuxes octal 2750 is
  # rendered as `2750`; macOS may differ slightly. Accept any 4-digit
  # mode where the second digit is 7 (group rwx) and the leading digit
  # is 2 (setgid).
  root_mode="$(stat -c '%a' "$tree_root" 2>/dev/null || stat -f '%Lp' "$tree_root" 2>/dev/null)"
  case "$root_mode" in
    2750|02750) ok "chgrp_setgid_recursive: root dir mode 2750" ;;
    *) die "chgrp_setgid_recursive: dir mode unexpected: $root_mode" ;;
  esac

  file_mode="$(stat -c '%a' "$tree_root/file.txt" 2>/dev/null || stat -f '%Lp' "$tree_root/file.txt" 2>/dev/null)"
  case "$file_mode" in
    640|0640) ok "chgrp_setgid_recursive: file mode 0640" ;;
    *) die "chgrp_setgid_recursive: file mode unexpected: $file_mode" ;;
  esac

  inner_mode="$(stat -c '%a' "$tree_root/sub" 2>/dev/null || stat -f '%Lp' "$tree_root/sub" 2>/dev/null)"
  case "$inner_mode" in
    2750|02750) ok "chgrp_setgid_recursive: nested dir mode 2750" ;;
    *) die "chgrp_setgid_recursive: nested dir mode unexpected: $inner_mode" ;;
  esac
else
  log "skipping chgrp_setgid_recursive test: cannot determine caller's primary group"
fi

# ---------------------------------------------------------------------------
# 6. agent_group_name composition
# ---------------------------------------------------------------------------

name="$(bridge_isolation_v2_agent_group_name "sales_sean")"
[[ "$name" == "ab-agent-sales_sean" ]] \
  || die "agent_group_name composition unexpected: $name"
ok "agent_group_name: composes ab-agent-<name>"

# Override prefix.
BRIDGE_AGENT_GROUP_PREFIX="custom-agent-" \
  name2="$(bridge_isolation_v2_agent_group_name "x")"
[[ "$name2" == "custom-agent-x" ]] \
  || die "agent_group_name prefix override failed: $name2"
ok "agent_group_name: respects prefix override"

# ---------------------------------------------------------------------------
# 7. group_exists + user_in_group: graceful negatives
# ---------------------------------------------------------------------------

bogus_group="bogus-bridge-group-$$-$(date +%s)"
if bridge_isolation_v2_group_exists "$bogus_group"; then
  die "group_exists returned 0 for nonexistent group $bogus_group"
fi
ok "group_exists: returns non-zero for nonexistent group"

bogus_user="bogus-bridge-user-$$-$(date +%s)"
if bridge_isolation_v2_user_in_group "$bogus_user" "$bogus_group"; then
  die "user_in_group returned 0 for bogus user/group pair"
fi
ok "user_in_group: returns non-zero for bogus user/group"

# ---------------------------------------------------------------------------
# 8. legacy regression — sourcing module does not change BRIDGE_HOME
# ---------------------------------------------------------------------------

# This is a very thin smoke check: BRIDGE_HOME is not set or modified
# by the v2 module. The full bridge-lib.sh sets a default for it, but
# the v2 module itself MUST NOT.
unset BRIDGE_HOME
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-isolation-v2.sh"
[[ -z "${BRIDGE_HOME:-}" ]] \
  || die "v2 module unexpectedly set BRIDGE_HOME: $BRIDGE_HOME"
ok "legacy regression: v2 module does not set BRIDGE_HOME"

# ---------------------------------------------------------------------------
# 9. legacy default does not pollute child env (r2 ITEM 1)
# ---------------------------------------------------------------------------

# Re-source under legacy default and confirm no v2 group vars leak into
# a fresh child shell. Pre-r2 this leaked BRIDGE_SHARED_GROUP=ab-shared
# etc. unconditionally; gated exports must not.
(
  unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT
  unset BRIDGE_SHARED_GROUP BRIDGE_CONTROLLER_GROUP BRIDGE_AGENT_GROUP_PREFIX
  unset BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/bridge-isolation-v2.sh"

  leaked="$(bash -c 'env | grep -E "^BRIDGE_(SHARED|CONTROLLER|AGENT)_(GROUP|ROOT|ROOT_V2|STATE_ROOT|GROUP_PREFIX)=" || true')"
  [[ -z "$leaked" ]] \
    || die "legacy default leaks v2 env vars to child: $leaked"
) || exit 1
ok "legacy default does not leak v2 group exports to child env"

# ---------------------------------------------------------------------------
# 10. chgrp_setgid_dir single-dir variant (r2 ITEM 8)
# ---------------------------------------------------------------------------

if [[ -n "$caller_group" ]]; then
  single_dir="$TMP_ROOT/setgid-single"
  mkdir -p "$single_dir"
  # PR #919 readiness gate: same rationale as the recursive variant
  # above — testing chgrp/chmod behavior on caller-owned tree, not
  # fresh-host readiness skip. Force the cache "yes" for this call.
  (
    export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=yes
    bridge_isolation_v2_chgrp_setgid_dir "$caller_group" 2750 "$single_dir"
  ) || die "chgrp_setgid_dir: failed on rootless primary-group path"
  single_mode="$(stat -c '%a' "$single_dir" 2>/dev/null || stat -f '%Lp' "$single_dir" 2>/dev/null)"
  case "$single_mode" in
    2750|02750|750) ok "chgrp_setgid_dir: applied mode (got $single_mode)" ;;
    *) die "chgrp_setgid_dir: dir mode unexpected: $single_mode" ;;
  esac
else
  log "skipping chgrp_setgid_dir test: cannot determine caller's primary group"
fi

# ---------------------------------------------------------------------------
# 11. _ensure_group basic shape — root only (r2 ITEM 8)
# ---------------------------------------------------------------------------

# Sudo path requires interactive password on most dev workstations, so
# only exercise the root branch. Idempotency check guarantees the
# rc=9-as-success path (ITEM 2) is covered when the second call hits
# an existing group.
if [[ "$(id -u)" -eq 0 ]] && command -v groupadd >/dev/null 2>&1; then
  test_group="bridge-test-group-$$-$(date +%s)"
  bridge_isolation_v2_ensure_group "$test_group" \
    || die "ensure_group failed for fresh group $test_group"
  bridge_isolation_v2_group_exists "$test_group" \
    || die "ensure_group did not actually create $test_group"
  bridge_isolation_v2_ensure_group "$test_group" \
    || die "ensure_group not idempotent on existing group"
  command -v groupdel >/dev/null 2>&1 && groupdel "$test_group" 2>/dev/null || true
  ok "ensure_group: creates fresh group + idempotent"
else
  log "skipping ensure_group test: not running as root (sudo path requires interactive password)"
fi

# ---------------------------------------------------------------------------
# 12. umask wrapper survives caller's set -e (r2 ITEM 5)
# ---------------------------------------------------------------------------

# Pre-r2 the wrapper set umask, ran "$@", then restored umask post-hoc.
# Under `set -e` in the caller, a non-zero rc from "$@" terminated the
# function before the restore ran. The trap-RETURN rewrite must guarantee
# restore on every exit path, including errexit propagation.
saved_before_seteset="$(umask)"
(
  set -e
  prev_umask="$(umask)"
  bridge_with_private_umask bash -c 'exit 23' || true
  [[ "$(umask)" == "$prev_umask" ]] \
    || { printf '[isolation-v2][error] set -e: umask not restored after failure (now %s, expected %s)\n' "$(umask)" "$prev_umask" >&2; exit 1; }
) || die "umask wrapper did not restore under caller's set -e"
[[ "$(umask)" == "$saved_before_seteset" ]] \
  || die "outer umask drifted after subshell test (now $(umask))"
ok "umask wrapper restores under caller's set -e"

log "all PR-A acceptance checks passed"
