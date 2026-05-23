#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1161-marker-readable-by-isolated.sh — Issue #1161
#
# Three production layout-marker writers previously chmod'd the marker to
# mode 0640 (group-only read). On real installs the isolated UIDs the
# marker was supposed to be readable by were not actually joined to the
# `ab-shared` group — `bridge_isolation_v2_ensure_user_in_group "$os_user"
# "ab-shared"` ran but did not survive on the live system — so the marker
# was unreadable from the isolated agent's `sudo -u` context. The
# resolver then fell back to `markerless(existing-install)` and
# `bridge-run.sh` died.
#
# Fix: broaden mode to 0644. Marker content is non-secret (BRIDGE_LAYOUT=v2
# + BRIDGE_DATA_ROOT=<abs-path>). The validator's mode check
# (lib/bridge-marker-bootstrap.sh:102) rejects only group/world WRITE
# bits (`mode_int & 0022`), not READ — 0644 stays valid against the
# existing gate, while every UID on the box can read the marker without
# depending on `ab-shared` group membership.
#
# This smoke pins the matrix:
#
#   T1: bridge_isolation_v2_migrate_marker_write           → file mode is 0644
#   T2: bridge_isolation_v2_migrate_marker_write_minimal   → file mode is 0644
#   T3: bridge_layout_write_v2_marker (fresh init path)    → file mode is 0644
#   T4: marker validator ACCEPTS 0644
#       (mode_int & 0022 == 0 — no group/world write)
#   T5: marker validator REJECTS 0664
#       (mode_int & 0022 != 0 — group write bit set)
#   T6: regression contract — every production writer asserts 0644 in
#       its source. Reverting any of the three sites to 0640 must
#       cause this smoke to fail. Implemented as a static grep against
#       the worktree source, scoped to the three writer functions.
#
# Host-agnostic: T1/T2/T3 run in an isolated $BRIDGE_HOME and source the
# minimum lib surface (same pattern as scripts/smoke/864-upgrade-perm-
# regressions.sh) so the writers don't need root or sudo — the sudo-chown
# step inside marker_write is best-effort and no-op's under the rootless
# dev tree, leaving the caller-owned 0644 file on disk. T4/T5 stub the
# stat shims (no privilege required to fake mode). T6 is a static-source
# assertion. Footgun #11 (heredoc-stdin subprocess) is avoided — every
# driver is built with `printf '%s\n' >>file`.

set -uo pipefail

SMOKE_NAME="1161-marker-readable-by-isolated"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Portable mode-read shim (GNU vs BSD stat).
file_mode_octal() {
  local path="$1"
  if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
    stat -f '%Lp' "$path" 2>/dev/null
  else
    stat -c '%a' "$path" 2>/dev/null
  fi
}

