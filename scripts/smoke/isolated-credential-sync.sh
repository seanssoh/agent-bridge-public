#!/usr/bin/env bash
# v0.13.6 hotfix track 5 (PR #883) — regression smoke for the
# isolation-aware credential-sync path in bridge-auth.sh.
#
# Coverage (mocked sudo + mocked isolation predicates):
#   A1 — isolated agent: bridge_auth_sync_agents writes the credential
#        file via bridge_isolation_write_file_as_agent_user_via_bash, and
#        the file content equals the JSON payload emitted by
#        ``bridge-auth.py emit-credential-payload``.
#   A2 — non-isolated agent: bridge_auth_sync_agent_python is exercised
#        (call counted via a stub), the isolated helper is NOT invoked,
#        and the file is written.
#   A3 — emit-credential-payload alone: registry with active token ->
#        payload JSON on stdout with the documented shape
#        (claudeAiOauth.accessToken + expiresAt + scopes).
#   A4 — emit-credential-payload alone: registry with no active token ->
#        rc=1, stdout empty, '[error]' on stderr.
#
# Notes:
#   - No heredoc / here-string anywhere in the test body (footgun #11).
#   - Mock predicates are defined AFTER sourcing bridge-lib.sh so they
#     win in the function table. bridge_auth_sync_agents itself is
#     untouched.
#   - The sudo shim mirrors PR #861 PR-1's pattern: strips ``-n -u
#     <user>`` and exec's the remaining command as the current user, so
#     the real isolation write helper actually runs its inline write
#     script (but as the smoke caller's UID).

set -uo pipefail

SMOKE_NAME="isolated-credential-sync"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# --- sudo shim builder -------------------------------------------------------

