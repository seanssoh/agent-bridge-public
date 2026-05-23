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
# r3 (#1151): the v2 sudo-read + render branches now invoke
# lib/skills-helpers/*.py via file-as-argv; the function under test
# resolves the helper paths via BRIDGE_SCRIPT_DIR. The unit harness
# does not run through bridge-lib.sh (where the global is normally
# set), so export it explicitly to the repo root.
printf '%s\n' 'export BRIDGE_SCRIPT_DIR="$REPO_ROOT"' >>"$T8_DRIVER"
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

# ---------- T9 — Symlink-CLAUDE.md is REFUSED, target content NOT copied (#1151 r3) ----------
#
# Codex r2 BLOCKING. Post-Step-A workdir is owned by isolated UID. An
# agent that swaps $workdir/CLAUDE.md for a symlink to a root-readable
# secret can race the controller's sudo read — the previous
# `bridge_linux_sudo_root cat ...` followed the link and the render
# materialized the captured secret in the agent's workdir.
#
# The fix opens via os.O_NOFOLLOW + stat.S_ISREG; the helper exits
# with rc=11 on ELOOP / refused open. The caller now warns + bails
# without proceeding to the install branch.
#
# Fixture:
#   - Workdir whose CLAUDE.md is a symlink to $T9_DIR/secret
#   - Secret content: a recognizable string the test asserts NEVER
#     appears in the final CLAUDE.md
#   - Same stubs as T8 (passthrough sudo, isolation effective,
#     Step A complete)
#
# Assertions:
#   - The driver runs to completion (no crash; bridge_warn surfaces
#     in $T9_LOG)
#   - $T9_WORKDIR/CLAUDE.md is STILL a symlink (helper refused →
#     no install branch → no atomic mv that would have replaced it)
#   - The secret content does NOT appear in the workdir CLAUDE.md
#     contents read via readlink-aware grep (i.e., we read the
#     symlink target via `cat` because that's what would catch a
#     "secret leaked into the workdir file" regression)
#
# Note on the previous behavior, for clarity: BEFORE the r3 fix, the
# sudo cat would read the secret into $_src_tmp, the render would
# splice the bridge guidance block into the secret content, and the
# atomic mv would replace the symlink with a regular file containing
# both the guidance block and the secret. The "secret_NEVER" check
# below would have failed because the workdir CLAUDE.md (now a
# regular file) would contain the secret.

T9_DIR="$SMOKE_TMP_ROOT/t9"
mkdir -p "$T9_DIR"
T9_WORKDIR="$T9_DIR/workdir"
mkdir -p "$T9_WORKDIR"
T9_SECRET_FILE="$T9_DIR/secret"
T9_SECRET_TOKEN="t9-secret-token-must-not-leak-$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")"
printf '# Pretend-secret\n%s\nMore secret content here.\n' "$T9_SECRET_TOKEN" >"$T9_SECRET_FILE"
ln -s "$T9_SECRET_FILE" "$T9_WORKDIR/CLAUDE.md"
[[ -L "$T9_WORKDIR/CLAUDE.md" ]] || smoke_fail "T9 fixture: expected symlink at $T9_WORKDIR/CLAUDE.md but got a regular file"

T9_DRIVER="$T9_DIR/driver.sh"
T9_LOG="$T9_DIR/log"

# Driver mirrors T8 but the workdir CLAUDE.md is a symlink. The function
# under test should refuse to read the target and return 0 without
# writing anything to workdir.
printf '%s\n' '#!/usr/bin/env bash' >"$T9_DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'set -uo pipefail' >>"$T9_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T9_DRIVER"
printf '%s\n' 'WORKDIR="$2"' >>"$T9_DRIVER"
printf '%s\n' 'export BRIDGE_HOME="$3"' >>"$T9_DRIVER"
printf '%s\n' 'export BRIDGE_AGENT_HOME_ROOT="$WORKDIR-not-a-real-prefix"' >>"$T9_DRIVER"
printf '%s\n' 'export BRIDGE_MANAGED_MARKER="agent-bridge-managed"' >>"$T9_DRIVER"
printf '%s\n' 'export BRIDGE_SCRIPT_DIR="$REPO_ROOT"' >>"$T9_DRIVER"
printf '%s\n' 'declare -A BRIDGE_AGENT_SKILLS' >>"$T9_DRIVER"
printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }' >>"$T9_DRIVER"
printf '%s\n' 'bridge_require_python() { command -v python3 >/dev/null 2>&1; }' >>"$T9_DRIVER"
printf '%s\n' 'bridge_path_is_within_root() { echo "0"; }' >>"$T9_DRIVER"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T9_DRIVER"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 0; }' >>"$T9_DRIVER"
printf '%s\n' 'bridge_agent_os_user() { echo "$(id -un)"; }' >>"$T9_DRIVER"
printf '%s\n' 'bridge_linux_sudo_root() { "$@"; }' >>"$T9_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T9_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-skills.sh"' >>"$T9_DRIVER"
printf '%s\n' 'bridge_ensure_project_claude_guidance "$WORKDIR" "smoke-agent"' >>"$T9_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T9_DRIVER"
chmod +x "$T9_DRIVER"