# ---------- shared writer-driver template ----------
#
# Each writer-driver:
#   1. Sets BRIDGE_HOME / BRIDGE_STATE_DIR / BRIDGE_LAYOUT_MARKER_DIR
#      under the test's tempdir.
#   2. Sources the minimum lib surface — bridge-core / marker-bootstrap /
#      isolation-v2 / isolation-v2-migrate / layout-resolver — directly
#      (NOT via bridge-lib.sh, which has heavier transitive deps).
#   3. Overrides bridge_die / bridge_warn to soft no-ops so the helper
#      can be called from inside the driver without an abort path.
#   4. Calls the writer-under-test.
build_writer_driver() {
  local driver="$1"
  local writer_fn="$2"
  # When $3 == "with-resolver" the driver also sources
  # lib/bridge-layout-resolver.sh — needed for T3 which calls
  # bridge_layout_write_v2_marker (defined in that file). Auto-resolver
  # only fires when BRIDGE_LAYOUT/BRIDGE_DATA_ROOT are exported in the
  # env (env-override branch) so the markerless-fresh-install fail-fast
  # does not abort the smoke.
  local include_resolver="${3:-no-resolver}"
  : >"$driver"
  # shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf '%s\n' 'REPO_ROOT="$1"'
    printf '%s\n' 'export BRIDGE_HOME="$2"'
    printf '%s\n' 'export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"'
    printf '%s\n' 'export BRIDGE_LAYOUT_MARKER_DIR="$BRIDGE_HOME/state"'
    printf '%s\n' 'DATA_ROOT="$3"'
    if [[ "$include_resolver" == "with-resolver" ]]; then
      # Pre-export BRIDGE_LAYOUT/BRIDGE_DATA_ROOT so the resolver's env-
      # override branch wins instead of fail-fast on a markerless tempdir.
      printf '%s\n' 'export BRIDGE_LAYOUT=v2'
      printf '%s\n' 'export BRIDGE_DATA_ROOT="$BRIDGE_HOME/data"'
    else
      printf '%s\n' 'unset BRIDGE_DATA_ROOT BRIDGE_LAYOUT 2>/dev/null || true'
    fi
    printf '%s\n' '# shellcheck disable=SC1091'
    printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"'
    printf '%s\n' '# shellcheck disable=SC1091'
    printf '%s\n' 'source "$REPO_ROOT/lib/bridge-marker-bootstrap.sh"'
    printf '%s\n' '# shellcheck disable=SC1091'
    printf '%s\n' 'source "$REPO_ROOT/lib/bridge-isolation-v2.sh"'
    printf '%s\n' '# shellcheck disable=SC1091'
    printf '%s\n' 'source "$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh"'
    if [[ "$include_resolver" == "with-resolver" ]]; then
      printf '%s\n' '# shellcheck disable=SC1091'
      printf '%s\n' 'source "$REPO_ROOT/lib/bridge-layout-resolver.sh"'
    fi
    # Soften bridge_die / bridge_warn so the writers do not abort the driver
    # on best-effort sudo paths. Defined AFTER sourcing so the lib's defs
    # do not clobber ours.
    printf '%s\n' '# shellcheck disable=SC2329'
    printf '%s\n' 'bridge_die() { printf "bridge_die: %s\n" "$*" >&2; return 1; }'
    printf '%s\n' '# shellcheck disable=SC2329'
    printf '%s\n' 'bridge_warn() { printf "bridge_warn: %s\n" "$*" >&2; }'
    printf '%s\n' "$writer_fn"' "$DATA_ROOT"'
    printf '%s\n' 'echo "RC=$?"'
  } >>"$driver"
  chmod +x "$driver"
}

# ---------- T1 — bridge_isolation_v2_migrate_marker_write produces 0644 ----------
T1_HOME="$SMOKE_TMP_ROOT/t1-home"
mkdir -p "$T1_HOME/state"
T1_MARKER="$T1_HOME/state/layout-marker.sh"
T1_DATA_ROOT="$T1_HOME/data"
T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.sh"
build_writer_driver "$T1_DRIVER" "bridge_isolation_v2_migrate_marker_write"

"$BRIDGE_BASH" "$T1_DRIVER" "$REPO_ROOT" "$T1_HOME" "$T1_DATA_ROOT" \
  >"$T1_HOME/out" 2>"$T1_HOME/err" \
  || smoke_fail "T1 marker_write failed (rc=$?). out: $(cat "$T1_HOME/out") err: $(cat "$T1_HOME/err")"
[[ -f "$T1_MARKER" ]] \
  || smoke_fail "T1 expected marker at $T1_MARKER (writer did not publish). out: $(cat "$T1_HOME/out") err: $(cat "$T1_HOME/err")"
t1_mode="$(file_mode_octal "$T1_MARKER")"
if [[ "$t1_mode" != "644" && "$t1_mode" != "0644" ]]; then
  smoke_fail "T1 expected mode 644 from bridge_isolation_v2_migrate_marker_write, got $t1_mode. out: $(cat "$T1_HOME/out") err: $(cat "$T1_HOME/err")"
fi
smoke_log "T1 PASS: bridge_isolation_v2_migrate_marker_write → mode $t1_mode"

# ---------- T2 — bridge_isolation_v2_migrate_marker_write_minimal produces 0644 ----------
T2_HOME="$SMOKE_TMP_ROOT/t2-home"
mkdir -p "$T2_HOME/state"
T2_MARKER="$T2_HOME/state/layout-marker.sh"
T2_DATA_ROOT="$T2_HOME/data"
T2_DRIVER="$SMOKE_TMP_ROOT/t2-driver.sh"
build_writer_driver "$T2_DRIVER" "bridge_isolation_v2_migrate_marker_write_minimal"

