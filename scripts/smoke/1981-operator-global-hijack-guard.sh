#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1981-operator-global-hijack-guard.sh — Issue #1981 (SAFETY).
#
# `bridge_link_claude_settings_to_shared` (lib/bridge-hooks.sh) symlinks
# `<workdir>/.claude/settings.json` -> the agent's `settings.effective.json` at
# launch. With NO guard, a dynamic agent launched (or mis-launched) with
# `workdir=$HOME` (the operator's home) would overwrite the operator's REAL
# global `~/.claude/settings.json` with a symlink into a bridge-managed agent's
# effective settings — hijacking the operator's own vanilla Claude sessions
# (bridge hooks leak in), and stranding an orphan symlink into a dead agent dir
# when the agent is closed.
#
# Fix (#1981): a launch-time operator-global hijack guard runs FIRST — before any
# link/render side effect (before #1945 F7's deferral + iso-UID render, before the
# #1766 group-publish, before the link-shared-settings call). When the managed
# workdir resolves the link target onto the operator global, the function skips
# the whole operation and warns loudly. The operator global stays a regular file.
#
# This smoke is HOST-AGNOSTIC (macOS dev hosts + Linux CI). It drives the real
# bash function `bridge_link_claude_settings_to_shared` with the downstream
# python side effects stubbed so the only thing that can mutate the filesystem is
# the `link-shared-settings` step — modeled by a stub that ACTUALLY creates the
# symlink, exactly like the real `cmd_link_shared_settings`. That makes the
# mutation test non-vacuous: remove the guard and the operator global becomes a
# symlink = the bug.
#
# Cases:
#   T1 — workdir == operator HOME -> operator global stays a REGULAR FILE, no
#        symlink, link-shared-settings NEVER invoked, loud #1981 warning. (teeth)
#   T2 — a NORMAL agent workdir (its own dir) -> link IS created to its own
#        effective file (no regression; the normal path is unchanged).
#   T3 — reverse direction: effective_file == operator global -> refused.
#   T4 — MUTATION: with the guard predicate forced FALSE, the same T1 launch
#        DOES hijack the operator global (proves T1 is non-vacuous).
#
# Footgun #11 (heredoc_write deadlock class): the driver is built with
# `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash functions; no `$()`
# capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1981-operator-global-hijack-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# The shared driver: sources bridge-hooks.sh, stubs the operator-home resolver
# and every downstream side effect, then calls bridge_link_claude_settings_to_shared.
# The ONLY filesystem-mutating stub is `bridge_hooks_python link-shared-settings`,
# which models the real cmd_link_shared_settings by atomically replacing
# <workdir>/.claude/settings.json with a symlink to the shared-settings file.
# Warnings go to stderr; "DRIVER_OK" is printed on success.
#
# argv to the driver (via env):
#   DRV_OPERATOR_HOME  — fixture operator HOME (resolver returns this)
#   DRV_WORKDIR        — the managed workdir passed to the function
#   DRV_FORCE_NO_GUARD — when "1", override the guard predicate to FALSE (mutation)
DRIVER="$SMOKE_TMP_ROOT/drive-link.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 (heredoc-stdin) off the table
printf '%s\n' 'set -uo pipefail' >>"$DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-hooks.sh"' >>"$DRIVER"
printf '%s\n' '# Resolver -> the fixture operator HOME.' >>"$DRIVER"
printf '%s\n' 'bridge_agent_operator_home_dir() { printf "%s" "$DRV_OPERATOR_HOME"; }' >>"$DRIVER"
printf '%s\n' '# Keep the function on the SHARED, non-isolated, no-agent legacy path so the' >>"$DRIVER"
printf '%s\n' '# only side effect reachable is the final link-shared-settings call below.' >>"$DRIVER"
printf '%s\n' 'bridge_claude_settings_mode() { printf "shared"; }' >>"$DRIVER"
printf '%s\n' 'bridge_hook_shared_settings_effective_file() { printf "%s" "$DRV_EFFECTIVE_FILE"; }' >>"$DRIVER"
printf '%s\n' 'bridge_hook_shared_settings_base_file() { printf "%s/base.json" "$DRV_TMP"; }' >>"$DRIVER"
printf '%s\n' 'bridge_hook_shared_settings_overlay_file() { printf "%s/overlay.json" "$DRV_TMP"; }' >>"$DRIVER"
printf '%s\n' 'bridge_hook_operator_global_settings_file() { printf "%s/.claude/settings.json" "$DRV_OPERATOR_HOME"; }' >>"$DRIVER"
printf '%s\n' '# Iso/channel probes are command -v gated in the function; undefine so the v2' >>"$DRIVER"
printf '%s\n' '# branches are never taken on this host. (They are not defined when only' >>"$DRIVER"
printf '%s\n' '# bridge-hooks.sh is sourced, so nothing to do — documented for clarity.)' >>"$DRIVER"
printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }' >>"$DRIVER"
printf '%s\n' '# Model the real cmd_link_shared_settings: replace settings.json with a' >>"$DRIVER"
printf '%s\n' '# symlink to the shared-settings file. This is the ONLY mutating stub.' >>"$DRIVER"
printf '%s\n' '# render-shared-settings + everything else is a no-op.' >>"$DRIVER"
printf '%s\n' 'bridge_hooks_python() {' >>"$DRIVER"
printf '%s\n' '  local sub="${1-}"; shift || true' >>"$DRIVER"
printf '%s\n' '  if [[ "$sub" == "link-shared-settings" ]]; then' >>"$DRIVER"
printf '%s\n' '    local wd="" sf=""' >>"$DRIVER"
printf '%s\n' '    while [[ $# -gt 0 ]]; do' >>"$DRIVER"
printf '%s\n' '      case "$1" in' >>"$DRIVER"
printf '%s\n' '        --workdir) wd="$2"; shift 2 ;;' >>"$DRIVER"
printf '%s\n' '        --shared-settings-file) sf="$2"; shift 2 ;;' >>"$DRIVER"
printf '%s\n' '        *) shift ;;' >>"$DRIVER"
printf '%s\n' '      esac' >>"$DRIVER"
printf '%s\n' '    done' >>"$DRIVER"
printf '%s\n' '    mkdir -p "$wd/.claude"' >>"$DRIVER"
printf '%s\n' '    ln -snf "$sf" "$wd/.claude/settings.json"' >>"$DRIVER"
printf '%s\n' '    printf "LINK_CREATED %s -> %s\n" "$wd/.claude/settings.json" "$sf" >&2' >>"$DRIVER"
printf '%s\n' '    return 0' >>"$DRIVER"
printf '%s\n' '  fi' >>"$DRIVER"
printf '%s\n' '  return 0' >>"$DRIVER"
printf '%s\n' '}' >>"$DRIVER"
printf '%s\n' '# MUTATION knob: force the hijack-guard predicate to always-false so the' >>"$DRIVER"
printf '%s\n' '# function proceeds to the link step even when workdir == operator HOME.' >>"$DRIVER"
printf '%s\n' 'if [[ "${DRV_FORCE_NO_GUARD:-0}" == "1" ]]; then' >>"$DRIVER"
printf '%s\n' '  bridge_link_settings_targets_operator_global() { return 1; }' >>"$DRIVER"
printf '%s\n' 'fi' >>"$DRIVER"
printf '%s\n' 'bridge_link_claude_settings_to_shared "$DRV_WORKDIR" "" ""' >>"$DRIVER"
printf '%s\n' 'printf "DRIVER_OK\n"' >>"$DRIVER"

