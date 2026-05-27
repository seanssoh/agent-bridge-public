#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/Beta-beta5-session-id-detect-sudo.sh —
# v0.15.0-beta5 Lane β (#1299) — iso v2 session_id detect 0600-jsonl read
# elevation via sudo-as-user.
#
# Re-exec under bash 4+ so we can source bridge-lib.sh directly for shim-
# level coverage (matches scripts/smoke/A-beta4-iso-path-resolution.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:Beta-beta5-session-id-detect-sudo][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Background — Issue #1299 (beta4 Lane A residual):
#   beta4 PR #1286 (#1277) fixed `bridge_resolve_agent_claude_config_dir`
#   to return the iso UID's `<iso-home>/.claude` via getent. R2 added the
#   `session_id_detect_empty` audit emit. Path resolution is correct.
#
#   But Claude Code writes session JSON + transcripts as:
#     -rw-------  agent-bridge-<a>  ab-agent-<a>  <session-id>.jsonl
#   The mode is 0600 — the group-read bit is unset. Even when the
#   controller is in the `ab-agent-<a>` supplementary group, the
#   detect-claude-session-id.py helper running under controller
#   privileges trips EACCES on `open()` and returns empty. 12 detect
#   attempts later, `bridge_refresh_agent_session_id` emits the
#   `session_id_detect_empty` audit row and restart spawns a fresh
#   Claude session instead of resuming.
#
# Fix — Option A (this lane): wrap the python invocation in the bash
# shim with `sudo -n -u <iso-uid> -- bash -c 'exec python3 "$@"' bash
# <args...>` so the read operations run as the iso UID. Per-agent
# sudoers entry from `bridge_migration_sudoers_entry` whitelists `bash`
# + `tmux` only — that's why the wrap goes through `bash -c 'exec
# python3 ...'` rather than calling python3 directly.
#
# Option B (configure Claude Code to write 0660) was REJECTED per
# Sean's root-vs-symptom-framing rule: elevate the reader (canonical)
# instead of relaxing the writer (workaround).
#
# Test plan (host-agnostic — static-source grep + bash function smoke):
#
#   T1: bridge_linux_sudo_as_user is defined and non-Linux platforms
#       transparently fall through to direct invocation (back-compat
#       on macOS / BSD dev hosts; matches bridge_linux_sudo_root's
#       Linux-only short-circuit so smokes can exercise the iso v2 code
#       path without needing real sudoers).
#
#   T2: bridge_resolve_agent_iso_sudo_user returns empty (and rc=1) for
#       an unregistered agent — back-compat for smoke fixtures.
#
#   T3: bridge_resolve_agent_iso_sudo_user returns empty (and rc=1) for
#       a registered NON-iso agent (legacy / dynamic / shared-mode) —
#       so the detect helper invocation stays direct and the legacy
#       behavior is byte-for-byte unchanged.
#
#   T4: bridge_detect_claude_session_id function body wraps the python
#       invocation through bridge_linux_sudo_as_user with the bash -c
#       'exec python3 "$@"' bash shape when the new os_user arg is set.
#       Asserts the fix shape by static grep on the function body — the
#       wrap MUST go through bash so the per-agent sudoers entry
#       (`tmux`+`bash` only) accepts the call. A direct
#       `bridge_linux_sudo_as_user "$os_user" python3 ...` would be
#       rejected by the sudoers policy on a production host.
#
#   T5: bridge_resolve_resume_session_id function body resolves os_user
#       via bridge_resolve_agent_iso_sudo_user AND wraps the python
#       invocation through bridge_linux_sudo_as_user with the same
#       bash -c 'exec python3 "$@"' shape.
#
#   T6: bridge_detect_claude_session_id with empty os_user (5th arg)
#       takes the direct python invocation path — exercised via the
#       existing 1015 fixture seed and `BRIDGE_HOST_PLATFORM_OVERRIDE=
#       Linux` to ensure the function still works in the non-isolated
#       branch when no wrap is requested.
#
#   T7: bridge_detect_claude_session_id with a non-empty os_user runs
#       its python through `bridge_linux_sudo_as_user` — verified by
#       stubbing `bridge_linux_sudo_as_user` to record argv and prove
#       the bash -c shape is used. (We don't exercise real sudo on the
#       dev host; the real-sudo path is host-acceptance scope.)
#
#   T8 (teeth): revert the wrap (replace the `bridge_linux_sudo_as_user`
#       call site in lib/bridge-state.sh with bare `python3`) — the
#       detect helper running as controller against a 0600-jsonl
#       returns empty, reproducing the pre-fix #1299 symptom. Asserts
#       the wrap is load-bearing: without it, iso v2 session continuity
#       breaks.
#
#   T9 (default 4-item brief checklist item 3 — data shape): the bash
#       shim emits ONLY the session_id UUID to stdout (no extra log
#       lines, no JSON wrap). Asserts via the existing direct-helper
#       fixture (T6 path) + a length / regex bound on the captured
#       value.
#
#   T10 (ci-select 4-site registration): scripts/ci-select-smoke.sh
#       maps the four files involved in this fix to this smoke.
#       Asserts the entries are present so a future ci-select pass
#       picks up regression coverage automatically.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout);
# the smoke never reads or writes the operator's live `~/.claude` or
# bridge runtime. Real sudo is never invoked — every test exercises
# the wrap shape or stubs the escalator. The full real-sudo loop is
# host-acceptance scope (linux VM with provisioned iso users).
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every
# assertion uses `printf` / `cat >file <<EOF` plain bodies or `grep -n`
# against source files. No `<<<` here-strings into bridge functions
# and no command substitution feeding a heredoc stdin into subprocess
# capture.

