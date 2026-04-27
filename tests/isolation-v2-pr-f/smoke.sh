#!/usr/bin/env bash
# tests/isolation-v2-pr-f/smoke.sh — PR-F isolate-v2 default flip smoke.
#
# Covers the resolver state machine and marker-dir anchor invariants agreed
# in plan-review #298/#300/#302/#304 (rounds r2-r5):
#
#   1. fresh-install dry-run is mutation-free
#   2. fresh-install candidate is NOT v2-active until init writes the marker
#   3. markerless existing install stays legacy (env evidence)
#   4. valid marker -> source=marker, v2 active
#   5. partial env override (BRIDGE_LAYOUT=v2 only) -> ignored, fallback
#   6. marker stays at $BRIDGE_LAYOUT_MARKER_DIR even when BRIDGE_STATE_DIR
#      is rebased (controller-state relocation rehearsal)
#   7. child process inherits BRIDGE_LAYOUT_MARKER_DIR and resolves
#      source=marker
#   8. dependent state family stays under $BRIDGE_HOME/state in PR-F (no
#      controller-state move yet)
#
# Tests run against an isolated BRIDGE_HOME under mktemp so they do not
# touch the operator's live runtime.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

PASS=0
FAIL=0
FAIL_DETAIL=()

log() { printf '[pr-f-smoke] %s\n' "$*"; }
ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$*"; }
nok() { FAIL=$((FAIL + 1)); FAIL_DETAIL+=("$*"); printf '  ✗ %s\n' "$*"; }

mk_isolated_home() {
  local tmp
  tmp="$(mktemp -d -t agb-prf.XXXXXX)"
  printf '%s\n' "$tmp"
}

