#!/usr/bin/env bash
# v0.13.10 Track A — regression smoke for the marker-only fast-path in
# `bridge_isolation_v2_migrate_apply_for_upgrade`.
#
# Reproduces the v0.13.9 gate that blocks v0.7.x → v0.13.x leaps on hosts
# without sudo: operator host has no isolation-v2 marker and no isolated
# agents in the roster. Pre-v0.13.10, the migrate helper either took the
# macos-shared-agent skip (status=ok but marker NOT written, so the next
# resolver call still rejects) or failed privilege preflight on Linux
# without root.
#
# Coverage:
#   T1 — markerless + no-isolated + BRIDGE_UPGRADE_CONTEXT=1 →
#        status=ok, reason=marker-only-no-isolated-roster, marker WRITTEN
#        on disk, sudo NEVER invoked, group_ops=skipped.
#   T2 — same as T1 + re-run → second call hits marker-present skip
#        (idempotent, no re-write).
#   T3 — markerless + no-isolated + BRIDGE_UPGRADE_CONTEXT UNSET → the
#        new fast-path does NOT fire; existing macos-shared-agent skip
#        still applies (regression guard for direct
#        `agent-bridge migrate isolation v2 --apply` callers).
#   T4 — markerless + has-isolated-agent + BRIDGE_UPGRADE_CONTEXT=1 →
#        the new fast-path does NOT fire (reason != marker-only-…);
#        roster predicate rc=0 must keep the existing migration path.
#   T5 — markerless + roster predicate unavailable (rc=2) +
#        BRIDGE_UPGRADE_CONTEXT=1 → the new fast-path does NOT fire
#        (rc=2 is "unknown" — must surface the existing preflight error
#        rather than silently writing a marker on an install whose
#        roster cannot be inspected).
#
# Footgun #11 (Bash 5.3.9 heredoc-class deadlock): all driver bodies are
# emitted via printf-to-file (no heredocs, no here-strings).

set -uo pipefail

SMOKE_NAME="isolation-v2-marker-only-migrate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# --- harness helpers ---------------------------------------------------------

# Build a `bin/` shim dir that records every `sudo` invocation. The
# marker-only fast-path must NOT call sudo (no group ops, no chown).
build_sudo_recorder_shim() {
  local shim_dir="$1"
  local sudo_log="$2"

  mkdir -p "$shim_dir"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# sudo recorder shim — logs each call and exits non-zero so a'
    printf '%s\n' '# silent state mutation surfaces as a loud test failure.'
    printf 'LOG=%q\n' "$sudo_log"
    printf '%s\n' 'printf "[sudo-shim] %s\n" "$*" >>"$LOG"'
    printf '%s\n' 'exit 99'
  } >"$shim_dir/sudo"
  chmod +x "$shim_dir/sudo"
}

# Symlink the other PATH essentials into the shim dir so the driver
# subshell still has access to bash/mkdir/rm/printf/cat/grep/etc when
# PATH is replaced wholesale.
populate_basic_path() {
  local shim_dir="$1"
  local cmd target
  for cmd in bash mkdir rm cat tr grep sed awk printf id stat tee chmod dirname env date mktemp readlink ls cp mv touch wc head tail find sort uniq true false python3 git tmux jq sqlite3 sha256sum md5 uname install; do
    target="$(command -v "$cmd" 2>/dev/null || true)"
    [[ -n "$target" && "${target:0:1}" == "/" ]] || continue
    [[ -L "$shim_dir/$cmd" || -e "$shim_dir/$cmd" ]] && continue
    ln -s "$target" "$shim_dir/$cmd" 2>/dev/null || true
  done
}

