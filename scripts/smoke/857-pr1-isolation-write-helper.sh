#!/usr/bin/env bash
# Issue #857 PR-1 — regression smoke for bridge_isolation_write_file_as_agent_user_via_bash.
#
# Coverage:
#   Default mocked-sudo cases (always run):
#     A1 — happy path: write content, mode 0600 default, no temp leak.
#     A2 — custom mode 0640 propagates to the published file.
#     A3 — destination directory missing -> caller-visible rc=5
#          (script-band rc, preserved unchanged per the read helper
#          convention — only rc=1/2 are shifted into the 3+ band).
#     A4 — empty stdin content (cat - on /dev/null) -> success with empty file.
#     A5 — sudo policy denial via shim rc=1 -> caller-visible rc=2.
#     A6 — pre-check returns rc=1 (not isolated) -> caller-visible rc=1.
#     A7 — pre-check returns rc=2 (isolated, no sudo) -> caller-visible rc=2.
#   Real two-UID case (env-gated, skipped otherwise):
#     B1 — write to a tmp dir as BRIDGE_ISOLATION_HELPERS_TEST_UID via real sudo
#          and verify file owner via stat.

set -uo pipefail

SMOKE_NAME="857-pr1-isolation-write-helper"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# --- harness helpers ---------------------------------------------------------

# Build a PATH directory containing a `sudo` shim. The shim strips `-n -u
# <user>` and execs the remaining command as the current user, so the helper's
# `sudo -n -u <user> bash -c "$script" bridge-isolation <dest> <mode>`
# invocation actually runs the inline write script. SHIM_RC=0 means the shim
# transparently exec's; SHIM_RC=1 simulates a sudo policy denial (rc=1, no
# exec).
build_sudo_shim() {
  local dir="$1"
  local shim_rc="$2"
  mkdir -p "$dir"
  # NOTE: emitted via printf to a file (NOT a heredoc) to stay clear of the
  # footgun #11 surface (Bash 5.3.9 heredoc_write deadlock class). The shim
  # body itself is a small bash program, so emitting it line-by-line via
  # printf into a target file is the safest form here.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Mocked sudo for smoke test #857 PR-1. Strips -n -u <user>'
    printf '%s\n' '# and execs the remainder as the current user.'
    printf 'shim_rc=%s\n' "$shim_rc"
    printf '%s\n' 'if [[ "$shim_rc" -ne 0 ]]; then'
    printf '%s\n' '  exit "$shim_rc"'
    printf '%s\n' 'fi'
    printf '%s\n' 'args=()'
    printf '%s\n' 'skip_next=0'
    printf '%s\n' 'for arg in "$@"; do'
    printf '%s\n' '  if [[ "$skip_next" -eq 1 ]]; then'
    printf '%s\n' '    skip_next=0'
    printf '%s\n' '    continue'
    printf '%s\n' '  fi'
    printf '%s\n' '  case "$arg" in'
    printf '%s\n' '    -n) ;;'
    printf '%s\n' '    -u) skip_next=1 ;;'
    printf '%s\n' '    *) args+=("$arg") ;;'
    printf '%s\n' '  esac'
    printf '%s\n' 'done'
    printf '%s\n' 'exec "${args[@]}"'
  } >"$dir/sudo"
  chmod +x "$dir/sudo"
}

# Source the helper into the current shell with mocked predicates so we can
# call bridge_isolation_write_file_as_agent_user_via_bash directly. Each test
# re-imports a fresh copy because we may want to flip predicate stubs.
import_helper_with_mocks() {
  local can_sudo_rc="$1"
  local os_user="$2"
  # We re-source the helper file but then redefine the predicates so the
  # write helper's pre-check sees our stubs. The helper file does NOT
  # define these predicates itself — they live in lib/bridge-agents.sh —
  # so a bare source + stub definition is sufficient.
  # shellcheck source=lib/bridge-isolation-helpers.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-isolation-helpers.sh"
  eval "bridge_isolation_can_sudo_to_agent() { return $can_sudo_rc; }"
  eval "bridge_agent_os_user() { printf '%s' '$os_user'; }"
  # The stub below is invoked indirectly by the real
  # bridge_isolation_can_sudo_to_agent (when that mock isn't taken).
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }
}

# --- case A1: happy path -----------------------------------------------------

case_a1_happy_path_default_mode() {
  local tmp dest content actual_content actual_mode rc
  tmp="$SMOKE_TMP_ROOT/a1"
  mkdir -p "$tmp"
  dest="$tmp/payload.env"
  content="hello-from-pr1"
  rc=0
  printf '%s\n' "$content" | bridge_isolation_write_file_as_agent_user_via_bash \
    agent-test "$dest" || rc=$?
  smoke_assert_eq 0 "$rc" "A1: helper returns 0 on success"
  smoke_assert_file_exists "$dest" "A1: destination file created"
  actual_content="$(cat "$dest")"
  smoke_assert_eq "$content" "$actual_content" "A1: content roundtrips through stdin pipe"
  actual_mode="$(stat -f '%Lp' "$dest" 2>/dev/null || stat -c '%a' "$dest")"
  smoke_assert_eq "600" "$actual_mode" "A1: default mode 0600 applied"
  # No temp leak in the dest dir (only `payload.env` should remain).
  local leak
  leak="$(find "$tmp" -name '.payload.env.bridge-write-tmp.*' -print 2>/dev/null | head -n 1)"
  [[ -z "$leak" ]] || smoke_fail "A1: temp file leak detected: $leak"
}

