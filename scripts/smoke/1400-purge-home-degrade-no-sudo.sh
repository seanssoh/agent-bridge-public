#!/usr/bin/env bash
# scripts/smoke/1400-purge-home-degrade-no-sudo.sh — issue #1400.
#
# `bridge_linux_sudo_root` `bridge_die`s "linux-user isolation requires
# sudo" → exit 1 on a sudo-less Linux host (e.g. a minimal container).
# Two best-effort / probe paths route through it where escalation is
# both impossible AND unnecessary:
#
#   1. `agent delete --purge-home` on a SHARED-mode agent. The home is
#      controller-owned, so a plain `rm` succeeds, but the unconditional
#      sudo escalation `die`s before `|| bridge_warn` can catch it.
#   2. The iso per-UID plugin manifest probe
#      (`_bridge_claude_plugin_bridge_manifest_has_spec`). The fatal
#      escalation `die`s inside a command substitution, so the documented
#      step-2 ab-shared shared-cache fallback is never reached and the
#      plugin check fails closed.
#
# The fix introduces a non-fatal sibling `bridge_linux_sudo_root_best_
# effort`: identical escalation logic (direct off Linux, direct as root,
# `sudo -n` as a non-root Linux caller) EXCEPT that when `sudo` is absent
# it degrades to a direct invocation instead of `bridge_die`. This smoke
# pins the helper's contract so a future change cannot silently
# re-introduce the fatal escalation on the degrade-to-direct path.
#
# Probe shape: the helper lives in lib/bridge-agents.sh, which sources
# standalone. We source it inside a file-as-argv probe (`bash $file`, not
# `bash <<PROBE` — footgun #11) with `uname`/`command`/`sudo`/`bridge_die`
# shimmed to RECORD decisions instead of mutating the host or exiting.
#
# Cases:
#   C1. Sudo-less Linux host → DEGRADE: best_effort runs the command
#       directly (RAN row), NO DIE, returns the command's own rc.
#   C2. Sudo-less Linux host → the FATAL sibling still `die`s (proves
#       the bug exists and that the degrade is the behavioral difference,
#       not a no-op).
#   C3. Linux host WITH sudo → ESCALATE: best_effort routes through
#       `sudo -n` exactly like the fatal variant (boundary not weakened
#       on a provisioned isolated install).
#   C4. Non-Linux (macOS) host → DIRECT: best_effort runs the command
#       directly without sudo (matches `bridge_linux_sudo_root`).
#   C5. Sudo-less Linux host → the degraded direct call PROPAGATES the
#       command's non-zero rc (best-effort callers rely on `|| bridge_warn`
#       still firing on a real rm failure).

set -euo pipefail

SMOKE_NAME="1400-purge-home-degrade-no-sudo"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

smoke_require_cmd mktemp
smoke_make_temp_root "$SMOKE_NAME"
trap 'smoke_cleanup_temp_root' EXIT

# Run the real bridge_linux_sudo_root{,_best_effort} under a synthetic
# host via shims. Emits a decision trace the caller greps:
#   RAN <cmd...>      — the helper dispatched the command directly
#   SUDO <cmd...>     — the helper escalated via `sudo -n`
#   DIE <msg>         — the fatal variant `bridge_die`d (recorded, not exit)
#   RC <n>            — the helper's return code
#
# Args:
#   $1 — which helper ("best_effort" | "fatal")
#   $2 — fake `uname -s` value ("Linux" | "Darwin")
#   $3 — sudo presence ("with-sudo" | "no-sudo")
#   $4 — the rc the dispatched command should return ("0" | "7")
run_helper_probe() {
  local which_helper="$1"
  local fake_uname="$2"
  local sudo_mode="$3"
  local cmd_rc="$4"

  local probe_file="$SMOKE_TMP_ROOT/probe-$$-${RANDOM}.sh"
  cat >"$probe_file" <<PROBE
set -uo pipefail

# uname shim: synthesize the host platform. The helper calls \`uname -s\`.
uname() {
  if [[ "\${1:-}" == "-s" ]]; then printf '%s\n' "${fake_uname}"; return 0; fi
  command uname "\$@"
}

# id shim: always report a non-root controller UID so the helper takes
# the sudo-or-degrade branch (not the root short-circuit).
id() {
  if [[ "\${1:-}" == "-u" ]]; then printf '%s\n' "1000"; return 0; fi
  command id "\$@"
}

# command -v sudo shim: report sudo present/absent per the case. Every
# other \`command\` form falls through to the builtin so sourcing the lib
# (which uses \`command -v\` for its own probes) is unaffected.
command() {
  if [[ "\${1:-}" == "-v" && "\${2:-}" == "sudo" ]]; then
    if [[ "${sudo_mode}" == "with-sudo" ]]; then printf 'sudo\n'; return 0; fi
    return 1
  fi
  builtin command "\$@"
}

# sudo shim: record the escalated argv instead of really escalating.
sudo() {
  # Drop the leading -n that the helper passes.
  [[ "\${1:-}" == "-n" ]] && shift
  printf 'SUDO %s\n' "\$*"
  return 0
}

# bridge_die shim: RECORD the die (with the message) and stop the probe
# with a sentinel rc so the caller can tell "died" from "ran". We use a
# distinct rc (42) so a real command rc of 0/7 is never confused with a die.
bridge_die() { printf 'DIE %s\n' "\$*"; exit 42; }

# The command the helper is asked to dispatch. Records its own argv +
# returns the requested rc so C5 can assert rc propagation.
probe_cmd() { printf 'RAN %s\n' "\$*"; return ${cmd_rc}; }

source "${SMOKE_REPO_ROOT}/lib/bridge-agents.sh"

case "${which_helper}" in
  best_effort) bridge_linux_sudo_root_best_effort probe_cmd alpha beta ;;
  fatal)       bridge_linux_sudo_root probe_cmd alpha beta ;;
