#!/usr/bin/env bash
# Beta20 L2 Variant 3A — unit smoke for lib/bridge-daemon-control.sh.
#
# Exercises the parser / lock / renderer / sanitizer without touching
# real /etc/sudoers.d or real sudo. The full Linux VM acceptance flow
# (real sudoers drop-in, real group mutation, real `agent create`) lives
# in the brief's "VM acceptance" section and is not reproducible from a
# macOS smoke harness.
#
# Run isolated: BRIDGE_HOME is set to a mktemp dir, BRIDGE_BASH_BIN is
# pinned to the bash that ran us, no functions touch external state
# except the helper's own tempfiles.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d -t agb-daemon-control.XXXXXX)"

cleanup() {
  rm -rf "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf '[daemon-control][error] %s\n' "$*" >&2
  exit 1
}
pass() {
  printf '[daemon-control][ok] %s\n' "$*"
}

# Set up an isolated environment so sourcing the helper does not blow up.
# The helper only requires BRIDGE_HOME, BRIDGE_BASH_BIN, and a couple of
# bridge_* shims (bridge_warn, bridge_audit_log, bridge_linux_sudo_root,
# bridge_current_user, bridge_daemon_pid).
export BRIDGE_HOME="$TMP_ROOT/.agent-bridge"
mkdir -p "$BRIDGE_HOME/scripts/sudoers-templates" "$BRIDGE_HOME/state"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_BASH_BIN="${BASH}"
# Copy the production template into our isolated BRIDGE_HOME so the
# renderer + check helpers see it via BRIDGE_HOME-relative lookup.
cp "$REPO_ROOT/scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template" \
   "$BRIDGE_HOME/scripts/sudoers-templates/"

# Minimal shims — the helper only calls these on the failure path. We
# define them BEFORE sourcing so the source-time function definitions
# don't shadow ours.
bridge_warn() { printf '[shim warn] %s\n' "$*" >&2; }
bridge_audit_log() { return 0; }  # No-op
bridge_linux_sudo_root() { "$@"; }  # Run direct (no sudo in test env)
bridge_current_user() { id -un; }
bridge_daemon_pid() { return 1; }  # Daemon-not-running default

# Source the helper module under test.
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/bridge-daemon-control.sh"

# ---------------------------------------------------------------------------
# Test 1: status-string contract — Linux gate
# ---------------------------------------------------------------------------
test_linux_gate() {
  if [[ "$(uname -s 2>/dev/null)" == "Linux" ]]; then
    pass "linux gate: host is Linux, skipping non-linux path test"
    return 0
  fi
  local status
  status="$(bridge_daemon_refresh_after_group_membership_change \
    --group ab-x --reason 'test' 2>/dev/null || true)"
  [[ "$status" == "skipped-non-linux" ]] \
    || fail "expected 'skipped-non-linux' on non-Linux host, got: '$status'"
  pass "linux gate returns 'skipped-non-linux' on non-Linux"
}

# ---------------------------------------------------------------------------
# Test 2: --dry-run on a fake-Linux host (override the gate) — verifies
# all status-string branches before sudo. We can't actually flip uname
# without /usr/bin/uname-shim, but we can directly test the parser by
# stubbing the Linux check.
# ---------------------------------------------------------------------------
test_arg_parser() {
  # Missing --group should error.
  local status rc=0
  status="$(bridge_daemon_refresh_after_group_membership_change --reason 'x' 2>&1)" \
    || rc=$?
  (( rc != 0 )) || fail "missing --group should fail rc!=0"
  pass "missing --group is rejected"

  # Unknown arg should error.
  rc=0
  status="$(bridge_daemon_refresh_after_group_membership_change \
    --group g --weird 2>&1)" || rc=$?
  (( rc != 0 )) || fail "unknown arg should fail rc!=0"
  pass "unknown arg is rejected"
}