# --- case A2: custom mode ----------------------------------------------------

case_a2_custom_mode() {
  local tmp dest rc actual_mode
  tmp="$SMOKE_TMP_ROOT/a2"
  mkdir -p "$tmp"
  dest="$tmp/payload.env"
  rc=0
  printf 'k=v\n' | bridge_isolation_write_file_as_agent_user_via_bash \
    agent-test "$dest" 0640 || rc=$?
  smoke_assert_eq 0 "$rc" "A2: helper returns 0 with custom mode"
  actual_mode="$(stat -f '%Lp' "$dest" 2>/dev/null || stat -c '%a' "$dest")"
  smoke_assert_eq "640" "$actual_mode" "A2: custom mode 0640 propagated"
}

# --- case A3: destination directory missing ----------------------------------

case_a3_dest_dir_missing() {
  local tmp dest rc
  tmp="$SMOKE_TMP_ROOT/a3"
  # NOTE: intentionally do NOT mkdir the dest dir.
  dest="$tmp/missing-subdir/payload.env"
  rc=0
  printf 'irrelevant\n' | bridge_isolation_write_file_as_agent_user_via_bash \
    agent-test "$dest" || rc=$?
  # rc=5 is the script-band exit for missing dest dir; the wrapper only
  # shifts rcs 1 and 2 into the 3+ band, so rc=5 reaches the caller as 5
  # (read helper convention preserved).
  smoke_assert_eq 5 "$rc" "A3: missing dest dir -> caller-visible rc=5"
  [[ ! -f "$dest" ]] || smoke_fail "A3: dest file unexpectedly created"
}

# --- case A4: empty stdin content --------------------------------------------

case_a4_empty_stdin() {
  local tmp dest rc actual_size
  tmp="$SMOKE_TMP_ROOT/a4"
  mkdir -p "$tmp"
  dest="$tmp/empty.env"
  rc=0
  bridge_isolation_write_file_as_agent_user_via_bash \
    agent-test "$dest" </dev/null || rc=$?
  smoke_assert_eq 0 "$rc" "A4: empty stdin write returns 0"
  smoke_assert_file_exists "$dest" "A4: empty file created"
  actual_size="$(wc -c <"$dest" | tr -d ' ')"
  smoke_assert_eq "0" "$actual_size" "A4: empty file is zero bytes"
}

# --- case A5: sudo shim denies ----------------------------------------------

case_a5_sudo_denial() {
  local tmp dest rc
  tmp="$SMOKE_TMP_ROOT/a5"
  mkdir -p "$tmp"
  dest="$tmp/should-not-exist.env"
  rc=0
  printf 'ignored\n' | bridge_isolation_write_file_as_agent_user_via_bash \
    agent-test "$dest" || rc=$?
  # Helper short-circuits on the bridge_isolation_can_sudo_to_agent stub when
  # it returns rc=2, so the caller sees rc=2 BEFORE the sudo shim is ever
  # invoked. To reach the "sudo invoked but rc=1" branch we have to make
  # can_sudo return 0 AND use a denying shim — see case A5b below; in this
  # case A5 keeps the pre-check happy and exercises the shim-denial path.
  smoke_assert_eq 3 "$rc" "A5: sudo shim returns 1 -> +2 shift -> caller rc=3 (script-band)"
  [[ ! -f "$dest" ]] || smoke_fail "A5: dest unexpectedly created on sudo denial"
}

# --- case A6: pre-check says not isolated ------------------------------------

case_a6_not_isolated() {
  local tmp dest rc
  tmp="$SMOKE_TMP_ROOT/a6"
  mkdir -p "$tmp"
  dest="$tmp/payload.env"
  rc=0
  printf 'ignored\n' | bridge_isolation_write_file_as_agent_user_via_bash \
    agent-test "$dest" || rc=$?
  smoke_assert_eq 1 "$rc" "A6: pre-check rc=1 -> caller rc=1 (caller falls back to direct write)"
  [[ ! -f "$dest" ]] || smoke_fail "A6: dest unexpectedly created"
}

# --- case A7: pre-check says no sudo -----------------------------------------

case_a7_no_sudo() {
  local tmp dest rc
  tmp="$SMOKE_TMP_ROOT/a7"
  mkdir -p "$tmp"
  dest="$tmp/payload.env"
  rc=0
  printf 'ignored\n' | bridge_isolation_write_file_as_agent_user_via_bash \
    agent-test "$dest" || rc=$?
  smoke_assert_eq 2 "$rc" "A7: pre-check rc=2 -> caller rc=2"
  [[ ! -f "$dest" ]] || smoke_fail "A7: dest unexpectedly created"
}

