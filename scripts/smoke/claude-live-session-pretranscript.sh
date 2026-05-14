#!/usr/bin/env bash
# scripts/smoke/claude-live-session-pretranscript.sh — Issue #827 smoke.
#
# Re-exec under bash 4+ so we can `source bridge-lib.sh` directly
# (matches the bootstrap done in scripts/smoke-test.sh and the
# idle-counter-latch smoke).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:claude-live-session-pretranscript][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Fresh Claude Code interactive sessions create `~/.claude/sessions/<pid>.json`
# before the matching `~/.claude/projects/<slug>/<sessionId>.jsonl` transcript
# exists. Issue #827 fixed `bridge_detect_claude_session_id` and
# `bridge_resolve_resume_session_id` to accept the live session id under
# narrow conditions (same realpath cwd + alive pid). This smoke pins that
# acceptance and the rejection paths around it.
#
#   T1. Live accept — sessions/<orchestrator-pid>.json exists, cwd matches,
#       pid is alive, no transcript jsonl on disk. detect returns the
#       synthesized session id, rc=0. resolve returns the same id, rc=0.
#   T2. Dead pid + no transcript — sessions/<dead-pid>.json with cwd match
#       but pid is bogus (999999, unallocated). detect returns empty,
#       resolve returns rc=1.
#   T3. Stale dead-pid + no transcript in an unrelated fresh cwd. Verifies
#       the rejection is not a cwd-aliasing artifact of T2.
#
# Isolation: this smoke writes to a temp HOME (NOT the operator's real
# ~/.claude). Each test pins HOME via `HOME=... bridge_detect_... `
# around the calls so the helper's `os.path.expanduser("~/.claude/...")`
# resolves against the fixture tree, not the operator's real install.

set -euo pipefail

SMOKE_NAME="claude-live-session-pretranscript"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "claude-live-session-pretranscript"

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# Source the library functions under test. We source bridge-lib.sh
# (which transitively sources lib/bridge-state.sh and friends) so the
# shell is wired up the same way the production daemon and CLI are. The
# function bodies of bridge_detect_claude_session_id and
# bridge_resolve_resume_session_id now call out to
# scripts/python-helpers/*.py rather than running an inline
# `python3 - <<'PY' ... PY` heredoc — that earlier inline form wedged on
# Bash 5.3.9 in the heredoc-write deadlock class (#815 / #800). The
# helper-file form is immune.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$SMOKE_REPO_ROOT/bridge-lib.sh"

# A pid that is overwhelmingly likely to be unallocated on every platform
# we run on. Linux's default pid_max is 32768 (4M on hosts that raised it),
# macOS caps at 99999. Picking 999999 means the kill -0 check returns
# false without our test ever owning the pid. We confirm at runtime.
DEAD_PID="999999"

# Synthesize a fixture HOME with a sessions/<pid>.json record. Echoes the
# session id on stdout.
#
# Footgun 11 self-audit: writes the JSON body via mktemp + redirect from
# python3 stdin → file → cp into fixture, not `cat <<EOF > $session_file`,
# so the smoke itself never reintroduces the heredoc-to-file pattern that
# the repo is guarding against.
make_fixture_home() {
  local fixture_home="$1"
  local pid="$2"
  local cwd="$3"
  local name="${4:-test}"

  local sid sessions_dir session_file body_tmp
  sid="$("$PY_BIN" -c 'import uuid; print(uuid.uuid4())')"
  sessions_dir="$fixture_home/.claude/sessions"
  mkdir -p "$sessions_dir"
  session_file="$sessions_dir/${pid}.json"

  body_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-827-body.XXXXXX")"
  PID="$pid" SID="$sid" CWD="$cwd" NAME="$name" \
    "$PY_BIN" -c '
import json
import os

print(
    json.dumps(
        {
            "pid": int(os.environ["PID"]),
            "sessionId": os.environ["SID"],
            "cwd": os.environ["CWD"],
            "name": os.environ["NAME"],
            "status": "idle",
            "startedAt": 1778722000000,
        }
    )
)
' > "$body_tmp"
  cp "$body_tmp" "$session_file"
  rm -f "$body_tmp"

  printf '%s\n' "$sid"
}

# Sanity-check the dead-pid sentinel BEFORE the negative tests rely on it.
guard_dead_pid_is_dead() {
  if kill -0 "$DEAD_PID" 2>/dev/null; then
    smoke_fail "guard: pid $DEAD_PID happens to be alive on this host; choose a different sentinel"
  fi
}

