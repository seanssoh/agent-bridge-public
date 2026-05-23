#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1151-r2-sudo-escalate.sh — Issue #1151 r2 (Codex BLOCKING).
#
# Beta10 follow-up to #1151 r1. PR #1153 r1 took the "DEFER everywhere under
# v2 isolation" approach for `bridge_sync_claude_runtime_skills` and
# `bridge_ensure_project_claude_guidance`. Codex review found that both
# defers drop user-visible behavior:
#
#   BLOCKING 1 — Configured runtime skills (BRIDGE_AGENT_SKILLS) were
#     installed by the legacy `bridge_sync_claude_runtime_skills` under
#     `$workdir/.claude/skills/`. v2 isolated Claude reads from
#     `$isolated_home/.claude/skills/` instead (CLAUDE_CONFIG_DIR is
#     pointed there). The r1 DEFER had no v2 replacement → CSV-configured
#     skills disappear for v2 agents.
#
#   BLOCKING 2 — Project CLAUDE.md guidance was the only production write
#     site that materializes the agent-bridge guidance block in workdir
#     CLAUDE.md. v2 Claude reads CLAUDE.md from workdir per the v2 profile
#     contract → r1 DEFER permanently dropped the block for v2 agents.
#
# r2 fix (this PR):
#   - `bridge_sync_isolated_home_claude_skills` extended to also iterate
#     `bridge_agent_skills_csv "$agent"` and sudo-install configured
#     runtime skills (T7).
#   - `bridge_ensure_project_claude_guidance` post-Step-A v2 branch now
#     SUDO-ESCALATEs the workdir CLAUDE.md write (T8).
#
# T7: BRIDGE_AGENT_SKILLS roundtrip
#   - Configure custom-skill → assert isolated home has it
#   - Remove custom-skill from CSV → assert it's gone
#
# T8: Project CLAUDE.md guidance v2 sudo-escalate
#   - v2 isolation effective + Step A complete + workdir CLAUDE.md exists
#   - Assert the guidance block is materialized into CLAUDE.md
#
# Stub-shim pattern mirrors 1145-option1-deferral-guard / 1151-step-a-helper:
# the bridge-side functions that escape the unit (sudo, isolation effective,
# os_user, isolation home) are stubbed; the function under test is sourced
# from `lib/bridge-skills.sh`. No real sudo, no real isolated UIDs, no
# `agent-bridge-*` accounts on the host.
#
# Footgun #11 (heredoc_write deadlock class): every driver is built with
# `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash functions; no
# `$()` capture of heredoc-stdin in test infrastructure (the function
# under test itself uses Pattern B `python3 - ... <<'PY'` which the
# lint-heredoc-ban baseline already covers).

set -uo pipefail

SMOKE_NAME="1151-r2-sudo-escalate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# ---------- T7 — Configured runtime skill (BRIDGE_AGENT_SKILLS) lands in isolated home ----------
#
# Fixture:
#   - Fake $isolated_home dir under SMOKE_TMP_ROOT
#   - Fake $BRIDGE_RUNTIME_SKILLS_DIR/custom-skill source dir
#   - BRIDGE_AGENT_SKILLS["smoke-agent"]="custom-skill"
#   - Stub `bridge_linux_sudo_root` as a direct passthrough (no real sudo)
#   - Stub isolation-effective + os_user + linux_user_home
#   - Source bridge-skills.sh and invoke `bridge_sync_isolated_home_claude_skills`
#
# After the call: assert `$isolated_home/.claude/skills/custom-skill/SKILL.md`
# exists. Then remove `custom-skill` from CSV, re-run, assert it's gone.

T7_DIR="$SMOKE_TMP_ROOT/t7"
mkdir -p "$T7_DIR"
T7_DRIVER="$T7_DIR/driver.sh"
T7_LOG="$T7_DIR/log"