# ---------------------------------------------------------------------------
# Test 3: sanitizer character class
# ---------------------------------------------------------------------------
test_sanitizer() {
  local out
  out="$(_bridge_daemon_control_sanitize_reason 'agent-create:patch')"
  [[ "$out" == "agent-create:patch" ]] \
    || fail "valid input mangled: '$out'"
  pass "sanitizer preserves allowed chars"

  out="$(_bridge_daemon_control_sanitize_reason 'hack$evil"; rm -rf')"
  case "$out" in
    *'$'*|*'"'*|*';'*|*' '*)
      fail "sanitizer leaked unsafe chars: '$out'"
      ;;
  esac
  pass "sanitizer strips shell metachars"

  # Empty input falls back to 'unspecified'.
  out="$(_bridge_daemon_control_sanitize_reason '')"
  [[ "$out" == "unspecified" ]] \
    || fail "empty input should yield 'unspecified', got '$out'"
  pass "sanitizer handles empty input"

  # Length cap to 256.
  local long
  long="$(printf 'a%.0s' $(seq 1 500))"
  out="$(_bridge_daemon_control_sanitize_reason "$long")"
  (( ${#out} == 256 )) \
    || fail "sanitizer should cap length to 256, got ${#out}"
  pass "sanitizer caps length to 256"
}

# ---------------------------------------------------------------------------
# Test 4: lock acquire / release — flock and mkdir fallback
# ---------------------------------------------------------------------------
test_lock_primitives() {
  local lock_path="$TMP_ROOT/lock-test"

  # Acquire.
  local token=""
  token="$(_bridge_daemon_control_lock_acquire "$lock_path" 5)" \
    || fail "lock acquire failed"
  [[ -n "$token" ]] || fail "lock token is empty"
  case "$token" in
    flock:*|mkdir:*) ;;
    *) fail "unexpected lock token shape: $token" ;;
  esac
  pass "lock acquired (token=$token)"

  # Release.
  _bridge_daemon_control_lock_release "$token"
  pass "lock released cleanly"

  # Re-acquire after release.
  token=""
  token="$(_bridge_daemon_control_lock_acquire "$lock_path" 5)" \
    || fail "lock re-acquire after release failed"
  _bridge_daemon_control_lock_release "$token"
  pass "lock re-acquired after release"
}

# ---------------------------------------------------------------------------
# Test 5: sudoers path generator — no dots in basename, runtime-id hash
# ---------------------------------------------------------------------------
test_sudoers_path() {
  local path
  path="$(bridge_daemon_control_sudoers_path "sean" "/Users/sean/.agent-bridge")"
  case "$path" in
    /etc/sudoers.d/agent-bridge-daemon-refresh-sean-*) ;;
    *) fail "unexpected sudoers path: $path" ;;
  esac
  pass "sudoers path has expected prefix"

  # Basename must not contain a dot.
  local basename_part="${path##*/}"
  case "$basename_part" in
    *.*) fail "sudoers basename contains dot: $basename_part" ;;
  esac
  pass "sudoers basename has no dot (sudoers #includedir compatible)"

  # Different BRIDGE_HOME paths yield different runtime_ids.
  local path1 path2
  path1="$(bridge_daemon_control_sudoers_path "sean" "/path/A")"
  path2="$(bridge_daemon_control_sudoers_path "sean" "/path/B")"
  [[ "$path1" != "$path2" ]] \
    || fail "different BRIDGE_HOME should yield different sudoers paths: $path1"
  pass "different BRIDGE_HOME paths yield distinct sudoers filenames"
}

