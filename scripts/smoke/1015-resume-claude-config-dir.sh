#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1015-resume-claude-config-dir.sh — Issue #1015.
#
# Re-exec under bash 4+ so we can `source bridge-lib.sh` directly for the
# shim-level coverage (matches scripts/smoke/claude-live-session-
# pretranscript.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1015-resume-claude-config-dir][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Pins the contract that the Claude session-id resolution keys off the
# *agent's* CLAUDE_CONFIG_DIR, not the daemon process's HOME.
#
# Root cause (issue #1015): static Claude agents launched by the
# isolation-v2 stack run with a custom HOME / CLAUDE_CONFIG_DIR, so the
# session JSON and transcripts land under `<agent-home>/.claude/`. Both
# python helpers expanded `~/.claude/...` against the daemon HOME, found
# nothing, returned rc=1, and `bridge_normalize_agent_session_id` then
# cleared the stored id — every restart launched a fresh session.
#
# The fix: both helpers resolve the config root from, in priority order,
# an explicit trailing argument > the CLAUDE_CONFIG_DIR env var >
# <HOME>/.claude > os.path.expanduser("~/.claude"). The bash shims
# (bridge_detect_claude_session_id / bridge_resolve_resume_session_id)
# auto-supply that trailing argument ONLY for registered, genuinely
# isolated agents whose config dir exists on disk
# (bridge_resolve_agent_claude_config_dir) — so test / unregistered /
# non-isolated callers that rely on a per-call HOME keep the daemon-HOME
# fallback exactly as on `main`.
#
# Test plan — two layers:
#
#   Direct helper coverage (the helpers invoked as standalone scripts):
#   T1. detect-claude-session-id.py resolves the session via the trailing
#       config-dir argument.
#   T2. detect-claude-session-id.py resolves it via CLAUDE_CONFIG_DIR env.
#   T3. detect-claude-session-id.py with no config dir / env falls back to
#       the ambient HOME — fixture lives elsewhere so nothing is found.
#   T4. resolve-claude-resume-session-id.py accepts the candidate (rc=0)
#       via the trailing config-dir argument.
#   T5. resolve-claude-resume-session-id.py accepts it via CLAUDE_CONFIG_DIR.
#   T6. resolve-claude-resume-session-id.py with no config dir / env
#       rejects the candidate (rc=1) — daemon-HOME fallback, unchanged.
#
#   Shim coverage (the actual Bash functions, the layer the #1018 r1
#   regression slipped past because the smoke only tested the helpers):
#   T7. bridge_detect_claude_session_id for a REGISTERED isolated agent
#       resolves the session under the agent's <agent-home>/.claude/.
#   T8. bridge_resolve_resume_session_id for the same registered isolated
#       agent accepts the candidate (rc=0).
#   T7b. (Issue #1370) a REGISTERED shared-mode agent (iso_effective=0) with
#        a Lane θ-scaffolded empty <agent-home>/.claude resolves EMPTY — the
#        derived path must never shadow the controller HOME for shared mode.
#   T7c. (Issue #1370) a REGISTERED linux-user agent on a non-Linux host
#        (iso never effective) likewise resolves EMPTY despite a scaffolded
#        <agent-home>/.claude — the admin's actual macOS shape.
#   T7d. (Issue #1439, Bug-1) a REGISTERED shared-mode per-agent-HOME agent
#        whose <agent-home>/.claude/projects/<slug>/ is POPULATED resolves to
#        <agent-home>/.claude — the live recovery. The resolver discriminates
#        an empty #1316 scaffold (T7b/T7c, resolve empty) from a live
#        per-agent home (this, resolve the dir) by whether projects/ holds a
#        directory; pinning both polarities catches a flip in either
#        direction. Runs AFTER T7b so its populate cannot pollute T7b's
#        empty-scaffold assertion (same SHARED_AGENT fixture).
#   T9. bridge_detect_claude_session_id for an UNREGISTERED agent with a
#       per-call HOME does NOT shadow that HOME — the guard returns empty
#       and the helper finds the fixture under the per-call HOME
#       (backward-compatible fallback).
#   T10. bridge_resolve_resume_session_id for an UNREGISTERED agent with a
#        per-call HOME likewise accepts the candidate via that HOME — the
#        regression vector from PR #1018 r1 (codex item 1).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout);
# the smoke never reads or writes the operator's live `~/.claude` or
# bridge runtime. The fallback cases pin HOME at a temp dir.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `printf` / `cat >file <<EOF` plain-body writes — no command
# substitution feeding a heredoc-stdin, no `<<<` here-strings into bridge
# functions.

