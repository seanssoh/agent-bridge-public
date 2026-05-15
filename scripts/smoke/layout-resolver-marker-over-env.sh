#!/usr/bin/env bash
# S2 regression smoke — BRIDGE_LAYOUT=legacy stale-env demotion.
#
# Reproduces the operator-visible blocker (v0.13.10 audit B17) where the
# layout resolver hard-died on `BRIDGE_LAYOUT=legacy` env even when the
# install was already migrated to v2 (a valid v2 marker on disk). The
# leak source is typically an old shell rc, a stale tmux session, or an
# operator script left over from pre-v0.8.0.
#
# Fix (lib/bridge-layout-resolver.sh): when env says legacy|v1 AND a
# valid v2 marker exists, demote to warning and prefer the marker.
# When no marker exists, keep the original hard-die so the operator
# sees the migration prompt.
#
# Coverage (cross-platform):
#   C1 — env=legacy + valid v2 marker present → resolver does NOT die,
#        warning emitted, BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV set,
#        marker step takes over (resolver source becomes "marker").
#   C2 — env=v2 + matching BRIDGE_DATA_ROOT (existing valid-env path) →
#        resolver returns source="env" (regression guard for valid env
#        overrides).
#   C3 — env=legacy + NO marker → resolver DIES with the original
#        migration prompt (regression guard for unmigrated installs).
#   C4 — env=legacy + marker pinned to v1 → resolver DIES WITHOUT the
#        false "preferring marker" warning. Codex r1 catch on PR #904:
#        the demotion contract is "env=legacy + marker=v2 → demote";
#        a v1 marker is itself un-migrated and must surface the hard-die
#        without the misleading warning.

set -uo pipefail

SMOKE_NAME="layout-resolver-marker-over-env"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

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

# Build a v2 marker file the resolver will accept. Validator allows only
# the keys in `marker_bootstrap.sh::bridge_isolation_v2_marker_validate`
# (BRIDGE_LAYOUT, BRIDGE_DATA_ROOT, plus group/prefix vars). Mode must
# not have group/world write bits.
write_v2_marker() {
  local home_dir="$1"
  local data_root="$2"
  local marker_dir="$home_dir/state"
  local marker_file="$marker_dir/layout-marker.sh"
  mkdir -p "$marker_dir"
  {
    printf '%s\n' '# bridge layout marker (v2) — written by smoke fixture'
    printf 'BRIDGE_LAYOUT=v2\n'
    printf 'BRIDGE_DATA_ROOT=%s\n' "$data_root"
  } > "$marker_file"
  chmod 0644 "$marker_file"
}

# Build a v1 (un-migrated) marker for the false-positive guard. The
# validator returns 0 for this shape (only the v2 branch checks
# data_root) — codex r1 caught that we were demoting based on validator
# rc alone.
write_v1_marker() {
  local home_dir="$1"
  local marker_dir="$home_dir/state"
  local marker_file="$marker_dir/layout-marker.sh"
  mkdir -p "$marker_dir"
  {
    printf '%s\n' '# bridge layout marker (v1) — un-migrated, smoke fixture'
    printf 'BRIDGE_LAYOUT=v1\n'
  } > "$marker_file"
  chmod 0644 "$marker_file"
}

run_resolver() {
  # Args: $1 = env_layout, $2 = env_data_root, $3 = home_dir,
  #       $4 = marker_kind (v2|v1|none), $5 = out_file
  local env_layout="$1"
  local env_data_root="$2"
  local home_dir="$3"
  local marker_kind="$4"
  local out_file="$5"

  mkdir -p "$home_dir/state" "$env_data_root"
  case "$marker_kind" in
    v2) write_v2_marker "$home_dir" "$env_data_root" ;;
    v1) write_v1_marker "$home_dir" ;;
    none|0) rm -f "$home_dir/state/layout-marker.sh" ;;
    1) write_v2_marker "$home_dir" "$env_data_root" ;;
    *) smoke_fail "internal: unknown marker_kind=$marker_kind" ;;
  esac

  local driver="$SMOKE_TMP_ROOT/driver-$$.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'cd %q\n' "$REPO_ROOT"
    printf 'export BRIDGE_HOME=%q\n' "$home_dir"
    printf 'export BRIDGE_STATE_DIR=%q\n' "$home_dir/state"
    printf 'export BRIDGE_LAYOUT_MARKER_DIR=%q\n' "$home_dir/state"
    if [[ -n "$env_layout" ]]; then
      printf 'export BRIDGE_LAYOUT=%q\n' "$env_layout"
    fi
    if [[ -n "$env_data_root" ]]; then
      printf 'export BRIDGE_DATA_ROOT=%q\n' "$env_data_root"
    fi
    printf '%s\n' 'source "$0_REPO_ROOT/bridge-lib.sh" 2>&1; rc=$?'
    printf '%s\n' 'echo "RC=$rc"'
    printf '%s\n' 'echo "LAYOUT=$BRIDGE_LAYOUT"'
    printf '%s\n' 'echo "SOURCE=${BRIDGE_LAYOUT_SOURCE:-<unset>}"'
    printf '%s\n' 'echo "IGNORED=${BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV:-<unset>}"'
  } | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$driver"
  chmod +x "$driver"

  "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1
  rm -f "$driver"
}

