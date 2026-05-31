#!/usr/bin/env bash
# scripts/smoke/1426-cron-shell-noniso-help.sh — Issue #1426.
#
# `agb cron create --kind shell --run-as-agent <agent>` runs a script under a
# dedicated isolated OS UID and only works on Linux hosts with linux-user
# isolation (iso v2) active. On macOS / non-iso installs it is structurally
# unavailable. The pre-#1426 behavior left the author at a dead end: a bare
# "--run-as-agent must name a linux-user isolated agent" with no fallback,
# after they had already written and tested a script.
#
# This smoke pins the #1426 clarity contract on a NON-iso roster (which is the
# default on macOS and on any host where the agent's isolation mode is not
# linux-user / the host is not Linux):
#
#   1. `cron --help` states the iso-v2 / --run-as-agent requirement UP FRONT
#      and names the supported scheduled-shell fallbacks.
#   2. `cron create --kind shell --run-as-agent <agent>` fails (non-zero) and
#      the error message:
#        - names the iso-v2 requirement,
#        - states macOS / non-iso unavailability,
#        - points at the supported alternatives (OS crontab / --kind text), and
#        - references the OPERATIONS.md section so the author can self-serve.
#
# Footgun #11 (heredoc_write deadlock class): all subprocess output capture
# goes through `$(... 2>&1)` against the shell script directly — no python
# heredoc-stdin into a subprocess, no `<<<` here-strings. The single heredoc
# in this file writes a roster FILE (not stdin into a subprocess), which is the
# allowed shape.

set -uo pipefail

SMOKE_NAME="1426-cron-shell-noniso-help"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

# The issue's reproduction is an operator running `agb cron create` from a
# plain controller shell — no BRIDGE_AGENT_ID. If this var leaks in from the
# harness's own bridge session it trips the unrelated iso-identity cross-agent
# reject guard BEFORE the shell validation, masking the contract under test.
unset BRIDGE_AGENT_ID BRIDGE_AGENT_NAME

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# A roster agent that is explicitly NOT linux-user isolation effective. Even if
# the roster declares linux-user mode, `bridge_agent_linux_user_isolation_effective`
# additionally requires the host to be Linux — so on macOS this agent is never
# iso-effective. To make the contract deterministic on Linux CI too, declare
# the agent in shared (non-iso) mode: no isolation mode + no os_user.
cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<'EOF'
bridge_add_agent_id_if_missing "noniso-agent"
BRIDGE_AGENT_DESC["noniso-agent"]="Smoke non-iso shared-mode agent"
BRIDGE_AGENT_ENGINE["noniso-agent"]="claude"
BRIDGE_AGENT_SESSION["noniso-agent"]="noniso-agent"
EOF

# A real executable script so --script is plausible; the iso reject fires
# before the script-path validation regardless, but a present script keeps the
# scenario faithful to the issue's reproduction.
SCRIPT_PATH="$SMOKE_TMP_ROOT/health-check.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SCRIPT_PATH"
chmod 0755 "$SCRIPT_PATH"

# --- 1. --help contract ----------------------------------------------------

help_out="$("$BRIDGE_BASH" "$REPO_ROOT/bridge-cron.sh" --help 2>&1)" || true
smoke_assert_contains "$help_out" "--kind shell" "cron --help names --kind shell"
smoke_assert_contains "$help_out" "iso v2" "cron --help names iso v2 requirement"
smoke_assert_contains "$help_out" "Linux only" "cron --help states Linux-only requirement"
smoke_assert_contains "$help_out" "OS crontab" "cron --help names OS crontab fallback"
smoke_assert_contains "$help_out" "OPERATIONS.md" "cron --help points at OPERATIONS.md"
smoke_log "ok: cron --help states the iso-v2 requirement + fallbacks up front"

# --- 2. create error contract ---------------------------------------------

err_out=""
err_rc=0
err_out="$("$BRIDGE_BASH" "$REPO_ROOT/bridge-cron.sh" create \
  --agent noniso-agent \
  --schedule '0 */3 * * *' \
  --title health-check \
  --kind shell \
  --script "$SCRIPT_PATH" \
  --run-as-agent noniso-agent 2>&1)" || err_rc=$?

if [[ "$err_rc" -eq 0 ]]; then
  echo "------ output ------" >&2
  echo "$err_out" >&2
  echo "--------------------" >&2
  smoke_fail "expected non-iso --kind shell create to FAIL, but it succeeded (rc=0)"
fi

smoke_assert_contains "$err_out" "linux-user isolated agent" \
  "error names the linux-user isolation requirement"
smoke_assert_contains "$err_out" "Linux-only" \
  "error states iso v2 is Linux-only"
smoke_assert_contains "$err_out" "OS crontab" \
  "error points at the OS crontab fallback"
smoke_assert_contains "$err_out" "--kind text" \
  "error points at the --kind text cron fallback"
smoke_assert_contains "$err_out" "OPERATIONS.md" \
  "error references OPERATIONS.md for the full story"
smoke_log "ok: non-iso --kind shell create fails with an actionable fallback (rc=$err_rc)"

# The job must NOT have been written to the inventory.
if [[ -s "$BRIDGE_NATIVE_CRON_JOBS_FILE" ]] \
    && grep -q '"name": *"health-check"' "$BRIDGE_NATIVE_CRON_JOBS_FILE" 2>/dev/null; then
  smoke_fail "refused --kind shell create must not write a job to the inventory"
fi
smoke_log "ok: refused create wrote no job to the cron inventory"

smoke_log "PASS"
