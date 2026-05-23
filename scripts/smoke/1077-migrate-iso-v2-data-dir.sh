#!/usr/bin/env bash
# Issue #1077 regression smoke — `agent-bridge migrate isolation v2`
# must repair grant-matrix rows under the v2 RUNTIME tree
# (`$BRIDGE_DATA_ROOT/agents/<a>/`), not under the legacy tracked
# profile tree (`$BRIDGE_HOME/agents/<a>/`).
#
# Pre-fix behavior: `bridge_isolation_v2_reapply_one_agent` resolved
# `agent_root` as `$BRIDGE_AGENT_HOME_ROOT/<a>` (legacy/profile tree).
# Every per-agent layout assertion therefore landed on a non-existent
# (or wrong) directory under `$BRIDGE_HOME/agents/<a>/`, emitting
# `skipped:no-such-directory` for the whole grant-matrix.
#
# Post-fix behavior: `agent_root` resolves via the typed v2 accessor
# `bridge_isolation_v2_agent_root` → `$BRIDGE_AGENT_ROOT_V2/<a>` (the
# `$BRIDGE_DATA_ROOT/agents/<a>` runtime tree). The action rows in
# `--check` mode now reference the runtime paths under
# `$BRIDGE_DATA_ROOT/agents/<a>/...` instead of `$BRIDGE_HOME/agents/<a>/...`.
#
# Asserts (mode=check, no chown/setfacl mutation — safe on macOS):
#   T1 — Every recorded action row referencing a per-agent leaf points
#        under `$BRIDGE_DATA_ROOT/agents/<agent>/`, NOT under
#        `$BRIDGE_HOME/agents/<agent>/`.
#   T2 — When the v2 runtime tree is fully present and canonical-shape
#        on disk, no action row reports `skipped:no-such-directory`
#        for the per-agent root `dir_root` row (the bug's signature).
#   T3 — The tracked profile template at `$BRIDGE_HOME/agents/<agent>/`,
#        if present, is NEVER referenced by an action row.

set -uo pipefail

SMOKE_NAME="1077-migrate-iso-v2-data-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

smoke_setup_bridge_home "$SMOKE_NAME"

AGENT="acme"
LEGACY_AGENT_ROOT="$BRIDGE_HOME/agents/$AGENT"        # tracked profile (wrong)
V2_AGENT_ROOT="$BRIDGE_DATA_ROOT/agents/$AGENT"       # runtime (right)

# Stage the v2 runtime tree (canonical subdirs) so action rows have
# something concrete to land on. Stage the tracked profile tree too;
# the repair tool must IGNORE this tree.
mkdir -p \
  "$V2_AGENT_ROOT/home" \
  "$V2_AGENT_ROOT/workdir" \
  "$V2_AGENT_ROOT/runtime" \
  "$V2_AGENT_ROOT/logs" \
  "$V2_AGENT_ROOT/requests" \
  "$V2_AGENT_ROOT/responses" \
  "$V2_AGENT_ROOT/credentials" \
  "$V2_AGENT_ROOT/.claude"
: >"$V2_AGENT_ROOT/agent-env.sh"
: >"$V2_AGENT_ROOT/credentials/launch-secrets.env"

mkdir -p \
  "$LEGACY_AGENT_ROOT/home" \
  "$LEGACY_AGENT_ROOT/workdir"

DRIVER="$SMOKE_TMP_ROOT/driver.sh"
ACTIONS_FILE="$SMOKE_TMP_ROOT/actions.tsv"
ERRORS_FILE="$SMOKE_TMP_ROOT/errors.log"
: >"$ACTIONS_FILE"
: >"$ERRORS_FILE"

# Write the driver. The driver sources bridge-lib.sh (which pulls
# the v2 modules + layout resolver), registers a single linux-user
# isolated agent into the in-memory roster arrays, and calls
# `bridge_isolation_v2_reapply_one_agent` in --check mode. Check mode
# performs only read probes — no chown, no setfacl — so it is safe
# to run on macOS without sudo.
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'cd "$REPO_ROOT"'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1'
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-isolation-v2-reapply.sh" >/dev/null 2>&1'
  # bridge_reset_roster_maps declares every BRIDGE_AGENT_* assoc array
  # under set -u — matches the production invariant before any resolver
  # call (the v0.12.1 set-u + undeclared-assoc-array footgun).
  printf '%s\n' 'bridge_reset_roster_maps'
  # Register one v2-isolated agent into the in-memory roster.
  printf 'AGENT=%q\n' "$AGENT"
  printf '%s\n' 'BRIDGE_AGENT_IDS=("$AGENT")'
  printf '%s\n' 'BRIDGE_AGENT_ISOLATION_MODE[$AGENT]="linux-user"'
  printf '%s\n' 'BRIDGE_AGENT_OS_USER[$AGENT]="agent-bridge-$AGENT"'
  printf 'ACTIONS_FILE=%q\n' "$ACTIONS_FILE"
  printf 'ERRORS_FILE=%q\n' "$ERRORS_FILE"
  printf '%s\n' 'bridge_isolation_v2_reapply_one_agent check "$AGENT" "$ACTIONS_FILE" "$ERRORS_FILE" || true'
} >"$DRIVER"
chmod +x "$DRIVER"