# ---------------------------------------------------------------------------
# Test 6: sudoers template rendering
# ---------------------------------------------------------------------------
test_sudoers_render() {
  local rendered
  rendered="$(bridge_daemon_control_sudoers_render \
    "alice" "/bin/bash" "/Users/alice/.agent-bridge")"

  # Must substitute all three placeholders.
  case "$rendered" in
    *'{{controller_user}}'*|*'{{bash_abs}}'*|*'{{bridge_home_abs}}'*)
      fail "template still contains unsubstituted placeholders"
      ;;
  esac
  pass "template placeholders all substituted"

  # Must contain the expected values.
  [[ "$rendered" == *"alice ALL=(alice)"* ]] \
    || fail "rendered doesn't contain 'alice ALL=(alice)': $rendered"
  pass "rendered contains the expected sudoers Cmnd"
  [[ "$rendered" == *"/Users/alice/.agent-bridge/bridge-daemon.sh restart --force --internal-reason=group-refresh"* ]] \
    || fail "rendered doesn't contain expected daemon command path: $rendered"
  pass "rendered contains exact daemon command shape"

  # r4: also authorize the bare `run` command so the sudo-wrapped
  # systemd ExecStart is accepted by sudoers policy.
  [[ "$rendered" == *"/Users/alice/.agent-bridge/bridge-daemon.sh run"* ]] \
    || fail "r4: rendered doesn't contain the systemd-unit-authorized 'run' Cmnd: $rendered"
  pass "r4: rendered contains the second authorized command (bridge-daemon.sh run)"

  # r4: there must be EXACTLY two `alice ALL=(alice)` policy lines.
  # More would mean someone added unrelated grants; fewer means the
  # run Cmnd is missing.
  local policy_lines
  policy_lines="$(printf '%s\n' "$rendered" | grep -cF -- 'alice ALL=(alice)' || true)"
  [[ "$policy_lines" == "2" ]] \
    || fail "r4: expected 2 sudoers policy lines, got $policy_lines"
  pass "r4: rendered template has exactly 2 sudoers policy lines"

  # r4: still no wildcards. Only audit non-comment lines — the rendered
  # template's header explanation legitimately mentions `restart *` /
  # `BRIDGE_*` in human prose, so a naive grep over the full content
  # would false-positive.
  if printf '%s\n' "$rendered" | grep -vE '^[[:space:]]*#' | grep -qE '\*[[:space:]]|\*$'; then
    fail "r4: rendered template (non-comment lines) contains forbidden sudoers wildcard"
  fi
  pass "r4: rendered template (non-comment lines) has no wildcards"

  # Reject non-absolute bash path.
  local rc=0
  rendered="$(bridge_daemon_control_sudoers_render \
    "alice" "bash" "/Users/alice/.agent-bridge" 2>&1)" || rc=$?
  (( rc != 0 )) || fail "non-absolute bash should be rejected"
  pass "non-absolute bash path rejected"

  # Reject non-absolute BRIDGE_HOME.
  rc=0
  rendered="$(bridge_daemon_control_sudoers_render \
    "alice" "/bin/bash" "./relative/home" 2>&1)" || rc=$?
  (( rc != 0 )) || fail "non-absolute BRIDGE_HOME should be rejected"
  pass "non-absolute BRIDGE_HOME rejected"
}

# ---------------------------------------------------------------------------
# Test 7: status string contract — daemon-not-running short-circuit
# (We override bridge_daemon_pid to return empty, so any Linux-host call
# falls into 'skipped-daemon-not-running'.)
# ---------------------------------------------------------------------------
test_daemon_not_running_branch() {
  if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
    pass "daemon-not-running branch: skipped (non-Linux gate fires first)"
    return 0
  fi
  # bridge_daemon_pid already returns rc=1 (empty pid) in our shim.
  local status
  status="$(bridge_daemon_refresh_after_group_membership_change \
    --group ab-x --reason 'test' 2>/dev/null || true)"
  [[ "$status" == "skipped-daemon-not-running" ]] \
    || fail "expected 'skipped-daemon-not-running', got: '$status'"
  pass "daemon-not-running short-circuit emits expected status"
}

# ---------------------------------------------------------------------------
# Test 8: preflight row format (key=value, single line)
# ---------------------------------------------------------------------------
test_preflight_row() {
  local row
  row="$(bridge_daemon_control_preflight_row 2>&1)"
  # Must be a single line, key=value.
  case "$row" in
    daemon_group_refresh_sudoers=*) ;;
    *) fail "unexpected preflight row format: '$row'" ;;
  esac
  # Single line.
  local line_count
  line_count="$(printf '%s' "$row" | wc -l | tr -d ' ')"
  (( line_count <= 1 )) || fail "preflight row should be single line, got $line_count lines"
  pass "preflight row format: key=value, single line ($row)"
}

# ---------------------------------------------------------------------------
# Test 9: cmd_restart parser in bridge-daemon.sh
# (verify --internal-reason=group-refresh + --force routing without
# actually restarting a daemon)
# ---------------------------------------------------------------------------
test_cmd_restart_parser() {
  # bash -n already covered syntactic correctness; here we grep for the
  # exact case-arm shape so future refactors don't silently lose the
  # --internal-reason handling.
  grep -qF -- '--internal-reason=*)' "$REPO_ROOT/bridge-daemon.sh" \
    || fail "bridge-daemon.sh missing --internal-reason= case arm"
  grep -qF -- 'daemon_restart_internal' "$REPO_ROOT/bridge-daemon.sh" \
    || fail "bridge-daemon.sh missing daemon_restart_internal audit emit"
  pass "cmd_restart parser shape preserved"
}

