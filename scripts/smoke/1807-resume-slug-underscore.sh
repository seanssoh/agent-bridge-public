#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1807-resume-slug-underscore.sh — Issue #1807.
#
# Re-exec under bash 4+ so we can `source bridge-lib.sh` for the optional
# shim-level coverage (matches scripts/smoke/1015-resume-claude-config-dir.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1807-resume-slug-underscore][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Pins the contract that the Claude project-dir slug candidates cover an
# underscore-containing workdir path.
#
# Root cause (issue #1807): both python helpers' `workdir_slug_candidates()`
# converted "/" and "." to "-" but NOT "_". Some shipped Claude Code versions
# slugify the cwd by also mapping "_" → "-" (the anthropics/claude-code #30828
# behavior, confirmed live on cm-prod across a v0.16.9 restart). So for any
# agent whose workdir path contains "_" (e.g. ".../agents/test_clean/workdir"),
# the bridge computed a project slug ("...test_clean...") that did NOT match the
# real on-disk Claude project dir ("...test-clean...") → 0 transcripts found →
# rc=1 → the launch builder started a fresh `claude` instead of `--resume`.
#
# The fix: both helpers add a third candidate
# `slash_dot_us = re.sub(r"[/._]", "-", path)`, de-duped against the existing
# slash-only and slash+dot candidates. The existing candidates stay for
# back-compat (Claude Code versions that preserve "_").
#
# Test plan — for BOTH helpers, against a fixture whose on-disk project dir is
# named with Claude's slugification (`_` → `-`), so ONLY the new third
# candidate can match:
#   T1. detect-claude-session-id.py resolves the session id from the
#       underscore-workdir transcript (was: empty, slug miss).
#   T2. resolve-claude-resume-session-id.py with an empty candidate resolves to
#       the freshest transcript (rc=0) for the underscore workdir (was: rc=1).
#   T3. resolve-claude-resume-session-id.py accepts a matching candidate id
#       (rc=0) for the underscore workdir (the actual restart path: a stored
#       AGENT_SESSION_ID that must resume, not relaunch fresh).
#   T4. Negative control — a NON-underscore workdir still resolves (the
#       existing slash+dot candidates must keep working; the new candidate
#       de-dupes to the same slug and must not change behavior).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout); the
# smoke never reads or writes the operator's live `~/.claude` or bridge
# runtime. All fixtures live under SMOKE_TMP_ROOT.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only `printf`
# plain-body writes — no command substitution feeding a heredoc-stdin, no
# `<<<` here-strings into bridge functions.

set -euo pipefail

SMOKE_NAME="1807-resume-slug-underscore"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "1807-resume-slug-underscore"

REPO_ROOT="$SMOKE_REPO_ROOT"
DETECT_HELPER="$REPO_ROOT/scripts/python-helpers/detect-claude-session-id.py"
RESOLVE_HELPER="$REPO_ROOT/scripts/python-helpers/resolve-claude-resume-session-id.py"

[[ -f "$DETECT_HELPER" ]] || smoke_fail "missing helper: $DETECT_HELPER"
[[ -f "$RESOLVE_HELPER" ]] || smoke_fail "missing helper: $RESOLVE_HELPER"

# Compute Claude Code's project-dir slug for a path: "/", ".", and "_" → "-".
# This mirrors the on-disk naming the underscore-mapping Claude Code versions
# produce; the helpers must reach this exact name via their new candidate.
claude_slug() {
  local p="$1"
  p="${p//\//-}"
  p="${p//./-}"
  p="${p//_/-}"
  printf '%s' "$p"
}

# Seed a Claude config dir (sessions/<pid>.json + a matching fresh transcript)
# whose project dir is named by Claude's slugification of the workdir.
seed_claude_config_dir_claude_slug() {
  local config_dir="$1"
  local workdir="$2"
  local session_id="$3"
  local slug now_ms
  slug="$(claude_slug "$workdir")"
  mkdir -p "$config_dir/sessions" "$config_dir/projects/$slug"
  now_ms=$(( $(date +%s) * 1000 ))
  printf '{"sessionId":"%s","cwd":"%s","pid":%s,"startedAt":%s}\n' \
    "$session_id" "$workdir" "$$" "$now_ms" \
    >"$config_dir/sessions/$$.json"
  printf '{"sessionId":"%s"}\n' "$session_id" \
    >"$config_dir/projects/$slug/$session_id.jsonl"
}

# --- Underscore-workdir fixture -----------------------------------------
# Build a workdir whose path component contains an underscore. Use realpath
# (`cd -P`) so the helpers' os.path.realpath() yields the same path we slug.
AGENT_CONFIG_DIR="$SMOKE_TMP_ROOT/agent-home/.claude"
US_WORKDIR_PARENT="$SMOKE_TMP_ROOT/agents/test_clean"
US_WORKDIR="$US_WORKDIR_PARENT/workdir"
US_SESSION_ID="abc12345-1807-underscore-fixture"
mkdir -p "$US_WORKDIR"
US_WORKDIR="$(cd -P "$US_WORKDIR" && pwd -P)"
[[ "$US_WORKDIR" == *_* ]] \
  || smoke_fail "fixture workdir lost its underscore after realpath: $US_WORKDIR"