set -euo pipefail

SMOKE_NAME="1015-resume-claude-config-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "1015-resume-claude-config-dir"

REPO_ROOT="$SMOKE_REPO_ROOT"
DETECT_HELPER="$REPO_ROOT/scripts/python-helpers/detect-claude-session-id.py"
RESOLVE_HELPER="$REPO_ROOT/scripts/python-helpers/resolve-claude-resume-session-id.py"

[[ -f "$DETECT_HELPER" ]] || smoke_fail "missing helper: $DETECT_HELPER"
[[ -f "$RESOLVE_HELPER" ]] || smoke_fail "missing helper: $RESOLVE_HELPER"

# Seed a Claude config dir (sessions/<pid>.json + matching fresh
# transcript) under a given root, mimicking what an isolation-v2 agent
# writes under <agent-home>/.claude/ .
seed_claude_config_dir() {
  local config_dir="$1"
  local workdir="$2"
  local session_id="$3"
  local slug now_ms
  slug="${workdir//\//-}"
  mkdir -p "$config_dir/sessions" "$config_dir/projects/$slug"
  now_ms=$(( $(date +%s) * 1000 ))
  cat >"$config_dir/sessions/$$.json" <<EOF
{"sessionId":"$session_id","cwd":"$workdir","pid":$$,"startedAt":$now_ms}
EOF
  printf '{"sessionId":"%s"}\n' "$session_id" \
    >"$config_dir/projects/$slug/$session_id.jsonl"
}

# --- Direct-helper fixture ----------------------------------------------
AGENT_CONFIG_DIR="$SMOKE_TMP_ROOT/agent-home/.claude"
WORKDIR="$SMOKE_TMP_ROOT/agent-workdir"
SESSION_ID="abc12345-1015-resume-fixture"
mkdir -p "$WORKDIR"
WORKDIR="$(cd -P "$WORKDIR" && pwd -P)"
seed_claude_config_dir "$AGENT_CONFIG_DIR" "$WORKDIR" "$SESSION_ID"

# An empty HOME for the "no config dir" fallback cases, so the operator's
# real ~/.claude cannot accidentally satisfy (or break) the assertion.
EMPTY_HOME="$SMOKE_TMP_ROOT/empty-home"
mkdir -p "$EMPTY_HOME"

# T1 — detect helper picks up the agent config dir via the trailing arg.
test_detect_via_argument() {
  local out=""
  out="$(python3 "$DETECT_HELPER" "$WORKDIR" 0 "" "$AGENT_CONFIG_DIR")"
  smoke_assert_eq "$SESSION_ID" "$out" \
    "T1 detect helper resolves session via trailing config-dir argument"
}

# T2 — detect helper picks up the agent config dir via CLAUDE_CONFIG_DIR.
test_detect_via_env() {
  local out=""
  out="$(CLAUDE_CONFIG_DIR="$AGENT_CONFIG_DIR" \
    python3 "$DETECT_HELPER" "$WORKDIR" 0 "")"
  smoke_assert_eq "$SESSION_ID" "$out" \
    "T2 detect helper resolves session via CLAUDE_CONFIG_DIR env var"
}

# T3 — detect helper with no config dir falls back to the ambient HOME;
# the fixture lives elsewhere so nothing is found (non-isolated path,
# unchanged from pre-#1015).
test_detect_fallback_finds_nothing() {
  local out=""
  out="$(env -u CLAUDE_CONFIG_DIR HOME="$EMPTY_HOME" \
    python3 "$DETECT_HELPER" "$WORKDIR" 0 "")"
  smoke_assert_eq "" "$out" \
    "T3 detect helper daemon-HOME fallback finds no fixture session"
}

