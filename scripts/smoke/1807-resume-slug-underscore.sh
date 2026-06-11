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
#   T5. detect helper, TRANSCRIPT-ONLY fixture (no live sessions/<pid>.json).
#       This is the tooth that genuinely pins the detect-helper slug bug. T1's
#       fixture seeds a live same-cwd session JSON, so on origin/main the OLD
#       helper still passes T1 even with the wrong slug: its primary
#       live-session loop matches the session record by cwd and then finds the
#       transcript via the *slug-independent* recursive
#       `projects/**/<sid>.jsonl` glob (and the #827 live-pid acceptance). With
#       NO session JSON the detect helper has only its slug-DEPENDENT fallback
#       transcript scan, so the underscore-mapping candidate is the ONLY thing
#       that can reach the on-disk project dir.
#   T6. resolve helper + matching candidate, TRANSCRIPT-ONLY fixture (no live
#       sessions/<pid>.json). The tooth that genuinely pins the resolve
#       candidate path. T3's fixture seeds a live same-cwd session JSON, so on
#       origin/main the #827 live-session shortcut accepts the candidate
#       *slug-independently* and T3 passes despite the wrong slug. With no
#       session JSON the shortcut is skipped and the candidate must be matched
#       against the slug-DEPENDENT eligible-transcript scan.
#
# Discrimination proof (smoke-only r2; mirrors the US_CLAUDE_SLUG !=
# US_SLASHDOT_SLUG sanity guard). T5/T6 use a transcript-only fixture so the
# underscore slug alone decides pass/fail. Verified against BOTH helper
# versions on a fixture whose on-disk project dir is the Claude-slugified
# (`_`->`-`) name:
#   detect  (T5):  origin/main -> ''            | branch -> <sid>
#   resolve (T6):  origin/main -> rc=1 out=''    | branch -> rc=0 out=<sid>
# i.e. T5/T6 FAIL on origin/main and PASS on the branch — the smoke now pins
# the regression. (The pre-existing T2 — resolve with an EMPTY candidate — was
# already slug-dependent on origin/main because an empty candidate skips the
# live-session shortcut, so it failed on main too; T1/T3 were the masked ones.)
# T1-T4 stay green on both helper versions (they assert the live-session
# behavior + back-compat control, which the fix does not change).
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