# --- case B1: real two-UID write --------------------------------------------

case_b1_real_two_uid() {
  local test_uid_user="${BRIDGE_ISOLATION_HELPERS_TEST_UID:-}"
  if [[ -z "$test_uid_user" ]]; then
    smoke_log "skip B1: BRIDGE_ISOLATION_HELPERS_TEST_UID unset"
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    smoke_log "skip B1: sudo not on PATH"
    return 0
  fi
  if ! sudo -n -u "$test_uid_user" bash -c 'exit 0' 2>/dev/null; then
    smoke_log "skip B1: passwordless sudo to $test_uid_user unavailable"
    return 0
  fi

  local tmp dest rc actual_owner
  tmp="$SMOKE_TMP_ROOT/b1"
  mkdir -p "$tmp"
  # The dest dir must be writable by $test_uid_user. The simplest portable
  # arrangement is to chmod 0777 so the isolated UID can drop a temp file
  # there; the actual file ownership check is what we care about.
  chmod 0777 "$tmp"
  dest="$tmp/real.env"

  # Stub predicates to declare $test_uid_user as the agent's os_user and
  # short-circuit the linux-user-isolation predicate.
  # shellcheck source=lib/bridge-isolation-helpers.sh
  source "$SMOKE_REPO_ROOT/lib/bridge-isolation-helpers.sh"
  # Stubs invoked indirectly by the real isolation helper code path.
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }
  # shellcheck disable=SC2329
  bridge_agent_os_user() { printf '%s' "$test_uid_user"; }
  # Let bridge_isolation_can_sudo_to_agent run for real here.

  rc=0
  printf 'real-two-uid-write\n' | bridge_isolation_write_file_as_agent_user_via_bash \
    agent-test "$dest" || rc=$?
  smoke_assert_eq 0 "$rc" "B1: real two-UID write returns 0"
  smoke_assert_file_exists "$dest" "B1: dest file created"
  actual_owner="$(stat -f '%Su' "$dest" 2>/dev/null || stat -c '%U' "$dest")"
  smoke_assert_eq "$test_uid_user" "$actual_owner" "B1: dest owned by isolated UID"
}

# --- main --------------------------------------------------------------------

main() {
  smoke_setup_bridge_home "857-pr1-isolation-write-helper"

  # Build a per-test sudo shim directory and prepend to PATH. The shim only
  # needs to exist on PATH while the helper invokes sudo, so we keep the
  # original PATH around and switch in setup.
  local shim_dir_ok shim_dir_deny
  shim_dir_ok="$SMOKE_TMP_ROOT/sudo-shim-ok"
  shim_dir_deny="$SMOKE_TMP_ROOT/sudo-shim-deny"
  build_sudo_shim "$shim_dir_ok" 0
  build_sudo_shim "$shim_dir_deny" 1

  local original_path="$PATH"

  # Cases A1, A2, A3, A4: pre-check OK, shim execs cleanly.
  (
    PATH="$shim_dir_ok:$original_path"
    import_helper_with_mocks 0 "$(id -un)"
    case_a1_happy_path_default_mode
    case_a2_custom_mode
    case_a3_dest_dir_missing
    case_a4_empty_stdin
  ) || smoke_fail "A1-A4 sub-shell failed"
  smoke_log "ok: A1-A4 (default-mode write, custom mode, missing-dir rc=5, empty stdin)"

  # Case A5: pre-check OK, shim returns 1.
  (
    PATH="$shim_dir_deny:$original_path"
    import_helper_with_mocks 0 "$(id -un)"
    case_a5_sudo_denial
  ) || smoke_fail "A5 sub-shell failed"
  smoke_log "ok: A5 (sudo shim denial)"

  # Case A6: pre-check says not isolated -> caller rc=1 BEFORE sudo invoked.
  (
    PATH="$shim_dir_ok:$original_path"
    import_helper_with_mocks 1 "$(id -un)"
    case_a6_not_isolated
  ) || smoke_fail "A6 sub-shell failed"
  smoke_log "ok: A6 (pre-check not-isolated short-circuits to rc=1)"

  # Case A7: pre-check says no sudo -> caller rc=2 BEFORE sudo invoked.
  (
    PATH="$shim_dir_ok:$original_path"
    import_helper_with_mocks 2 "$(id -un)"
    case_a7_no_sudo
  ) || smoke_fail "A7 sub-shell failed"
  smoke_log "ok: A7 (pre-check no-sudo short-circuits to rc=2)"

  # Case B1: real two-UID via env gate (skip with explicit log when unset).
  (
    PATH="$original_path"
    case_b1_real_two_uid
  ) || smoke_fail "B1 sub-shell failed"

  smoke_log "passed"
}

main "$@"
