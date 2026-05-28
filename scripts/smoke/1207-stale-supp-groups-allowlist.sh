#!/usr/bin/env bash
# scripts/smoke/1207-stale-supp-groups-allowlist.sh — unit smoke for the
# #1207 read/probe-only literal-prefix allowlist fallback.
#
# Reproduces the KNOWN_ISSUES §28 / #1207 surface in CI without real
# supp-groups drift: stubs the roster + the iso-side existence probe
# helper so we can control:
#   - whether the controller can canonicalize the roster root
#     (simulated by making the root non-traversable to readlink -f)
#   - whether the iso UID claims to "see" the root (controlled mock)
#
# Asserts:
#   (A) positive  — read/probe op (stat, env-has-any-key) under a raw
#                   roster root passes when controller canonicalize
#                   fails AND iso-side probe reports the root present.
#   (B) negative  — a `..` segment in the request is rejected even when
#                   the fallback is otherwise eligible (rc=40).
#   (C) negative  — fallback when iso-side probe reports the root absent
#                   → rc=40.
#   (D) negative  — write/publish op (atomic-write, publish-root-file)
#                   under the same simulated controller-blind root MUST
#                   still rc=40. This is the key guard against weakening
#                   the symlink-ancestor write-side protection.
#   (E) regression — when controller CAN canonicalize, behavior is
#                    unchanged (canonical compare passes).
#
# Footgun #11: pipe/argv stdin only, no heredoc-stdin, no here-string.
#
# Exits 0 on full pass, non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1207-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

# Provide an iso-v2 env envelope so bridge-lib.sh's layout-resolver
# accepts the BRIDGE_HOME (otherwise on a CI fresh checkout it sees
# `markerless(fresh-install-candidate)` and bridge_dies). Mirrors what
# `smoke_setup_bridge_home` in scripts/smoke/lib.sh exports — we don't
# source lib.sh here because this smoke does its own isolated setup,
# but the resolver contract is the same.
export BRIDGE_HOME="$SMOKE_DIR/.agent-bridge"
export BRIDGE_LAYOUT="v2"
export BRIDGE_DATA_ROOT="$SMOKE_DIR/data"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LAYOUT_MARKER_DIR="$BRIDGE_STATE_DIR"
mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_DATA_ROOT"

# Use a synthetic agent name; stubs below intercept the roster lookups
# so we never need a real provisioned agent.
AGENT="agent_iso_1207"

# Source bridge-lib so bridge_iso_run + bridge_iso_run_path_under_allowlist
# are available.
# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1 || {
  printf '[FAIL] source bridge-lib.sh failed\n' >&2
  exit 1
}

if ! declare -F bridge_iso_run_path_under_allowlist >/dev/null 2>&1; then
  printf '[FAIL] bridge_iso_run_path_under_allowlist not loaded\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
#
# The smoke's strategy is to override the roster helpers + the iso-side
# existence probe helper so we can control what the allowlist gate sees.
#
# WORKDIR is the simulated agent workdir. We populate it with files so
# the request paths under WORKDIR are real and readable, but we toggle
# CANONICALIZE_BLIND on/off to simulate the controller's
# `_bridge_iso_run_canonicalize` returning empty (the stale-supp-groups
# surface). The iso-side probe is also a mock that obeys
# ISO_SIDE_ROOT_PRESENT.

# Real on-disk dir we use as the simulated agent workdir.
WORKDIR="$SMOKE_DIR/agent-workdir"
mkdir -p "$WORKDIR/.teams"
# noqa: iso-helper-boundary — smoke fixture, not production controller-side write
printf 'TEAMS_APP_ID=fake-app-id\n' >"$WORKDIR/.teams/.env" # noqa: iso-helper-boundary

# Stub roster helpers — bridge-agents.sh defines these, but our smoke
# overrides them so the allowlist gate uses our synthetic workdir
# regardless of any real roster. Invoked indirectly via `declare -F` +
# function name from `_bridge_iso_run_collect_canonical_roots` and
# `_bridge_iso_run_collect_raw_roster_roots`.
# shellcheck disable=SC2329
bridge_agent_workdir() { printf '%s' "$WORKDIR"; }
# shellcheck disable=SC2329
bridge_agent_default_home() { printf '%s' "$WORKDIR/home"; }
# shellcheck disable=SC2329
bridge_agent_idle_marker_dir() { printf '%s' "$WORKDIR/idle-markers"; }