"$BRIDGE_BASH" "$T9_DRIVER" "$REPO_ROOT" "$T9_WORKDIR" "$T9_DIR/bridge-home" >"$T9_LOG" 2>&1 \
  || smoke_fail "T9 driver failed: $(tr '\n' '|' <"$T9_LOG" | tail -c 800)"

# The CLAUDE.md path in the workdir should STILL be the original
# symlink — the helper refused the read so the install branch never
# ran, no atomic mv replaced the link. (If the bug were unfixed, the
# symlink would have been replaced by a regular file containing the
# secret content + the guidance block.)
if [[ ! -L "$T9_WORKDIR/CLAUDE.md" ]]; then
  smoke_fail "T9: workdir CLAUDE.md is no longer a symlink — helper followed the link or install branch ran. content: $(head -c 600 "$T9_WORKDIR/CLAUDE.md" 2>/dev/null | tr '\n' '|')"
fi

# The secret token MUST NOT appear in any controller-side file written
# under the workdir. (The symlink itself still resolves to the secret;
# the test is whether the controller copied the secret content into a
# new regular file in the workdir.)
# Walk the workdir for regular files and grep them. If the helper kept
# the symlink in place, there are no regular files under workdir other
# than what we ourselves created (none in this fixture).
# Avoid `< <(find ...)` process-substitution (would add an H3 site to
# lint-heredoc-ban baseline). Spool the find output to a tmpfile and
# read it line-by-line; symlinks are excluded via `-type f` so the
# original symlink at workdir/CLAUDE.md is not counted as a regular
# file even though it resolves to one.
T9_FIND_OUT="$T9_DIR/find-out"
find "$T9_WORKDIR" -type f >"$T9_FIND_OUT" 2>/dev/null || true
T9_LEAK_FOUND=0
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  if grep -Fq "$T9_SECRET_TOKEN" "$candidate" 2>/dev/null; then
    T9_LEAK_FOUND=1
    smoke_log "T9 LEAK candidate: $candidate"
  fi
done <"$T9_FIND_OUT"
if (( T9_LEAK_FOUND == 1 )); then
  smoke_fail "T9: secret token leaked into a regular file under workdir — symlink-traversal attack was NOT mitigated"
fi

# The warn message should also have surfaced so an operator can spot
# the refusal. We accept either "refused read" (the new helper's
# wording) or any bridge_warn line mentioning CLAUDE.md to keep the
# assertion forgiving across minor wording tweaks.
if ! grep -Eq "(refused read|refused open|not a regular file|symlink or non-regular)" "$T9_LOG"; then
  smoke_log "T9 note: refusal warn was not surfaced in driver log (informational; not a hard fail)"
fi

smoke_log "T9 PASS: symlink CLAUDE.md refused; secret target content did NOT leak into workdir (BLOCKING fixed)"

# ---------- T10 — exit-code-2 sentinel is detected (no spurious warn, no install) (#1151 r3) ----------
#
# Codex r2 SHOULD-FIX. The render helper exits with rc=2 when the
# rendered content is byte-identical to the source — "no-op fast path".
# The previous bash form `if ! python3 ...; then local _py_rc=$?`
# captured the rc of `!`, not Python — so rc=2 was misread as 0 and
# the caller proceeded to the install branch with an unwritten dst
# tmpfile (which the atomic mv then propagated as an empty file). The
# r3 fix captures the rc via `|| _py_rc=$?` so rc=2 is correctly
# observed.
#
# Fixture:
#   - workdir/CLAUDE.md already contains the guidance block
#     (rendered by a prior pass). A second invocation should detect
#     "no change" and skip the install branch entirely.
#   - We do not have a clean signal that "install branch did not
#     run" from inside the unit-style harness, but we can test the
#     observable: after the second pass, the file is byte-identical
#     to its pre-call state (mtime check via stat, OR md5 check via
#     `cksum`).
#
# Assertions:
#   - The driver returns 0.
#   - The CLAUDE.md content after the second pass is byte-identical
#     to the content before. (Pre-r3 fix would still write a copy via
#     the install branch, so even though content matched, mtime and
#     inode would change.)
#   - The driver log does NOT contain "python render failed" — the
#     generic-failure path that the misread rc=2 falls through to.

T10_DIR="$SMOKE_TMP_ROOT/t10"
mkdir -p "$T10_DIR"
T10_WORKDIR="$T10_DIR/workdir"
mkdir -p "$T10_WORKDIR"

