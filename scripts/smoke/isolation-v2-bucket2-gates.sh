#!/usr/bin/env bash
# S5 Track A1 regression smoke — Bucket 2 platform-discriminator gates.
#
# Verifies the Bucket 2 enforcement gate from S3 (`bridge_isolation_v2_enforce`)
# is wired correctly into the additional v2-cluster sites converted by
# S5 Track A1:
#
#   - bridge_isolation_v2_chgrp_setgid_recursive (audit C08, v2.sh)
#   - bridge_isolation_v2_migrate_normalize_layout (audit C13, v2-migrate.sh)
#
# Coverage (cross-platform via BRIDGE_HOST_PLATFORM_OVERRIDE):
#   G1 — chgrp_setgid_recursive with host=Darwin (default policy) →
#         no-op return 0 without chgrp/chmod on the target tree.
#   G2 — chgrp_setgid_recursive with host=Linux + valid dir →
#         passes the gate; chgrp/chmod execute (or fail loudly on
#         missing group, which IS the desired Linux semantics).
#   G3 — chgrp_setgid_recursive with host=Darwin +
#         BRIDGE_ISOLATION_REQUIRED=yes → engages enforcement (chgrp/
#         chmod run; will fail on missing group, but the gate did NOT
#         short-circuit).
#
# Footgun #11: no heredoc-stdin to subprocess (printf-to-file drivers).

set -uo pipefail

SMOKE_NAME="isolation-v2-bucket2-gates"
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

run_gate_probe() {
  # Args: $1 = env_required, $2 = host_override, $3 = snippet, $4 = out_file
  #       $5 = primitives_ready_override ("yes"|"no" or empty)
  local env_required="$1"
  local host_override="$2"
  local snippet="$3"
  local out_file="$4"
  local primitives_ready="${5:-}"
  local driver="$SMOKE_TMP_ROOT/driver-$$.sh"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'cd %q\n' "$REPO_ROOT"
    printf 'export BRIDGE_HOME=%q\n' "$SMOKE_TMP_ROOT/bh"
    printf 'export BRIDGE_STATE_DIR=%q\n' "$SMOKE_TMP_ROOT/bh/state"
    printf 'export BRIDGE_LAYOUT=v2\n'
    printf 'export BRIDGE_DATA_ROOT=%q\n' "$SMOKE_TMP_ROOT/bh/data"
    printf 'export BRIDGE_HOST_PLATFORM_OVERRIDE=%q\n' "$host_override"
    if [[ -n "$env_required" ]]; then
      printf 'export BRIDGE_ISOLATION_REQUIRED=%q\n' "$env_required"
    fi
    printf '%s\n' 'mkdir -p "$BRIDGE_HOME/state" "$BRIDGE_DATA_ROOT"'
    printf '%s\n' 'source "$0_REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1'
    # PR #919 readiness gate: bypass the getent probe so the smoke is
    # deterministic regardless of whether the test host has an
    # ab-shared group. "yes" → primitives ready, gate may engage;
    # "no" → primitives missing, gate skips on auto policy.
    if [[ -n "$primitives_ready" ]]; then
      printf 'export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=%q\n' "$primitives_ready"
    fi
    printf '%s\n' "$snippet"
  } | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$driver"
  chmod +x "$driver"

  "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1
  local rc=$?
  rm -f "$driver"
  return $rc
}

# G1 — chgrp_setgid_recursive on host=Darwin should silent no-op
smoke_log "G1: chgrp_setgid_recursive Darwin no-op (default policy)"
G1_OUT="$SMOKE_TMP_ROOT/g1.out"
G1_TREE="$SMOKE_TMP_ROOT/g1-tree"
mkdir -p "$G1_TREE/sub"
touch "$G1_TREE/file" "$G1_TREE/sub/file2"
run_gate_probe "" "Darwin" \
  "bridge_isolation_v2_chgrp_setgid_recursive ab-shared 2750 0640 '$G1_TREE'; echo \"RC=\$?\"" \
  "$G1_OUT" || true

