#!/usr/bin/env bash
# Unit test for process_memory_daily_orphan_sweep (refs #791).
#
# The helper lives inside bridge-daemon.sh, which is too heavy to source in
# isolation (it boots the daemon loop on load). This test extracts JUST the
# function body via awk, sources the snippet, and stubs every external
# collaborator (bridge_admin_agent_id, bridge_agent_exists, bridge_load_roster,
# bridge-cron.sh, bridge_queue_cli, bridge_audit_log, daemon_info,
# daemon_warn) so the helper can be exercised without a live daemon.
#
# Scenarios covered (4):
#   1. orphans-detected      — one orphan cron job → exactly one queue
#                              create call, marker written, rc=0.
#   2. marker-dedup          — re-invoke same day → no queue create, marker
#                              still in place, rc=1 (suppressed).
#   3. marker-rotated-re-emits — delete the marker → re-invoke → new queue
#                              create + new marker, rc=0.
#   4. no-orphan-noop        — all cron jobs match a roster agent → no
#                              queue create, no marker, rc=1.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP_ROOT="$(mktemp -d -t agb-orphan-sweep-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Extract process_memory_daily_orphan_sweep out of bridge-daemon.sh into a
# self-contained snippet. The function spans a python3 heredoc that contains
# a literal "PY" delimiter and a final "}\n" terminator — match the first
# top-level "^}$" after the opening line.
EXTRACT_TMP="$TMP_ROOT/sweep.sh"
awk '
  /^process_memory_daily_orphan_sweep\(\) \{/ { copy = 1 }
  copy { print }
  copy && /^\}$/ { copy = 0; exit }
' "$ROOT_DIR/bridge-daemon.sh" >"$EXTRACT_TMP"

# Sanity check: the extracted snippet should contain the python3 heredoc and
# the marker-rollback line. If awk missed the closing brace we will catch it
# now rather than at first invocation.
if ! grep -q '^process_memory_daily_orphan_sweep() {' "$EXTRACT_TMP"; then
  printf 'extract failed: function header missing from %s\n' "$EXTRACT_TMP" >&2
  exit 2
fi
if ! grep -q 'memory-daily orphan-sweep: failed to emit' "$EXTRACT_TMP"; then
  printf 'extract failed: rollback warn line missing from %s\n' "$EXTRACT_TMP" >&2
  exit 2
fi

# --- Mock harness ---------------------------------------------------------

# Per-scenario state-dir + counters. reset_mocks resets all of them.
MOCK_STATE_DIR=""
MOCK_QUEUE_CREATE_CALLS=0
MOCK_QUEUE_UPDATE_CALLS=0
MOCK_QUEUE_FIND_OPEN_RESULT=""
MOCK_CRON_LIST_JSON=""
MOCK_AUDIT_CALLS=0
MOCK_INFO_CALLS=0
MOCK_WARN_CALLS=0

reset_mocks() {
  MOCK_STATE_DIR="$TMP_ROOT/state-$$-$RANDOM"
  mkdir -p "$MOCK_STATE_DIR"
  export BRIDGE_STATE_DIR="$MOCK_STATE_DIR"
  export BRIDGE_MEMORY_DAILY_ORPHAN_SWEEP_ENABLED=1
  export SCRIPT_DIR="$ROOT_DIR"
  export BRIDGE_BASH_BIN="${BASH:-/usr/bin/env bash}"
  MOCK_QUEUE_CREATE_CALLS=0
  MOCK_QUEUE_UPDATE_CALLS=0
  MOCK_QUEUE_FIND_OPEN_RESULT=""
  MOCK_CRON_LIST_JSON=""
  MOCK_AUDIT_CALLS=0
  MOCK_INFO_CALLS=0
  MOCK_WARN_CALLS=0
  BRIDGE_AGENT_IDS=()
}

# Stub collaborators. The function calls bridge-cron.sh via
# "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-cron.sh" list --json — we cannot
# easily swap that subprocess invocation, so we shadow the subprocess
# behaviour by exporting MOCK_CRON_LIST_JSON and pointing SCRIPT_DIR at a
# temp dir that holds a fake bridge-cron.sh.
install_fake_bridge_cron() {
  local fake_dir="$TMP_ROOT/fake-bin"
  mkdir -p "$fake_dir"
  cat >"$fake_dir/bridge-cron.sh" <<'CRONSTUB'
#!/usr/bin/env bash
# Test stub — echoes the JSON the test driver placed in MOCK_CRON_LIST_JSON.
# Accepts and ignores any args (the helper passes "list --json").
printf '%s' "${MOCK_CRON_LIST_JSON:-}"
CRONSTUB
  chmod +x "$fake_dir/bridge-cron.sh"
  export SCRIPT_DIR="$fake_dir"
}

