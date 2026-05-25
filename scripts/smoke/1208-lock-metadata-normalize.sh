#!/usr/bin/env bash
# scripts/smoke/1208-lock-metadata-normalize.sh — unit smoke for
# `lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py`'s lock
# metadata normalization (issue #1208).
#
# Asserts:
#   (A) Unit — when BRIDGE_PLUGIN_LOCK_GROUP=<current-user-primary-group>
#               is set, the helper creates the sidecar
#               `known_marketplaces.json.lock` with mode 0660 and group
#               set to the requested group. A second Python process can
#               then `open(O_RDWR)` + `fcntl.flock(LOCK_EX)`.
#   (B) Regression — pre-create the lock as mode 0600, run the helper,
#               assert the mode is normalized to 0660 and group is set.
#   (C) Absent env var — the helper still works (idempotent fallback to
#               default 0600 lock; we don't enforce normalization without
#               an explicit group request).
#
# Runs as the current user (mode-based test). The cross-UID case (real
# iso UID acquiring the flock as a different process) is exercised by
# integration tests on Linux hosts only; this smoke covers the metadata
# contract that the cross-UID case depends on.
#
# Footgun #11: pipe/argv stdin only.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1208-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

HELPER="$REPO_ROOT/lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py"
if [[ ! -f "$HELPER" ]]; then
  printf '[FAIL] helper not found at %s\n' "$HELPER" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '[FAIL] python3 not on PATH\n' >&2
  exit 1
fi

# Resolve current user's primary group name (portable: id -gn on Linux
# + macOS).
PRIMARY_GROUP="$(id -gn 2>/dev/null || true)"
if [[ -z "$PRIMARY_GROUP" ]]; then
  printf '[FAIL] could not resolve current user primary group\n' >&2
  exit 1
fi

# Portable stat-mode helper (Linux GNU stat: -c %a; BSD/macOS stat: -f %A).
_stat_mode() {
  local p="$1"
  if stat -c '%a' "$p" 2>/dev/null; then
    return 0
  fi
  if stat -f '%A' "$p" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Portable stat-group helper (Linux: -c %G; BSD/macOS: -f %Sg).
_stat_group() {
  local p="$1"
  if stat -c '%G' "$p" 2>/dev/null; then
    return 0
  fi
  if stat -f '%Sg' "$p" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Test A — helper creates lock with mode 0660 + correct group when
# BRIDGE_PLUGIN_LOCK_GROUP is set; a peer Python process can flock.
# ---------------------------------------------------------------------------
PLUGINS_DIR_A="$SMOKE_DIR/scenario-a"
mkdir -p "$PLUGINS_DIR_A"
OUT_A="$PLUGINS_DIR_A/known_marketplaces.json" # noqa: iso-helper-boundary
LOCK_A="$PLUGINS_DIR_A/known_marketplaces.json.lock" # noqa: iso-helper-boundary

rc=0
BRIDGE_PLUGIN_LOCK_GROUP="$PRIMARY_GROUP" python3 "$HELPER" \
  "-" "$OUT_A" "test-marketplace" "/tmp/fake/root" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -ne 0 ]]; then
  _fail "A: helper run rc=0" "got rc=$rc"
elif [[ ! -f "$LOCK_A" ]]; then
  _fail "A: lock file created" "$LOCK_A missing"
else
  mode="$(_stat_mode "$LOCK_A")"
  group="$(_stat_group "$LOCK_A")"
  if [[ "$mode" == "660" ]]; then
    _pass "A: lock mode 0660 (got $mode)"
  else
    _fail "A: lock mode 0660" "got $mode"
  fi
  if [[ "$group" == "$PRIMARY_GROUP" ]]; then
    _pass "A: lock group $PRIMARY_GROUP (got $group)"
  else
    _fail "A: lock group $PRIMARY_GROUP" "got $group"
  fi
fi