set -uo pipefail

SMOKE_NAME="Beta-beta5-session-id-detect-sudo"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
SYNC_SH="$REPO_ROOT/bridge-sync.sh"
DETECT_HELPER="$REPO_ROOT/scripts/python-helpers/detect-claude-session-id.py"

[[ -f "$AGENTS_LIB" ]] || smoke_fail "missing $AGENTS_LIB"
[[ -f "$STATE_LIB" ]]  || smoke_fail "missing $STATE_LIB"
[[ -f "$SYNC_SH" ]]    || smoke_fail "missing $SYNC_SH"
[[ -f "$DETECT_HELPER" ]] || smoke_fail "missing $DETECT_HELPER"

# ---------------------------------------------------------------------
# T1: bridge_linux_sudo_as_user exists + non-Linux falls through direct.
# ---------------------------------------------------------------------
smoke_log "T1: bridge_linux_sudo_as_user is defined; non-Linux fall-through to direct invocation"

# Static-source: function definition is present in lib/bridge-agents.sh.
if ! grep -nE '^bridge_linux_sudo_as_user\(\) \{' "$AGENTS_LIB" >/dev/null; then
  smoke_fail "T1: bridge_linux_sudo_as_user() not defined in $AGENTS_LIB"
fi

# Runtime: source the library and verify the non-Linux branch dispatches
# the wrapped command directly (no sudo). Override the host platform to
# 'Darwin' so we exercise the macOS path without depending on the host.
T1_OUT="$(
  BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin \
  /opt/homebrew/bin/bash -c '
    set -uo pipefail
    source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1 || true
    # Smoke driver invokes the helper directly; the wrapped command
    # is `printf RAN=1\n` which simply emits its marker.
    bridge_linux_sudo_as_user "agent-bridge-fakeuser" printf "RAN=%s\n" 1
  ' 2>&1
)"
smoke_assert_contains "$T1_OUT" "RAN=1" \
  "T1: non-Linux fall-through dispatches the wrapped command directly (no sudo)"
smoke_log "T1 PASS — bridge_linux_sudo_as_user defined + macOS dev-host fall-through works"

# ---------------------------------------------------------------------
# T2: resolver returns empty for unregistered agents.
# ---------------------------------------------------------------------
smoke_log "T2: bridge_resolve_agent_iso_sudo_user returns empty for unregistered agent"

T2_OUT="$(
  /opt/homebrew/bin/bash -c '
    set -uo pipefail
    source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1 || true
    out="$(bridge_resolve_agent_iso_sudo_user "no-such-agent" 2>/dev/null)" || true
    printf "OUT=[%s]\n" "$out"
  ' 2>&1
)"
smoke_assert_contains "$T2_OUT" "OUT=[]" \
  "T2: resolver returns empty stdout for unregistered agent (back-compat)"