"$BRIDGE_BASH" "$T2_DRIVER" "$REPO_ROOT" "$T2_HOME" "$T2_DATA_ROOT" \
  >"$T2_HOME/out" 2>"$T2_HOME/err" \
  || smoke_fail "T2 marker_write_minimal failed (rc=$?). out: $(cat "$T2_HOME/out") err: $(cat "$T2_HOME/err")"
[[ -f "$T2_MARKER" ]] \
  || smoke_fail "T2 expected marker at $T2_MARKER (writer did not publish). out: $(cat "$T2_HOME/out") err: $(cat "$T2_HOME/err")"
t2_mode="$(file_mode_octal "$T2_MARKER")"
if [[ "$t2_mode" != "644" && "$t2_mode" != "0644" ]]; then
  smoke_fail "T2 expected mode 644 from bridge_isolation_v2_migrate_marker_write_minimal, got $t2_mode. out: $(cat "$T2_HOME/out") err: $(cat "$T2_HOME/err")"
fi
smoke_log "T2 PASS: bridge_isolation_v2_migrate_marker_write_minimal → mode $t2_mode"

# ---------- T3 — bridge_layout_write_v2_marker (fresh init) produces 0644 ----------
T3_HOME="$SMOKE_TMP_ROOT/t3-home"
mkdir -p "$T3_HOME/state"
T3_MARKER="$T3_HOME/state/layout-marker.sh"
T3_DATA_ROOT="$T3_HOME/data"
T3_DRIVER="$SMOKE_TMP_ROOT/t3-driver.sh"
build_writer_driver "$T3_DRIVER" "bridge_layout_write_v2_marker" "with-resolver"

"$BRIDGE_BASH" "$T3_DRIVER" "$REPO_ROOT" "$T3_HOME" "$T3_DATA_ROOT" \
  >"$T3_HOME/out" 2>"$T3_HOME/err" \
  || smoke_fail "T3 bridge_layout_write_v2_marker failed (rc=$?). out: $(cat "$T3_HOME/out") err: $(cat "$T3_HOME/err")"
[[ -f "$T3_MARKER" ]] \
  || smoke_fail "T3 expected marker at $T3_MARKER (writer did not publish). out: $(cat "$T3_HOME/out") err: $(cat "$T3_HOME/err")"
t3_mode="$(file_mode_octal "$T3_MARKER")"
if [[ "$t3_mode" != "644" && "$t3_mode" != "0644" ]]; then
  smoke_fail "T3 expected mode 644 from bridge_layout_write_v2_marker, got $t3_mode. out: $(cat "$T3_HOME/out") err: $(cat "$T3_HOME/err")"
fi
smoke_log "T3 PASS: bridge_layout_write_v2_marker → mode $t3_mode"

# ---------- T4 — validator ACCEPTS mode 0644 ----------
# Build a stat-shim driver so we can fake the mode without chowning.
T4_MARKER="$SMOKE_TMP_ROOT/t4-marker.sh"
: >"$T4_MARKER"
{
  printf '%s\n' 'BRIDGE_LAYOUT=v2'
  printf '%s\n' "BRIDGE_DATA_ROOT='$SMOKE_TMP_ROOT/t4-data'"
} >>"$T4_MARKER"
chmod 0644 "$T4_MARKER"

T4_DRIVER="$SMOKE_TMP_ROOT/t4-driver.sh"
: >"$T4_DRIVER"
# shellcheck disable=SC2129  # grouped block; per-line keeps footgun #11 off the table
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"'
  printf '%s\n' 'MARKER_PATH="$2"'
  printf '%s\n' 'WARN_LOG="$3"'
  printf '%s\n' 'SIM_MODE="$4"'
  printf '%s\n' ': >"$WARN_LOG"'
  printf '%s\n' 'bridge_warn() { printf "%s\n" "$*" >>"$WARN_LOG"; }'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/lib/bridge-marker-bootstrap.sh"'
  printf '%s\n' 'CURRENT_UID="$(id -u)"'
  printf '%s\n' 'bridge_marker_stat_uid() { printf "%s" "$CURRENT_UID"; }'
  printf '%s\n' 'bridge_marker_stat_mode() { printf "%s" "$SIM_MODE"; }'
  printf '%s\n' 'bridge_isolation_v2_marker_validate "$MARKER_PATH"'
  printf '%s\n' 'echo "RC=$?" >>"$WARN_LOG"'
} >>"$T4_DRIVER"
chmod +x "$T4_DRIVER"