printf '%s\n' '#!/usr/bin/env bash' >"$T7_DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'set -uo pipefail' >>"$T7_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T7_DRIVER"
printf '%s\n' 'FIXTURE_ROOT="$2"' >>"$T7_DRIVER"
printf '%s\n' 'OPERATION="$3"  # "install" or "remove"' >>"$T7_DRIVER"
printf '%s\n' 'AGENT="smoke-agent"' >>"$T7_DRIVER"
printf '%s\n' 'export BRIDGE_HOME="$FIXTURE_ROOT/bridge-home"' >>"$T7_DRIVER"
printf '%s\n' 'mkdir -p "$BRIDGE_HOME"' >>"$T7_DRIVER"
printf '%s\n' 'export BRIDGE_AGENT_HOME_ROOT="$FIXTURE_ROOT/agent-homes"' >>"$T7_DRIVER"
printf '%s\n' 'export BRIDGE_RUNTIME_SKILLS_DIR="$FIXTURE_ROOT/runtime-skills"' >>"$T7_DRIVER"
printf '%s\n' 'export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$FIXTURE_ROOT/iso-home-root"' >>"$T7_DRIVER"
printf '%s\n' 'export BRIDGE_MANAGED_MARKER="agent-bridge-managed"' >>"$T7_DRIVER"
# Reset / re-create the runtime skill source for each invocation.
printf '%s\n' 'mkdir -p "$BRIDGE_RUNTIME_SKILLS_DIR/custom-skill"' >>"$T7_DRIVER"
printf '%s\n' 'printf "%s\n" "# custom-skill" >"$BRIDGE_RUNTIME_SKILLS_DIR/custom-skill/SKILL.md"' >>"$T7_DRIVER"
# Configure CSV based on operation.
printf '%s\n' 'declare -A BRIDGE_AGENT_SKILLS' >>"$T7_DRIVER"
printf '%s\n' 'if [[ "$OPERATION" == "install" ]]; then' >>"$T7_DRIVER"
printf '%s\n' '  BRIDGE_AGENT_SKILLS["smoke-agent"]="custom-skill"' >>"$T7_DRIVER"
printf '%s\n' 'else' >>"$T7_DRIVER"
# Operation "remove" → empty CSV but the previously-installed skill should
# still be present in $isolated_home from the prior install run.
printf '%s\n' '  BRIDGE_AGENT_SKILLS["smoke-agent"]=""' >>"$T7_DRIVER"
printf '%s\n' 'fi' >>"$T7_DRIVER"
# Stubs that the function under test reaches outside this module.
printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }' >>"$T7_DRIVER"
printf '%s\n' 'bridge_require_python() { command -v python3 >/dev/null 2>&1; }' >>"$T7_DRIVER"
printf '%s\n' 'bridge_path_is_within_root() { echo "0"; }' >>"$T7_DRIVER"
printf '%s\n' 'bridge_with_timeout() { shift 2; "$@"; }' >>"$T7_DRIVER"
printf '%s\n' 'bridge_trim_whitespace() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf "%s" "$s"; }' >>"$T7_DRIVER"
# Provide bridge_agent_skills_csv mirroring the real signature.
printf '%s\n' 'bridge_agent_skills_csv() {' >>"$T7_DRIVER"
printf '%s\n' '  local agent="$1"' >>"$T7_DRIVER"
printf '%s\n' '  local configured="${BRIDGE_AGENT_SKILLS[$agent]-}"' >>"$T7_DRIVER"
printf '%s\n' '  local normalized="" skill=""' >>"$T7_DRIVER"
printf '%s\n' '  configured="${configured//,/ }"' >>"$T7_DRIVER"
printf '%s\n' '  for skill in $configured; do' >>"$T7_DRIVER"
printf '%s\n' '    skill="$(bridge_trim_whitespace "$skill")"' >>"$T7_DRIVER"
printf '%s\n' '    [[ -n "$skill" ]] || continue' >>"$T7_DRIVER"
printf '%s\n' '    normalized+="${normalized:+ }$skill"' >>"$T7_DRIVER"
printf '%s\n' '  done' >>"$T7_DRIVER"
printf '%s\n' '  printf "%s" "$normalized"' >>"$T7_DRIVER"
printf '%s\n' '}' >>"$T7_DRIVER"
# Isolation effective stub — always returns 0 (yes, isolated).
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T7_DRIVER"
# Roster os_user → "smoke-iso-user" (the value passed to chown). The test
# uses the real $USER (or "nobody" fallback) so chown can succeed.
printf '%s\n' 'bridge_agent_os_user() { echo "$(id -un)"; }' >>"$T7_DRIVER"
printf '%s\n' 'bridge_agent_linux_user_home() { echo "$FIXTURE_ROOT/iso-home-root/$(id -un)"; }' >>"$T7_DRIVER"
# sudo-passthrough — the smoke runs as the test user; no actual privilege
# escalation. The function-under-test's call sites use the same primitive
# regardless of platform.
printf '%s\n' 'bridge_linux_sudo_root() { "$@"; }' >>"$T7_DRIVER"
# Source the module so the helper functions are defined.
printf '%s\n' '# shellcheck disable=SC1090' >>"$T7_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-skills.sh"' >>"$T7_DRIVER"
printf '%s\n' 'bridge_sync_isolated_home_claude_skills "$AGENT"' >>"$T7_DRIVER"
printf '%s\n' 'echo "DONE"' >>"$T7_DRIVER"
chmod +x "$T7_DRIVER"