if ! grep -q '^RC=0$' "$G1_OUT"; then
  cat "$G1_OUT"; smoke_fail "G1: expected RC=0 (silent no-op on Darwin)"
fi
if grep -qE 'chmod:|chgrp:|operation not permitted' "$G1_OUT"; then
  cat "$G1_OUT"; smoke_fail "G1: gate did not short-circuit (chgrp/chmod attempted on Darwin)"
fi
smoke_log "G1 PASS"

# G2 — chgrp_setgid_recursive on host=Linux engages.
# Codex r1 catch (PR #910): a short-circuited gate also prints RC=0,
# so just asserting `^RC=` exists doesn't prove enforcement engaged.
# Use a deliberately-missing group name and assert RC != 0 — that
# proves the gate let the chgrp through (which then fails because the
# group doesn't exist on the test host).
smoke_log "G2: chgrp_setgid_recursive Linux engages (asserts gate let chgrp fall through to fail-loud)"
G2_OUT="$SMOKE_TMP_ROOT/g2.out"
G2_TREE="$SMOKE_TMP_ROOT/g2-tree"
mkdir -p "$G2_TREE"
touch "$G2_TREE/file"
run_gate_probe "" "Linux" \
  "bridge_isolation_v2_chgrp_setgid_recursive definitely_missing_group_910 2750 0640 '$G2_TREE'; echo \"RC=\$?\"" \
  "$G2_OUT" "yes" || true

if grep -q '^RC=0$' "$G2_OUT"; then
  cat "$G2_OUT"; smoke_fail "G2: gate short-circuited (RC=0); enforcement did NOT engage on host=Linux"
fi
if ! grep -qE '^RC=[1-9]' "$G2_OUT"; then
  cat "$G2_OUT"; smoke_fail "G2: helper did not return non-zero RC after engaged chgrp on missing group"
fi
smoke_log "G2 PASS (gate engaged on host=Linux; chgrp failed on missing group as expected)"

# G3 — explicit BRIDGE_ISOLATION_REQUIRED=yes on host=Darwin engages.
# Same assertion shape as G2 — missing group + RC != 0 proves the gate
# let enforcement through.
smoke_log "G3: chgrp_setgid_recursive Darwin + explicit opt-in engages (asserts gate let chgrp fall through)"
G3_OUT="$SMOKE_TMP_ROOT/g3.out"
G3_TREE="$SMOKE_TMP_ROOT/g3-tree"
mkdir -p "$G3_TREE"
touch "$G3_TREE/file"
run_gate_probe "yes" "Darwin" \
  "bridge_isolation_v2_chgrp_setgid_recursive definitely_missing_group_910 2750 0640 '$G3_TREE'; echo \"RC=\$?\"" \
  "$G3_OUT" "no" || true

if grep -q '^RC=0$' "$G3_OUT"; then
  cat "$G3_OUT"; smoke_fail "G3: gate short-circuited (RC=0); BRIDGE_ISOLATION_REQUIRED=yes did NOT override Darwin default"
fi
if ! grep -qE '^RC=[1-9]' "$G3_OUT"; then
  cat "$G3_OUT"; smoke_fail "G3: helper did not return non-zero RC after engaged chgrp on missing group"
fi
smoke_log "G3 PASS (explicit BRIDGE_ISOLATION_REQUIRED=yes overrode the Darwin default skip)"

# --- C13 direct coverage ----------------------------------------------------
# Codex r1 catch (PR #910): C13 is a changed site but the smoke never
# called bridge_isolation_v2_migrate_normalize_layout. Add a small
# fixture that exercises it directly with deliberately-missing groups
# so we can assert the gate engaged vs. short-circuited (same shape
# as G1/G2/G3).

stage_normalize_fixture() {
  # Creates a minimal data_root with the dirs `migrate_normalize_layout`
  # touches: shared/ + state/runtime/. Returns the data_root path.
  local fixture_root="$1"
  rm -rf "$fixture_root"
  mkdir -p "$fixture_root/shared" "$fixture_root/state/runtime"
  touch "$fixture_root/shared/file" "$fixture_root/state/runtime/file"
  printf '%s\n' "$fixture_root"
}

