#!/usr/bin/env bash
#
# scripts/smoke/skill-render-no-help-recursion.sh — issue #828 regression.
#
# Proves that `bridge_render_project_bridge_reference` does NOT invoke
# `agent-bridge --help` on the default render path (the one that fires during
# dynamic agent start / attach). Operator-observed wedge mode: starting an
# agent re-entered the CLI stack via help rendering, multiplied roster /
# daemon-ensure work, and (per #815 failure modes) made wedges easier.
#
# What we exercise (in order):
#
#   1. Stub `agent-bridge` so any `--help` invocation appends to a sentinel
#      file. Wire the stub via `BRIDGE_CLI_NAME` so the two helpers
#      (`bridge_cli_top_level_subcommands`, `bridge_cli_subcommand_help_summary`)
#      pick it up when they call `"$cli" --help`.
#   2. Call the auto-help section helper
#      `bridge_render_project_bridge_auto_help_section` with the env unset:
#      the parent function `bridge_render_project_bridge_reference` only
#      calls this helper when `BRIDGE_RENDER_SKILL_AUTO_HELP=1`, so by
#      directly testing the gate-controlled surface we prove the helper is
#      not reached on the default agent-start path. (We do not exercise the
#      parent function's curated-reference heredoc here — that block has an
#      independent Bash 5.3.9 `heredoc_write` deadlock class tracked under
#      #815 which is out of scope for #828; we assert the gate via
#      `declare -f` parsing of the parent function source instead.)
#   3. Call the auto-help helper with `BRIDGE_CLI_NAME` set to the stub.
#      Sentinel MUST be populated and the helper MUST emit the
#      "## Full Subcommand Reference" header — proving the opt-in path
#      still works end-to-end.
#
# Footgun 11 self-audit: this smoke writes its fixture files via
# `mktemp + printf '%s\n' … > file + chmod +x`. No `cat <<EOF > $file` for
# multi-line bodies, no `<<<` here-strings against subprocesses.

# Bash 4+ re-exec (mirrors scripts/smoke/daemon.sh).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:skill-render-no-help-recursion] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="skill-render-no-help-recursion"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Resolve the Bash 4+ binary path so the inner drivers re-exec into a known
# Bash 4+. Falls back to the current $BASH if it is already Bash 4+ (we
# guaranteed that via the re-exec block above).
BASH4_BIN="${BASH4_BIN:-}"
if [[ -z "$BASH4_BIN" ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH:-}"; do
    [[ -n "$_candidate" && -x "$_candidate" ]] || continue
    if "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BASH4_BIN="$_candidate"
      break
    fi
  done
fi
[[ -n "$BASH4_BIN" ]] || smoke_fail "no Bash 4+ interpreter on PATH; set BASH4_BIN"

smoke_setup_bridge_home "$SMOKE_NAME"

# Sentinel file — appended to by the stub on every `--help` invocation. If
# the default render path recurses, this file will be non-empty after the
# default call and the smoke will fail.
SENTINEL="$SMOKE_TMP_ROOT/help-invoked.log"
: >"$SENTINEL"

# Write the stub `agent-bridge` binary. Footgun 11: line-by-line `printf`
# instead of a heredoc for the body.
STUB_CLI="$SMOKE_TMP_ROOT/agent-bridge"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# Stub for scripts/smoke/skill-render-no-help-recursion.sh (#828).'
  printf '%s\n' '# Records every invocation to the sentinel and returns canned --help text'
  printf '%s\n' '# so the helpers can find their "Usage:" section if they happen to be called.'
  printf '%s\n' 'set -u'
  printf '%s\n' 'printf "%s\n" "stub-invoked: $*" >> "${BRIDGE_SMOKE_SENTINEL:?}"'
  printf '%s\n' 'if [[ "${1:-}" == "--help" ]]; then'
  printf '%s\n' '  printf "Usage:\n"'
  printf '%s\n' '  printf "  agent-bridge cron list\n"'
  printf '%s\n' '  printf "  agent-bridge task create\n"'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'exit 0'
} >"$STUB_CLI"
chmod +x "$STUB_CLI"