T4_WARN_LOG="$SMOKE_TMP_ROOT/t4-warn.log"
"$BRIDGE_BASH" "$T4_DRIVER" "$REPO_ROOT" "$T4_MARKER" "$T4_WARN_LOG" "644" \
  2>"$SMOKE_TMP_ROOT/t4-err" || true
grep -q '^RC=0$' "$T4_WARN_LOG" \
  || smoke_fail "T4 expected RC=0 (validator accepts 0644). log: $(tr '\n' '|' <"$T4_WARN_LOG") err: $(cat "$SMOKE_TMP_ROOT/t4-err")"
if grep -q 'layout-marker.sh ignored:' "$T4_WARN_LOG"; then
  smoke_fail "T4 expected NO rejection warn for mode 0644. log: $(tr '\n' '|' <"$T4_WARN_LOG")"
fi
smoke_log "T4 PASS: marker validator ACCEPTS mode 0644 (no group/world write bit)"

# ---------- T5 — validator REJECTS mode 0664 (group write bit set) ----------
T5_WARN_LOG="$SMOKE_TMP_ROOT/t5-warn.log"
"$BRIDGE_BASH" "$T4_DRIVER" "$REPO_ROOT" "$T4_MARKER" "$T5_WARN_LOG" "664" \
  2>"$SMOKE_TMP_ROOT/t5-err" || true
grep -q '^RC=1$' "$T5_WARN_LOG" \
  || smoke_fail "T5 expected RC=1 (validator rejects 0664). log: $(tr '\n' '|' <"$T5_WARN_LOG") err: $(cat "$SMOKE_TMP_ROOT/t5-err")"
grep -q 'mode 664 has group or world write bit' "$T5_WARN_LOG" \
  || smoke_fail "T5 expected explicit group-write rejection warn. log: $(tr '\n' '|' <"$T5_WARN_LOG")"
smoke_log "T5 PASS: marker validator REJECTS mode 0664 (security gate intact)"

# ---------- T6 — regression contract: source asserts 0644 at every writer ----------
#
# Static-source assertion. Each writer's chmod line must read `0644`,
# never `0640`. This is the boomerang that makes a future revert to
# 0640 immediately fail the smoke instead of silently re-introducing
# the install-path bug. Scope each grep to the literal line the writer
# uses so an adjacent unrelated chmod (other modes) is not confused
# with the writer's marker chmod.
T6_FAIL=0

# Writer #1: bridge_isolation_v2_migrate_marker_write
# Two chmod sites — one on $tmp before mv, one on $marker_path after the
# sudo-chown. Both must be 0644.
T6_SOURCE_MIGRATE="$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh"
if grep -q 'chmod 0640 "$tmp" || { rm -f "$tmp"; bridge_die "marker chmod failed"; }' "$T6_SOURCE_MIGRATE"; then
  smoke_log "T6 FAIL: bridge_isolation_v2_migrate_marker_write still has 'chmod 0640 \"\$tmp\"' (regression)"
  T6_FAIL=1
fi
if grep -q '_bridge_isolation_v2_run_root_or_sudo chmod 0640 "$marker_path"' "$T6_SOURCE_MIGRATE"; then
  smoke_log "T6 FAIL: bridge_isolation_v2_migrate_marker_write still has 'chmod 0640 \"\$marker_path\"' via sudo (regression)"
  T6_FAIL=1
fi
# Writer #2: bridge_isolation_v2_migrate_marker_write_minimal
if grep -q 'chmod 0640 "$tmp" || { rm -f "$tmp"; bridge_warn "marker_write_minimal: chmod failed"; return 1; }' "$T6_SOURCE_MIGRATE"; then
  smoke_log "T6 FAIL: bridge_isolation_v2_migrate_marker_write_minimal still has 'chmod 0640 \"\$tmp\"' (regression)"
  T6_FAIL=1