# T4 — resolve helper accepts the candidate (rc=0) via the trailing arg.
test_resolve_via_argument() {
  local out="" rc=0
  set +e
  out="$(python3 "$RESOLVE_HELPER" \
    "$WORKDIR" "$SESSION_ID" 48 testagent "" "$AGENT_CONFIG_DIR" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T4 resolve helper rc=0 when config dir passed as trailing argument"
  smoke_assert_eq "$SESSION_ID" "$out" \
    "T4 resolve helper returns the candidate session id"
}

# T5 — resolve helper accepts the candidate (rc=0) via CLAUDE_CONFIG_DIR.
test_resolve_via_env() {
  local out="" rc=0
  set +e
  out="$(CLAUDE_CONFIG_DIR="$AGENT_CONFIG_DIR" \
    python3 "$RESOLVE_HELPER" \
    "$WORKDIR" "$SESSION_ID" 48 testagent "" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T5 resolve helper rc=0 when config dir comes from CLAUDE_CONFIG_DIR"
  smoke_assert_eq "$SESSION_ID" "$out" \
    "T5 resolve helper returns the candidate session id via env var"
}

# T6 — resolve helper with no config dir falls back to the ambient HOME;
# no transcript exists there so the candidate is rejected (rc=1), exactly
# as before #1015 (the non-isolated path must not regress).
test_resolve_fallback_rejects() {
  local rc=0
  set +e
  env -u CLAUDE_CONFIG_DIR HOME="$EMPTY_HOME" \
    python3 "$RESOLVE_HELPER" \
    "$WORKDIR" "$SESSION_ID" 48 testagent "" >/dev/null 2>&1
  rc=$?
  set -e
  smoke_assert_eq "1" "$rc" \
    "T6 resolve helper daemon-HOME fallback rejects candidate (rc=1)"
}

# --- Shim coverage: source bridge-lib.sh and exercise the Bash shims ----
#
# bridge-lib.sh transitively sources lib/bridge-state.sh (the shims) and
# lib/bridge-agents.sh (bridge_agent_exists / bridge_agent_claude_config_dir).
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

declare -F bridge_detect_claude_session_id >/dev/null \
  || smoke_fail "bridge_detect_claude_session_id not defined after sourcing bridge-lib.sh"
declare -F bridge_resolve_resume_session_id >/dev/null \
  || smoke_fail "bridge_resolve_resume_session_id not defined"
declare -F bridge_resolve_agent_claude_config_dir >/dev/null \
  || smoke_fail "bridge_resolve_agent_claude_config_dir not defined (issue #1015 guard)"
declare -F bridge_reset_roster_maps >/dev/null \
  || smoke_fail "bridge_reset_roster_maps not defined"

# Register one isolated agent. Issue #1370 (beta5-2 #1316 regression): the
# resolver now gates on `bridge_agent_linux_user_isolation_effective` BEFORE
# the on-disk `-d` check, so a registered agent only earns a private config
# dir when its linux-user isolation is genuinely effective — linux-user mode
# + Linux host + non-empty os_user (lib/bridge-agents.sh:1023). Model all
# three so the fixture is iso-effective even on a macOS CI runner:
#   * BRIDGE_HOST_PLATFORM_OVERRIDE=Linux       (host predicate)
#   * BRIDGE_AGENT_ISOLATION_MODE=linux-user    (mode predicate)
#   * BRIDGE_AGENT_OS_USER=<probe-user>          (os_user predicate)
# Point BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT at a writable temp dir so the
# resolved config dir (`<root>/<os_user>/.claude`) lands somewhere the smoke
# can actually seed, rather than the production `/home/<os_user>/.claude`.
bridge_reset_roster_maps

ISO_AGENT="rcd-1015"
ISO_OS_USER="agent-bridge-rcd-1015"
ISO_WORKDIR="$SMOKE_TMP_ROOT/iso-workdir"
ISO_SESSION_ID="def67890-1015-iso-fixture"
ISO_HOME_ROOT="$SMOKE_TMP_ROOT/iso-home-root"
mkdir -p "$ISO_WORKDIR" "$ISO_HOME_ROOT"
ISO_WORKDIR="$(cd -P "$ISO_WORKDIR" && pwd -P)"
ISO_HOME_ROOT="$(cd -P "$ISO_HOME_ROOT" && pwd -P)"