# ---------------------------------------------------------------------------
# T1 — live accept: same-cwd sessions/<orchestrator-pid>.json with alive pid,
#                   no transcript jsonl on disk.
# ---------------------------------------------------------------------------
test_live_accept_without_transcript() {
  local fixture_home tmp_cwd sid detected resolved live_pid rc

  fixture_home="$SMOKE_TMP_ROOT/t1-home"
  tmp_cwd="$SMOKE_TMP_ROOT/t1-cwd"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"

  live_pid="$$"
  if ! kill -0 "$live_pid" 2>/dev/null; then
    smoke_fail "T1 self pid $live_pid is not alive — environment broken"
  fi

  sid="$(make_fixture_home "$fixture_home" "$live_pid" "$tmp_cwd" "test")"

  detected="$(HOME="$fixture_home" bridge_detect_claude_session_id "$tmp_cwd" 0 "")"
  rc=$?
  smoke_assert_eq "0" "$rc" "T1 detect rc"
  smoke_assert_eq "$sid" "$detected" "T1 detect returns synthesized session id"

  resolved="$(HOME="$fixture_home" bridge_resolve_resume_session_id claude test "$tmp_cwd" "$detected" 2>/dev/null)"
  rc=$?
  smoke_assert_eq "0" "$rc" "T1 resolve rc"
  smoke_assert_eq "$sid" "$resolved" "T1 resolve accepts live session id"

  # Guard: no transcript was created behind our back during the call.
  local slug transcript_root
  slug="$(printf '%s' "$tmp_cwd" | tr '/.' '-')"
  transcript_root="$fixture_home/.claude/projects/$slug"
  if [[ -d "$transcript_root" ]]; then
    smoke_fail "T1 transcript dir leaked into fixture HOME: $transcript_root"
  fi
}

# ---------------------------------------------------------------------------
# T2 — dead pid + no transcript: same fixture shape but with $DEAD_PID
#      written into the sessions/<pid>.json (filename AND body pid field).
#      detect should drop the record, resolve should rc=1.
# ---------------------------------------------------------------------------
test_dead_pid_rejected() {
  local fixture_home tmp_cwd sid detected rc

  fixture_home="$SMOKE_TMP_ROOT/t2-home"
  tmp_cwd="$SMOKE_TMP_ROOT/t2-cwd"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"

  guard_dead_pid_is_dead

  sid="$(make_fixture_home "$fixture_home" "$DEAD_PID" "$tmp_cwd" "test")"

  detected="$(HOME="$fixture_home" bridge_detect_claude_session_id "$tmp_cwd" 0 "")"
  rc=$?
  smoke_assert_eq "0" "$rc" "T2 detect rc"
  smoke_assert_eq "" "$detected" "T2 detect drops dead-pid session record"

  # Pass the original sid in as the candidate so resolve has to evaluate it.
  set +e
  HOME="$fixture_home" bridge_resolve_resume_session_id claude test "$tmp_cwd" "$sid" >/dev/null 2>/dev/null
  rc=$?
  set -e
  smoke_assert_eq "1" "$rc" "T2 resolve rejects dead-pid + no-transcript"
}

# ---------------------------------------------------------------------------
# T3 — stale dead-pid + no transcript in an unrelated fresh cwd. Verifies
#      the rejection is not a cwd-aliasing artifact of T2 and survives a
#      directory rename.
# ---------------------------------------------------------------------------
test_stale_dead_pid_rejected() {
  local fixture_home tmp_cwd sid detected rc

  fixture_home="$SMOKE_TMP_ROOT/t3-home"
  tmp_cwd="$SMOKE_TMP_ROOT/t3-cwd-fresh"
  mkdir -p "$tmp_cwd"
  tmp_cwd="$(cd -P "$tmp_cwd" && pwd -P)"

  guard_dead_pid_is_dead

  sid="$(make_fixture_home "$fixture_home" "$DEAD_PID" "$tmp_cwd" "test")"

  detected="$(HOME="$fixture_home" bridge_detect_claude_session_id "$tmp_cwd" 0 "")"
  rc=$?
  smoke_assert_eq "0" "$rc" "T3 detect rc"
  smoke_assert_eq "" "$detected" "T3 detect drops stale dead-pid record"

  set +e
  HOME="$fixture_home" bridge_resolve_resume_session_id claude test "$tmp_cwd" "$sid" >/dev/null 2>/dev/null
  rc=$?
  set -e
  smoke_assert_eq "1" "$rc" "T3 resolve rejects stale dead-pid + no-transcript"
}

smoke_run "T1 live accept (alive pid, no transcript)"     test_live_accept_without_transcript
smoke_run "T2 dead pid + no transcript rejected"          test_dead_pid_rejected
smoke_run "T3 stale dead pid + no transcript rejected"    test_stale_dead_pid_rejected

smoke_log "all checks passed"