fi

# Writer #3: bridge_layout_write_v2_marker (lib/bridge-layout-resolver.sh)
T6_SOURCE_RESOLVER="$REPO_ROOT/lib/bridge-layout-resolver.sh"
# Inside bridge_layout_write_v2_marker the only `chmod 0NNN "$tmp"` line
# is the marker mode; grep the literal expected post-fix line and the
# anti-pattern.
if grep -q '^  chmod 0640 "$tmp"$' "$T6_SOURCE_RESOLVER"; then
  smoke_log "T6 FAIL: bridge_layout_write_v2_marker still has 'chmod 0640 \"\$tmp\"' (regression)"
  T6_FAIL=1
fi

# Positive assertion: every writer must contain the 0644 line we
# expect. Catches a future refactor that drops the chmod entirely.
grep -q 'chmod 0644 "$tmp" || { rm -f "$tmp"; bridge_die "marker chmod failed"; }' "$T6_SOURCE_MIGRATE" \
  || { smoke_log "T6 FAIL: bridge_isolation_v2_migrate_marker_write missing the expected 'chmod 0644 \"\$tmp\"' line"; T6_FAIL=1; }
grep -q '_bridge_isolation_v2_run_root_or_sudo chmod 0644 "$marker_path"' "$T6_SOURCE_MIGRATE" \
  || { smoke_log "T6 FAIL: bridge_isolation_v2_migrate_marker_write missing the expected 'chmod 0644 \"\$marker_path\"' sudo line"; T6_FAIL=1; }
grep -q 'chmod 0644 "$tmp" || { rm -f "$tmp"; bridge_warn "marker_write_minimal: chmod failed"; return 1; }' "$T6_SOURCE_MIGRATE" \
  || { smoke_log "T6 FAIL: bridge_isolation_v2_migrate_marker_write_minimal missing the expected 'chmod 0644 \"\$tmp\"' line"; T6_FAIL=1; }
grep -q '^  chmod 0644 "$tmp"$' "$T6_SOURCE_RESOLVER" \
  || { smoke_log "T6 FAIL: bridge_layout_write_v2_marker missing the expected 'chmod 0644 \"\$tmp\"' line"; T6_FAIL=1; }

if (( T6_FAIL != 0 )); then
  smoke_fail "T6 regression-contract assertions failed (see T6 FAIL lines above)"
fi
smoke_log "T6 PASS: all three production writers source-assert mode 0644 (regression contract intact)"

# ---------- T7 — parent marker dir is mode 0711 at every writer site ----------
#
# r1 codex review caught the parent-dir traversal gap: the marker file
# can be mode 0644, but if its parent dir is 0750 / 0710 (no others --x)
# then POSIX traversal from a non-`ab-shared` UID fails BEFORE the file
# mode matters. The r2 fix promotes the parent dir to 0711 (owner rwx,
# group --x, others --x) so isolated UIDs can `open()` the marker by
# full path even without ab-shared group membership.
#
# This test reads the parent dir of each writer's marker file (produced
# by T1/T2/T3 above) and asserts the dir mode contains the `others +x`
# bit. The drivers run as the test user under the temp root, so the
# matrix's `chgrp ab-controller` step is a best-effort no-op; the
# direct `chmod 0711` survives.
T7_FAIL=0
for _idx in 1 2 3; do
  _home_var="T${_idx}_HOME"
  _marker_var="T${_idx}_MARKER"
  _dir="$(dirname "${!_marker_var}")"
  _mode="$(file_mode_octal "$_dir")"
  case "$_mode" in
    711|0711) smoke_log "T7 PASS[T${_idx}]: parent dir $_dir → mode $_mode" ;;
    751|0751|755|0755)
      # Acceptable variants (others --x present, group rights vary).
      smoke_log "T7 PASS[T${_idx}]: parent dir $_dir → mode $_mode (others --x present)"
      ;;
    *)
      smoke_log "T7 FAIL[T${_idx}]: parent dir $_dir mode $_mode lacks others --x — non-ab-shared UID cannot traverse"
      T7_FAIL=1
      ;;
  esac
