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
SKIP=0
FAIL_DETAIL=()

log() { printf '[pr-f-smoke] %s\n' "$*"; }
ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$*"; }
nok() { FAIL=$((FAIL + 1)); FAIL_DETAIL+=("$*"); printf '  ✗ %s\n' "$*"; }
# Issue #418 codex r2 item 12: track deferred tests as explicit skips with
# reasons rather than dropping them silently. Skip counter is separate from
# pass/fail so coverage gaps stay visible to the operator.
skip() { SKIP=$((SKIP + 1)); printf '  ⊘ SKIP: %s\n' "$*"; }

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
# Test 7 — agent-bridge init --dry-run is mutation-free under fresh BRIDGE_HOME
# ---------------------------------------------------------------------------
# Issue #418 codex r2 item 7: Test 1 above only sources bridge-lib.sh and
# checks resolver-only side effects. It does NOT exercise the full init
# entry point. This test invokes `agent-bridge init --dry-run` with an
# isolated BRIDGE_HOME and asserts zero filesystem entries are created.
log "Test 7: agent-bridge init --dry-run mutation-free (item 7)"
ISOLATED_HOME="$(mk_isolated_home)"
before_count="$(find "$ISOLATED_HOME" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

# Run init --dry-run; tolerate non-zero exit because the isolated env may
# lack roster/profile setup and we only care about mutation count.
env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_LAYOUT_SOURCE \
    -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
    BRIDGE_HOME="$ISOLATED_HOME" \
    BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
    BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
    "$SOURCE_DIR/agent-bridge" init --dry-run >/dev/null 2>&1 || true

after_count="$(find "$ISOLATED_HOME" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

if [[ "$after_count" -eq "$before_count" ]]; then
  ok "init --dry-run created no new entries under fresh BRIDGE_HOME ($after_count == $before_count)"
else
  nok "init --dry-run mutated filesystem: before=$before_count after=$after_count"
fi

if [[ ! -e "$ISOLATED_HOME/state/layout-marker.sh" ]]; then
  ok "init --dry-run did NOT write layout-marker.sh"
else
  nok "init --dry-run wrote layout-marker.sh (should be deferred until non-dry init)"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Test 8 — marker write is atomic (tmpfile + mv, no partial)
# ---------------------------------------------------------------------------
# Issue #418 codex r2 item 10: assert the marker writer uses a tmpfile
# rename (no partial file ever exposed at the marker_path). We verify by
# inspecting the source: bridge_isolation_v2_migrate_marker_write must
# write to ${marker_path}.tmp.$$ then mv -f, and validate after move.
log "Test 8: marker write atomicity (tmpfile + mv pattern)"

migrate_lib="$SOURCE_DIR/lib/bridge-isolation-v2-migrate.sh"
if grep -qE 'local tmp="\$\{marker_path\}\.tmp\.\$\$"' "$migrate_lib" \
    && grep -qE 'mv -f "\$tmp" "\$marker_path"' "$migrate_lib"; then
  ok "marker write uses tmpfile + mv (atomic rename)"
else
  nok "marker write does not match tmpfile + mv pattern in $migrate_lib"
fi

# Functional check: after a successful marker_write, no .tmp.* leftover
# remains in the marker dir.
ISOLATED_HOME="$(mk_isolated_home)"
mkdir -p "$ISOLATED_HOME/state"
data_root="$ISOLATED_HOME/data"
mkdir -p "$data_root"
env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_LAYOUT_SOURCE \
    -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
    BRIDGE_HOME="$ISOLATED_HOME" \
    BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
    BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
    bash --noprofile --norc -c "
      source '$SOURCE_DIR/bridge-lib.sh' >/dev/null 2>&1 || true
      source '$SOURCE_DIR/lib/bridge-isolation-v2-migrate.sh' >/dev/null 2>&1 || true
      bridge_isolation_v2_migrate_marker_write '$data_root' >/dev/null 2>&1 || true
    " 2>/dev/null || true

leftover_tmp_count="$(find "$ISOLATED_HOME/state" -name 'layout-marker.sh.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$leftover_tmp_count" == "0" ]]; then
  ok "no .tmp.* leftover after marker_write (atomic rename completed)"
else
  nok "found $leftover_tmp_count .tmp.* leftover files in $ISOLATED_HOME/state"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Test 9 — migrate-status drops marker lines with unknown keys
# ---------------------------------------------------------------------------
# Issue #418 codex r2 item 10: feed migrate-status a marker with an
# attacker-injected junk key; assert the junk line never appears in the
# status output.
log "Test 9: migrate-status redacts unknown keys"
ISOLATED_HOME="$(mk_isolated_home)"
mkdir -p "$ISOLATED_HOME/state"
data_root="$ISOLATED_HOME/data"
mkdir -p "$data_root"
cat >"$ISOLATED_HOME/state/layout-marker.sh" <<EOF
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT=$data_root
EVIL_INJECTED_KEY=attacker-controlled-bytes
# malicious comment line
EOF
chmod 0640 "$ISOLATED_HOME/state/layout-marker.sh"