# --- T7 install pass ---
"$BRIDGE_BASH" "$T7_DRIVER" "$REPO_ROOT" "$T7_DIR" "install" >"$T7_LOG" 2>&1 \
  || smoke_fail "T7 install driver failed: $(tr '\n' '|' <"$T7_LOG" | tail -c 800)"

T7_ISO_HOME="$T7_DIR/iso-home-root/$(id -un)"
T7_TARGET="$T7_ISO_HOME/.claude/skills/custom-skill/SKILL.md"

[[ -f "$T7_TARGET" ]] \
  || smoke_fail "T7 install: expected $T7_TARGET to exist after configured-skill sync. log: $(tr '\n' '|' <"$T7_LOG" | tail -c 800)"

# Body should match the source.
T7_EXPECTED_BODY="$(printf '%s\n' '# custom-skill')"
T7_ACTUAL_BODY="$(cat "$T7_TARGET")"
[[ "$T7_ACTUAL_BODY" == "$T7_EXPECTED_BODY" ]] \
  || smoke_fail "T7 install: content mismatch. expected=$T7_EXPECTED_BODY actual=$T7_ACTUAL_BODY"

smoke_log "T7a PASS: BRIDGE_AGENT_SKILLS[smoke-agent]=\"custom-skill\" → \$isolated_home/.claude/skills/custom-skill/SKILL.md materialized"

# --- T7 removal pass ---
# Re-invoke with empty CSV. The previously-installed `custom-skill` should
# now be deleted from the isolated home (since it was installed by this
# function in the prior pass and is no longer referenced).
"$BRIDGE_BASH" "$T7_DRIVER" "$REPO_ROOT" "$T7_DIR" "remove" >"$T7_LOG" 2>&1 \
  || smoke_fail "T7 remove driver failed: $(tr '\n' '|' <"$T7_LOG" | tail -c 800)"

if [[ -e "$T7_ISO_HOME/.claude/skills/custom-skill" ]]; then
  smoke_fail "T7 remove: expected \$isolated_home/.claude/skills/custom-skill to be DELETED after CSV removal; still present"
fi
smoke_log "T7b PASS: empty CSV removed previously-installed custom-skill from isolated home"

# ---------- T8 — Project CLAUDE.md guidance sudo-escalate (v2 post-Step-A) ----------
#
# Fixture:
#   - Workdir at $T8_DIR/workdir (owned by current user — stand-in for
#     "isolated UID owns workdir post-Step-A")
#   - Stub `bridge_agent_workdir_step_a_complete` to return 0 (Step A complete)
#   - Stub isolation effective to return 0
#   - Stub `bridge_linux_sudo_root` as direct passthrough
#   - Pre-create $workdir/CLAUDE.md with a project heading
#   - Invoke `bridge_ensure_project_claude_guidance "$workdir" "$agent"`
#
# After the call: assert that CLAUDE.md still exists AND contains the
# guidance block marker.