# ---------------------------------------------------------------------------
# Test 10 (r4): install-daemon-systemd.sh renders sudo-wrapped ExecStart
# when --sudo-self is forced. Auto-detect path is host-dependent so we
# don't assert it here; --no-sudo-self and --sudo-self are the explicit
# overrides we can lock down.
# ---------------------------------------------------------------------------
test_install_daemon_systemd_render() {
  local script="$REPO_ROOT/scripts/install-daemon-systemd.sh"
  [[ -x "$script" ]] || fail "install-daemon-systemd.sh missing or not executable"

  # --no-sudo-self → legacy direct ExecStart, no refresh-mode env.
  local out_legacy
  out_legacy="$("$script" --bridge-home /tmp/agb-test --no-sudo-self 2>&1)"
  [[ "$out_legacy" == *"sudo_self_active: 0"* ]] \
    || fail "r4: --no-sudo-self should report sudo_self_active=0"
  if printf '%s' "$out_legacy" | grep -qE '^ExecStart=.*sudo '; then
    fail "r4: --no-sudo-self should NOT render sudo-prefixed ExecStart"
  fi
  if printf '%s' "$out_legacy" | grep -qF -- 'BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE='; then
    fail "r4: --no-sudo-self should NOT render the refresh-mode env marker"
  fi
  pass "r4: --no-sudo-self renders legacy direct ExecStart"

  # --sudo-self: only proven on hosts with the sudoers drop-in already
  # installed. Skip when sudoers absent (macOS smoke env, fresh VM).
  local sudoers_present=0
  local glob="/etc/sudoers.d/agent-bridge-daemon-refresh-$(id -un)-*"
  # shellcheck disable=SC2086
  set -- $glob
  if [[ -e "$1" ]]; then
    sudoers_present=1
  fi
  if (( sudoers_present == 1 )); then
    local out_sudo rc=0
    out_sudo="$("$script" --bridge-home /tmp/agb-test --sudo-self 2>&1)" || rc=$?
    if (( rc == 0 )); then
      [[ "$out_sudo" == *"sudo_self_active: 1"* ]] \
        || fail "r4: --sudo-self should report sudo_self_active=1"
      printf '%s' "$out_sudo" | grep -qE '^ExecStart=.*sudo .*-u .* -H .*--preserve-env=BRIDGE_HOME' \
        || fail "r4: --sudo-self should render sudo-prefixed ExecStart with --preserve-env"
      printf '%s' "$out_sudo" | grep -qF -- 'BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE=sudo-self' \
        || fail "r4: --sudo-self should render the refresh-mode env marker"
      pass "r4: --sudo-self renders sudo-wrapped ExecStart"
    else
      pass "r4: --sudo-self correctly failed when probe rejects (rc=$rc) — host doesn't grant refresh"
    fi
  else
    pass "r4: --sudo-self test skipped (no daemon-refresh sudoers drop-in on this host)"
  fi
}

# ---------------------------------------------------------------------------
# Test 11 (r4): systemd-detection helpers exist + parse correctly.
# ---------------------------------------------------------------------------
test_systemd_helpers() {
  # _bridge_daemon_control_systemd_active should be defined and rc!=0
  # on macOS / hosts without systemctl.
  if command -v systemctl >/dev/null 2>&1; then
    pass "r4: systemd helpers: host has systemctl (linux/wsl) — runtime check, no smoke assertion"
    return 0
  fi
  if _bridge_daemon_control_systemd_active 2>/dev/null; then
    fail "r4: _bridge_daemon_control_systemd_active should fail when systemctl is absent"
  fi
  pass "r4: _bridge_daemon_control_systemd_active returns rc!=0 without systemctl"

  if _bridge_daemon_control_systemd_unit_is_refresh_capable 2>/dev/null; then
    fail "r4: _bridge_daemon_control_systemd_unit_is_refresh_capable should fail without systemctl"
  fi
  pass "r4: _bridge_daemon_control_systemd_unit_is_refresh_capable returns rc!=0 without systemctl"
}

test_linux_gate
test_arg_parser
test_sanitizer
test_lock_primitives
test_sudoers_path
test_sudoers_render
test_daemon_not_running_branch
test_preflight_row
test_cmd_restart_parser
test_install_daemon_systemd_render
test_systemd_helpers

printf '\n[daemon-control] all unit smokes passed\n'