# Mirrors PR #861 PR-1's harness: build a directory containing a ``sudo``
# shim that drops ``-n -u <user>`` and exec's the remaining argv as the
# current user. SHIM_RC=0 means the shim transparently exec's; any other
# value short-circuits and returns it (simulates sudoers denial).
build_sudo_shim() {
  local dir="$1"
  local shim_rc="$2"
  mkdir -p "$dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Mocked sudo for isolated-credential-sync smoke.'
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

# --- registry helper ---------------------------------------------------------

# Write a minimal token registry with one active token. We piggy-back on
# the real ``bridge-auth.py add`` so the registry shape stays in sync
# with whatever cmd_add writes (version, normalization, etc.).
seed_registry_with_active_token() {
  local registry="$1"
  local token="$2"
  # ``add`` reads the token from stdin; emit it via printf (no heredoc).
  printf '%s\n' "$token" | python3 \
    "$SMOKE_REPO_ROOT/bridge-auth.py" \
    --registry "$registry" add --id test-token --stdin --activate >/dev/null
}

# --- case A3: emit-credential-payload happy path -----------------------------

case_a3_emit_payload_happy() {
  local registry payload exit_rc
  registry="$SMOKE_TMP_ROOT/a3/reg.json"
  mkdir -p "$(dirname "$registry")"
  seed_registry_with_active_token "$registry" "sk-fake-token-very-long-enough"
  exit_rc=0
  payload="$(python3 "$SMOKE_REPO_ROOT/bridge-auth.py" --registry "$registry" \
    emit-credential-payload --agent some-agent)" || exit_rc=$?
  smoke_assert_eq 0 "$exit_rc" "A3: emit-credential-payload rc=0"
  smoke_assert_contains "$payload" '"claudeAiOauth"' "A3: payload contains claudeAiOauth"
  smoke_assert_contains "$payload" '"accessToken": "sk-fake-token-very-long-enough"' \
    "A3: payload contains the active token"
  smoke_assert_contains "$payload" '"expiresAt": 4102444800000' "A3: payload contains expiresAt"
  smoke_assert_contains "$payload" '"user:inference"' "A3: payload contains inference scope"
  smoke_assert_contains "$payload" '"user:profile"' "A3: payload contains profile scope"
}

# --- case A4: emit-credential-payload no active token ------------------------

case_a4_emit_payload_no_active() {
  local registry exit_rc stdout_out stderr_out
  registry="$SMOKE_TMP_ROOT/a4/reg.json"
  mkdir -p "$(dirname "$registry")"
  # Write an empty registry that ``load_registry`` will normalize.
  printf '{}\n' >"$registry"
  exit_rc=0
  # Capture stdout and stderr separately to assert error shape without
  # heredoc/here-string. We redirect stderr to a tempfile.
  local stderr_file="$SMOKE_TMP_ROOT/a4/stderr"
  stdout_out="$(python3 "$SMOKE_REPO_ROOT/bridge-auth.py" --registry "$registry" \
    emit-credential-payload --agent some-agent 2>"$stderr_file")" || exit_rc=$?
  stderr_out="$(cat "$stderr_file")"
  smoke_assert_eq 1 "$exit_rc" "A4: emit-credential-payload rc=1 on empty registry"
  smoke_assert_eq "" "$stdout_out" "A4: stdout is empty when active token missing"
  smoke_assert_contains "$stderr_out" "no active token id" \
    "A4: stderr names the missing-active-token failure mode"
}

# --- bridge-auth.sh sourcing harness -----------------------------------------

# We need to source bridge-auth.sh's helper functions WITHOUT triggering
# its top-level command dispatch. bridge-auth.sh's bottom calls
# ``case "$command" in ... esac`` after argv parsing; we work around
# this by setting an empty argv and re-sourcing the file in a sub-shell
# context that runs only the function-definition phase via a guard.
#
# Simpler approach: define a wrapper that sources bridge-lib.sh + the
# helper function bodies directly. bridge-auth.sh's helpers are
# well-encapsulated bash functions — we extract them by sourcing the
# full file in a sub-shell with a stub ``case`` that catches the
# dispatch. The cleanest way is to set the BRIDGE_AUTH_SMOKE_SOURCE_ONLY
# guard — but that doesn't exist yet, and we don't want to add a
# top-level guard to bridge-auth.sh just for smoke. Instead we source
# bridge-lib.sh ourselves and then ``source`` bridge-auth.sh with the
# trailing dispatch tail trimmed off via sed-on-tempfile (NO sed
# redirection chain — we write the trimmed copy explicitly).
import_bridge_auth_helpers() {
  local repo_root="$SMOKE_REPO_ROOT"
  local stripped="$SMOKE_TMP_ROOT/bridge-auth-helpers-only.sh"
  # Stripping logic lives in a sibling fixture script — keeping it out
  # of this file avoids embedding a Python heredoc here (footgun #11:
  # heredoc/here-string into shell-side contexts).
  #
  # Anchor on a locally-resolved path rather than the top-level
  # SCRIPT_DIR global; the helper reassigns SCRIPT_DIR to
  # $SMOKE_REPO_ROOT below before sourcing the stripped bridge-auth.sh,
  # and we want to stay correct regardless of caller ordering.
  local fixture_dir
  fixture_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/isolated-credential-sync-helpers"
  # Strip:
  #   - the top-of-file ``source bridge-lib.sh`` chain (we source it
  #     ourselves from the real repo root so SCRIPT_DIR-relative paths
  #     resolve correctly);
  #   - the trailing ``command="${1:-}"`` argv dispatch (we want only
  #     function defs, not the CLI).
  python3 "$fixture_dir/strip-bridge-auth-dispatch.py" \
    "$repo_root/bridge-auth.sh" "$stripped"
  # Pre-source bridge-lib.sh against the real repo so SCRIPT_DIR resolves
  # to $SMOKE_REPO_ROOT, then re-anchor SCRIPT_DIR for the bridge-auth
  # helper bodies (they use $SCRIPT_DIR/bridge-auth.py from inside the
  # isolated and non-isolated sync paths).
  # shellcheck source=bridge-lib.sh
  source "$SMOKE_REPO_ROOT/bridge-lib.sh"
  SCRIPT_DIR="$SMOKE_REPO_ROOT"
  # shellcheck disable=SC1090
  source "$stripped"
}

# --- case A1 helpers ---------------------------------------------------------

# Stub predicates that mimic the isolated agent. The real
# ``bridge_agent_linux_user_isolation_effective`` requires a Linux host
# AND a v2 roster entry; we mock it to return 0. ``bridge_agent_os_user``
# returns the smoke caller's own username so the sudo shim's exec
# succeeds.
mock_agent_isolated() {
  local agent_name="$1"
  local os_user
  os_user="$(id -un)"
  # shellcheck disable=SC2329
  eval "bridge_agent_linux_user_isolation_effective() { [[ \"\$1\" == \"$agent_name\" ]]; }"
  # shellcheck disable=SC2329
  eval "bridge_agent_os_user() { printf '%s' '$os_user'; }"
  # bridge_isolation_can_sudo_to_agent's positive branch needs both
  # predicates above + the sudo shim. Force-stub it to rc=0 (sudo OK).
  # shellcheck disable=SC2329
  bridge_isolation_can_sudo_to_agent() { return 0; }
  # The credential file path resolution helper needs an existing
  # agent-home root we control. Mock it to a smoke-owned tempdir.
  # shellcheck disable=SC2329
  eval "bridge_auth_claude_credentials_file_for_agent() {
    printf '%s' '$SMOKE_TMP_ROOT/agents/$agent_name/home/.claude/.credentials.json'
  }"
  # Mock prepare to just mkdir -p the parent — the real implementation
  # uses bridge_auth_run_privileged which needs the v2 isolation API on
  # the host. We just need the dir present for the write helper.
  # shellcheck disable=SC2329
  eval "bridge_auth_prepare_credential_file() {
    mkdir -p \"\$(dirname \"\$2\")\" || return 1
    return 0
  }"
  # Mock the legacy env update to no-op (we're not exercising it).
  # shellcheck disable=SC2329
  bridge_auth_update_legacy_claude_config_env() { return 0; }
  # Mock the legacy file path helper.
  # shellcheck disable=SC2329
  eval "bridge_auth_legacy_secret_env_file_for_agent() {
    printf '%s' '$SMOKE_TMP_ROOT/agents/\$1/legacy.env'
  }"
  # Selected agents — make the selector return our test agent regardless
  # of spec.
  # shellcheck disable=SC2329
  eval "bridge_auth_selected_agents() { printf '%s\n' '$agent_name'; }"
}