T8_DIR="$SMOKE_TMP_ROOT/t8"
mkdir -p "$T8_DIR"
T8_WORKDIR="$T8_DIR/workdir"
mkdir -p "$T8_WORKDIR"
printf '%s\n' '# Project' >"$T8_WORKDIR/CLAUDE.md"
printf '%s\n' '' >>"$T8_WORKDIR/CLAUDE.md"
printf '%s\n' 'Existing project content.' >>"$T8_WORKDIR/CLAUDE.md"

T8_DRIVER="$T8_DIR/driver.sh"
T8_LOG="$T8_DIR/log"

printf '%s\n' '#!/usr/bin/env bash' >"$T8_DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'set -uo pipefail' >>"$T8_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T8_DRIVER"
printf '%s\n' 'WORKDIR="$2"' >>"$T8_DRIVER"
printf '%s\n' 'export BRIDGE_HOME="$3"' >>"$T8_DRIVER"
printf '%s\n' 'export BRIDGE_AGENT_HOME_ROOT="$WORKDIR-not-a-real-prefix"' >>"$T8_DRIVER"
printf '%s\n' 'export BRIDGE_MANAGED_MARKER="agent-bridge-managed"' >>"$T8_DRIVER"
printf '%s\n' 'declare -A BRIDGE_AGENT_SKILLS' >>"$T8_DRIVER"
printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }' >>"$T8_DRIVER"
printf '%s\n' 'bridge_require_python() { command -v python3 >/dev/null 2>&1; }' >>"$T8_DRIVER"
printf '%s\n' 'bridge_path_is_within_root() { echo "0"; }' >>"$T8_DRIVER"
# Stub the v2 isolation predicates so the v2 branch fires.
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T8_DRIVER"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 0; }' >>"$T8_DRIVER"
printf '%s\n' 'bridge_agent_os_user() { echo "$(id -un)"; }' >>"$T8_DRIVER"
# sudo-passthrough — read/install/mv all run as the current user.
printf '%s\n' 'bridge_linux_sudo_root() { "$@"; }' >>"$T8_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T8_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-skills.sh"' >>"$T8_DRIVER"
printf '%s\n' 'bridge_ensure_project_claude_guidance "$WORKDIR" "smoke-agent"' >>"$T8_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T8_DRIVER"
chmod +x "$T8_DRIVER"

"$BRIDGE_BASH" "$T8_DRIVER" "$REPO_ROOT" "$T8_WORKDIR" "$T8_DIR/bridge-home" >"$T8_LOG" 2>&1 \
  || smoke_fail "T8 driver failed: $(tr '\n' '|' <"$T8_LOG" | tail -c 800)"

# Assert the guidance block landed in workdir/CLAUDE.md.
T8_CLAUDE_FILE="$T8_WORKDIR/CLAUDE.md"
[[ -f "$T8_CLAUDE_FILE" ]] || smoke_fail "T8: workdir/CLAUDE.md disappeared after sudo-escalate write"

grep -Fq "<!-- BEGIN AGENT BRIDGE PROJECT GUIDANCE -->" "$T8_CLAUDE_FILE" \
  || smoke_fail "T8: guidance block START marker missing from CLAUDE.md after v2 post-Step-A sudo-escalate. content: $(head -c 600 "$T8_CLAUDE_FILE" | tr '\n' '|')"

grep -Fq "<!-- END AGENT BRIDGE PROJECT GUIDANCE -->" "$T8_CLAUDE_FILE" \
  || smoke_fail "T8: guidance block END marker missing from CLAUDE.md"

grep -Fq "## Agent Bridge" "$T8_CLAUDE_FILE" \
  || smoke_fail "T8: guidance block heading missing from CLAUDE.md"

# Project content preserved.
grep -Fq "Existing project content." "$T8_CLAUDE_FILE" \
  || smoke_fail "T8: original project content lost after guidance install"

smoke_log "T8 PASS: v2 post-Step-A sudo-escalate write installed guidance block into workdir/CLAUDE.md (no DEFER drop)"

smoke_log "all 4 tests PASS (#1151 r2 sudo-escalate contract)"