# Seed a Claude config dir with a transcript ONLY — NO sessions/<pid>.json —
# whose project dir is named by Claude's slugification of the workdir. This is
# the DEAD / no-live-session shape: the helpers cannot fall back to the
# slug-independent live-session paths (detect's recursive `projects/**` glob
# is only reached for a matched session record; resolve's #827 live-session
# shortcut needs a live same-cwd record), so the underscore-mapping slug
# candidate is the only thing that can find the transcript. T5/T6 use this so
# the smoke genuinely pins the regression instead of passing via a live record.
seed_claude_config_dir_transcript_only() {
  local config_dir="$1"
  local workdir="$2"
  local session_id="$3"
  local slug
  slug="$(claude_slug "$workdir")"
  mkdir -p "$config_dir/projects/$slug"
  printf '{"sessionId":"%s"}\n' "$session_id" \
    >"$config_dir/projects/$slug/$session_id.jsonl"
  # Assert the no-live-session precondition: no sessions/<pid>.json may exist,
  # or T5/T6 would silently degrade back into the slug-independent live paths.
  [[ ! -e "$config_dir/sessions" ]] \
    || smoke_fail "transcript-only fixture leaked a sessions dir: $config_dir/sessions"
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

# --- Transcript-only underscore fixture (the regression-pinning teeth) ----
# A DEAD / no-live-session underscore workdir: a transcript exists on disk
# under the Claude-slugified (`_`->`-`) project dir, but there is NO
# sessions/<pid>.json. Without a live record neither helper can take its
# slug-INDEPENDENT path (detect's recursive `projects/**` glob; resolve's #827
# live-session shortcut), so ONLY the new underscore-mapping slug candidate can
# reach the transcript. This is what makes T5/T6 fail on origin/main (old slugs
# → empty/rc=1) and pass on the branch (new candidate → finds the transcript).
TO_CONFIG_DIR="$SMOKE_TMP_ROOT/agent-home-transcript-only/.claude"
TO_WORKDIR_PARENT="$SMOKE_TMP_ROOT/agents/dead_session"
TO_WORKDIR="$TO_WORKDIR_PARENT/workdir"
TO_SESSION_ID="abc12345-1807-transcript-only-fixture"
mkdir -p "$TO_WORKDIR"
TO_WORKDIR="$(cd -P "$TO_WORKDIR" && pwd -P)"
[[ "$TO_WORKDIR" == *_* ]] \
  || smoke_fail "transcript-only fixture workdir lost its underscore: $TO_WORKDIR"
seed_claude_config_dir_transcript_only "$TO_CONFIG_DIR" "$TO_WORKDIR" "$TO_SESSION_ID"

# Same discriminating-slug sanity as the T1-T3 fixture: the on-disk project
# dir must be the Claude slug AND differ from the slash+dot-only slug, so only
# the #1807 candidate can match.
TO_CLAUDE_SLUG="$(claude_slug "$TO_WORKDIR")"
TO_SLASHDOT_SLUG="${TO_WORKDIR//\//-}"; TO_SLASHDOT_SLUG="${TO_SLASHDOT_SLUG//./-}"
[[ -d "$TO_CONFIG_DIR/projects/$TO_CLAUDE_SLUG" ]] \
  || smoke_fail "transcript-only project dir not seeded at Claude slug: $TO_CLAUDE_SLUG"
[[ "$TO_CLAUDE_SLUG" != "$TO_SLASHDOT_SLUG" ]] \
  || smoke_fail "transcript-only slug not discriminating: $TO_CLAUDE_SLUG"

# T5 — detect helper, TRANSCRIPT-ONLY. Genuinely pins the detect-helper slug
# bug: with no live session record the only path to the transcript is the
# slug-DEPENDENT fallback scan. origin/main old slugs miss → empty (FAIL);
# the branch's underscore candidate finds it (PASS).
test_detect_underscore_transcript_only() {
  local out=""
  out="$(python3 "$DETECT_HELPER" "$TO_WORKDIR" 0 "" "$TO_CONFIG_DIR")"
  smoke_assert_eq "$TO_SESSION_ID" "$out" \
    "T5 detect resolves an underscore workdir from transcript ONLY, no live session (#1807; FAILS on origin/main)"
}

# T6 — resolve helper + matching candidate, TRANSCRIPT-ONLY. Genuinely pins
# the resolve candidate path: with no live session record the #827
# live-session shortcut is skipped, so the candidate must be matched against
# the slug-DEPENDENT eligible-transcript scan. origin/main old slugs →
# rc=1/empty (FAIL); the branch's underscore candidate → rc=0/<sid> (PASS).
test_resolve_underscore_candidate_transcript_only() {
  local out="" rc=0
  set +e
  out="$(python3 "$RESOLVE_HELPER" \
    "$TO_WORKDIR" "$TO_SESSION_ID" 48 testagent "" "$TO_CONFIG_DIR" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T6 resolve rc=0 accepts candidate from transcript ONLY, no live session (#1807; rc=1 on origin/main)"
  smoke_assert_eq "$TO_SESSION_ID" "$out" \
    "T6 resolve returns the transcript-only candidate id"
}

smoke_run "T1 detect resolves underscore workdir"           test_detect_underscore_workdir
smoke_run "T2 resolve empty-candidate underscore workdir"   test_resolve_underscore_empty_candidate
smoke_run "T3 resolve candidate underscore workdir"         test_resolve_underscore_candidate
smoke_run "T4 resolve non-underscore control"               test_resolve_no_underscore_control
smoke_run "T5 detect transcript-only underscore workdir"    test_detect_underscore_transcript_only
smoke_run "T6 resolve candidate transcript-only workdir"    test_resolve_underscore_candidate_transcript_only

smoke_log "all checks passed"