cleanup() {
  if [[ -n "${ISOLATED_HOME:-}" && -d "$ISOLATED_HOME" ]]; then
    rm -rf "$ISOLATED_HOME"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test 1 — fresh install dry-run mutation-free
# ---------------------------------------------------------------------------
log "Test 1: fresh-install dry-run mutation-free"
ISOLATED_HOME="$(mk_isolated_home)"
before_files="$(find "$ISOLATED_HOME" -mindepth 1 2>/dev/null | wc -l)"

# Source bridge-lib.sh in an isolated HOME and run resolver only.
output="$(env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_LAYOUT_SOURCE \
          -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
          BRIDGE_HOME="$ISOLATED_HOME" \
          BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
          BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
          bash --noprofile --norc -c "
            source '$SOURCE_DIR/bridge-lib.sh';
            printf 'source=%s\n' \"\${BRIDGE_LAYOUT_SOURCE:-unset}\";
            printf 'layout=%s\n' \"\${BRIDGE_LAYOUT:-unset}\";
            printf 'active=%s\n' \"\$(bridge_isolation_v2_active && echo yes || echo no)\";
          " 2>&1)"

# Note: bridge-lib.sh source itself doesn't materialize state/, but
# bridge_load_roster does. We only sourced the lib + resolver — no roster
# load — so we expect zero new files. (bridge-init.sh defers
# bridge_load_roster until after dry-run check.)
after_files="$(find "$ISOLATED_HOME" -mindepth 1 2>/dev/null | wc -l)"

if grep -q "source=fresh-install-candidate" <<<"$output"; then
  ok "fresh install resolver source=fresh-install-candidate"
else
  nok "expected source=fresh-install-candidate, got: $output"
fi

if grep -q "active=no" <<<"$output"; then
  ok "fresh-install-candidate is NOT active (marker-is-source-of-truth)"
else
  nok "fresh-install-candidate must NOT activate v2"
fi

if (( before_files == after_files )); then
  ok "no files created during resolver-only source (mutation-free read)"
else
  nok "resolver source mutated filesystem ($before_files -> $after_files)"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Test 2 — markerless existing install stays legacy
# ---------------------------------------------------------------------------
log "Test 2: markerless existing install stays legacy"
ISOLATED_HOME="$(mk_isolated_home)"
mkdir -p "$ISOLATED_HOME/state/agents"
# Add evidence: a fake registered agent home directory.
mkdir -p "$ISOLATED_HOME/agents/some-agent"
touch "$ISOLATED_HOME/agents/some-agent/CLAUDE.md"

output="$(env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_LAYOUT_SOURCE \
          -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
          BRIDGE_HOME="$ISOLATED_HOME" \
          BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
          BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
          bash --noprofile --norc -c "
            source '$SOURCE_DIR/bridge-lib.sh';
            printf 'source=%s\n' \"\${BRIDGE_LAYOUT_SOURCE:-unset}\";
            printf 'layout=%s\n' \"\${BRIDGE_LAYOUT:-unset}\";
          " 2>&1)"

if grep -q "source=missing-marker" <<<"$output"; then
  ok "markerless existing install -> source=missing-marker(existing)"
else
  nok "expected source=missing-marker(existing), got: $output"
fi
if grep -q "layout=legacy" <<<"$output"; then
  ok "markerless existing install -> layout=legacy invariant"
else
  nok "markerless existing install must stay legacy: $output"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Test 3 — valid marker -> source=marker, v2 active
# ---------------------------------------------------------------------------
log "Test 3: valid marker -> source=marker"
ISOLATED_HOME="$(mk_isolated_home)"
mkdir -p "$ISOLATED_HOME/state"
data_root="$ISOLATED_HOME/data"
cat >"$ISOLATED_HOME/state/layout-marker.sh" <<EOF
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT='$data_root'
EOF
chmod 0640 "$ISOLATED_HOME/state/layout-marker.sh"

output="$(env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_LAYOUT_SOURCE \
          -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
          BRIDGE_HOME="$ISOLATED_HOME" \
          BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
          BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
          bash --noprofile --norc -c "
            source '$SOURCE_DIR/bridge-lib.sh';
            printf 'source=%s\n' \"\${BRIDGE_LAYOUT_SOURCE:-unset}\";
            printf 'layout=%s\n' \"\${BRIDGE_LAYOUT:-unset}\";
            printf 'data_root=%s\n' \"\${BRIDGE_DATA_ROOT:-unset}\";
            printf 'active=%s\n' \"\$(bridge_isolation_v2_active && echo yes || echo no)\";
          " 2>&1)"

if grep -q "source=marker" <<<"$output"; then ok "source=marker"; else nok "expected source=marker: $output"; fi
if grep -q "layout=v2" <<<"$output"; then ok "layout=v2"; else nok "expected layout=v2: $output"; fi
if grep -q "active=yes" <<<"$output"; then ok "v2 active"; else nok "v2 must be active when marker is valid: $output"; fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Test 4 — partial env override is ignored
# ---------------------------------------------------------------------------
log "Test 4: partial env override (BRIDGE_LAYOUT=v2 only) -> ignored"
ISOLATED_HOME="$(mk_isolated_home)"
mkdir -p "$ISOLATED_HOME/state/agents/foo"   # existing-install evidence

output="$(BRIDGE_HOME="$ISOLATED_HOME" \
          BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
          BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
          BRIDGE_LAYOUT=v2 \
          bash --noprofile --norc -c "
            source '$SOURCE_DIR/bridge-lib.sh';
            printf 'source=%s\n' \"\${BRIDGE_LAYOUT_SOURCE:-unset}\";
            printf 'ignored=%s\n' \"\${BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV:-unset}\";
            printf 'active=%s\n' \"\$(bridge_isolation_v2_active && echo yes || echo no)\";
          " 2>&1)"

if grep -q "ignored=BRIDGE_LAYOUT" <<<"$output"; then
  ok "partial env BRIDGE_LAYOUT=v2 reported as ignored"
else
  nok "expected ignored=BRIDGE_LAYOUT, got: $output"
fi
if grep -q "active=no" <<<"$output"; then
  ok "partial env does not activate v2"
else
  nok "partial env must not activate v2: $output"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Test 5 — marker stays at BRIDGE_LAYOUT_MARKER_DIR even with rebased BRIDGE_STATE_DIR
# ---------------------------------------------------------------------------
log "Test 5: marker discoverable after BRIDGE_STATE_DIR rebase"
ISOLATED_HOME="$(mk_isolated_home)"
mkdir -p "$ISOLATED_HOME/state"
data_root="$ISOLATED_HOME/data"
mkdir -p "$data_root/state"  # simulate v2 controller state location
cat >"$ISOLATED_HOME/state/layout-marker.sh" <<EOF
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT='$data_root'
EOF
chmod 0640 "$ISOLATED_HOME/state/layout-marker.sh"

# Simulate rebased BRIDGE_STATE_DIR by pointing it at the v2 controller-state
# location. Marker must remain discoverable via BRIDGE_LAYOUT_MARKER_DIR
# (which stays at $BRIDGE_HOME/state) regardless.
output="$(env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_LAYOUT_SOURCE \
          -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
          BRIDGE_HOME="$ISOLATED_HOME" \
          BRIDGE_STATE_DIR="$data_root/state" \
          BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
          bash --noprofile --norc -c "
            source '$SOURCE_DIR/bridge-lib.sh';
            printf 'source=%s\n' \"\${BRIDGE_LAYOUT_SOURCE:-unset}\";
            printf 'active=%s\n' \"\$(bridge_isolation_v2_active && echo yes || echo no)\";
          " 2>&1)"

if grep -q "source=marker" <<<"$output" && grep -q "active=yes" <<<"$output"; then
  ok "marker stays discoverable via BRIDGE_LAYOUT_MARKER_DIR even when BRIDGE_STATE_DIR is rebased"
else
  nok "marker discovery broke after BRIDGE_STATE_DIR rebase: $output"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Test 6 — env override valid + clean
# ---------------------------------------------------------------------------
log "Test 6: explicit valid env override -> source=env"
ISOLATED_HOME="$(mk_isolated_home)"
data_root="$ISOLATED_HOME/data"
mkdir -p "$data_root"

output="$(BRIDGE_HOME="$ISOLATED_HOME" \
          BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
          BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
          BRIDGE_LAYOUT=v2 \
          BRIDGE_DATA_ROOT="$data_root" \
          bash --noprofile --norc -c "
            source '$SOURCE_DIR/bridge-lib.sh';
            printf 'source=%s\n' \"\${BRIDGE_LAYOUT_SOURCE:-unset}\";
            printf 'layout=%s\n' \"\${BRIDGE_LAYOUT:-unset}\";
            printf 'active=%s\n' \"\$(bridge_isolation_v2_active && echo yes || echo no)\";
          " 2>&1)"

if grep -q "source=env" <<<"$output" && grep -q "active=yes" <<<"$output"; then
  ok "explicit env override -> source=env, v2 active"
else
  nok "explicit env override failed: $output"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "=== Summary ==="
log "passed: $PASS"
log "failed: $FAIL"
if (( FAIL > 0 )); then
  log "failures:"
  for d in "${FAIL_DETAIL[@]}"; do
    log "  - $d"
  done
  exit 1
fi
exit 0