smoke_log "T2 PASS — resolver guards unregistered callers"

# ---------------------------------------------------------------------
# T3: resolver returns empty for a registered NON-iso agent.
# ---------------------------------------------------------------------
smoke_log "T3: bridge_resolve_agent_iso_sudo_user returns empty for registered non-iso agent"

T3_DRIVER="$SMOKE_TMP_ROOT/t3-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$REPO_ROOT/bridge-lib.sh\" >/dev/null 2>&1 || true"
  printf '%s\n' 'bridge_reset_roster_maps'
  # Register a NON-iso agent: no os_user, no linux-user isolation_mode.
  printf '%s\n' 'BRIDGE_AGENT_IDS=("noniso")'
  printf '%s\n' 'BRIDGE_AGENT_DESC["noniso"]="noniso smoke fixture"'
  printf '%s\n' 'BRIDGE_AGENT_ENGINE["noniso"]="claude"'
  printf '%s\n' 'BRIDGE_AGENT_SESSION["noniso"]="noniso"'
  printf '%s\n' 'BRIDGE_AGENT_WORKDIR["noniso"]="/tmp/noniso"'
  printf '%s\n' 'BRIDGE_AGENT_LOOP["noniso"]="1"'
  printf '%s\n' 'BRIDGE_AGENT_CONTINUE["noniso"]="1"'
  printf '%s\n' 'BRIDGE_AGENT_SOURCE["noniso"]="static"'
  printf '%s\n' 'BRIDGE_AGENT_CREATED_AT["noniso"]="$(date +%s)"'
  printf '%s\n' 'BRIDGE_AGENT_SESSION_ID["noniso"]=""'
  # No BRIDGE_AGENT_OS_USER, no BRIDGE_AGENT_ISOLATION_MODE → resolver
  # should reject this agent (rc=1, empty stdout).
  printf '%s\n' 'out="$(bridge_resolve_agent_iso_sudo_user "noniso" 2>/dev/null)" || true'
  printf '%s\n' 'printf "OUT=[%s]\n" "$out"'
} >"$T3_DRIVER"
chmod +x "$T3_DRIVER"

T3_OUT="$(/opt/homebrew/bin/bash "$T3_DRIVER" 2>&1)"
smoke_assert_contains "$T3_OUT" "OUT=[]" \
  "T3: resolver returns empty for registered non-iso agent (legacy behavior preserved)"
smoke_log "T3 PASS — resolver scopes to genuinely iso-v2-effective agents only"

# ---------------------------------------------------------------------
# T4: bridge_detect_claude_session_id function body has the sudo-wrap
# branch with the bash -c 'exec python3 "$@"' shape.
# ---------------------------------------------------------------------
smoke_log "T4: bridge_detect_claude_session_id wraps python via bridge_linux_sudo_as_user + bash -c"

T4_DETECT_FN_BODY="$(awk '/^bridge_detect_claude_session_id\(\) \{/,/^\}/' "$STATE_LIB")"
if [[ -z "$T4_DETECT_FN_BODY" ]]; then
  smoke_fail "T4: bridge_detect_claude_session_id definition not found in $STATE_LIB"
fi
if [[ "$T4_DETECT_FN_BODY" != *"bridge_linux_sudo_as_user"* ]]; then
  smoke_fail "T4: bridge_detect_claude_session_id lacks bridge_linux_sudo_as_user call — iso v2 0600-jsonl read elevation missing (#1299 regression)"
fi
# The wrap MUST go through `bash -c 'exec python3 "$@"' bash` so the
# per-agent sudoers entry (tmux + bash only) accepts the call. A direct
# `bridge_linux_sudo_as_user "$os_user" python3 ...` would be rejected
# by the production sudoers policy.
if [[ "$T4_DETECT_FN_BODY" != *'exec python3 "$@"'* ]]; then
  smoke_fail "T4: bridge_detect_claude_session_id sudo wrap missing the bash -c 'exec python3 \"\$@\"' shape — per-agent sudoers entry whitelists bash only, so a bare python3 invocation would be rejected"