done

# Static-source assertion: every writer site sets parent dir to 0711.
# Boomerang: reverting any writer to `install -d -m 0750` or `chmod 0750
# "$marker_dir"` immediately fails this test. Scope each grep to the
# literal line so an unrelated 0750 in the file is not confused.
T7_SOURCE_MIGRATE="$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh"
T7_SOURCE_RESOLVER="$REPO_ROOT/lib/bridge-layout-resolver.sh"
T7_SOURCE_MATRIX="$REPO_ROOT/lib/bridge-isolation-v2.sh"

# marker_write + marker_write_minimal each have one `install -d -m 0711`
# line for the marker parent. There are two writers, so we expect two
# occurrences total of the literal install -d line, and at least two
# `chmod 0711 "$(dirname "$marker_path")"` follow-up calls.
_install_count=$(grep -c 'install -d -m 0711 "\$(dirname "\$marker_path")"' "$T7_SOURCE_MIGRATE" || true)
if (( _install_count < 2 )); then
  smoke_log "T7 FAIL: bridge-isolation-v2-migrate.sh has $_install_count 'install -d -m 0711' marker-parent sites, expected >= 2 (marker_write + marker_write_minimal)"
  T7_FAIL=1
fi
# Anti-pattern: 0750 must NOT appear on the marker-parent install line.
if grep -q 'install -d -m 0750 "\$(dirname "\$marker_path")"' "$T7_SOURCE_MIGRATE"; then
  smoke_log "T7 FAIL: bridge-isolation-v2-migrate.sh still has 'install -d -m 0750' on a marker-parent site (regression)"
  T7_FAIL=1
fi

# Writer #3 fresh-init: `chmod 0711 "$marker_dir"` (NOT 0750).
if grep -q '^  chmod 0750 "$marker_dir"' "$T7_SOURCE_RESOLVER"; then
  smoke_log "T7 FAIL: bridge-layout-resolver.sh still chmods marker_dir to 0750 (regression)"
  T7_FAIL=1
fi
grep -q '^  chmod 0711 "$marker_dir"' "$T7_SOURCE_RESOLVER" \
  || { smoke_log "T7 FAIL: bridge-layout-resolver.sh missing expected 'chmod 0711 \"\$marker_dir\"' line"; T7_FAIL=1; }

# Matrix rows: state-root + state-agents-root must be 0711 (not 0710).
# Grep the literal mode token in the matrix-row printf line.
if grep -q "^    printf 'state-root|%s|dir_only_traverse|controller|%s|0710" "$T7_SOURCE_MATRIX"; then
  smoke_log "T7 FAIL: bridge-isolation-v2.sh state-root matrix row still 0710 (regression)"
  T7_FAIL=1
fi
if grep -q "^    printf 'state-agents-root|%s|dir_only_traverse|controller|%s|0710" "$T7_SOURCE_MATRIX"; then
  smoke_log "T7 FAIL: bridge-isolation-v2.sh state-agents-root matrix row still 0710 (regression)"
  T7_FAIL=1
fi
grep -q "^    printf 'state-root|%s|dir_only_traverse|controller|%s|0711" "$T7_SOURCE_MATRIX" \
  || { smoke_log "T7 FAIL: bridge-isolation-v2.sh state-root matrix row missing 0711"; T7_FAIL=1; }
grep -q "^    printf 'state-agents-root|%s|dir_only_traverse|controller|%s|0711" "$T7_SOURCE_MATRIX" \
  || { smoke_log "T7 FAIL: bridge-isolation-v2.sh state-agents-root matrix row missing 0711"; T7_FAIL=1; }

# Live chmod call in normalize_layout: state/ + state/agents/ must be 0711.
if grep -q '_bridge_isolation_v2_run_root_or_sudo chmod 0710 "\$data_root/state"' "$T7_SOURCE_MIGRATE"; then
  smoke_log "T7 FAIL: bridge-isolation-v2-migrate.sh normalize_layout still chmods state/ to 0710 (regression)"
  T7_FAIL=1