mock_agent_not_isolated() {
  local agent_name="$1"
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 1; }
  # shellcheck disable=SC2329
  eval "bridge_auth_claude_credentials_file_for_agent() {
    printf '%s' '$SMOKE_TMP_ROOT/agents/$agent_name/home/.claude/.credentials.json'
  }"
  # shellcheck disable=SC2329
  eval "bridge_auth_prepare_credential_file() {
    mkdir -p \"\$(dirname \"\$2\")\" || return 1
    return 0
  }"
  # Track that the python path was invoked — write a marker file and
  # do a passable credential write so the caller's success path runs.
  # shellcheck disable=SC2329
  eval "bridge_auth_sync_agent_python() {
    : >'$SMOKE_TMP_ROOT/python-path-called'
    printf '{\"status\":\"synced\"}\n'
    printf 'mocked-python-credential-write' >\"\$3\"
    return 0
  }"
  # Track that the isolated path was NOT invoked.
  # shellcheck disable=SC2329
  eval "bridge_auth_sync_agent_isolated_via_sudo() {
    : >'$SMOKE_TMP_ROOT/isolated-path-called'
    printf 'should_not_be_called\n'
    return 1
  }"
  # shellcheck disable=SC2329
  bridge_auth_update_legacy_claude_config_env() { return 0; }
  # shellcheck disable=SC2329
  eval "bridge_auth_legacy_secret_env_file_for_agent() {
    printf '%s' '$SMOKE_TMP_ROOT/agents/\$1/legacy.env'
  }"
  # shellcheck disable=SC2329
  eval "bridge_auth_selected_agents() { printf '%s\n' '$agent_name'; }"
}

# --- case A1: isolated agent end-to-end --------------------------------------