run_normalize_probe() {
  # Args: $1 = env_required, $2 = host_override, $3 = data_root, $4 = out_file
  #       $5 = primitives_ready_override ("yes"|"no" or empty)
  local env_required="$1"
  local host_override="$2"
  local data_root="$3"
  local out_file="$4"
  local primitives_ready="${5:-}"
  local driver="$SMOKE_TMP_ROOT/normalize-driver-$$.sh"
  local snapshot="$SMOKE_TMP_ROOT/normalize-snapshot.json"
  printf '{}\n' >"$snapshot"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'cd %q\n' "$REPO_ROOT"
    printf 'export BRIDGE_HOME=%q\n' "$SMOKE_TMP_ROOT/normalize-bh"
    printf 'export BRIDGE_STATE_DIR=%q\n' "$SMOKE_TMP_ROOT/normalize-bh/state"
    printf 'export BRIDGE_LAYOUT=v2\n'
    printf 'export BRIDGE_DATA_ROOT=%q\n' "$data_root"
    printf 'export BRIDGE_HOST_PLATFORM_OVERRIDE=%q\n' "$host_override"
    printf 'export BRIDGE_SHARED_GROUP=definitely_missing_shared_grp_910\n'
    printf 'export BRIDGE_CONTROLLER_GROUP=definitely_missing_ctrl_grp_910\n'
    if [[ -n "$env_required" ]]; then
      printf 'export BRIDGE_ISOLATION_REQUIRED=%q\n' "$env_required"
    fi
    if [[ -n "$primitives_ready" ]]; then
      printf 'export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=%q\n' "$primitives_ready"
    fi
    printf '%s\n' 'mkdir -p "$BRIDGE_HOME/state"'
    printf '%s\n' 'source "$0_REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1'
    # v2-migrate.sh is loaded on-demand by bridge-upgrade.sh; for this
    # smoke we source it explicitly.
    printf '%s\n' 'source "$0_REPO_ROOT/lib/bridge-isolation-v2-migrate.sh" >/dev/null 2>&1'
    printf 'bridge_isolation_v2_migrate_normalize_layout %q %q; echo "RC=$?"\n' \
      "$snapshot" "$data_root"
  } | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$driver"
  chmod +x "$driver"

  "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1
  rm -f "$driver"
}

# G4 — migrate_normalize_layout on host=Darwin (default) → silent no-op
smoke_log "G4: migrate_normalize_layout Darwin no-op (default policy)"
G4_DATA="$(stage_normalize_fixture "$SMOKE_TMP_ROOT/g4-data")"
G4_OUT="$SMOKE_TMP_ROOT/g4.out"
run_normalize_probe "" "Darwin" "$G4_DATA" "$G4_OUT"

if ! grep -q '^RC=0$' "$G4_OUT"; then
  cat "$G4_OUT"; smoke_fail "G4: expected RC=0 (silent no-op on Darwin)"
fi
if grep -qE 'normalize_layout.*failed' "$G4_OUT"; then
  cat "$G4_OUT"; smoke_fail "G4: gate did not short-circuit (normalize_layout failure emitted on Darwin)"
fi
smoke_log "G4 PASS"

# G5 — migrate_normalize_layout on host=Linux (default) → engages, fails on missing group
smoke_log "G5: migrate_normalize_layout Linux engages (asserts non-zero RC on missing groups)"
G5_DATA="$(stage_normalize_fixture "$SMOKE_TMP_ROOT/g5-data")"
G5_OUT="$SMOKE_TMP_ROOT/g5.out"
run_normalize_probe "" "Linux" "$G5_DATA" "$G5_OUT" "yes"

if grep -q '^RC=0$' "$G5_OUT"; then
  cat "$G5_OUT"; smoke_fail "G5: gate short-circuited on host=Linux (RC=0); enforcement did NOT engage"