REPO_ROOT="$REPO_ROOT" "$BRIDGE_BASH" "$DRIVER" >"$SMOKE_TMP_ROOT/driver.out" 2>&1 || true

if [[ ! -s "$ACTIONS_FILE" ]]; then
  smoke_log "driver stdout/stderr follows:"
  cat "$SMOKE_TMP_ROOT/driver.out" >&2 || true
  smoke_log "errors file follows:"
  cat "$ERRORS_FILE" >&2 || true
  smoke_fail "actions file empty — reapply_one_agent did not record any rows"
fi

# T1 — every per-agent path in the actions file points under
# $BRIDGE_DATA_ROOT/agents/<agent>/, NOT under $BRIDGE_HOME/agents/<agent>/.
LEGACY_HITS="$(grep -E "(^|	|=| )${LEGACY_AGENT_ROOT}(/|	|$)" "$ACTIONS_FILE" || true)"
if [[ -n "$LEGACY_HITS" ]]; then
  smoke_log "actions file follows:"
  cat "$ACTIONS_FILE" >&2 || true
  smoke_fail "T1 FAIL: action rows reference the legacy profile tree under $LEGACY_AGENT_ROOT (bug #1077 not fixed). Offending rows:
$LEGACY_HITS"
fi
smoke_log "T1 PASS: no action row references the tracked profile tree ($LEGACY_AGENT_ROOT)"

V2_HITS="$(grep -cE "${V2_AGENT_ROOT}(/|	|$)" "$ACTIONS_FILE" || true)"
if [[ "${V2_HITS:-0}" -lt 1 ]]; then
  smoke_log "actions file follows:"
  cat "$ACTIONS_FILE" >&2 || true
  smoke_fail "T1 FAIL: no action row references the v2 runtime tree ($V2_AGENT_ROOT) — repair tool did not target the correct path"
fi
smoke_log "T1 PASS: $V2_HITS action row(s) reference the v2 runtime tree ($V2_AGENT_ROOT)"

# T2 — with the v2 runtime tree present and canonical-shape, the
# per-agent root `dir_root` row must NOT be `skipped:no-such-directory`.
# (That status was the user-visible signature of #1077: the path-resolver
# bug made every row land on a non-existent legacy path.)
ROOT_ROW="$(grep -E "${V2_AGENT_ROOT}	chown_chmod_dir	" "$ACTIONS_FILE" \
              | grep -vE "${V2_AGENT_ROOT}/" \
              | head -n 1 || true)"
if [[ -z "$ROOT_ROW" ]]; then
  smoke_log "actions file follows:"
  cat "$ACTIONS_FILE" >&2 || true
  smoke_fail "T2 FAIL: no dir_root action row for $V2_AGENT_ROOT"
fi
case "$ROOT_ROW" in
  *"skipped:no-such-directory"*)
    smoke_log "actions file follows:"
    cat "$ACTIONS_FILE" >&2 || true
    smoke_fail "T2 FAIL: per-agent dir_root row still records skipped:no-such-directory (the #1077 signature):
$ROOT_ROW"
    ;;
esac
smoke_log "T2 PASS: per-agent dir_root row resolved against the v2 runtime tree (no skipped:no-such-directory)"

# T3 — the tracked profile template must never appear in any action row.
PROFILE_SCRATCH="$BRIDGE_HOME/agents"
PROFILE_HITS="$(awk -v root="$LEGACY_AGENT_ROOT/" '
  index($0, root) { print; }
' "$ACTIONS_FILE" || true)"
if [[ -n "$PROFILE_HITS" ]]; then
  smoke_log "actions file follows:"
  cat "$ACTIONS_FILE" >&2 || true
  smoke_fail "T3 FAIL: action rows reference the tracked profile tree ($LEGACY_AGENT_ROOT/...):
$PROFILE_HITS"
fi
smoke_log "T3 PASS: tracked profile template at $PROFILE_SCRATCH is untouched by the matrix-repair tool"

smoke_log "all 3 tests PASS (#1077)"