run_driver() {
  # $1 operator_home  $2 workdir  $3 effective_file  $4 force_no_guard  $5 errfile
  REPO_ROOT="$REPO_ROOT" \
  DRV_OPERATOR_HOME="$1" \
  DRV_WORKDIR="$2" \
  DRV_EFFECTIVE_FILE="$3" \
  DRV_FORCE_NO_GUARD="$4" \
  DRV_TMP="$SMOKE_TMP_ROOT" \
    bash "$DRIVER" 2>"$5"
}

# Build the operator HOME fixture with a REAL regular settings.json.
OP_HOME="$SMOKE_TMP_ROOT/operator-home"
mkdir -p "$OP_HOME/.claude"
OP_GLOBAL="$OP_HOME/.claude/settings.json"
printf '%s\n' '{"operator": "real-global", "model": "opusplan"}' >"$OP_GLOBAL"

# A bridge-managed effective file (the link target the function would point at).
EFFECTIVE="$SMOKE_TMP_ROOT/agents/.claude/settings.effective.json"  # noqa: iso-helper-boundary — test scaffolding under a temp root, not a controller->iso boundary callsite
mkdir -p "$SMOKE_TMP_ROOT/agents/.claude"
printf '%s\n' '{"bridge": "effective"}' >"$EFFECTIVE"