bridge_admin_agent_id() { printf 'admin\n'; }
bridge_agent_exists() { [[ "$1" == "admin" ]]; }
bridge_load_roster() { :; }

bridge_queue_cli() {
  case "$1" in
    find-open)
      printf '%s' "$MOCK_QUEUE_FIND_OPEN_RESULT"
      [[ -n "$MOCK_QUEUE_FIND_OPEN_RESULT" ]] && return 0
      return 1
      ;;
    create)
      MOCK_QUEUE_CREATE_CALLS=$((MOCK_QUEUE_CREATE_CALLS + 1))
      return 0
      ;;
    update)
      MOCK_QUEUE_UPDATE_CALLS=$((MOCK_QUEUE_UPDATE_CALLS + 1))
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_audit_log() { MOCK_AUDIT_CALLS=$((MOCK_AUDIT_CALLS + 1)); return 0; }
daemon_info() { MOCK_INFO_CALLS=$((MOCK_INFO_CALLS + 1)); return 0; }
daemon_warn() { MOCK_WARN_CALLS=$((MOCK_WARN_CALLS + 1)); return 0; }

export -f bridge_admin_agent_id bridge_agent_exists bridge_load_roster
export -f bridge_queue_cli bridge_audit_log daemon_info daemon_warn

# Source the extracted helper. Must happen after the stubs above are
# defined so bash function lookup resolves to the stubs.
# shellcheck source=/dev/null
source "$EXTRACT_TMP"

# Helper: build a memory-daily cron list JSON with the given agent names.
make_cron_list_json() {
  local out='{"jobs":['
  local first=1
  local name
  for name in "$@"; do
    if (( first )); then first=0; else out+=","; fi
    out+="{\"id\":\"id-${name}\",\"name\":\"memory-daily-${name}\",\"family\":\"memory-daily\"}"
  done
  out+="]}"
  printf '%s' "$out"
}

today_marker_path() {
  local today
  today="$(date -u '+%Y-%m-%d')"
  printf '%s/memory-daily-orphan-sweep/%s.surfaced\n' "$BRIDGE_STATE_DIR" "$today"
}

# --- Scenarios ------------------------------------------------------------

scenario_orphans_detected() {
  printf '\n== scenario: orphans-detected ==\n' >&2
  reset_mocks
  install_fake_bridge_cron
  BRIDGE_AGENT_IDS=("admin" "tester")
  export MOCK_CRON_LIST_JSON
  MOCK_CRON_LIST_JSON="$(make_cron_list_json admin tester ghost-agent)"

  local rc=0
  process_memory_daily_orphan_sweep >/dev/null 2>&1 || rc=$?

  step "orphans-detected: rc"
  if [[ "$rc" == "0" ]]; then ok; else err "expected rc=0, got rc=$rc"; fi

  step "orphans-detected: exactly one queue create"
  if [[ "$MOCK_QUEUE_CREATE_CALLS" == "1" ]]; then ok; else err "expected 1, got $MOCK_QUEUE_CREATE_CALLS"; fi

  step "orphans-detected: no queue update (find-open returned empty)"
  if [[ "$MOCK_QUEUE_UPDATE_CALLS" == "0" ]]; then ok; else err "expected 0, got $MOCK_QUEUE_UPDATE_CALLS"; fi

  step "orphans-detected: marker file written"
  if [[ -f "$(today_marker_path)" ]]; then ok; else err "marker $(today_marker_path) missing"; fi

  step "orphans-detected: audit_log called once"
  if [[ "$MOCK_AUDIT_CALLS" == "1" ]]; then ok; else err "expected 1, got $MOCK_AUDIT_CALLS"; fi
}