# iso-effective predicate inputs (see comment above).
export BRIDGE_HOST_PLATFORM_OVERRIDE="Linux"
export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$ISO_HOME_ROOT"

BRIDGE_AGENT_IDS=("$ISO_AGENT")
BRIDGE_AGENT_DESC["$ISO_AGENT"]="$ISO_AGENT smoke fixture"
BRIDGE_AGENT_ENGINE["$ISO_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$ISO_AGENT"]="$ISO_AGENT"
BRIDGE_AGENT_WORKDIR["$ISO_AGENT"]="$ISO_WORKDIR"
BRIDGE_AGENT_LOOP["$ISO_AGENT"]="1"
BRIDGE_AGENT_CONTINUE["$ISO_AGENT"]="1"
BRIDGE_AGENT_SOURCE["$ISO_AGENT"]="static"
BRIDGE_AGENT_CREATED_AT["$ISO_AGENT"]="$(date +%s)"
BRIDGE_AGENT_SESSION_ID["$ISO_AGENT"]=""
BRIDGE_AGENT_ISOLATION_MODE["$ISO_AGENT"]="linux-user"
BRIDGE_AGENT_OS_USER["$ISO_AGENT"]="$ISO_OS_USER"

bridge_agent_linux_user_isolation_effective "$ISO_AGENT" \
  || smoke_fail "fixture not iso-effective for $ISO_AGENT (predicate inputs wrong)"

ISO_CONFIG_DIR="$(bridge_agent_claude_config_dir "$ISO_AGENT")"
[[ -n "$ISO_CONFIG_DIR" ]] \
  || smoke_fail "bridge_agent_claude_config_dir returned empty for registered agent"
seed_claude_config_dir "$ISO_CONFIG_DIR" "$ISO_WORKDIR" "$ISO_SESSION_ID"

# T7 — bridge_detect_claude_session_id resolves the registered isolated
# agent's session under its own <agent-home>/.claude/ . The guard
# auto-supplies the config dir; HOME is irrelevant here.
test_shim_detect_isolated_agent() {
  local detected="" _cfg=""
  _cfg="$(bridge_resolve_agent_claude_config_dir "$ISO_AGENT")"
  smoke_assert_eq "$ISO_CONFIG_DIR" "$_cfg" \
    "T7 guard resolves the registered isolated agent's config dir"
  detected="$(bridge_detect_claude_session_id "$ISO_WORKDIR" 0 "" "$_cfg" 2>/dev/null)"
  smoke_assert_eq "$ISO_SESSION_ID" "$detected" \
    "T7 shim detects session under the isolated agent's CLAUDE_CONFIG_DIR"
}

# T8 — bridge_resolve_resume_session_id accepts the candidate (rc=0) for
# the registered isolated agent; the shim auto-resolves the config dir.
test_shim_resolve_isolated_agent() {
  local resolved="" rc=0
  set +e
  resolved="$(bridge_resolve_resume_session_id \
    claude "$ISO_AGENT" "$ISO_WORKDIR" "$ISO_SESSION_ID" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T8 shim resolve rc=0 for registered isolated agent"
  smoke_assert_eq "$ISO_SESSION_ID" "$resolved" \
    "T8 shim resolve accepts the isolated agent's live session id"
}

# --- Issue #1370 negative controls: shared-mode agents fall through ------
#
# beta5-2's Lane θ ".claude tree normalize" backfill scaffolds an (empty)
# `<agent-home>/.claude` for shared-mode agents too, so the resolver's
# `-d` guard alone no longer filters them out — the new iso-effective gate
# is what keeps a shared-mode (admin / non-Linux) agent from shadowing the
# controller HOME and blocking `--continue` resume. These two cases are the
# regression-prevention teeth for #1370: a REGISTERED agent whose `.claude`
# EXISTS on disk but whose isolation is NOT effective MUST resolve empty.