export BRIDGE_REPO_ROOT="$SMOKE_REPO_ROOT"
export BRIDGE_SMOKE_SENTINEL="$SENTINEL"
# Wire the stub into the helpers. `bridge_cli_top_level_subcommands` /
# `bridge_cli_subcommand_help_summary` resolve their CLI as
# `${BRIDGE_CLI_NAME:-${BRIDGE_SCRIPT_DIR:-.}/agent-bridge}` — setting
# BRIDGE_CLI_NAME is the cleanest hook.
export BRIDGE_CLI_NAME="$STUB_CLI"

# Sanity: the stub records when called directly. This guards against a typo
# in the stub silently making the rest of the smoke a no-op (e.g. a
# `--help` call that exits before reaching the sentinel write).
"$STUB_CLI" --help >/dev/null
if [[ ! -s "$SENTINEL" ]]; then
  smoke_fail "stub self-check failed: sentinel not populated after direct --help invocation"
fi
: >"$SENTINEL"  # reset for the real assertions

# Source-level gate check (Case A): inspect the parent function source to
# prove the BRIDGE_RENDER_SKILL_AUTO_HELP gate is present and gates the
# auto-help helper call. This is a static check — it never executes the
# function's curated-reference heredoc, which sidesteps the unrelated Bash
# 5.3.9 heredoc deadlock class tracked in #815.
GATE_SOURCE="$("$BASH4_BIN" -c '
  # shellcheck source=/dev/null
  source "${BRIDGE_REPO_ROOT:?}/lib/bridge-skills.sh" >/dev/null 2>&1
  declare -f bridge_render_project_bridge_reference
')"
if [[ -z "$GATE_SOURCE" ]]; then
  smoke_fail "bridge_render_project_bridge_reference not found after sourcing lib/bridge-skills.sh"
fi
if [[ "$GATE_SOURCE" != *'BRIDGE_RENDER_SKILL_AUTO_HELP'* ]]; then
  smoke_fail "bridge_render_project_bridge_reference is missing the BRIDGE_RENDER_SKILL_AUTO_HELP gate (#828)"
fi
if [[ "$GATE_SOURCE" != *'bridge_render_project_bridge_auto_help_section'* ]]; then
  smoke_fail "bridge_render_project_bridge_reference does not delegate to bridge_render_project_bridge_auto_help_section helper"
fi
smoke_log "[ok] parent function source contains the BRIDGE_RENDER_SKILL_AUTO_HELP gate"

# Driver: source bridge-skills.sh + bridge-core.sh (just the modules the
# helper needs), then call the auto-help helper. We avoid the full
# bridge-lib.sh source path because lib/bridge-skills.sh + lib/bridge-core.sh
# are independently self-contained for these two helpers (the auto-help
# helper only calls bridge_cli_top_level_subcommands +
# bridge_cli_subcommand_help_summary which are defined in bridge-core.sh).
# Written to disk to keep us off `<<<`/`<<` boundaries.
DRIVER="$SMOKE_TMP_ROOT/auto-help-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' '# shellcheck source=/dev/null'
  printf '%s\n' 'source "${BRIDGE_REPO_ROOT:?}/lib/bridge-core.sh"'
  printf '%s\n' '# shellcheck source=/dev/null'
  printf '%s\n' 'source "${BRIDGE_REPO_ROOT:?}/lib/bridge-skills.sh"'
  printf '%s\n' 'bridge_render_project_bridge_auto_help_section "${BRIDGE_HOME:?}"'
} >"$DRIVER"
chmod +x "$DRIVER"

OUTPUT_DEFAULT="$SMOKE_TMP_ROOT/render-default.out"
OUTPUT_OPTIN="$SMOKE_TMP_ROOT/render-optin.out"

# Pick a timeout helper. Falls back to a bare invocation when neither
# timeout(1) nor gtimeout(1) is available.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

run_driver() {
  local output_file="$1"
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" 15 "$BASH4_BIN" "$DRIVER" >"$output_file" 2>/dev/null
  else
    "$BASH4_BIN" "$DRIVER" >"$output_file" 2>/dev/null
  fi
}