scenario_marker_dedup() {
  printf '\n== scenario: marker-dedup ==\n' >&2
  reset_mocks
  install_fake_bridge_cron
  BRIDGE_AGENT_IDS=("admin" "tester")
  export MOCK_CRON_LIST_JSON
  MOCK_CRON_LIST_JSON="$(make_cron_list_json admin tester ghost-agent)"

  # Pre-seed the marker (simulate "already surfaced earlier today").
  mkdir -p "$BRIDGE_STATE_DIR/memory-daily-orphan-sweep"
  : >"$(today_marker_path)"

  local rc=0
  process_memory_daily_orphan_sweep >/dev/null 2>&1 || rc=$?

  step "marker-dedup: rc non-zero (suppressed)"
  if [[ "$rc" != "0" ]]; then ok; else err "expected non-zero rc, got 0"; fi

  step "marker-dedup: no queue create"
  if [[ "$MOCK_QUEUE_CREATE_CALLS" == "0" ]]; then ok; else err "expected 0, got $MOCK_QUEUE_CREATE_CALLS"; fi

  step "marker-dedup: no queue update"
  if [[ "$MOCK_QUEUE_UPDATE_CALLS" == "0" ]]; then ok; else err "expected 0, got $MOCK_QUEUE_UPDATE_CALLS"; fi

  step "marker-dedup: marker still present"
  if [[ -f "$(today_marker_path)" ]]; then ok; else err "marker disappeared"; fi
}

scenario_marker_rotated_re_emits() {
  printf '\n== scenario: marker-rotated-re-emits ==\n' >&2
  reset_mocks
  install_fake_bridge_cron
  BRIDGE_AGENT_IDS=("admin" "tester")
  export MOCK_CRON_LIST_JSON
  MOCK_CRON_LIST_JSON="$(make_cron_list_json admin tester ghost-agent)"

  # Simulate yesterday's marker getting rotated away — directory exists
  # but today's marker file does not.
  mkdir -p "$BRIDGE_STATE_DIR/memory-daily-orphan-sweep"
  rm -f "$(today_marker_path)"

  local rc=0
  process_memory_daily_orphan_sweep >/dev/null 2>&1 || rc=$?

  step "marker-rotated-re-emits: rc=0"
  if [[ "$rc" == "0" ]]; then ok; else err "expected rc=0, got rc=$rc"; fi

  step "marker-rotated-re-emits: exactly one queue create"
  if [[ "$MOCK_QUEUE_CREATE_CALLS" == "1" ]]; then ok; else err "expected 1, got $MOCK_QUEUE_CREATE_CALLS"; fi

  step "marker-rotated-re-emits: new marker written"
  if [[ -f "$(today_marker_path)" ]]; then ok; else err "marker $(today_marker_path) missing"; fi
}

scenario_no_orphan_noop() {
  printf '\n== scenario: no-orphan-noop ==\n' >&2
  reset_mocks
  install_fake_bridge_cron
  BRIDGE_AGENT_IDS=("admin" "tester")
  export MOCK_CRON_LIST_JSON
  # All cron jobs map to roster agents — no orphans.
  MOCK_CRON_LIST_JSON="$(make_cron_list_json admin tester)"

  local rc=0
  process_memory_daily_orphan_sweep >/dev/null 2>&1 || rc=$?

  step "no-orphan-noop: rc non-zero (nothing to do)"
  if [[ "$rc" != "0" ]]; then ok; else err "expected non-zero rc, got 0"; fi

  step "no-orphan-noop: no queue create"
  if [[ "$MOCK_QUEUE_CREATE_CALLS" == "0" ]]; then ok; else err "expected 0, got $MOCK_QUEUE_CREATE_CALLS"; fi

  step "no-orphan-noop: no queue update"
  if [[ "$MOCK_QUEUE_UPDATE_CALLS" == "0" ]]; then ok; else err "expected 0, got $MOCK_QUEUE_UPDATE_CALLS"; fi

  step "no-orphan-noop: no marker written"
  if [[ ! -f "$(today_marker_path)" ]]; then ok; else err "marker should not exist"; fi
}

scenario_orphans_detected
scenario_marker_dedup
scenario_marker_rotated_re_emits
scenario_no_orphan_noop

printf '\nresults: %d pass, %d fail\n' "$PASS" "$FAIL" >&2
if (( FAIL > 0 )); then
  exit 1
fi
printf 'all scenarios pass\n' >&2
exit 0