# Register a shared-mode (iso_effective=0) sibling on the same Linux host:
# mode=shared, no os_user → predicate fails on the requested-mode check.
SHARED_AGENT="rcd-1015-shared"
BRIDGE_AGENT_IDS+=("$SHARED_AGENT")
BRIDGE_AGENT_DESC["$SHARED_AGENT"]="$SHARED_AGENT shared-mode negative control"
BRIDGE_AGENT_ENGINE["$SHARED_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$SHARED_AGENT"]="$SHARED_AGENT"
BRIDGE_AGENT_WORKDIR["$SHARED_AGENT"]="$ISO_WORKDIR"
BRIDGE_AGENT_SOURCE["$SHARED_AGENT"]="static"
BRIDGE_AGENT_CREATED_AT["$SHARED_AGENT"]="$(date +%s)"
BRIDGE_AGENT_SESSION_ID["$SHARED_AGENT"]=""
BRIDGE_AGENT_ISOLATION_MODE["$SHARED_AGENT"]="shared"
# Scaffold the empty agent-home `.claude` (what Lane θ #1316 backfill leaves
# behind) so the on-disk `-d` guard would otherwise pass.
SHARED_SCAFFOLD_DIR="$(bridge_agent_claude_config_dir "$SHARED_AGENT")"
mkdir -p "$SHARED_SCAFFOLD_DIR/projects" "$SHARED_SCAFFOLD_DIR/sessions"

# Register a linux-user agent that is iso-INeffective because the host is
# non-Linux (Darwin) — the admin's actual macOS shape. Same scaffolded dir.
DARWIN_AGENT="rcd-1015-darwin"
BRIDGE_AGENT_IDS+=("$DARWIN_AGENT")
BRIDGE_AGENT_DESC["$DARWIN_AGENT"]="$DARWIN_AGENT non-Linux negative control"
BRIDGE_AGENT_ENGINE["$DARWIN_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$DARWIN_AGENT"]="$DARWIN_AGENT"
BRIDGE_AGENT_WORKDIR["$DARWIN_AGENT"]="$ISO_WORKDIR"
BRIDGE_AGENT_SOURCE["$DARWIN_AGENT"]="static"
BRIDGE_AGENT_CREATED_AT["$DARWIN_AGENT"]="$(date +%s)"
BRIDGE_AGENT_SESSION_ID["$DARWIN_AGENT"]=""
BRIDGE_AGENT_ISOLATION_MODE["$DARWIN_AGENT"]="linux-user"
BRIDGE_AGENT_OS_USER["$DARWIN_AGENT"]="agent-bridge-rcd-1015-darwin"

# T7b — shared-mode agent on a Linux host: iso_effective=0 even with the
# Lane θ-scaffolded `.claude` present → resolver returns empty so detect
# falls back to the controller HOME (the #1370 fix contract).
test_shared_mode_resolves_empty() {
  bridge_agent_linux_user_isolation_effective "$SHARED_AGENT" 2>/dev/null \
    && smoke_fail "T7b fixture should NOT be iso-effective (mode=shared)"
  [[ -d "$SHARED_SCAFFOLD_DIR" ]] \
    || smoke_fail "T7b scaffolded agent-home .claude should exist on disk"
  local resolved=""
  resolved="$(bridge_resolve_agent_claude_config_dir "$SHARED_AGENT")"
  smoke_assert_eq "" "$resolved" \
    "T7b shared-mode agent resolves empty despite scaffolded .claude (#1370)"
}

# T7c — linux-user agent on a non-Linux (Darwin) host: iso never effective,
# so even the scaffolded `.claude` must not shadow the controller HOME.
# Flip the host platform override only for the duration of this assertion.
test_non_linux_host_resolves_empty() {
  local resolved="" _saved_platform="${BRIDGE_HOST_PLATFORM_OVERRIDE:-}"
  export BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin"
  bridge_agent_linux_user_isolation_effective "$DARWIN_AGENT" 2>/dev/null \
    && { export BRIDGE_HOST_PLATFORM_OVERRIDE="$_saved_platform"; \
         smoke_fail "T7c fixture should NOT be iso-effective on a Darwin host"; }
  local scaffold_dir=""
  scaffold_dir="$(bridge_agent_claude_config_dir "$DARWIN_AGENT")"
  mkdir -p "$scaffold_dir/projects" "$scaffold_dir/sessions"
  resolved="$(bridge_resolve_agent_claude_config_dir "$DARWIN_AGENT")"
  export BRIDGE_HOST_PLATFORM_OVERRIDE="$_saved_platform"
  smoke_assert_eq "" "$resolved" \
    "T7c non-Linux-host agent resolves empty despite scaffolded .claude (#1370)"
}

