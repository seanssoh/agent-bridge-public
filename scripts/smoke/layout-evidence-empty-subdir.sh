#!/usr/bin/env bash
# Regression smoke — empty cron/runtime subdirs must NOT trip the
# `bridge_layout_resolver_has_existing_evidence` check.
#
# Background (discovered 2026-05-17, OrbStack VM Ubuntu noble lifecycle
# test):
#   First `bridge-init.sh --admin patch --engine claude --skip-channel-setup`
#   on a truly empty `$BRIDGE_HOME` would auto-create empty
#   `state/cron/workers/` (and similar `state/runtime/<sub>/`) shells.
#   Any subsequent invocation then walked into
#   `bridge_layout_resolver_has_existing_evidence` and false-tripped on
#   `compgen -G "$state/cron/*"` — which matches any entry, including
#   empty subdirectories. The resolver therefore classified the install
#   as `markerless(existing-install)` and hard-died, sending the
#   operator to `agent-bridge upgrade --apply` for an install that was
#   brand new. This blocked every clean Linux install path.
#
#   Operator macOS doesn't see this because they're already migrated to
#   the v2 marker — the marker branch wins before evidence is consulted.
#
# Fix (lib/bridge-layout-resolver.sh): switch the cron/runtime evidence
# probes from `compgen -G` to `find -mindepth 1 -type f`, matching the
# documented intent ("have content"). Same class as PR #897 (v0.13.10
# Track A) where source-checkout `agents/_template/` falsely tripped
# the parallel `home/agents/` walk.
#
# Coverage:
#   C1 — empty state/cron/workers/ + empty state/runtime/<sub>/ →
#        evidence returns 1 (no evidence; fresh install can proceed).
#   C2 — file under state/cron/ → evidence returns 0.
#   C3 — file under state/runtime/ → evidence returns 0.
#   C4 — pre-existing evidence (tasks.db) → still returns 0
#        (regression guard for the existing-install path).

set -uo pipefail

SMOKE_NAME="layout-evidence-empty-subdir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Probe the resolver function in isolation. Stubs out marker / die /
# warn so we exercise ONLY the evidence helper. The driver is written
# to a temp file because Bash 5.3.9 deadlocks on heredoc-stdin to
# subprocesses with command substitution (footgun #11, see
# KNOWN_ISSUES.md §26).
run_evidence_probe() {
  # Args: $1 = home_dir, $2 = expected_rc (0 or 1), $3 = label
  local home_dir="$1"
  local expected_rc="$2"
  local label="$3"

  local driver="$SMOKE_TMP_ROOT/driver-${label}.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'export BRIDGE_HOME=%q\n' "$home_dir"
    printf 'export BRIDGE_STATE_DIR=%q\n' "$home_dir/state"
    printf '%s\n' 'bridge_die() { printf "DIE: %s\n" "$*"; exit 99; }'
    printf '%s\n' 'bridge_warn() { printf "WARN: %s\n" "$*"; }'
    printf '%s\n' 'bridge_isolation_v2_marker_path() { printf "%s\n" "$BRIDGE_STATE_DIR/layout-marker.sh"; }'
    printf '%s\n' 'bridge_isolation_v2_marker_validate() { return 1; }'
    printf '%s\n' 'bridge_isolation_v2_marker_load() { :; }'
    # Strip the bottom auto-resolve call so we can call the evidence
    # helper without triggering bridge_resolve_layout (which would die
    # on the fresh-install candidate / markerless branches).
    printf 'sed "/^bridge_resolve_layout$/d" %q > %q\n' \
      "$REPO_ROOT/lib/bridge-layout-resolver.sh" \
      "$SMOKE_TMP_ROOT/resolver-noauto-${label}.sh"
    printf 'source %q\n' "$SMOKE_TMP_ROOT/resolver-noauto-${label}.sh"
    printf '%s\n' 'if bridge_layout_resolver_has_existing_evidence; then'
    printf '%s\n' '  printf "EVIDENCE=true\n"'
    printf '%s\n' 'else'
    printf '%s\n' '  printf "EVIDENCE=false\n"'
    printf '%s\n' 'fi'
  } >"$driver"
  chmod +x "$driver"

  local out
  out="$("$BRIDGE_BASH" "$driver" 2>&1)"
  rm -f "$driver"

  local got
  if [[ "$out" == *"EVIDENCE=true"* ]]; then
    got=0
  elif [[ "$out" == *"EVIDENCE=false"* ]]; then
    got=1
  else
    smoke_log "${label} unexpected output:"; printf '%s\n' "$out"
    smoke_fail "${label}: probe did not print EVIDENCE=true|false"
  fi

  if (( got != expected_rc )); then
    smoke_log "${label} output:"; printf '%s\n' "$out"
    smoke_fail "${label}: expected evidence rc=${expected_rc}, got rc=${got}"
  fi
}

# C1 — empty cron/workers/ + empty runtime/<sub>/ → no evidence
smoke_log "C1: empty state/cron/workers/ + empty state/runtime/<sub>/ → no evidence"
C1_HOME="$SMOKE_TMP_ROOT/c1-home"
mkdir -p "$C1_HOME/state/cron/workers" "$C1_HOME/state/runtime/sweepers"
run_evidence_probe "$C1_HOME" 1 "c1"
smoke_log "C1 PASS"

# C2 — file under state/cron/ → evidence
smoke_log "C2: file under state/cron/ → evidence trips"
C2_HOME="$SMOKE_TMP_ROOT/c2-home"
mkdir -p "$C2_HOME/state/cron/workers"
: > "$C2_HOME/state/cron/workers/worker.log"
run_evidence_probe "$C2_HOME" 0 "c2"
smoke_log "C2 PASS"

# C3 — file under state/runtime/ → evidence
smoke_log "C3: file under state/runtime/ → evidence trips"
C3_HOME="$SMOKE_TMP_ROOT/c3-home"
mkdir -p "$C3_HOME/state/runtime/sweepers"
: > "$C3_HOME/state/runtime/sweepers/sweep.state"
run_evidence_probe "$C3_HOME" 0 "c3"
smoke_log "C3 PASS"

# C4 — pre-existing evidence (tasks.db) still wins regardless of
#       empty cron/runtime subdirs around it.
smoke_log "C4: state/tasks.db present + empty cron/runtime subdirs → evidence trips"
C4_HOME="$SMOKE_TMP_ROOT/c4-home"
mkdir -p "$C4_HOME/state/cron/workers" "$C4_HOME/state/runtime/sweepers"
: > "$C4_HOME/state/tasks.db"
run_evidence_probe "$C4_HOME" 0 "c4"
smoke_log "C4 PASS"

smoke_log "PASS — empty cron/runtime subdirs no longer false-trip evidence"
exit 0