# ---------- T1 — workdir == operator HOME -> operator global protected ----------

T1_ERR="$SMOKE_TMP_ROOT/t1.err"
T1_OUT="$(run_driver "$OP_HOME" "$OP_HOME" "$EFFECTIVE" "0" "$T1_ERR")" \
  || smoke_fail "T1 driver failed rc=$? — out: $T1_OUT; err: $(cat "$T1_ERR" 2>/dev/null)"
T1_ERR_BODY="$(cat "$T1_ERR" 2>/dev/null || printf '')"

smoke_assert_contains "$T1_OUT" "DRIVER_OK" "T1 function returned cleanly (return 0, not an error)"
# The core teeth: the operator global is STILL a regular file, NOT a symlink.
[[ -f "$OP_GLOBAL" && ! -L "$OP_GLOBAL" ]] \
  || smoke_fail "T1 operator global MUST stay a regular file — got: $(ls -l "$OP_GLOBAL" 2>/dev/null)"
# Its content is untouched.
smoke_assert_contains "$(cat "$OP_GLOBAL" 2>/dev/null)" "real-global" \
  "T1 operator global content preserved (not rewritten)"
# The link step was never invoked.
smoke_assert_not_contains "$T1_ERR_BODY" "LINK_CREATED" \
  "T1 link-shared-settings MUST NOT run when workdir is the operator HOME"
# A loud #1981 warning was emitted.
smoke_assert_contains "$T1_ERR_BODY" "[#1981]" \
  "T1 a loud #1981 warning MUST be emitted"
smoke_assert_contains "$T1_ERR_BODY" "operator" \
  "T1 the warning names the operator-global contamination"
smoke_log "T1 PASS: workdir=operator-HOME -> operator global stays a regular file, no link, warning emitted"

# ---------- T2 — a NORMAL agent workdir -> link created (no regression) ----------

NORMAL_WD="$SMOKE_TMP_ROOT/normal-agent-workdir"
mkdir -p "$NORMAL_WD"
T2_ERR="$SMOKE_TMP_ROOT/t2.err"
T2_OUT="$(run_driver "$OP_HOME" "$NORMAL_WD" "$EFFECTIVE" "0" "$T2_ERR")" \
  || smoke_fail "T2 driver failed rc=$? — out: $T2_OUT; err: $(cat "$T2_ERR" 2>/dev/null)"
T2_ERR_BODY="$(cat "$T2_ERR" 2>/dev/null || printf '')"

smoke_assert_contains "$T2_OUT" "DRIVER_OK" "T2 function returned cleanly"
# The normal agent's settings.json IS now a symlink to its effective file.
[[ -L "$NORMAL_WD/.claude/settings.json" ]] \
  || smoke_fail "T2 normal agent workdir MUST get its settings.json symlinked (no regression) — got: $(ls -l "$NORMAL_WD/.claude/settings.json" 2>/dev/null)"