# Verify a peer Python process can open + flock the same lock file.
# Use argv-only input to a single python -c invocation.
PEER_PY='
import fcntl, os, sys
lp = sys.argv[1]
fd = os.open(lp, os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
print("flock-ok")
'
rc=0
out="$(python3 -c "$PEER_PY" "$LOCK_A" 2>&1)" || rc=$?
if [[ "$rc" -eq 0 && "$out" == "flock-ok" ]]; then
  _pass "A: peer python can open + flock the normalized lock"
else
  _fail "A: peer python can open + flock the normalized lock" "rc=$rc out=$out"
fi

# ---------------------------------------------------------------------------
# Test B — pre-existing bad lock (mode 0600) is normalized to 0660 + group
# on next helper run.
# ---------------------------------------------------------------------------
PLUGINS_DIR_B="$SMOKE_DIR/scenario-b"
mkdir -p "$PLUGINS_DIR_B"
OUT_B="$PLUGINS_DIR_B/known_marketplaces.json" # noqa: iso-helper-boundary
LOCK_B="$PLUGINS_DIR_B/known_marketplaces.json.lock" # noqa: iso-helper-boundary

# Pre-create the lock as 0600 (the beta24 bad shape).
: > "$LOCK_B"
chmod 0600 "$LOCK_B"

# Confirm pre-state.
pre_mode="$(_stat_mode "$LOCK_B")"
if [[ "$pre_mode" != "600" ]]; then
  _fail "B: pre-state lock 0600" "got $pre_mode (test setup error)"
fi

rc=0
BRIDGE_PLUGIN_LOCK_GROUP="$PRIMARY_GROUP" python3 "$HELPER" \
  "-" "$OUT_B" "another-marketplace" "/tmp/fake/other-root" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -ne 0 ]]; then
  _fail "B: helper run rc=0 with pre-existing lock" "got rc=$rc"
else
  post_mode="$(_stat_mode "$LOCK_B")"
  post_group="$(_stat_group "$LOCK_B")"
  if [[ "$post_mode" == "660" ]]; then
    _pass "B: pre-existing 0600 lock normalized to 0660 (got $post_mode)"
  else
    _fail "B: pre-existing 0600 lock normalized to 0660" "got $post_mode"
  fi
  if [[ "$post_group" == "$PRIMARY_GROUP" ]]; then
    _pass "B: pre-existing lock group set to $PRIMARY_GROUP (got $post_group)"
  else
    _fail "B: pre-existing lock group set to $PRIMARY_GROUP" "got $post_group"
  fi
fi

# ---------------------------------------------------------------------------
# Test C — helper works without BRIDGE_PLUGIN_LOCK_GROUP (controller's
# own ~/.claude/plugins/ case). Lock created with default permissions;
# helper does NOT fail.
# ---------------------------------------------------------------------------
PLUGINS_DIR_C="$SMOKE_DIR/scenario-c"
mkdir -p "$PLUGINS_DIR_C"
OUT_C="$PLUGINS_DIR_C/known_marketplaces.json" # noqa: iso-helper-boundary
LOCK_C="$PLUGINS_DIR_C/known_marketplaces.json.lock" # noqa: iso-helper-boundary

rc=0
unset BRIDGE_PLUGIN_LOCK_GROUP
python3 "$HELPER" \
  "-" "$OUT_C" "ctrl-marketplace" "/tmp/fake/ctrl-root" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 && -f "$LOCK_C" ]]; then
  _pass "C: helper works without BRIDGE_PLUGIN_LOCK_GROUP (no-op normalization)"
else
  _fail "C: helper works without BRIDGE_PLUGIN_LOCK_GROUP" "rc=$rc lock=$LOCK_C"
fi

# ---------------------------------------------------------------------------
# Test D — passing a non-existent group → helper warns but does NOT fail
# (degraded mode). Lock is created with default 0600 (no normalization).
# ---------------------------------------------------------------------------
PLUGINS_DIR_D="$SMOKE_DIR/scenario-d"
mkdir -p "$PLUGINS_DIR_D"
OUT_D="$PLUGINS_DIR_D/known_marketplaces.json" # noqa: iso-helper-boundary

rc=0
BRIDGE_PLUGIN_LOCK_GROUP="this-group-does-not-exist-1208" python3 "$HELPER" \
  "-" "$OUT_D" "yet-another" "/tmp/fake/yet-another" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  _pass "D: helper degrades gracefully when BRIDGE_PLUGIN_LOCK_GROUP names a non-existent group"
else
  _fail "D: helper degrades gracefully when BRIDGE_PLUGIN_LOCK_GROUP names a non-existent group" \
    "got rc=$rc (expected 0)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n[summary] %d/%d tests passed\n' $((TOTAL - FAILS)) "$TOTAL"
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