fi
smoke_log "G5 PASS (gate engaged on host=Linux; normalize_layout failed on missing groups as expected)"

# G6 — migrate_normalize_layout on host=Darwin + opt-in → engages
smoke_log "G6: migrate_normalize_layout Darwin + opt-in engages"
G6_DATA="$(stage_normalize_fixture "$SMOKE_TMP_ROOT/g6-data")"
G6_OUT="$SMOKE_TMP_ROOT/g6.out"
run_normalize_probe "yes" "Darwin" "$G6_DATA" "$G6_OUT" "no"

if grep -q '^RC=0$' "$G6_OUT"; then
  cat "$G6_OUT"; smoke_fail "G6: gate short-circuited on Darwin+opt-in (RC=0); enforcement did NOT engage"
fi
smoke_log "G6 PASS (explicit opt-in engaged enforcement on Darwin)"

# --- C-S2 direct coverage (reapply_strip_layout_acls) ---------------------
# Audit C-S2 (S5 Track A2): the setfacl tool-presence check would false-pass
# on Darwin with Homebrew-installed Linux setfacl. The discriminator gate
# pre-empts that. Verifies the new action-record code path.

run_strip_probe() {
  # Args: $1 = env_required, $2 = host_override, $3 = out_file
  #       $4 = primitives_ready_override ("yes"|"no" or empty)
  local env_required="$1"
  local host_override="$2"
  local out_file="$3"
  local primitives_ready="${4:-}"
  local driver="$SMOKE_TMP_ROOT/strip-driver-$$.sh"
  local actions_file="$SMOKE_TMP_ROOT/strip-actions-$$.tsv"
  local errors_file="$SMOKE_TMP_ROOT/strip-errors-$$.tsv"
  local target_dir="$SMOKE_TMP_ROOT/strip-target-$$"
  mkdir -p "$target_dir"
  : >"$actions_file"
  : >"$errors_file"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'cd %q\n' "$REPO_ROOT"
    printf 'export BRIDGE_HOME=%q\n' "$SMOKE_TMP_ROOT/strip-bh-$$"
    printf 'export BRIDGE_STATE_DIR=%q\n' "$SMOKE_TMP_ROOT/strip-bh-$$/state"
    printf 'export BRIDGE_LAYOUT=v2\n'
    printf 'export BRIDGE_DATA_ROOT=%q\n' "$SMOKE_TMP_ROOT/strip-bh-$$/data"
    printf 'export BRIDGE_HOST_PLATFORM_OVERRIDE=%q\n' "$host_override"
    if [[ -n "$env_required" ]]; then
      printf 'export BRIDGE_ISOLATION_REQUIRED=%q\n' "$env_required"
    fi
    if [[ -n "$primitives_ready" ]]; then
      printf 'export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=%q\n' "$primitives_ready"
    fi
    printf '%s\n' 'mkdir -p "$BRIDGE_HOME/state" "$BRIDGE_DATA_ROOT"'
    printf '%s\n' 'source "$0_REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1'
    printf 'bridge_isolation_v2_reapply_strip_layout_acls apply 1 %q %q %q; echo "RC=$?"\n' \
      "$actions_file" "$errors_file" "$target_dir"
    printf 'echo "ACTIONS:"; cat %q\n' "$actions_file"
  } | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$driver"
  chmod +x "$driver"

  "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1
  rm -f "$driver"
}

# G7 — strip_layout_acls Darwin default → skipped:platform-discriminator
smoke_log "G7: strip_layout_acls Darwin default → discriminator skip"
G7_OUT="$SMOKE_TMP_ROOT/g7.out"
run_strip_probe "" "Darwin" "$G7_OUT"

if ! grep -q '^RC=0$' "$G7_OUT"; then
  cat "$G7_OUT"; smoke_fail "G7: expected RC=0 (silent no-op on Darwin)"
fi
if ! grep -q 'skipped:platform-discriminator' "$G7_OUT"; then
  cat "$G7_OUT"; smoke_fail "G7: expected the new platform-discriminator action record on Darwin"
fi
smoke_log "G7 PASS"