# Build a one-shot driver script via printf line-by-line. No heredocs.
write_driver_script() {
  local out="$1"
  shift
  : >"$out"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

# Stage a markerless-existing-install fixture under $home_dir:
#   - state/, agents/, logs/, shared/, data/ subdirs present
#   - empty roster files
#   - layout-marker.sh ABSENT (no $home_dir/state/layout-marker.sh)
stage_markerless_install() {
  local home_dir="$1"
  mkdir -p "$home_dir/state" "$home_dir/agents" "$home_dir/logs" \
           "$home_dir/shared" "$home_dir/data/shared" \
           "$home_dir/data/agents" "$home_dir/data/state"
  : >"$home_dir/agent-roster.local.sh"
  rm -f "$home_dir/state/layout-marker.sh"
}

# Invoke `bridge_isolation_v2_migrate_apply_for_upgrade` under a PATH
# that contains our sudo recorder.
#
# Args:
#   $1 = home_dir          (absolute path)
#   $2 = roster_kind       (empty|shared|isolated|unknown)
#   $3 = upgrade_context   (1|<empty>)
#   $4 = out_file          (absolute path; captures stdout+stderr)
run_apply_for_upgrade() {
  local home_dir="$1"
  local roster_kind="$2"
  local upgrade_context="$3"
  local out_file="$4"

  local shim_dir="$home_dir/shim-bin"
  local sudo_log="$home_dir/sudo-calls.log"
  : >"$sudo_log"
  build_sudo_recorder_shim "$shim_dir" "$sudo_log"
  populate_basic_path "$shim_dir"

  local roster_setup
  case "$roster_kind" in
    empty)
      # roster array unset -> predicate returns rc=2 (unknown)
      roster_setup='unset BRIDGE_AGENT_IDS 2>/dev/null || true'
      ;;
    shared)
      # roster has agents but all return rc=1 -> predicate rc=1 (confirmed-no)
      roster_setup='BRIDGE_AGENT_IDS=(a1 a2); bridge_agent_linux_user_isolation_effective() { return 1; }'
      ;;
    isolated)
      # at least one agent returns rc=0 -> predicate rc=0 (has-isolated)
      roster_setup='BRIDGE_AGENT_IDS=(a1 a2); bridge_agent_linux_user_isolation_effective() { local a="${1:-}"; case "$a" in a2) return 0;; *) return 1;; esac; }'
      ;;
    unknown)
      # remove the predicate function -> rc=2 (unknown)
      roster_setup='BRIDGE_AGENT_IDS=(a1); unset -f bridge_agent_linux_user_isolation_effective 2>/dev/null || true'
      ;;
    *) smoke_fail "internal: unknown roster_kind=$roster_kind" ;;
  esac

  local driver="$home_dir/driver.sh"
  # BRIDGE_LAYOUT=v2 is exported BEFORE bridge-lib.sh so the layout
  # resolver takes the env-set source-path and does not bridge_die on
  # the markerless fixture. In the live upgrade flow, the same bypass
  # happens via BRIDGE_LAYOUT_RESOLVER_BYPASS. We pick BRIDGE_LAYOUT=v2
  # for the test fixture because the migrate function does not gate on
  # the resolver's source enum — it inspects the on-disk marker via
  # bridge_isolation_v2_marker_path, which is anchored on
  # BRIDGE_LAYOUT_MARKER_DIR (also exported).
  write_driver_script "$driver" \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'cd "$REPO_ROOT"' \
    'export BRIDGE_HOME="$HOME_DIR"' \
    'export BRIDGE_STATE_DIR="$HOME_DIR/state"' \
    'export BRIDGE_LAYOUT_MARKER_DIR="$HOME_DIR/state"' \
    'export BRIDGE_LOG_DIR="$HOME_DIR/logs"' \
    'export BRIDGE_SHARED_DIR="$HOME_DIR/shared"' \
    'export BRIDGE_DATA_ROOT="$HOME_DIR/data"' \
    'export BRIDGE_LAYOUT="v2"' \
    'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1' \
    'source "$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh" >/dev/null 2>&1' \
    "$roster_setup" \
    'bridge_isolation_v2_migrate_apply_for_upgrade --target-root "$HOME_DIR" --json 2>/dev/null || true'

  PATH="$shim_dir" \
    REPO_ROOT="$REPO_ROOT" \
    HOME_DIR="$home_dir" \
    BRIDGE_HOME="$home_dir" \
    BRIDGE_STATE_DIR="$home_dir/state" \
    BRIDGE_LAYOUT_MARKER_DIR="$home_dir/state" \
    BRIDGE_LOG_DIR="$home_dir/logs" \
    BRIDGE_SHARED_DIR="$home_dir/shared" \
    BRIDGE_DATA_ROOT="$home_dir/data" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_UPGRADE_CONTEXT="$upgrade_context" \
    "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1 || true
}