case_a1_isolated_writes_via_helper() {
  local registry token cred_file expected actual rc
  local agent_name="smoke-isolated-agent"
  registry="$SMOKE_TMP_ROOT/a1/reg.json"
  mkdir -p "$(dirname "$registry")"
  token="sk-fake-isolated-token-very-long-enough"
  seed_registry_with_active_token "$registry" "$token"

  mock_agent_isolated "$agent_name"

  cred_file="$SMOKE_TMP_ROOT/agents/$agent_name/home/.claude/.credentials.json"
  # Marker to detect that bridge_auth_sync_agent_python was NOT called
  # in the isolated branch.
  rm -f "$SMOKE_TMP_ROOT/python-path-called"
  # shellcheck disable=SC2329
  eval "bridge_auth_sync_agent_python() {
    : >'$SMOKE_TMP_ROOT/python-path-called'
    printf 'python_path_called_unexpectedly\n'
    return 1
  }"

  rc=0
  bridge_auth_sync_agents "$registry" "$agent_name" 0 >/dev/null 2>&1 || rc=$?
  smoke_assert_eq 0 "$rc" "A1: bridge_auth_sync_agents returns 0 for isolated agent"
  smoke_assert_file_exists "$cred_file" "A1: credential file written"
  [[ ! -f "$SMOKE_TMP_ROOT/python-path-called" ]] \
    || smoke_fail "A1: bridge_auth_sync_agent_python invoked on isolated path"

  # Compute the expected payload via emit-credential-payload itself —
  # the file must equal that bytes-for-bytes (minus the trailing newline
  # the helper writes after JSON, which is present in both sides).
  expected="$(python3 "$SMOKE_REPO_ROOT/bridge-auth.py" --registry "$registry" \
    emit-credential-payload --agent "$agent_name")"
  actual="$(cat "$cred_file")"
  # The helper's ``cat -`` preserves stdin bytes-for-bytes. The shell-
  # side wrapper uses ``printf '%s' "$payload"`` which strips the
  # trailing newline that the Python emitter appended. Compare with the
  # same normalization.
  expected_normalized="$(printf '%s' "$expected")"
  smoke_assert_eq "$expected_normalized" "$actual" \
    "A1: file content equals emit-credential-payload output (newline-stripped)"
}

# --- case A2: non-isolated agent falls through to python ---------------------

case_a2_non_isolated_uses_python() {
  local registry token cred_file rc
  local agent_name="smoke-non-isolated-agent"
  registry="$SMOKE_TMP_ROOT/a2/reg.json"
  mkdir -p "$(dirname "$registry")"
  token="sk-fake-noniso-token-very-long-enough"
  seed_registry_with_active_token "$registry" "$token"

  mock_agent_not_isolated "$agent_name"

  cred_file="$SMOKE_TMP_ROOT/agents/$agent_name/home/.claude/.credentials.json"
  rm -f "$SMOKE_TMP_ROOT/python-path-called" "$SMOKE_TMP_ROOT/isolated-path-called"

  rc=0
  bridge_auth_sync_agents "$registry" "$agent_name" 0 >/dev/null 2>&1 || rc=$?
  smoke_assert_eq 0 "$rc" "A2: bridge_auth_sync_agents returns 0 for non-isolated agent"
  smoke_assert_file_exists "$SMOKE_TMP_ROOT/python-path-called" \
    "A2: bridge_auth_sync_agent_python WAS invoked"
  [[ ! -f "$SMOKE_TMP_ROOT/isolated-path-called" ]] \
    || smoke_fail "A2: isolated path invoked on non-isolated agent"
  smoke_assert_file_exists "$cred_file" "A2: credential file written via mocked python path"
}

# --- main --------------------------------------------------------------------

main() {
  smoke_setup_bridge_home "isolated-credential-sync"

  # Always-on standalone payload cases first — no sourcing required.
  case_a3_emit_payload_happy
  smoke_log "ok: A3 (emit-credential-payload happy path)"
  case_a4_emit_payload_no_active
  smoke_log "ok: A4 (emit-credential-payload empty registry)"

  # Build sudo shim and put it on PATH.
  local shim_dir="$SMOKE_TMP_ROOT/sudo-shim"
  build_sudo_shim "$shim_dir" 0
  local original_path="$PATH"

  # A1: isolated agent end-to-end. Run in a sub-shell so the function
  # table mutations stay scoped — A2 needs a clean slate.
  (
    PATH="$shim_dir:$original_path"
    import_bridge_auth_helpers
    case_a1_isolated_writes_via_helper
  ) || smoke_fail "A1 sub-shell failed"
  smoke_log "ok: A1 (isolated agent writes via bridge_isolation_write_file_as_agent_user_via_bash)"

  # A2: non-isolated agent end-to-end. Fresh sub-shell so the A1 stubs
  # do not bleed in.
  (
    PATH="$original_path"
    import_bridge_auth_helpers
    case_a2_non_isolated_uses_python
  ) || smoke_fail "A2 sub-shell failed"
  smoke_log "ok: A2 (non-isolated agent falls through to bridge_auth_sync_agent_python)"

  smoke_log "passed"
}

main "$@"