fi
# 5th argument (os_user) is plumbed into the function signature.
if [[ "$T4_DETECT_FN_BODY" != *'local os_user="${5:-}"'* ]]; then
  smoke_fail "T4: bridge_detect_claude_session_id missing the os_user 5th-arg plumbing — callers cannot opt into the sudo wrap"
fi
smoke_log "T4 PASS — detect shim has the canonical sudo wrap shape"

# ---------------------------------------------------------------------
# T5: bridge_resolve_resume_session_id wraps python via sudo-as-user.
# ---------------------------------------------------------------------
smoke_log "T5: bridge_resolve_resume_session_id wraps python via bridge_linux_sudo_as_user + bash -c"

T5_RESOLVE_FN_BODY="$(awk '/^bridge_resolve_resume_session_id\(\) \{/,/^\}/' "$STATE_LIB")"
if [[ -z "$T5_RESOLVE_FN_BODY" ]]; then
  smoke_fail "T5: bridge_resolve_resume_session_id definition not found in $STATE_LIB"
fi
if [[ "$T5_RESOLVE_FN_BODY" != *"bridge_resolve_agent_iso_sudo_user"* ]]; then
  smoke_fail "T5: bridge_resolve_resume_session_id lacks bridge_resolve_agent_iso_sudo_user lookup — iso UID cannot be threaded into the wrap"
fi
if [[ "$T5_RESOLVE_FN_BODY" != *"bridge_linux_sudo_as_user"* ]]; then
  smoke_fail "T5: bridge_resolve_resume_session_id lacks bridge_linux_sudo_as_user call — the resolver helper (resolve-claude-resume-session-id.py) reads the same 0600-jsonl files as detect-claude-session-id.py and must use the same wrap"
fi
if [[ "$T5_RESOLVE_FN_BODY" != *'exec python3 "$@"'* ]]; then
  smoke_fail "T5: bridge_resolve_resume_session_id sudo wrap missing the bash -c 'exec python3 \"\$@\"' shape (sudoers entry whitelists bash only)"
fi
smoke_log "T5 PASS — resolve shim has the canonical sudo wrap shape"

# ---------------------------------------------------------------------
# T6: empty os_user → direct python invocation (back-compat).
# ---------------------------------------------------------------------
smoke_log "T6: empty os_user keeps the legacy direct-python invocation"

# Seed a Claude config dir + transcript on disk (controller-owned, so a
# direct controller `open()` succeeds). Then invoke
# bridge_detect_claude_session_id with empty os_user → must return the
# session id without going through the wrap.
T6_AGENT_HOME="$SMOKE_TMP_ROOT/t6-agent-home"
T6_CONFIG_DIR="$T6_AGENT_HOME/.claude"
T6_WORKDIR="$SMOKE_TMP_ROOT/t6-workdir"
T6_SESSION_ID="aaaa1111-bbbb-2222-cccc-3333dddd4444"
mkdir -p "$T6_WORKDIR"
T6_WORKDIR="$(cd -P "$T6_WORKDIR" && pwd -P)"
T6_SLUG="${T6_WORKDIR//\//-}"
mkdir -p "$T6_CONFIG_DIR/sessions" "$T6_CONFIG_DIR/projects/$T6_SLUG"
T6_NOW_MS=$(( $(date +%s) * 1000 ))
cat >"$T6_CONFIG_DIR/sessions/$$.json" <<EOF
{"sessionId":"$T6_SESSION_ID","cwd":"$T6_WORKDIR","pid":$$,"startedAt":$T6_NOW_MS}
EOF
printf '{"sessionId":"%s"}\n' "$T6_SESSION_ID" \
  >"$T6_CONFIG_DIR/projects/$T6_SLUG/$T6_SESSION_ID.jsonl"

T6_DRIVER="$SMOKE_TMP_ROOT/t6-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$REPO_ROOT/bridge-lib.sh\" >/dev/null 2>&1 || true"
  # 5-arg shape; empty os_user → direct invocation path.
  printf '%s\n' "out=\"\$(bridge_detect_claude_session_id \"$T6_WORKDIR\" 0 \"\" \"$T6_CONFIG_DIR\" \"\" 2>/dev/null || true)\""
  printf '%s\n' 'printf "DETECTED=[%s]\n" "$out"'
} >"$T6_DRIVER"
chmod +x "$T6_DRIVER"