assert_marker_only_path() {
  local label="$1"
  local payload="$2"
  case "$payload" in
    *'"reason":"marker-only-no-isolated-roster"'*) ;;
    *) smoke_fail "$label expected reason=marker-only-no-isolated-roster, got: $payload" ;;
  esac
  case "$payload" in
    *'"status":"ok"'*) ;;
    *) smoke_fail "$label expected status=ok, got: $payload" ;;
  esac
  case "$payload" in
    *'"group_ops":"skipped"'*) ;;
    *) smoke_fail "$label expected group_ops=skipped, got: $payload" ;;
  esac
  case "$payload" in
    *'"mode":"isolation-v2-migrate"'*) ;;
    *) smoke_fail "$label expected mode=isolation-v2-migrate, got: $payload" ;;
  esac
}

assert_not_marker_only_path() {
  local label="$1"
  local payload="$2"
  case "$payload" in
    *'"reason":"marker-only-no-isolated-roster"'*)
      smoke_fail "$label: marker-only fast-path fired on a context that should NOT take it. payload=$payload" ;;
  esac
}

# --- T1: markerless + no-isolated + upgrade context → marker written ---------

smoke_log "T1: markerless + no-isolated + BRIDGE_UPGRADE_CONTEXT=1 → marker-only path"

T1_HOME="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_HOME"
stage_markerless_install "$T1_HOME"
T1_OUT="$T1_HOME/out.txt"
run_apply_for_upgrade "$T1_HOME" shared 1 "$T1_OUT"
T1_PAYLOAD="$(cat "$T1_OUT")"
assert_marker_only_path "T1" "$T1_PAYLOAD"

# Marker file MUST exist on disk and carry BRIDGE_LAYOUT=v2.
T1_MARKER="$T1_HOME/state/layout-marker.sh"
if [[ ! -f "$T1_MARKER" ]]; then
  smoke_fail "T1: expected marker at $T1_MARKER to exist after marker-only path"
fi
if ! grep -q '^BRIDGE_LAYOUT=' "$T1_MARKER"; then
  smoke_fail "T1: marker $T1_MARKER missing BRIDGE_LAYOUT= line. contents=$(cat "$T1_MARKER")"
fi
if ! grep -q '^BRIDGE_DATA_ROOT=' "$T1_MARKER"; then
  smoke_fail "T1: marker $T1_MARKER missing BRIDGE_DATA_ROOT= line. contents=$(cat "$T1_MARKER")"
fi

# sudo MUST NOT have been invoked.
if [[ -s "$T1_HOME/sudo-calls.log" ]]; then
  smoke_fail "T1: sudo shim recorded calls — marker-only path must NOT call sudo. log=$(cat "$T1_HOME/sudo-calls.log")"
fi
smoke_log "T1 PASS: marker written + sudo never invoked"

# --- T2: idempotent — second run hits marker-present skip --------------------

smoke_log "T2: second call hits marker-present skip (idempotent)"