esac
printf 'RC %s\n' "\$?"
PROBE
  # Source lib/bridge-agents.sh under the SAME Bash 4+/5.x that runs this
  # smoke (`$BASH`), never plain `bash` — on a macOS dev host plain `bash`
  # is 3.2, which mis-parses the Bash-4.2 `[[ -v "ARR[$k]" ]]` array tests
  # the lib uses (the brief's standing warning + same convention as
  # scripts/smoke/1427-B / 1520).
  "${BASH:-/opt/homebrew/bin/bash}" "$probe_file"
  local probe_rc=$?
  command rm -f "$probe_file"
  return $probe_rc
}

# ---------------------------------------------------------------------------
# C1 — sudo-less Linux: best_effort degrades to a direct dispatch, no die.
# ---------------------------------------------------------------------------
test_c1_degrade_to_direct_no_die() {
  local out
  # `|| true`: the probe's own exit code is intentionally meaningful in
  # the die/failure cases (C2/C5) — assertions read the captured decision
  # trace, not the probe rc — so never let `set -e` abort on it.
  out="$(run_helper_probe "best_effort" "Linux" "no-sudo" "0")" || true
  smoke_assert_contains "$out" "RAN alpha beta" \
    "C1: sudo-less Linux best_effort dispatches the command directly"
  smoke_assert_not_contains "$out" "DIE" \
    "C1: sudo-less Linux best_effort does NOT bridge_die"
  smoke_assert_not_contains "$out" "SUDO" \
    "C1: sudo-less Linux best_effort does NOT attempt sudo"
  smoke_assert_contains "$out" "RC 0" \
    "C1: best_effort returns the dispatched command's rc (0)"
}

# ---------------------------------------------------------------------------
# C2 — sudo-less Linux: the FATAL sibling still dies (proves the bug +
#       that the degrade is the real behavioral difference).
# ---------------------------------------------------------------------------
test_c2_fatal_sibling_still_dies() {
  local out
  out="$(run_helper_probe "fatal" "Linux" "no-sudo" "0")" || true
  smoke_assert_contains "$out" "DIE linux-user isolation requires sudo" \
    "C2: sudo-less Linux fatal bridge_linux_sudo_root still dies (unchanged)"
  smoke_assert_not_contains "$out" "RAN" \
    "C2: fatal variant never reaches the command on a sudo-less host"
}

# ---------------------------------------------------------------------------
# C3 — Linux WITH sudo: best_effort escalates via sudo -n (boundary kept).
# ---------------------------------------------------------------------------
test_c3_provisioned_linux_still_escalates() {
  local out
  out="$(run_helper_probe "best_effort" "Linux" "with-sudo" "0")" || true
  smoke_assert_contains "$out" "SUDO probe_cmd alpha beta" \
    "C3: provisioned Linux best_effort escalates via sudo (boundary intact)"
  smoke_assert_not_contains "$out" "RAN alpha beta" \
    "C3: with sudo, best_effort does NOT run the command un-escalated"
  smoke_assert_not_contains "$out" "DIE" \
    "C3: with sudo present, best_effort never dies"
}

# ---------------------------------------------------------------------------
# C4 — non-Linux (macOS): best_effort dispatches directly, no sudo, no die.
# ---------------------------------------------------------------------------
test_c4_non_linux_direct() {
  local out
  out="$(run_helper_probe "best_effort" "Darwin" "no-sudo" "0")" || true
  smoke_assert_contains "$out" "RAN alpha beta" \
    "C4: non-Linux best_effort dispatches directly"
  smoke_assert_not_contains "$out" "SUDO" \
    "C4: non-Linux best_effort never escalates"
  smoke_assert_not_contains "$out" "DIE" \
    "C4: non-Linux best_effort never dies"
}

# ---------------------------------------------------------------------------
# C5 — sudo-less Linux: the degraded direct call propagates a non-zero rc
#       so `|| bridge_warn` at the --purge-home call sites still fires.
# ---------------------------------------------------------------------------
test_c5_degrade_propagates_failure_rc() {
  local out
  out="$(run_helper_probe "best_effort" "Linux" "no-sudo" "7")" || true
  smoke_assert_contains "$out" "RAN alpha beta" \
    "C5: degraded best_effort still dispatches the command"
  smoke_assert_contains "$out" "RC 7" \
    "C5: degraded best_effort propagates the command's non-zero rc"
  smoke_assert_not_contains "$out" "DIE" \
    "C5: a failing degraded command warns via rc, never dies"
}

test_c1_degrade_to_direct_no_die
test_c2_fatal_sibling_still_dies
test_c3_provisioned_linux_still_escalates
test_c4_non_linux_direct
test_c5_degrade_propagates_failure_rc

smoke_log "PASS ($SMOKE_NAME): best_effort degrades to direct on sudo-less Linux; fatal sibling + provisioned escalation unchanged"