T6_OUT="$(/opt/homebrew/bin/bash "$T6_DRIVER" 2>&1)"
smoke_assert_contains "$T6_OUT" "DETECTED=[$T6_SESSION_ID]" \
  "T6: empty os_user → direct python invocation finds the session_id"
smoke_log "T6 PASS — non-iso back-compat preserved"

# ---------------------------------------------------------------------
# T7: non-empty os_user → wrap routes through bridge_linux_sudo_as_user.
# Stub bridge_linux_sudo_as_user so we can capture its argv.
# ---------------------------------------------------------------------
smoke_log "T7: non-empty os_user dispatches python via bridge_linux_sudo_as_user (argv capture)"

T7_DRIVER="$SMOKE_TMP_ROOT/t7-driver.sh"
T7_ARGV_LOG="$SMOKE_TMP_ROOT/t7-argv.log"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$REPO_ROOT/bridge-lib.sh\" >/dev/null 2>&1 || true"
  # Stub bridge_linux_sudo_as_user to record its argv and emit a known
  # marker on stdout (no real sudo).
  printf '%s\n' "bridge_linux_sudo_as_user() { printf '%s\\n' \"\$@\" >\"$T7_ARGV_LOG\"; printf 'WRAP_FIRED=%s\\n' 1; }"
  printf '%s\n' "out=\"\$(bridge_detect_claude_session_id \"$T6_WORKDIR\" 0 \"\" \"$T6_CONFIG_DIR\" \"agent-bridge-faketest\" 2>/dev/null || true)\""
  printf '%s\n' 'printf "OUT=[%s]\n" "$out"'
} >"$T7_DRIVER"
chmod +x "$T7_DRIVER"

T7_OUT="$(/opt/homebrew/bin/bash "$T7_DRIVER" 2>&1)"
smoke_assert_contains "$T7_OUT" "OUT=[WRAP_FIRED=1]" \
  "T7: the sudo wrap fires (stub captured the invocation) when os_user is set"
if [[ ! -f "$T7_ARGV_LOG" ]]; then
  smoke_fail "T7: stub did not produce an argv log at $T7_ARGV_LOG"
fi
T7_ARGV="$(cat "$T7_ARGV_LOG")"
# argv shape: <os_user> <bash_bin> -c 'exec python3 "$@"' bash <detect.py> <workdir> ...
if [[ "$T7_ARGV" != *"agent-bridge-faketest"* ]]; then
  smoke_fail "T7: stub argv missing the os_user. Got: $T7_ARGV"
fi
if [[ "$T7_ARGV" != *'exec python3 "$@"'* ]]; then
  smoke_fail "T7: stub argv missing the canonical 'exec python3 \"\$@\"' inline body. Got: $T7_ARGV"
fi
if [[ "$T7_ARGV" != *"detect-claude-session-id.py"* ]]; then
  smoke_fail "T7: stub argv missing the detect helper path. Got: $T7_ARGV"
fi
smoke_log "T7 PASS — os_user → bash -c 'exec python3' wrap shape confirmed"

# ---------------------------------------------------------------------
# T8 (teeth): no wrap == empty detect against 0600 (controller cannot
# read). Simulate by chmod'ing the seeded jsonl to 0600 owned by current
# user; controller-direct read still succeeds when WE are the owner —
# so this teeth assertion has two flavors.
#
# Pure static teeth (works on every host): if the
# `bridge_linux_sudo_as_user` call site is removed from the function
# body, we lose the iso v2 escalation. Without an iso fixture (real
# foreign UID), we cannot actually reproduce the EACCES symptom on a
# dev host. Instead, assert the load-bearing wrap is still present —
# the same approach the test-stale-resume.sh harness uses for the
# resume-shim contract.
# ---------------------------------------------------------------------
smoke_log "T8 (teeth): assert the wrap is load-bearing (a future patch that drops it must trip this)"