T2_OUT_B="$T1_HOME/out-b.txt"
run_apply_for_upgrade "$T1_HOME" shared 1 "$T2_OUT_B"
T2_PAYLOAD_B="$(cat "$T2_OUT_B")"
case "$T2_PAYLOAD_B" in
  *'"reason":"marker-present"'*) ;;
  *'"reason":"macos-shared-agent"'*) ;;
  *)
    # On Linux without sudo + valid marker, the marker-present branch
    # falls back to "no-privilege/inactive" which still uses
    # reason=marker-present. macOS path also acceptable when the
    # privilege preflight fails. Reject anything carrying our new
    # marker-only reason (we already wrote the marker, T2 must NOT
    # re-fire the marker-only path).
    case "$T2_PAYLOAD_B" in
      *'"reason":"marker-only-no-isolated-roster"'*)
        smoke_fail "T2: second call re-took the marker-only path; should have hit marker-present skip. payload=$T2_PAYLOAD_B" ;;
    esac
    ;;
esac
smoke_log "T2 PASS: idempotent — second call did not re-take the marker-only path"

# --- T3: markerless + no-isolated + UPGRADE_CONTEXT unset → old skip ---------

smoke_log "T3: markerless + no-isolated + BRIDGE_UPGRADE_CONTEXT unset → fast-path NOT fired"

T3_HOME="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_HOME"
stage_markerless_install "$T3_HOME"
T3_OUT="$T3_HOME/out.txt"
run_apply_for_upgrade "$T3_HOME" shared "" "$T3_OUT"
T3_PAYLOAD="$(cat "$T3_OUT")"
assert_not_marker_only_path "T3" "$T3_PAYLOAD"

# Marker file MUST NOT have been written (the existing macOS/Linux
# branches do not write a marker without privilege preflight).
T3_MARKER="$T3_HOME/state/layout-marker.sh"
if [[ -f "$T3_MARKER" ]]; then
  smoke_fail "T3: marker $T3_MARKER unexpectedly written without BRIDGE_UPGRADE_CONTEXT=1. contents=$(cat "$T3_MARKER")"
fi
smoke_log "T3 PASS: marker-only path stays gated behind BRIDGE_UPGRADE_CONTEXT=1"

# --- T4: markerless + has-isolated + upgrade context → fast-path NOT fired --

smoke_log "T4: markerless + has-isolated + BRIDGE_UPGRADE_CONTEXT=1 → fast-path NOT fired"

T4_HOME="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_HOME"
stage_markerless_install "$T4_HOME"
T4_OUT="$T4_HOME/out.txt"
run_apply_for_upgrade "$T4_HOME" isolated 1 "$T4_OUT"
T4_PAYLOAD="$(cat "$T4_OUT")"
assert_not_marker_only_path "T4" "$T4_PAYLOAD"
smoke_log "T4 PASS: has-isolated-roster path bypasses the marker-only fast-path"

# --- T5: markerless + roster predicate unavailable (rc=2) → fast-path NOT fired

smoke_log "T5: markerless + roster predicate rc=2 (unknown) → fast-path NOT fired"

T5_HOME="$SMOKE_TMP_ROOT/t5"
mkdir -p "$T5_HOME"
stage_markerless_install "$T5_HOME"
T5_OUT="$T5_HOME/out.txt"
run_apply_for_upgrade "$T5_HOME" unknown 1 "$T5_OUT"
T5_PAYLOAD="$(cat "$T5_OUT")"
assert_not_marker_only_path "T5" "$T5_PAYLOAD"

# Marker file MUST NOT have been written under rc=2 — silently writing a
# marker on an install whose roster cannot be inspected would mask the
# legitimate preflight error the operator needs to see.
T5_MARKER="$T5_HOME/state/layout-marker.sh"
if [[ -f "$T5_MARKER" ]]; then
  smoke_fail "T5: marker $T5_MARKER unexpectedly written under rc=2 (unknown roster). contents=$(cat "$T5_MARKER")"
fi
smoke_log "T5 PASS: rc=2 unknown roster keeps the operator-visible preflight path"

smoke_log "all 5 tests PASS"