# T7d — (Issue #1439, Bug-1) a REGISTERED shared-mode agent launched with its
# OWN HOME (per-agent-HOME layout, e.g. macOS / non-Linux) whose
# <agent-home>/.claude/projects/<slug>/ is POPULATED with live session data
# MUST resolve to <agent-home>/.claude — NOT empty. This is the live-recovery
# the #1439 fix restored: the old #1370 gate discarded the per-agent home for
# any non-iso-effective agent, so bridge_detect_claude_session_id scanned the
# stale controller HOME, found no fresh transcript, returned 1, and the
# restart helper rolled back every just-launched session (whole-fleet
# crash-loop). The resolver now discriminates an empty #1316 scaffold (T7b /
# T7c — resolve empty) from a LIVE per-agent home (this case — resolve the
# dir) by whether projects/ holds a directory. Same fixture shape as T7b but
# with a populated projects/<slug>/ so the polarity is pinned in both
# directions: a flip back to the old gate fails BOTH T7b (empty re-breaks
# #1370) and T7d (populated re-breaks #1439 Bug-1).
test_per_agent_home_populated_resolves_dir() {
  bridge_agent_linux_user_isolation_effective "$SHARED_AGENT" 2>/dev/null \
    && smoke_fail "T7d fixture should NOT be iso-effective (mode=shared)"

  # Populate projects/<slug>/ with a live session dir (the discriminator the
  # resolver uses: a directory under projects/, not just the scaffold).
  local slug="${ISO_WORKDIR//\//-}"
  mkdir -p "$SHARED_SCAFFOLD_DIR/projects/$slug"
  printf '{"sessionId":"t7d-live"}\n' \
    >"$SHARED_SCAFFOLD_DIR/projects/$slug/t7d-live.jsonl"

  local resolved=""
  resolved="$(bridge_resolve_agent_claude_config_dir "$SHARED_AGENT")"
  smoke_assert_eq "$SHARED_SCAFFOLD_DIR" "$resolved" \
    "T7d shared-mode per-agent-HOME with populated projects/ resolves the dir (#1439 Bug-1)"
}

# --- Issue #2106: resolver/launch config-dir split-brain -----------------
#
# THE crash-loop case the existing #1370 empty-scaffold heuristic could not
# distinguish: a shared (non-iso) static/admin Claude agent whose launch path
# (bridge_run_shared_launch) WILL pin CLAUDE_CONFIG_DIR=<agent-home>/.claude
# because its per-agent credential is authed — but whose
# <agent-home>/.claude/projects/ is EMPTY (the #1750 per-agent-identity
# migration left the prior transcripts ORPHANED in the operator HOME).
#
# Pre-fix: empty projects/ + iso-ineffective → resolver returns EMPTY → falls
# back to scanning the operator HOME → fs-selects an orphaned operator-home
# transcript id → launch `--resume <orphan>` against the per-agent config that
# lacks it → `No conversation found` → exit 1 → rapid-fail circuit-breaker
# crash-loop. THIS smoke FAILS before the fix (resolver returns "" not the dir).
#
# Post-fix: the launch-pin proof (a `.credentials.json` under the per-agent
# dir — the same proof bridge_run_shared_launch gates its export on) makes the
# resolver return the per-agent dir even with an empty projects/, so detection-
# dir == launch-dir. The resolver scans the (empty) per-agent dir, finds
# nothing, resume resolves to "no eligible transcript", and the launch starts
# FRESH — no orphan re-resume, no crash-loop.
S2106_AGENT="rcd-2106-split-brain"
BRIDGE_AGENT_IDS+=("$S2106_AGENT")
BRIDGE_AGENT_DESC["$S2106_AGENT"]="$S2106_AGENT #2106 split-brain repro"
BRIDGE_AGENT_ENGINE["$S2106_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$S2106_AGENT"]="$S2106_AGENT"
BRIDGE_AGENT_WORKDIR["$S2106_AGENT"]="$ISO_WORKDIR"
BRIDGE_AGENT_SOURCE["$S2106_AGENT"]="static"
BRIDGE_AGENT_CREATED_AT["$S2106_AGENT"]="$(date +%s)"
BRIDGE_AGENT_SESSION_ID["$S2106_AGENT"]=""
BRIDGE_AGENT_ISOLATION_MODE["$S2106_AGENT"]="shared"
S2106_DIR="$(bridge_agent_claude_config_dir "$S2106_AGENT")"
# The #1750 split-brain shape: the per-agent .claude exists with an EMPTY
# projects/ (no transcript dirs — the prior sessions are orphaned elsewhere).
mkdir -p "$S2106_DIR/projects" "$S2106_DIR/sessions"