smoke_assert_contains "$T2_ERR_BODY" "LINK_CREATED" \
  "T2 link-shared-settings MUST run for a normal agent workdir"
smoke_assert_not_contains "$T2_ERR_BODY" "[#1981]" \
  "T2 the #1981 guard MUST NOT fire on a normal agent workdir"
# And the operator global is untouched.
[[ -f "$OP_GLOBAL" && ! -L "$OP_GLOBAL" ]] \
  || smoke_fail "T2 operator global must remain a regular file"
smoke_log "T2 PASS: normal agent workdir still links to its own effective file (no regression)"

# ---------- T3 — reverse direction: effective_file == operator global -> refused -

# Re-seed the operator global (T2 did not touch it, but be explicit).
printf '%s\n' '{"operator": "real-global"}' >"$OP_GLOBAL"
REV_WD="$SMOKE_TMP_ROOT/reverse-agent-workdir"
mkdir -p "$REV_WD"
T3_ERR="$SMOKE_TMP_ROOT/t3.err"
# effective_file is the operator global itself -> the reverse re-check must refuse.
T3_OUT="$(run_driver "$OP_HOME" "$REV_WD" "$OP_GLOBAL" "0" "$T3_ERR")" \
  || smoke_fail "T3 driver failed rc=$? — out: $T3_OUT; err: $(cat "$T3_ERR" 2>/dev/null)"
T3_ERR_BODY="$(cat "$T3_ERR" 2>/dev/null || printf '')"

smoke_assert_contains "$T3_OUT" "DRIVER_OK" "T3 function returned cleanly"
smoke_assert_contains "$T3_ERR_BODY" "[#1981]" \
  "T3 reverse-direction (effective_file == operator global) MUST be refused with a #1981 warning"
smoke_assert_not_contains "$T3_ERR_BODY" "LINK_CREATED" \
  "T3 reverse-direction MUST NOT reach the link step"
[[ -f "$OP_GLOBAL" && ! -L "$OP_GLOBAL" ]] \
  || smoke_fail "T3 operator global must remain a regular file"
smoke_log "T3 PASS: reverse direction (operator global as link source) refused"

# ---------- T4 — MUTATION: guard forced off -> the bug reproduces ----------------

# Same T1 launch (workdir == operator HOME) but with the guard predicate forced
# always-false. The link step now runs and HIJACKS the operator global into a
# symlink — proving T1's protection is non-vacuous.
printf '%s\n' '{"operator": "real-global"}' >"$OP_GLOBAL"
[[ -L "$OP_GLOBAL" ]] && smoke_fail "T4 precondition: operator global must start as a regular file"
T4_ERR="$SMOKE_TMP_ROOT/t4.err"
T4_OUT="$(run_driver "$OP_HOME" "$OP_HOME" "$EFFECTIVE" "1" "$T4_ERR")" \
  || smoke_fail "T4 driver failed rc=$? — out: $T4_OUT; err: $(cat "$T4_ERR" 2>/dev/null)"
T4_ERR_BODY="$(cat "$T4_ERR" 2>/dev/null || printf '')"

smoke_assert_contains "$T4_OUT" "DRIVER_OK" "T4 function returned cleanly (the mutation still completes)"
# WITHOUT the guard, the operator global is now a symlink = the #1981 bug.
[[ -L "$OP_GLOBAL" ]] \
  || smoke_fail "T4 mutation FAILED to reproduce: with the guard forced off, the operator global should have become a symlink (the bug). The smoke would be VACUOUS — got: $(ls -l "$OP_GLOBAL" 2>/dev/null)"
smoke_assert_contains "$T4_ERR_BODY" "LINK_CREATED" \
  "T4 mutation: the link step runs when the guard is disabled"
smoke_log "T4 PASS: guard-off mutation reproduces the hijack (operator global -> symlink) — T1 is non-vacuous"

smoke_log "all 4 tests PASS (#1981)"