# Force isolation_effective true so the iso-side probe code branch
# becomes reachable (and so that the agent-bridge `iso-run` CLI path
# also flips to iso-mode if anyone uses it). The dispatcher already
# falls through to the direct path when not isolated; for #1207 we
# need to exercise the fallback predicate, which is gate-only and
# doesn't actually require a real iso UID — only the existence probe
# response.
# shellcheck disable=SC2329
bridge_agent_linux_user_isolation_effective() { return 0; }
# shellcheck disable=SC2329
bridge_agent_os_user() { printf 'agent-bridge-%s' "$1"; }
# shellcheck disable=SC2329
bridge_agent_linux_user_home() { printf '%s' "$WORKDIR/home"; }

# Stub _bridge_iso_run_canonicalize. Toggle on CANONICALIZE_BLIND=1 to
# simulate the controller stale-supp-groups condition (readlink -f
# returns empty for the WORKDIR root and any descendant).
CANONICALIZE_BLIND=0
# shellcheck disable=SC2329
_bridge_iso_run_canonicalize() {
  local p="$1"
  if [[ "$CANONICALIZE_BLIND" -eq 1 ]]; then
    # Mimic controller's stale-supp-groups: the WORKDIR tree is opaque
    # to readlink -f and Python realpath. Any other path resolves
    # normally (so /etc still canonicalizes, etc.).
    if [[ "$p" == "$WORKDIR" || "$p" == "$WORKDIR"/* ]]; then
      return 1
    fi
  fi
  # Default behavior: real-canonicalize.
  local out=""
  if out="$(readlink -f -- "$p" 2>/dev/null)" && [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

# Stub _bridge_iso_run_canonicalize_destination. When blind, return
# empty for any path under WORKDIR (no "deepest ancestor" can be
# canonicalized either). Otherwise fall back to the real behavior.
# shellcheck disable=SC2329
_bridge_iso_run_canonicalize_destination() {
  local p="$1"
  if [[ "$CANONICALIZE_BLIND" -eq 1 ]]; then
    if [[ "$p" == "$WORKDIR" || "$p" == "$WORKDIR"/* ]]; then
      return 1
    fi
  fi
  # Default: identity for existing paths, parent-walk for non-existent.
  if [[ -e "$p" ]]; then
    _bridge_iso_run_canonicalize "$p"
    return $?
  fi
  local d b
  d="$(dirname -- "$p")"
  b="$(basename -- "$p")"
  if [[ -e "$d" ]]; then
    local canon=""
    canon="$(_bridge_iso_run_canonicalize "$d")" || return 1
    printf '%s/%s' "${canon%/}" "$b"
    return 0
  fi
  return 1
}

# Stub bridge_isolation_run_as_agent_user_via_bash so the iso-side
# probe of `_bridge_iso_run_iso_side_root_exists` is controllable.
# ISO_SIDE_ROOT_PRESENT=1 → root visible from iso UID (rc=0 → predicate d
# satisfied). ISO_SIDE_ROOT_PRESENT=0 → root not visible (rc=3+ band →
# the helper's "iso UID confirms absent" branch fires).
ISO_SIDE_ROOT_PRESENT=1
# shellcheck disable=SC2329
bridge_isolation_run_as_agent_user_via_bash() {
  local agent="$1"
  local script="$2"
  shift 2
  # We don't actually execute as a different UID — we just simulate
  # the rc the iso side would have returned. The helper's probe
  # script is `[[ -d "$1" ]]`, so we return 0 when present, 3 when
  # absent (which after the +2 unshift band would be the iso UID's
  # rc=1, i.e. test failure).
  : "$agent" "$script" "$@"
  if [[ "$ISO_SIDE_ROOT_PRESENT" -eq 1 ]]; then
    return 0
  fi
  # rc=3 lands in the helper's "+2 band" — caller's
  # _bridge_iso_run_iso_side_root_exists converts to its "1" return
  # (iso confirms not -d), and the allowlist treats that as fail closed.
  return 3
}

# ---------------------------------------------------------------------------
# Test A — positive: read/probe op under raw root, controller blind, iso
# UID confirms root present → fallback admits the path.
# ---------------------------------------------------------------------------
CANONICALIZE_BLIND=1
ISO_SIDE_ROOT_PRESENT=1

# noqa: iso-helper-boundary — smoke fixture; production callers go through bridge_iso_run.
rc=0
TEST_PATH_TEAMS_ENV="$WORKDIR/.teams/.env" # noqa: iso-helper-boundary
bridge_iso_run_path_under_allowlist "$AGENT" "$TEST_PATH_TEAMS_ENV" "stat" \
  || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "A: stat under raw workdir admitted via fallback (controller-blind, iso sees root)"
else
  _fail "A: stat under raw workdir admitted via fallback" "got rc=$rc"
fi

rc=0
bridge_iso_run_path_under_allowlist "$AGENT" "$TEST_PATH_TEAMS_ENV" "env-has-any-key" \
  || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "A: env-has-any-key under raw workdir admitted via fallback"
else
  _fail "A: env-has-any-key under raw workdir admitted via fallback" "got rc=$rc"
fi

rc=0
bridge_iso_run_path_under_allowlist "$AGENT" "$TEST_PATH_TEAMS_ENV" "read-env-key" \
  || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "A: read-env-key under raw workdir admitted via fallback"
else
  _fail "A: read-env-key under raw workdir admitted via fallback" "got rc=$rc"
fi

# ---------------------------------------------------------------------------
# Test B — negative: `..` segment in request rejected even if fallback
# would otherwise apply.
# ---------------------------------------------------------------------------
rc=0
bridge_iso_run_path_under_allowlist "$AGENT" "$WORKDIR/../etc/passwd" "stat" \
  || rc=$?
if [[ "$rc" -ne 0 ]]; then
  _pass "B: request with .. segment rejected even under fallback-eligible op"
else
  _fail "B: request with .. segment rejected under fallback" "got rc=$rc (expected non-zero)"
fi

# ---------------------------------------------------------------------------
# Test C — negative: iso-side probe says root absent → fallback fails closed.
# ---------------------------------------------------------------------------
ISO_SIDE_ROOT_PRESENT=0
rc=0
bridge_iso_run_path_under_allowlist "$AGENT" "$TEST_PATH_TEAMS_ENV" "stat" \
  || rc=$?
if [[ "$rc" -ne 0 ]]; then
  _pass "C: read-probe fallback rejected when iso UID does NOT see root"
else
  _fail "C: read-probe fallback rejected when iso UID does NOT see root" \
    "got rc=$rc (expected non-zero)"
fi

# ---------------------------------------------------------------------------
# Test D — KEY GUARD: write/publish ops MUST stay canonical fail-closed
# even when the controller-blind + iso-side-present preconditions are
# satisfied. This is the symlink-ancestor write protection preserved.
# ---------------------------------------------------------------------------
ISO_SIDE_ROOT_PRESENT=1

for op in atomic-write mkdir-p rename publish-root-file publish-root-symlink \
          state-marker-write; do
  rc=0
  bridge_iso_run_path_under_allowlist "$AGENT" "$TEST_PATH_TEAMS_ENV" "$op" \
    || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _pass "D: write/publish op '$op' under blind workdir rejected (canonical fail-closed)"
  else
    _fail "D: write/publish op '$op' under blind workdir rejected" \
      "got rc=$rc (expected non-zero — fallback must NOT apply to writes)"
  fi
done

# ---------------------------------------------------------------------------
# Test E — regression: when controller CAN canonicalize, behavior is
# unchanged (canonical compare admits path).
# ---------------------------------------------------------------------------
CANONICALIZE_BLIND=0
rc=0
bridge_iso_run_path_under_allowlist "$AGENT" "$TEST_PATH_TEAMS_ENV" "stat" \
  || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "E: regression — canonical compare admits path when canonicalize works"
else
  _fail "E: regression — canonical compare admits path when canonicalize works" \
    "got rc=$rc"
fi

# Also: when canonicalize works, write ops still pass under the legitimate
# root (no behavior regression).
rc=0
bridge_iso_run_path_under_allowlist "$AGENT" "$WORKDIR/.teams/new-file.txt" "atomic-write" \
  || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "E: regression — atomic-write under legitimate root admitted (canonical compare)"
else
  _fail "E: regression — atomic-write under legitimate root admitted" "got rc=$rc"
fi

# ---------------------------------------------------------------------------
# Test F — request path is OUTSIDE the raw root + canonicalize blind →
# fallback must NOT admit (predicate (a) lexical-prefix fails).
# ---------------------------------------------------------------------------
CANONICALIZE_BLIND=1
ISO_SIDE_ROOT_PRESENT=1
rc=0
bridge_iso_run_path_under_allowlist "$AGENT" "/etc/passwd" "stat" \
  || rc=$?
if [[ "$rc" -ne 0 ]]; then
  _pass "F: request outside raw roster root rejected even with fallback enabled"
else
  _fail "F: request outside raw roster root rejected" "got rc=$rc (expected non-zero)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n[summary] %d/%d tests passed\n' $((TOTAL - FAILS)) "$TOTAL"
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