# T11a — WITHOUT the launch-pin credential proof the agent is indistinguishable
# from an empty #1316 scaffold, so the resolver still resolves EMPTY (the
# #1370 contract holds; launch would NOT pin a per-agent dir for it either).
test_split_brain_no_credential_resolves_empty() {
  bridge_agent_linux_user_isolation_effective "$S2106_AGENT" 2>/dev/null \
    && smoke_fail "T11a fixture should NOT be iso-effective (mode=shared)"
  [[ ! -f "$S2106_DIR/.credentials.json" ]] \
    || smoke_fail "T11a precondition: no credential should be present yet"
  local resolved=""
  resolved="$(bridge_resolve_agent_claude_config_dir "$S2106_AGENT")"
  smoke_assert_eq "" "$resolved" \
    "T11a empty per-agent dir with NO credential resolves empty (#1370 preserved)"
}

# T11b — WITH the per-agent `.credentials.json` (launch WILL pin the dir), the
# resolver returns the per-agent dir despite the empty projects/. This is the
# #2106 fix: detection-dir == launch-dir, so launch can no longer be handed an
# orphaned operator-home id. FAILS before the fix.
test_split_brain_credentialed_resolves_dir() {
  printf '{"claudeAiOauth":{"accessToken":"x"}}\n' >"$S2106_DIR/.credentials.json"
  local resolved=""
  resolved="$(bridge_resolve_agent_claude_config_dir "$S2106_AGENT")"
  smoke_assert_eq "$S2106_DIR" "$resolved" \
    "T11b credentialed shared+agent_home with empty projects/ resolves the dir (#2106)"
}

# T11c — end-to-end alignment: the resume resolver scans the SAME (empty)
# per-agent dir and finds NO eligible transcript (rc=1), so the launch starts
# fresh instead of re-injecting the orphaned operator-home id. Even when an
# orphan transcript exists in the per-call HOME (the operator HOME), the
# credentialed per-agent dir wins and shields it from selection.
test_split_brain_resume_resolves_fresh() {
  # Plant an orphan transcript in the operator-HOME projects/<slug>/ — exactly
  # what the #1750 migration leaves behind. Pre-fix this would be selected.
  local op_home="$SMOKE_TMP_ROOT/op-home-2106"
  local slug="${ISO_WORKDIR//\//-}"
  local orphan_id="0a0a0a0a-2106-orphan-operator"
  mkdir -p "$op_home/.claude/projects/$slug"
  printf '{"sessionId":"%s"}\n' "$orphan_id" \
    >"$op_home/.claude/projects/$slug/$orphan_id.jsonl"
  local rc=0 resolved=""
  set +e
  resolved="$(HOME="$op_home" \
    bridge_resolve_resume_session_id \
    claude "$S2106_AGENT" "$ISO_WORKDIR" "" 2>/dev/null)"
  rc=$?
  set -e
  # rc=1 (no eligible transcript under the per-agent dir) AND the orphan id was
  # NOT selected. Pre-fix: the resolver falls back to $HOME/.claude, finds the
  # orphan, returns it (rc=0/2) → the crash-loop.
  smoke_assert_eq "1" "$rc" \
    "T11c resume resolves to NO eligible transcript for the empty per-agent dir (#2106)"
  [[ "$resolved" != "$orphan_id" ]] \
    || smoke_fail "T11c resolver selected the orphaned operator-home id (split-brain re-broke)"
}