# G8 — strip_layout_acls Linux default → engages, hits the
# tool-presence check or proceeds to setfacl. RC=0 either way (since
# the function always records and returns 0 on missing tooling or
# completed strip).
smoke_log "G8: strip_layout_acls Linux default → gate engaged (not skipped:platform-discriminator)"
G8_OUT="$SMOKE_TMP_ROOT/g8.out"
run_strip_probe "" "Linux" "$G8_OUT" "yes"

if grep -q 'skipped:platform-discriminator' "$G8_OUT"; then
  cat "$G8_OUT"; smoke_fail "G8: gate short-circuited on host=Linux (should engage)"
fi
smoke_log "G8 PASS (gate engaged on host=Linux)"

# G9 — strip_layout_acls Darwin + opt-in → engages
smoke_log "G9: strip_layout_acls Darwin + opt-in → gate engaged"
G9_OUT="$SMOKE_TMP_ROOT/g9.out"
run_strip_probe "yes" "Darwin" "$G9_OUT" "no"

if grep -q 'skipped:platform-discriminator' "$G9_OUT"; then
  cat "$G9_OUT"; smoke_fail "G9: gate short-circuited on Darwin+opt-in (should engage)"
fi
smoke_log "G9 PASS (explicit opt-in overrode Darwin default)"

# G10 — standalone reapply module source brings in discriminator.
# Codex r1 catch on PR #911: a direct caller sourcing only
# lib/bridge-isolation-v2-reapply.sh (without bridge-lib.sh) hit
# `bridge_isolation_v2_enforce: command not found`. r2 added the
# guarded self-source pattern. This case verifies the regression
# guard for the standalone source path.
smoke_log "G10: standalone reapply module source brings in discriminator"
G10_OUT="$SMOKE_TMP_ROOT/g10.out"
G10_DRIVER="$SMOKE_TMP_ROOT/g10-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf 'cd %q\n' "$REPO_ROOT"
  # Stub bridge_warn / bridge_die as the standalone harness pattern does.
  printf '%s\n' 'bridge_warn() { printf "[stub_warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_die() { printf "[stub_die] %s\n" "$*" >&2; exit 1; }'
  # Source ONLY the reapply module (no bridge-lib.sh).
  printf '%s\n' 'source "$0_REPO_ROOT/lib/bridge-isolation-v2-reapply.sh" 2>&1'
  printf '%s\n' 'if declare -f bridge_isolation_v2_enforce >/dev/null 2>&1; then echo "ENFORCE_DEFINED=yes"; else echo "ENFORCE_DEFINED=no"; fi'
  # Sanity probe: with host=Linux + primitives ready, the gate must
  # engage (not the discriminator-skip path). PR #919 readiness gate:
  # set the cache var to make this deterministic regardless of whether
  # the test host has an ab-shared group.
  printf '%s\n' 'export BRIDGE_HOST_PLATFORM_OVERRIDE=Linux'
  printf '%s\n' 'export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=yes'
  printf '%s\n' 'bridge_isolation_v2_enforce; echo "ENFORCE_RC=$?"'
} | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$G10_DRIVER"
chmod +x "$G10_DRIVER"
"$BRIDGE_BASH" "$G10_DRIVER" >"$G10_OUT" 2>&1 || true
rm -f "$G10_DRIVER"

if ! grep -q '^ENFORCE_DEFINED=yes$' "$G10_OUT"; then
  cat "$G10_OUT"; smoke_fail "G10: standalone reapply source did not bring in bridge_isolation_v2_enforce"
fi
if ! grep -q '^ENFORCE_RC=0$' "$G10_OUT"; then
  cat "$G10_OUT"; smoke_fail "G10: bridge_isolation_v2_enforce did not return 0 with host=Linux override"
fi
smoke_log "G10 PASS"

smoke_log "PASS — Bucket 2 gates wired correctly across 10 cases (C08: G1/G2/G3, C13: G4/G5/G6, C-S2: G7/G8/G9, standalone: G10)"
exit 0