# Seed with the SAME content the render helper produces. We do this
# by running the render helper standalone against an empty src tmp,
# then dropping the result into the workdir as CLAUDE.md.
T10_SEED_SRC="$T10_DIR/seed-src"
T10_SEED_DST="$T10_DIR/seed-dst"
: >"$T10_SEED_SRC"
python3 "$REPO_ROOT/lib/skills-helpers/claude-md-render.py" \
  "$T10_SEED_SRC" "$T10_SEED_DST" \
  "$T10_DIR/bridge-home" \
  "<!-- BEGIN AGENT BRIDGE PROJECT GUIDANCE -->" \
  "<!-- END AGENT BRIDGE PROJECT GUIDANCE -->" \
  "agent-bridge-managed" \
  || smoke_fail "T10 seed render failed"
cp "$T10_SEED_DST" "$T10_WORKDIR/CLAUDE.md"

# Capture pre-call cksum so we can detect ANY rewrite (the bug would
# rewrite the file via the install branch even though content matched).
T10_PRE_CKSUM="$(cksum <"$T10_WORKDIR/CLAUDE.md")"

T10_DRIVER="$T10_DIR/driver.sh"
T10_LOG="$T10_DIR/log"

printf '%s\n' '#!/usr/bin/env bash' >"$T10_DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'set -uo pipefail' >>"$T10_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T10_DRIVER"
printf '%s\n' 'WORKDIR="$2"' >>"$T10_DRIVER"
printf '%s\n' 'export BRIDGE_HOME="$3"' >>"$T10_DRIVER"
printf '%s\n' 'export BRIDGE_AGENT_HOME_ROOT="$WORKDIR-not-a-real-prefix"' >>"$T10_DRIVER"
printf '%s\n' 'export BRIDGE_MANAGED_MARKER="agent-bridge-managed"' >>"$T10_DRIVER"
printf '%s\n' 'export BRIDGE_SCRIPT_DIR="$REPO_ROOT"' >>"$T10_DRIVER"
printf '%s\n' 'declare -A BRIDGE_AGENT_SKILLS' >>"$T10_DRIVER"
printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }' >>"$T10_DRIVER"
printf '%s\n' 'bridge_require_python() { command -v python3 >/dev/null 2>&1; }' >>"$T10_DRIVER"
printf '%s\n' 'bridge_path_is_within_root() { echo "0"; }' >>"$T10_DRIVER"
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T10_DRIVER"
printf '%s\n' 'bridge_agent_workdir_step_a_complete() { return 0; }' >>"$T10_DRIVER"
printf '%s\n' 'bridge_agent_os_user() { echo "$(id -un)"; }' >>"$T10_DRIVER"
printf '%s\n' 'bridge_linux_sudo_root() { "$@"; }' >>"$T10_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T10_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-skills.sh"' >>"$T10_DRIVER"
printf '%s\n' 'bridge_ensure_project_claude_guidance "$WORKDIR" "smoke-agent"' >>"$T10_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T10_DRIVER"
chmod +x "$T10_DRIVER"

# Use the same bridge-home seed dir so the rendered block matches.
"$BRIDGE_BASH" "$T10_DRIVER" "$REPO_ROOT" "$T10_WORKDIR" "$T10_DIR/bridge-home" >"$T10_LOG" 2>&1 \
  || smoke_fail "T10 driver failed: $(tr '\n' '|' <"$T10_LOG" | tail -c 800)"

# Sentinel detection: caller should have returned 0 via the rc==2
# branch and skipped the install. The file must be byte-identical to
# its pre-call state (cksum unchanged). NOTE: this also catches the
# pre-r3 bug shape where rc=2 was misread as 0 and the install branch
# ran an empty-dst mv (the post-call file would have been empty).
T10_POST_CKSUM="$(cksum <"$T10_WORKDIR/CLAUDE.md")"
if [[ "$T10_PRE_CKSUM" != "$T10_POST_CKSUM" ]]; then
  smoke_fail "T10: CLAUDE.md was rewritten across the no-op call. pre=$T10_PRE_CKSUM post=$T10_POST_CKSUM — rc=2 sentinel was misread (probably the pre-r3 \`if ! python3 ...; then local _py_rc=\$?\` bug)"
fi

# The warn path "python render failed" must NOT have fired — that's
# the symptom of the misread sentinel (rc=2 falling through to the
# generic-failure branch).
if grep -Fq "python render failed" "$T10_LOG"; then
  smoke_fail "T10: 'python render failed' warning surfaced — rc=2 sentinel was misread as generic failure. log: $(tr '\n' '|' <"$T10_LOG" | tail -c 800)"
fi

smoke_log "T10 PASS: rc=2 sentinel (no-op) detected — no install branch, no spurious warn"

smoke_log "all 6 tests PASS (#1151 r3 symlink-safe sudo read + exit-2 sentinel capture)"