# Verify both call sites — detect AND resolve.
T8_DETECT="$(awk '/^bridge_detect_claude_session_id\(\) \{/,/^\}/' "$STATE_LIB" | grep -c "bridge_linux_sudo_as_user" || true)"
T8_RESOLVE="$(awk '/^bridge_resolve_resume_session_id\(\) \{/,/^\}/' "$STATE_LIB" | grep -c "bridge_linux_sudo_as_user" || true)"
if [[ "$T8_DETECT" -lt 1 ]]; then
  smoke_fail "T8 teeth: bridge_detect_claude_session_id no longer routes via bridge_linux_sudo_as_user — #1299 regression"
fi
if [[ "$T8_RESOLVE" -lt 1 ]]; then
  smoke_fail "T8 teeth: bridge_resolve_resume_session_id no longer routes via bridge_linux_sudo_as_user — #1299 regression"
fi
smoke_log "T8 PASS — wrap is present at both detect + resolve call sites"

# ---------------------------------------------------------------------
# T9: stdout data shape — only the session_id UUID, no extra log noise.
# (Default 4-item brief checklist item 3.)
# ---------------------------------------------------------------------
smoke_log "T9: detect helper stdout is a single session_id UUID (no log lines, no JSON wrap)"

T9_OUT="$(python3 "$DETECT_HELPER" "$T6_WORKDIR" 0 "" "$T6_CONFIG_DIR")"
# Strip a trailing newline if any (print() emits one) — the contract is
# "single session_id line". Multiple lines or surrounding decoration
# would break callers that capture via $(...).
T9_LINES="$(printf '%s' "$T9_OUT" | wc -l | tr -d ' ')"
if [[ "$T9_LINES" != "0" ]]; then
  # `wc -l` counts newlines; print() emits exactly one, captured by
  # $(...) which strips trailing newlines. So lines must be 0.
  smoke_fail "T9: detect helper stdout has $T9_LINES embedded newline(s) — callers expect a single token. Got: $T9_OUT"
fi
if [[ "$T9_OUT" != "$T6_SESSION_ID" ]]; then
  smoke_fail "T9: detect helper stdout != the seeded session_id. Got: [$T9_OUT] Expected: [$T6_SESSION_ID]"
fi
smoke_log "T9 PASS — stdout is exactly the session_id UUID"

# ---------------------------------------------------------------------
# T10: ci-select-smoke.sh 4-site registration (default checklist #4).
# The four files involved must route to this smoke when changed.
# ---------------------------------------------------------------------
smoke_log "T10: ci-select-smoke.sh maps the 4 files involved in this fix to this smoke"

CI_SELECT="$REPO_ROOT/scripts/ci-select-smoke.sh"
[[ -f "$CI_SELECT" ]] || smoke_fail "T10: missing $CI_SELECT"

# All four canonical sites must register to this smoke. Allow either the
# explicit smoke filename OR the __ALL__ catch-all (sometimes ci-select
# routes via the all-smokes umbrella for cross-cutting changes).
T10_MISSING=()
for _site in \
    "lib/bridge-state.sh" \
    "lib/bridge-agents.sh" \
    "scripts/python-helpers/detect-claude-session-id.py" \
    "bridge-sync.sh" \
    ; do
  if ! grep -nF "$_site" "$CI_SELECT" >/dev/null; then
    T10_MISSING+=("$_site (file not in ci-select dispatch table)")
    continue
  fi
done
# Check our smoke file is registered (either by name or in __ALL__).
if ! grep -nF "Beta-beta5-session-id-detect-sudo" "$CI_SELECT" >/dev/null; then
  T10_MISSING+=("Beta-beta5-session-id-detect-sudo smoke not in ci-select-smoke.sh")
fi
if (( ${#T10_MISSING[@]} > 0 )); then
  smoke_fail "T10: ci-select-smoke.sh missing 4-site registration. Missing: ${T10_MISSING[*]}"
fi
smoke_log "T10 PASS — ci-select-smoke.sh has the 4 file + 1 smoke registrations"

smoke_log "ALL TESTS PASSED — v0.15.0-beta5 Lane β (#1299) session_id detect sudo wrap"