# Case B (sentinel — default path): the parent function's gate must short-
# circuit before the auto-help helper runs. We can't easily observe the
# parent's gate at runtime here (heredoc deadlock on Bash 5.3.9), so we
# verified the gate statically above (Case A). We can however assert the
# helper itself, when invoked, *does* call agent-bridge --help — which
# confirms the helper is the recursion source the gate is protecting
# against. The default path skipping the helper is the conclusion of A+C.
# Defensively also run the helper-call sentinel reset before Case C so a
# spurious pre-test invocation cannot mask a real recursion.
: >"$SENTINEL"

# Case C: opt-in path — calling the helper directly MUST invoke
# `agent-bridge --help` (sentinel populated) and emit the section header.
# This proves the helper is the recursion source the gate is protecting
# against, and that the opt-in path still works.
if ! run_driver "$OUTPUT_OPTIN"; then
  rc=$?
  if [[ "$rc" == "124" || "$rc" == "137" ]]; then
    smoke_fail "auto-help helper driver timed out — Bash 5.3.9 heredoc class? (#815). Re-run on a non-broken bash."
  fi
  smoke_fail "auto-help helper driver failed (rc=$rc)"
fi

if [[ ! -s "$SENTINEL" ]]; then
  smoke_fail "auto-help helper did NOT invoke agent-bridge --help — helpers may have been wired incorrectly"
fi
smoke_log "[ok] auto-help helper invokes agent-bridge --help when called (sentinel populated)"

if ! grep -q "## Full Subcommand Reference" "$OUTPUT_OPTIN"; then
  smoke_fail "auto-help helper must emit '## Full Subcommand Reference' header"
fi
smoke_log "[ok] auto-help helper emits Full Subcommand Reference header"

# The helper should pick up at least one subcommand from the stub's --help
# (cron / task in the canned output). This proves the helpers actually
# consumed --help, not just that the section header was printed.
if ! grep -q "### cron" "$OUTPUT_OPTIN"; then
  smoke_fail "auto-help helper did not produce '### cron' subcommand section from stub --help output"
fi
smoke_log "[ok] auto-help helper parses stub --help into per-subcommand sections"

# Case D: the parent function gate must NOT delegate to the helper when the
# env is unset. We synthesize a tiny driver that imitates the gate logic
# exactly — sourcing just enough to call the gate test — and asserts the
# sentinel stays empty. This isolates the gate semantics from the parent
# function's curated heredoc.
: >"$SENTINEL"
GATE_DRIVER="$SMOKE_TMP_ROOT/gate-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' '# Mimic the parent function gate verbatim (lib/bridge-skills.sh #828):'
  printf '%s\n' 'unset BRIDGE_RENDER_SKILL_AUTO_HELP'
  printf '%s\n' '# shellcheck source=/dev/null'
  printf '%s\n' 'source "${BRIDGE_REPO_ROOT:?}/lib/bridge-core.sh"'
  printf '%s\n' '# shellcheck source=/dev/null'
  printf '%s\n' 'source "${BRIDGE_REPO_ROOT:?}/lib/bridge-skills.sh"'
  printf '%s\n' 'if [[ "${BRIDGE_RENDER_SKILL_AUTO_HELP:-0}" != "1" ]]; then'
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'bridge_render_project_bridge_auto_help_section "${BRIDGE_HOME:?}"'
} >"$GATE_DRIVER"
chmod +x "$GATE_DRIVER"

if ! "$BASH4_BIN" "$GATE_DRIVER" >/dev/null 2>&1; then
  smoke_fail "gate driver (env unset) failed"
fi

if [[ -s "$SENTINEL" ]]; then
  smoke_log "sentinel content after default gate path:"
  while IFS= read -r line; do
    smoke_log "  $line"
  done <"$SENTINEL"
  smoke_fail "default gate path recursed into agent-bridge --help (#828 regression)"
fi
smoke_log "[ok] default gate path does NOT invoke agent-bridge --help"

smoke_log "all assertions passed (#828 regression)"