# C1 — env=legacy + valid v2 marker → demote, prefer marker
smoke_log "C1: env=legacy + valid v2 marker → demote-to-warning"
C1_HOME="$SMOKE_TMP_ROOT/c1-home"
C1_DATA="$SMOKE_TMP_ROOT/c1-data"
C1_OUT="$SMOKE_TMP_ROOT/c1.out"
run_resolver "legacy" "$C1_DATA" "$C1_HOME" 1 "$C1_OUT"

if grep -q 'requires isolation-v2' "$C1_OUT" && ! grep -q 'stale pre-v0.8.0 env override' "$C1_OUT"; then
  smoke_log "C1 output:"; cat "$C1_OUT"
  smoke_fail "C1: resolver still hard-died with stale legacy env over valid v2 marker"
fi
if ! grep -q 'stale pre-v0.8.0 env override' "$C1_OUT"; then
  smoke_log "C1 output:"; cat "$C1_OUT"
  smoke_fail "C1: expected demotion warning ('stale pre-v0.8.0 env override') not found"
fi
if ! grep -q 'SOURCE=marker' "$C1_OUT"; then
  smoke_log "C1 output:"; cat "$C1_OUT"
  smoke_fail "C1: expected SOURCE=marker after demotion (got: $(grep '^SOURCE=' "$C1_OUT"))"
fi
smoke_log "C1 PASS"

# C2 — env=v2 + matching data_root (existing valid-env path)
smoke_log "C2: env=v2 + matching data_root → source=env"
C2_HOME="$SMOKE_TMP_ROOT/c2-home"
C2_DATA="$SMOKE_TMP_ROOT/c2-data"
C2_OUT="$SMOKE_TMP_ROOT/c2.out"
run_resolver "v2" "$C2_DATA" "$C2_HOME" 0 "$C2_OUT"

if ! grep -q 'SOURCE=env' "$C2_OUT"; then
  smoke_log "C2 output:"; cat "$C2_OUT"
  smoke_fail "C2: expected SOURCE=env for valid env override (got: $(grep '^SOURCE=' "$C2_OUT"))"
fi
smoke_log "C2 PASS"

# C3 — env=legacy + NO marker → still die
smoke_log "C3: env=legacy + no marker → preserve hard-die"
C3_HOME="$SMOKE_TMP_ROOT/c3-home"
C3_DATA="$SMOKE_TMP_ROOT/c3-data"
C3_OUT="$SMOKE_TMP_ROOT/c3.out"
run_resolver "legacy" "$C3_DATA" "$C3_HOME" 0 "$C3_OUT" || true

if ! grep -q 'requires isolation-v2' "$C3_OUT"; then
  smoke_log "C3 output:"; cat "$C3_OUT"
  smoke_fail "C3: expected hard-die ('requires isolation-v2') when no v2 marker present"
fi
if grep -q 'stale pre-v0.8.0 env override' "$C3_OUT"; then
  smoke_log "C3 output:"; cat "$C3_OUT"
  smoke_fail "C3: must NOT demote when there is no v2 marker on disk"
fi
smoke_log "C3 PASS"

# C4 — env=legacy + marker pinned to v1 (un-migrated) → no false demote
smoke_log "C4: env=legacy + marker pinned to v1 → hard-die WITHOUT demotion warning"
C4_HOME="$SMOKE_TMP_ROOT/c4-home"
C4_DATA="$SMOKE_TMP_ROOT/c4-data"
C4_OUT="$SMOKE_TMP_ROOT/c4.out"
run_resolver "legacy" "$C4_DATA" "$C4_HOME" "v1" "$C4_OUT" || true

if ! grep -q 'requires isolation-v2' "$C4_OUT"; then
  smoke_log "C4 output:"; cat "$C4_OUT"
  smoke_fail "C4: expected hard-die ('requires isolation-v2') when marker pins layout to v1"
fi
if grep -q 'stale pre-v0.8.0 env override' "$C4_OUT"; then
  smoke_log "C4 output:"; cat "$C4_OUT"
  smoke_fail "C4: must NOT emit the 'preferring marker' demotion warning when marker pins layout to v1"
fi
smoke_log "C4 PASS"

smoke_log "PASS — stale-env demotion behaves correctly across 4 cases"
exit 0