fi
grep -q '_bridge_isolation_v2_run_root_or_sudo chmod 0711 "\$data_root/state"' "$T7_SOURCE_MIGRATE" \
  || { smoke_log "T7 FAIL: bridge-isolation-v2-migrate.sh normalize_layout missing 'chmod 0711 \"\$data_root/state\"' line"; T7_FAIL=1; }

if (( T7_FAIL != 0 )); then
  smoke_fail "T7 parent-dir traversal contract failed (see T7 FAIL lines above)"
fi
smoke_log "T7 PASS: marker parent dir mode 0711 at every writer site (runtime + source + matrix)"

# ---------- T8 — cross-UID actual `cat` (Linux-only) ----------
#
# This is the test r1's smoke missed: spawn a different UID (not the
# test-user, not in ab-shared) and `cat` the marker. Asserts the
# parent-chain traversal + file-mode grant compose correctly end-to-end.
#
# Requires: Linux + nobody UID exists + we have sudo to su to it.
# macOS dev hosts lack the ab-shared layout and the `nobody` semantics
# differ; we SKIP with a clear breadcrumb that the assertion was
# verified on the patch operator's Linux host.
if ! smoke_is_linux; then
  smoke_skip "T8" "cross-UID cat is Linux-only; verified on patch host (macOS skip)"
elif ! command -v sudo >/dev/null 2>&1; then
  smoke_skip "T8" "sudo not available — cannot spawn cross-UID cat"
else
  # Pick a non-controller UID that exists and is NOT in ab-shared.
  # `nobody` is the canonical non-privileged UID on every Linux distro.
  T8_TEST_USER="${BRIDGE_TEST_NON_SHARED_USER:-nobody}"
  if ! id "$T8_TEST_USER" >/dev/null 2>&1; then
    smoke_skip "T8" "test user '$T8_TEST_USER' does not exist on this host"
  else
    # Probe sudo: must be passwordless to this user, or we can't run.
    if ! sudo -n -u "$T8_TEST_USER" true >/dev/null 2>&1; then
      smoke_skip "T8" "passwordless sudo to '$T8_TEST_USER' unavailable (CI gate)"
    else
      # Pre-flight: tempdir + its parents (/tmp/agent-bridge-...) must
      # already be world-traversable. mktemp -d gives 0700 by default;
      # widen to 0711 along the chain so the test isolates the marker
      # parent dir behavior, not the tempdir mode.
      _t8_chain="$SMOKE_TMP_ROOT"
      while [[ "$_t8_chain" != "/" && "$_t8_chain" != "" ]]; do
        chmod o+x "$_t8_chain" 2>/dev/null || true
        _t8_chain="$(dirname "$_t8_chain")"
      done

      T8_FAIL=0
      for _idx in 1 2 3; do
        _marker_var="T${_idx}_MARKER"
        _marker="${!_marker_var}"
        if [[ ! -f "$_marker" ]]; then
          smoke_log "T8 FAIL[T${_idx}]: marker missing at $_marker (T${_idx} prerequisite)"
          T8_FAIL=1
          continue
        fi
        _out="$(sudo -n -u "$T8_TEST_USER" cat "$_marker" 2>&1)" || {
          smoke_log "T8 FAIL[T${_idx}]: cross-UID cat ($T8_TEST_USER) failed for $_marker: $_out"
          T8_FAIL=1
          continue
        }
        if ! printf '%s' "$_out" | grep -q '^BRIDGE_LAYOUT=v2$'; then
          smoke_log "T8 FAIL[T${_idx}]: cross-UID cat got unexpected content for $_marker: $_out"
          T8_FAIL=1
          continue
        fi
        smoke_log "T8 PASS[T${_idx}]: cross-UID ($T8_TEST_USER) cat $_marker OK (BRIDGE_LAYOUT=v2)"
      done
      if (( T8_FAIL != 0 )); then
        smoke_fail "T8 cross-UID traversal failed (see T8 FAIL lines above)"
      fi
      smoke_log "T8 PASS: cross-UID ($T8_TEST_USER, not in ab-shared) can cat marker at every writer site"
    fi
  fi
fi

smoke_log "all tests PASS (#1161 marker writers chmod 0644 + parent dir 0711 — readable by isolated UIDs)"
