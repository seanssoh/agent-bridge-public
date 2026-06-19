#!/usr/bin/env bash
# scripts/smoke/2002-onboarding-nudge-guard.sh — issue #2002.
#
# THE BUG. The fresh-install onboarding nudge (`bridge_start_should_send_
# onboarding_nudge`, bridge-start.sh) used `onboarding_state == pending` as its
# ONLY first-launch proxy — no `--replace` suppression and no launch-history
# check. So once the state drifted back to `pending` (the #2004 stale-marker
# incident), EVERY restart of an already-operational admin re-typed the canned
# onboarding prompt into the resumed session.
#
# THE FIX (defense-in-depth, pinned here): the gate now also requires
# `REPLACE == 0` AND the absence of the once-per-lifetime `initial-inbox.started`
# launch-history marker. A genuine first launch (pending + no marker + not
# replace) still nudges; a replacement or any second-and-later launch (marker
# present) never does, even if the state has drifted.
#
# Asserts (driver sources the REAL predicate from bridge-start.sh, stubs only
# the workdir/onboarding-state resolvers, and uses the REAL initial-inbox marker
# resolver against a fixture state dir):
#   G1 — first-launch pending admin (no marker, REPLACE=0)  → nudge (rc 0).
#   G2 — same admin under `--replace` (REPLACE=1)           → NO nudge (rc 1).
#   G3 — same admin with the initial-inbox marker present   → NO nudge (rc 1).
#   G4 — non-admin pending (e.g. static-claude)             → NO nudge (rc 1).
#   G5 — admin already complete                              → NO nudge (rc 1).
#
# Footgun #11: the driver body is emitted with `printf '%s\n' >file` and
# invoked file-as-argv; no `<<EOF` / `<<'PY'` heredoc-stdin into a subprocess.

set -uo pipefail

SMOKE_NAME="2002-onboarding-nudge-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

AGENT="admin-x"
WORK_DIR="$SMOKE_TMP_ROOT/$AGENT-workdir"
mkdir -p "$WORK_DIR"

# ---------------------------------------------------------------------------
# Driver: pull the REAL predicate out of bridge-start.sh, stub the two
# session-state resolvers to point at the fixture SESSION-TYPE.md + state, and
# call the predicate. The initial-inbox marker resolver is the REAL one, so the
# launch-history gate is exercised against an actual state path.
# ---------------------------------------------------------------------------
DRIVER="$SMOKE_TMP_ROOT/nudge-guard-driver.sh"
: >"$DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' '#!/usr/bin/env bash' >>"$DRIVER"
printf '%s\n' 'set -uo pipefail' >>"$DRIVER"
printf '%s\n' 'REPO_ROOT="$1"; AGENT="$2"; WORK_DIR="$3"; STYPE="$4"; STATE="$5"; REPLACE="$6"' >>"$DRIVER"
# Author the fixture SESSION-TYPE.md from STYPE/STATE so the predicate greps the
# real session-type line (the gate is `grep admin` on the workdir file).
printf '%s\n' 'printf "# Session Type\n\n- Session Type: %s\n- Onboarding State: %s\n- Engine: claude\n" "$STYPE" "$STATE" >"$WORK_DIR/SESSION-TYPE.md"' >>"$DRIVER"
# Extract just the predicate function from bridge-start.sh (it is not sourceable
# whole — bridge-start.sh runs its launch flow on load).
printf '%s\n' 'awk "/^bridge_start_should_send_onboarding_nudge\\(\\) \\{/,/^\\}/" "$REPO_ROOT/bridge-start.sh" >"$WORK_DIR/predicate.sh"' >>"$DRIVER"
# Pull the real bridge-lib so bridge_agent_initial_inbox_marker_file resolves.
printf '%s\n' '# shellcheck disable=SC1091' >>"$DRIVER"
printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1 || true' >>"$DRIVER"
# Stub the two session-state resolvers to the fixture.
printf '%s\n' 'bridge_agent_workdir() { printf "%s" "$WORK_DIR"; }' >>"$DRIVER"
printf '%s\n' 'bridge_agent_onboarding_state() { printf "%s" "$STATE"; }' >>"$DRIVER"
printf '%s\n' '# shellcheck disable=SC1091' >>"$DRIVER"
printf '%s\n' 'source "$WORK_DIR/predicate.sh"' >>"$DRIVER"
printf '%s\n' 'if bridge_start_should_send_onboarding_nudge "$AGENT" "$REPLACE"; then printf "NUDGE=1\\n"; else printf "NUDGE=0\\n"; fi' >>"$DRIVER"
chmod +x "$DRIVER"

run_guard() {
  # args: <stype> <state> <replace>
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$AGENT" "$WORK_DIR" "$1" "$2" "$3" 2>/dev/null
}

# Resolve the REAL initial-inbox marker path the predicate consults, so G3 can
# create/remove it exactly where the gate looks.
MARKER_FILE="$("$BRIDGE_BASH" -c 'source "$1/bridge-lib.sh" >/dev/null 2>&1 || true; bridge_agent_initial_inbox_marker_file "$2"' _ "$REPO_ROOT" "$AGENT" 2>/dev/null)"
[[ -n "$MARKER_FILE" ]] || smoke_fail "could not resolve initial-inbox marker path"
mkdir -p "$(dirname "$MARKER_FILE")"

# --- G1: first-launch pending admin → nudge ---------------------------------
rm -f "$MARKER_FILE"
smoke_assert_eq "NUDGE=1" "$(run_guard admin pending 0)" \
  "G1 (#2002): a genuine first-launch pending admin (no marker, not --replace) must STILL be nudged"

# --- G2: --replace pending admin → NO nudge ---------------------------------
rm -f "$MARKER_FILE"
smoke_assert_eq "NUDGE=0" "$(run_guard admin pending 1)" \
  "G2 (#2002): a --replace launch must NOT re-type onboarding (replacement is never a first run)"

# --- G3: marker-present pending admin → NO nudge ----------------------------
printf '%s\n' "$(date +%s)" >"$MARKER_FILE"
smoke_assert_eq "NUDGE=0" "$(run_guard admin pending 0)" \
  "G3 (#2002): a pending admin that has already launched once (initial-inbox marker present) must NOT be re-nudged — this is the restart-drift case"
rm -f "$MARKER_FILE"

# --- G4: non-admin pending → NO nudge (unchanged) ---------------------------
smoke_assert_eq "NUDGE=0" "$(run_guard static-claude pending 0)" \
  "G4: a non-admin session type is never nudged (unchanged)"

# --- G5: admin already complete → NO nudge (unchanged) ----------------------
smoke_assert_eq "NUDGE=0" "$(run_guard admin complete 0)" \
  "G5: a completed admin is never nudged (unchanged)"

smoke_log "passed"