# T9 — bridge_detect_claude_session_id for an UNREGISTERED agent with a
# per-call HOME must NOT shadow that HOME. The guard returns empty (agent
# not in the roster) so the helper falls back to HOME/.claude — where the
# direct-helper fixture lives. This is the regression vector from #1018 r1.
test_shim_detect_unregistered_home_fallback() {
  local guard_out="" detected=""
  guard_out="$(bridge_resolve_agent_claude_config_dir "unregistered-xyz")"
  smoke_assert_eq "" "$guard_out" \
    "T9 guard returns empty for an unregistered agent (no HOME shadowing)"
  # The shim takes the config dir as an explicit arg; with the guard
  # returning empty, the caller passes "" and the helper uses HOME.
  detected="$(HOME="$SMOKE_TMP_ROOT/agent-home" \
    bridge_detect_claude_session_id "$WORKDIR" 0 "" "" 2>/dev/null)"
  smoke_assert_eq "$SESSION_ID" "$detected" \
    "T9 shim detect honours the per-call HOME fallback (no config dir)"
}

# T10 — bridge_resolve_resume_session_id for an UNREGISTERED agent with a
# per-call HOME accepts the candidate via that HOME. Direct re-creation of
# the claude-live-session-pretranscript T1 regression vector: prior to the
# r1 fix the shim auto-computed a derived config dir for the unregistered
# `test`-style agent and overrode HOME, breaking the fallback.
test_shim_resolve_unregistered_home_fallback() {
  local resolved="" rc=0
  set +e
  resolved="$(HOME="$SMOKE_TMP_ROOT/agent-home" \
    bridge_resolve_resume_session_id \
    claude "unregistered-xyz" "$WORKDIR" "$SESSION_ID" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "0" "$rc" \
    "T10 shim resolve rc=0 via per-call HOME for an unregistered agent"
  smoke_assert_eq "$SESSION_ID" "$resolved" \
    "T10 shim resolve accepts candidate via the per-call HOME fallback"
}

smoke_run "T1 detect resolves via trailing argument"     test_detect_via_argument
smoke_run "T2 detect resolves via CLAUDE_CONFIG_DIR"      test_detect_via_env
smoke_run "T3 detect fallback finds no fixture"           test_detect_fallback_finds_nothing
smoke_run "T4 resolve accepts via trailing argument"      test_resolve_via_argument
smoke_run "T5 resolve accepts via CLAUDE_CONFIG_DIR"      test_resolve_via_env
smoke_run "T6 resolve fallback rejects candidate"         test_resolve_fallback_rejects
smoke_run "T7 shim detect for registered isolated agent"  test_shim_detect_isolated_agent
smoke_run "T8 shim resolve for registered isolated agent" test_shim_resolve_isolated_agent
smoke_run "T7b shared-mode agent resolves empty (#1370)"  test_shared_mode_resolves_empty
smoke_run "T7c non-Linux host resolves empty (#1370)"     test_non_linux_host_resolves_empty
smoke_run "T7d per-agent-HOME populated resolves dir (#1439)" test_per_agent_home_populated_resolves_dir
smoke_run "T11a empty per-agent dir, no credential, resolves empty (#2106)" test_split_brain_no_credential_resolves_empty
smoke_run "T11b credentialed empty per-agent dir resolves the dir (#2106)" test_split_brain_credentialed_resolves_dir
smoke_run "T11c resume resolves fresh, orphan id shielded (#2106)" test_split_brain_resume_resolves_fresh
smoke_run "T9 shim detect honours per-call HOME"          test_shim_detect_unregistered_home_fallback
smoke_run "T10 shim resolve honours per-call HOME"        test_shim_resolve_unregistered_home_fallback

smoke_log "all checks passed"