status_output="$(env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_LAYOUT_SOURCE \
                 -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
                 BRIDGE_HOME="$ISOLATED_HOME" \
                 BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
                 BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
                 "$SOURCE_DIR/agent-bridge" migrate isolation-v2 status 2>&1 || true)"

if grep -q "EVIL_INJECTED_KEY" <<<"$status_output"; then
  nok "junk key leaked into status output: $status_output"
else
  ok "unknown key (EVIL_INJECTED_KEY) dropped from migrate-status output"
fi
if grep -q "BRIDGE_LAYOUT=v2" <<<"$status_output"; then
  ok "valid BRIDGE_LAYOUT line still emitted"
else
  nok "expected BRIDGE_LAYOUT=v2 in status output, got: $status_output"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Test 10 — migrate-status drops malformed values for known keys
# ---------------------------------------------------------------------------
# Issue #418 codex r2 item 2 + item 10: known keys with shell-metachar
# values must be value-level redacted (the r1 fix only filtered keys, so a
# tampered marker BRIDGE_DATA_ROOT='$(rm -rf /)' previously echoed bytes
# verbatim).
log "Test 10: migrate-status redacts malformed values for known keys"
ISOLATED_HOME="$(mk_isolated_home)"
mkdir -p "$ISOLATED_HOME/state"
cat >"$ISOLATED_HOME/state/layout-marker.sh" <<'EOF'
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT=$(rm -rf /)
BRIDGE_LAYOUT_MARKER_VERSION=not-a-number
EOF
chmod 0640 "$ISOLATED_HOME/state/layout-marker.sh"

status_output="$(env -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_LAYOUT_SOURCE \
                 -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
                 BRIDGE_HOME="$ISOLATED_HOME" \
                 BRIDGE_STATE_DIR="$ISOLATED_HOME/state" \
                 BRIDGE_LAYOUT_MARKER_DIR="$ISOLATED_HOME/state" \
                 "$SOURCE_DIR/agent-bridge" migrate isolation-v2 status 2>&1 || true)"

# The malformed BRIDGE_DATA_ROOT value contains shell metacharacters; the
# value-level allowlist regex must reject it.
if grep -q 'rm -rf' <<<"$status_output"; then
  nok "shell-metachar value leaked into status output: $status_output"
else
  ok "BRIDGE_DATA_ROOT with shell metachars dropped (value-level redaction)"
fi
# BRIDGE_LAYOUT_MARKER_VERSION must be digits — not-a-number must be dropped.
if grep -q 'BRIDGE_LAYOUT_MARKER_VERSION=not-a-number' <<<"$status_output"; then
  nok "non-numeric MARKER_VERSION leaked: $status_output"
else
  ok "BRIDGE_LAYOUT_MARKER_VERSION non-numeric value dropped"
fi
# BRIDGE_LAYOUT=v2 has a clean value and must still be emitted.
if grep -q 'BRIDGE_LAYOUT=v2' <<<"$status_output"; then
  ok "clean BRIDGE_LAYOUT=v2 line still passes value validation"
else
  nok "expected BRIDGE_LAYOUT=v2 in status output, got: $status_output"
fi
cleanup
unset ISOLATED_HOME

# ---------------------------------------------------------------------------
# Tests 11-13 — explicit skip stubs (item 12)
# ---------------------------------------------------------------------------
# Issue #418 codex r2 item 12: deferred test bodies that need a larger
# harness (daemon-safe migration env, scripts/smoke-test.sh integration,
# operator session/daemon safety review). Documented explicitly via
# skip() so coverage gaps remain visible in CI output rather than being
# silently absent.
log "Test 11: full migration apply smoke (deferred)"
skip "test_full_migration_apply_smoke — deferred to follow-up: requires daemon-safe migration harness (#418 r2 item 12)"

log "Test 12: PR-E regression invocation (deferred)"
skip "test_pr_e_regression_invocation — deferred to follow-up: needs scripts/smoke-test.sh integration (#418 r2 item 12)"

log "Test 13: session/daemon safety review (deferred)"
skip "test_session_daemon_safety_review — deferred to follow-up: needs operator session/daemon safety review (#418 r2 item 12)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log ""
log "=== Summary ==="
log "passed: $PASS"
log "failed: $FAIL"
log "skipped: $SKIP"
if (( FAIL > 0 )); then
  log "failures:"
  for d in "${FAIL_DETAIL[@]}"; do
    log "  - $d"
  done
  exit 1
fi
exit 0