seed_claude_config_dir_claude_slug "$AGENT_CONFIG_DIR" "$US_WORKDIR" "$US_SESSION_ID"

# Sanity: the project dir on disk must be the Claude-slugified name, and it
# must DIFFER from the slash+dot-only slug (otherwise the test would pass even
# without the #1807 fix). slash+dot keeps "_"; Claude-slug maps it.
US_CLAUDE_SLUG="$(claude_slug "$US_WORKDIR")"
US_SLASHDOT_SLUG="${US_WORKDIR//\//-}"; US_SLASHDOT_SLUG="${US_SLASHDOT_SLUG//./-}"
[[ -d "$AGENT_CONFIG_DIR/projects/$US_CLAUDE_SLUG" ]] \
  || smoke_fail "fixture project dir not seeded at Claude slug: $US_CLAUDE_SLUG"
[[ "$US_CLAUDE_SLUG" != "$US_SLASHDOT_SLUG" ]] \
  || smoke_fail "fixture slug not discriminating (no underscore mapped): $US_CLAUDE_SLUG"

# T1 — detect helper resolves the session id under the underscore workdir.
test_detect_underscore_workdir() {
  local out=""
  out="$(python3 "$DETECT_HELPER" "$US_WORKDIR" 0 "" "$AGENT_CONFIG_DIR")"
  smoke_assert_eq "$US_SESSION_ID" "$out" \
    "T1 detect helper resolves session for an underscore workdir (#1807)"
}

# T2 — resolve helper with an EMPTY candidate resolves to the freshest
# transcript (rc=0) — the latent-restart path where no candidate id is stored
# but a resumable transcript exists on disk.
test_resolve_underscore_empty_candidate() {
  local out="" rc=0
  set +e
  out="$(python3 "$RESOLVE_HELPER" \
    "$US_WORKDIR" "" 48 testagent "" "$AGENT_CONFIG_DIR" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T2 resolve helper rc=0 (not rc=1 fresh-launch) for underscore workdir (#1807)"
  smoke_assert_eq "$US_SESSION_ID" "$out" \
    "T2 resolve helper returns the underscore-workdir transcript id"
}

# T3 — resolve helper accepts a matching candidate id (rc=0) for the
# underscore workdir. This is the real restart path: a stored AGENT_SESSION_ID
# that the freshness gate must accept (resume), not reject (fresh launch).
test_resolve_underscore_candidate() {
  local out="" rc=0
  set +e
  out="$(python3 "$RESOLVE_HELPER" \
    "$US_WORKDIR" "$US_SESSION_ID" 48 testagent "" "$AGENT_CONFIG_DIR" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T3 resolve helper rc=0 accepts candidate for underscore workdir (#1807)"
  smoke_assert_eq "$US_SESSION_ID" "$out" \
    "T3 resolve helper returns the candidate session id"
}

# --- Negative control: non-underscore workdir still resolves -------------
NU_CONFIG_DIR="$SMOKE_TMP_ROOT/agent-home-nu/.claude"
NU_WORKDIR="$SMOKE_TMP_ROOT/agents/no-underscore/workdir"
NU_SESSION_ID="def67890-1807-no-underscore-fixture"
mkdir -p "$NU_WORKDIR"
NU_WORKDIR="$(cd -P "$NU_WORKDIR" && pwd -P)"
seed_claude_config_dir_claude_slug "$NU_CONFIG_DIR" "$NU_WORKDIR" "$NU_SESSION_ID"

# T4 — a non-underscore workdir still resolves via the existing candidates;
# the new candidate de-dupes to the same slug (no behavior change). Guards
# against the fix accidentally narrowing the back-compat path.
test_resolve_no_underscore_control() {
  local out="" rc=0
  set +e
  out="$(python3 "$RESOLVE_HELPER" \
    "$NU_WORKDIR" "$NU_SESSION_ID" 48 testagent "" "$NU_CONFIG_DIR" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T4 resolve helper rc=0 for a non-underscore workdir (back-compat control)"
  smoke_assert_eq "$NU_SESSION_ID" "$out" \
    "T4 resolve helper returns the non-underscore candidate id"
}

smoke_run "T1 detect resolves underscore workdir"           test_detect_underscore_workdir
smoke_run "T2 resolve empty-candidate underscore workdir"   test_resolve_underscore_empty_candidate
smoke_run "T3 resolve candidate underscore workdir"         test_resolve_underscore_candidate
smoke_run "T4 resolve non-underscore control"               test_resolve_no_underscore_control

smoke_log "all checks passed"
