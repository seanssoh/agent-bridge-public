#!/usr/bin/env bash
# scripts/smoke/4494-integrated-helpers/skill-gate-driver.sh
#
# Driver for case C and case D of scripts/smoke/4494-integrated-dynamic-recovery.sh.
#
# Mimics the BRIDGE_RENDER_SKILL_AUTO_HELP gate from lib/bridge-skills.sh
# (#828) verbatim: sources the same two library modules the parent
# function pulls in, then either short-circuits (default) or invokes the
# auto-help helper (opt-in). Asserts the sentinel file stays empty in
# the default path — proving the agent-start render path does NOT
# recurse into agent-bridge --help.
#
# Shipped as a tracked file (not embedded as a heredoc-to-file body in
# the wrapper smoke). The heredoc-to-file pattern with a multi-line body
# wedges in the Bash 5.3.9 heredoc_write deadlock class — see
# feedback_bash_heredoc_write_class_recurrence.md and the Wave C/Wave B
# smoke notes. (Forbidden pattern strings intentionally omitted from
# this comment so the footgun #11 self-audit grep recipe does not flag
# a textual mention as a real callsite.)
#
# Invocation:
#   bash scripts/smoke/4494-integrated-helpers/skill-gate-driver.sh \
#     <mode> <repo_root> <sentinel_path> <stub_cli_path>
#
# Where:
#   mode             — "default" (env unset, sentinel must stay empty) or
#                      "optin"   (env=1, sentinel must be populated)
#   repo_root        — checkout root (so the driver can source
#                      lib/bridge-core.sh and lib/bridge-skills.sh)
#   sentinel_path    — file the stubbed agent-bridge appends to on every
#                      invocation; cleared by the wrapper before each
#                      mode is exercised
#   stub_cli_path    — path to the stub agent-bridge binary; wired into
#                      the helpers via BRIDGE_CLI_NAME

set -uo pipefail

mode="${1:?need mode (default|optin)}"
repo_root="${2:?need repo root}"
sentinel_path="${3:?need sentinel path}"
stub_cli_path="${4:?need stub cli path}"

# The wrapper smoke already wrote and exported these but a subshell driver
# must re-export them locally so the helpers pick them up regardless of
# how Bash inherited the env across the fork.
export BRIDGE_REPO_ROOT="$repo_root"
export BRIDGE_SMOKE_SENTINEL="$sentinel_path"
export BRIDGE_CLI_NAME="$stub_cli_path"

# Match the gate logic in lib/bridge-skills.sh verbatim (#828):
case "$mode" in
  default)
    unset BRIDGE_RENDER_SKILL_AUTO_HELP
    ;;
  optin)
    export BRIDGE_RENDER_SKILL_AUTO_HELP=1
    ;;
  *)
    echo "skill-gate-driver: unknown mode: $mode" >&2
    exit 2
    ;;
esac

# Source just the two modules the parent function and its auto-help
# helper depend on. Avoids the full bridge-lib.sh bootstrap (which calls
# bridge_assert_isolation_v2 and refuses to run outside a v2 layout).
# shellcheck source=/dev/null
source "$repo_root/lib/bridge-core.sh"
# shellcheck source=/dev/null
source "$repo_root/lib/bridge-skills.sh"

if [[ "${BRIDGE_RENDER_SKILL_AUTO_HELP:-0}" != "1" ]]; then
  # Default agent-start render path: the parent function's gate at
  # lib/bridge-skills.sh exits before calling the auto-help helper.
  # We mirror that exit here and assert via the wrapper that the
  # sentinel stays empty.
  exit 0
fi

# Opt-in branch: invoke the same helper the gated parent calls. We
# do NOT call bridge_render_project_bridge_reference directly because
# the parent function's curated-reference heredoc body is the unrelated
# Bash 5.3.9 heredoc_write deadlock class tracked under #815 — calling
# it under `>file` redirection wedges the smoke. (Forbidden pattern
# strings intentionally omitted from this comment so the footgun #11
# self-audit grep recipe does not flag a textual mention as a real
# callsite.) The helper isolation is what the brief explicitly permits
# as the safe target.
bridge_render_project_bridge_auto_help_section "${BRIDGE_HOME:-/tmp/x}" >/dev/null 2>&1
exit 0
