#!/usr/bin/env bash
# scripts/smoke/1214-channel-validator-iso-fallback.sh — issue #1214.
#
# Pins the contract closed by #1214 — `bridge_channel_env_file_readiness`
# in `lib/bridge-agents.sh` must:
#   (a) Not short-circuit on `[[ ! -e "$file" ]]` (the pre-#1214 early
#       return that defeated beta25 #1207's read-fallback when the
#       controller's supp-groups were stale).
#   (b) Route directly through `bridge_iso_run --op env-has-any-key`
#       whenever `bridge_agent_linux_user_isolation_effective` is true
#       — without an outer `bridge_isolation_can_sudo_to_agent` pre-gate.
#   (c) Map the `bridge_iso_run` rc band to the readiness enum:
#         0       → 'present'
#         30, 31  → 'missing'
#         32      → 'unreadable'
#         20, 40  → 'controller-blind' (never 'missing')
#         10      → fall through to legacy unreadable path
#         other   → 'controller-blind' (defensive)
#   (d) `bridge_agent_channel_runtime_ready_for_item` must use
#       `bridge_channel_access_file_present` for access.json checks
#       (not raw `[[ -f ]]`) so an isolated workdir resolves the same
#       way as the status-reason path.
#
# Tests:
#   T1 (positive)        — controller -e fails, iso probe rc=0 →
#                          'present'.
#   T2 (rc=30 missing)   — iso probe says file absent → 'missing'.
#   T3 (rc=31 empty key) → 'missing'.
#   T4 (rc=32 unread)    → 'unreadable'.
#   T5 (rc=20 nosudo)    → 'controller-blind' (NOT 'missing').
#   T6 (rc=40 unsafe)    → 'controller-blind' (NOT 'missing').
#   T7 (rc=10 noniso)    → fall through to legacy unreadable.
#   T8 (other rc)        → 'controller-blind'.
#   T9 (no iso effective) → legacy unreadable path.
#   T10 (access.json)    → `bridge_agent_channel_runtime_ready_for_item`
#                          uses `bridge_channel_access_file_present`
#                          (assertion via grep on the function body).
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
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1214-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

AGENTS_FILE="$REPO_ROOT/lib/bridge-agents.sh"
if [[ ! -f "$AGENTS_FILE" ]]; then
  printf '[FAIL] lib/bridge-agents.sh not found at %s\n' "$AGENTS_FILE" >&2
  exit 1
fi

# Build a minimal harness file that:
#   1. Defines the helper deps that `bridge_channel_env_file_readiness`
#      uses (the controller-side env reader + stubs for the iso path).
#   2. Sources lib/bridge-agents.sh JUST FAR ENOUGH to pick up the
#      target function (we can't source the full file from this smoke
#      because it pulls bridge-lib's full graph; instead extract the
#      function with awk and eval it under our stubbed env).
#
# This is the same shape PR #1207's smoke used.
HARNESS="$SMOKE_DIR/harness.sh"
: >"$HARNESS"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' ''
  # ---- Stubs we control via env vars ----
  # The internal controller-side env reader. Reads from STUB_CTRL_RC.
  printf '%s\n' 'bridge_env_file_has_any_nonempty_key() { return "${STUB_CTRL_RC:-2}"; }'
  # Predicate that gates the iso branch.
  printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return "${STUB_ISO_EFFECTIVE_RC:-1}"; }'
  # The iso-side probe. Always returns STUB_ISO_RC.
  printf '%s\n' 'bridge_iso_run() { return "${STUB_ISO_RC:-32}"; }'
  printf '%s\n' ''
  # ---- Extract the target function from lib/bridge-agents.sh ----
  printf '%s\n' 'source "$1"'
  # Then test driver.
  printf '%s\n' 'agent="${TEST_AGENT:-test_iso_v25}"'
  printf '%s\n' 'item="${TEST_ITEM:-plugin:ms365}"'
  printf '%s\n' 'file="${TEST_FILE:-/nonexistent/.env}"'  # noqa: iso-helper-boundary
  printf '%s\n' 'result="$(bridge_channel_env_file_readiness "$agent" "$item" "$file" MS365_CLIENT_ID)"'
  printf '%s\n' 'printf "%s\n" "$result"'
} >>"$HARNESS"
chmod +x "$HARNESS"

# Helper: extract just the target functions (and their deps) into a
# minimal sourceable file. We only need the readiness function so the
# tests stay surgical.
EXTRACTED="$SMOKE_DIR/extracted-fn.sh"
awk '
  /^bridge_channel_env_file_readiness\(\) \{$/ { capture=1 }
  capture { print }
  capture && /^\}$/ && !inblock { exit }
  capture && /^\}$/ { inblock=0 }
  capture && /^[a-zA-Z_]+\(\) \{$/ && NR > 1 { inblock=1 }
' "$AGENTS_FILE" >"$EXTRACTED"

# Guard against awk skipping the closing brace.
if ! grep -q "^bridge_channel_env_file_readiness" "$EXTRACTED"; then
  printf '[FAIL] failed to extract bridge_channel_env_file_readiness from %s\n' "$AGENTS_FILE" >&2
  exit 1
fi
# Sanity-check: last line of extracted file should be `}`.
if [[ "$(tail -n1 "$EXTRACTED")" != "}" ]]; then
  printf '[FAIL] extracted function does not end with closing brace; bottom 5 lines:\n' >&2
  tail -n5 "$EXTRACTED" >&2
  exit 1
fi

# Validate harness syntax with the extracted function.
if ! /opt/homebrew/bin/bash -n "$HARNESS" 2>/dev/null && ! /usr/bin/env bash -n "$HARNESS" 2>/dev/null; then
  printf '[FAIL] harness fails syntax check\n' >&2
  exit 1
fi
if ! /opt/homebrew/bin/bash -n "$EXTRACTED" 2>"$SMOKE_DIR/extracted.err"; then
  if ! /usr/bin/env bash -n "$EXTRACTED" 2>"$SMOKE_DIR/extracted.err"; then
    printf '[FAIL] extracted function fails syntax check: %s\n' "$(cat "$SMOKE_DIR/extracted.err")" >&2
    exit 1
  fi
fi

# Pick a real-ish bash (5+ where available).
BASH_BIN="$(command -v /opt/homebrew/bin/bash || command -v bash)"

run_case() {
  # Args: ctrl_rc iso_effective_rc iso_rc -> stdout
  local ctrl_rc="$1" iso_eff="$2" iso_rc="$3"
  STUB_CTRL_RC="$ctrl_rc" \
    STUB_ISO_EFFECTIVE_RC="$iso_eff" \
    STUB_ISO_RC="$iso_rc" \
    "$BASH_BIN" "$HARNESS" "$EXTRACTED"
}

# ---------------------------------------------------------------------------
# T1 — controller can't read (rc=2), iso effective, iso rc=0 → 'present'.
# ---------------------------------------------------------------------------
T1_OUT="$(run_case 2 0 0)"
if [[ "$T1_OUT" == "present" ]]; then
  _pass "T1: controller-blind + iso rc=0 → present"
else
  _fail "T1" "expected 'present', got: '$T1_OUT'"
fi

# ---------------------------------------------------------------------------
# T2 — iso rc=30 → 'missing'.
# ---------------------------------------------------------------------------
T2_OUT="$(run_case 2 0 30)"
if [[ "$T2_OUT" == "missing" ]]; then
  _pass "T2: iso rc=30 → missing"
else
  _fail "T2" "expected 'missing', got: '$T2_OUT'"
fi

# ---------------------------------------------------------------------------
# T3 — iso rc=31 → 'missing'.
# ---------------------------------------------------------------------------
T3_OUT="$(run_case 2 0 31)"
if [[ "$T3_OUT" == "missing" ]]; then
  _pass "T3: iso rc=31 → missing"
else
  _fail "T3" "expected 'missing', got: '$T3_OUT'"
fi

# ---------------------------------------------------------------------------
# T4 — iso rc=32 → 'unreadable'.
# ---------------------------------------------------------------------------
T4_OUT="$(run_case 2 0 32)"
if [[ "$T4_OUT" == "unreadable" ]]; then
  _pass "T4: iso rc=32 → unreadable"
else
  _fail "T4" "expected 'unreadable', got: '$T4_OUT'"
fi

# ---------------------------------------------------------------------------
# T5 — iso rc=20 → 'controller-blind' (never 'missing').
# ---------------------------------------------------------------------------
T5_OUT="$(run_case 2 0 20)"
if [[ "$T5_OUT" == "controller-blind" ]]; then
  _pass "T5: iso rc=20 (sudo unavailable) → controller-blind"
else
  _fail "T5" "expected 'controller-blind', got: '$T5_OUT'"
fi

# ---------------------------------------------------------------------------
# T6 — iso rc=40 → 'controller-blind' (never 'missing'; never 'unreadable').
# ---------------------------------------------------------------------------
T6_OUT="$(run_case 2 0 40)"
if [[ "$T6_OUT" == "controller-blind" ]]; then
  _pass "T6: iso rc=40 (unsafe path) → controller-blind"
else
  _fail "T6" "expected 'controller-blind', got: '$T6_OUT'"
fi

# ---------------------------------------------------------------------------
# T7 — iso rc=10 → fall through to legacy unreadable path.
# ---------------------------------------------------------------------------
T7_OUT="$(run_case 2 0 10)"
if [[ "$T7_OUT" == "unreadable" ]]; then
  _pass "T7: iso rc=10 (not isolated) → legacy unreadable"
else
  _fail "T7" "expected 'unreadable', got: '$T7_OUT'"
fi

# ---------------------------------------------------------------------------
# T8 — iso rc=99 (undefined) → 'controller-blind' (defensive).
# ---------------------------------------------------------------------------
T8_OUT="$(run_case 2 0 99)"
if [[ "$T8_OUT" == "controller-blind" ]]; then
  _pass "T8: iso rc=99 (undefined) → controller-blind (defensive)"
else
  _fail "T8" "expected 'controller-blind', got: '$T8_OUT'"
fi

# ---------------------------------------------------------------------------
# T9 — `bridge_agent_linux_user_isolation_effective` returns non-zero
# (no iso effective) → never enters the iso branch → legacy unreadable.
# ---------------------------------------------------------------------------
T9_OUT="$(run_case 2 1 0)"
if [[ "$T9_OUT" == "unreadable" ]]; then
  _pass "T9: iso not effective → legacy unreadable path"
else
  _fail "T9" "expected 'unreadable', got: '$T9_OUT'"
fi

# ---------------------------------------------------------------------------
# T10 — `bridge_agent_channel_runtime_ready_for_item` uses
# `bridge_channel_access_file_present` (not raw `[[ -f ]]`) for the
# access.json checks. Source-level grep assertion.
#
# Body staged to a tmpfile so the grep guards read it via argv instead
# of a here-string (footgun #11 / lint-heredoc-ban H3).
# ---------------------------------------------------------------------------
T10_BODY_FILE="$SMOKE_DIR/t10-body.txt"
awk '
  /^bridge_agent_channel_runtime_ready_for_item\(\) \{$/ { capture=1 }
  capture { print }
  capture && /^\}$/ { exit }
' "$AGENTS_FILE" >"$T10_BODY_FILE"

T10_ERRORS=""
# Should not contain a raw `-f "$dir/access.json"` test anymore. Ignore
# comment lines (which reference the old pattern in past tense for
# documentation purposes). Stage non-comment lines into a tmpfile to
# avoid `<<< $VAR` + pipe chain.
T10_NONCOMMENT_FILE="$SMOKE_DIR/t10-noncomment.txt"
grep -vE '^\s*#' "$T10_BODY_FILE" >"$T10_NONCOMMENT_FILE" || true
if grep -E '\[\[ -f "\$dir/access\.json" \]\]' "$T10_NONCOMMENT_FILE" >/dev/null; then
  T10_ERRORS+="bridge_agent_channel_runtime_ready_for_item still uses raw [[ -f \$dir/access.json ]]; "
fi
# Should contain at least 4 calls to bridge_channel_access_file_present
# (discord/telegram/teams/mattermost).
CALLS_COUNT="$(grep -cE 'bridge_channel_access_file_present "\$dir/access\.json" "\$agent"' "$T10_BODY_FILE" || true)"
# `grep -c` returns 0 with empty stdout when not invoked via pipe stdin;
# the explicit `|| true` keeps `set -uo pipefail` happy.
if [[ -z "$CALLS_COUNT" ]]; then
  CALLS_COUNT=0
fi
if [[ "$CALLS_COUNT" -lt 4 ]]; then
  T10_ERRORS+="expected >=4 bridge_channel_access_file_present calls, got $CALLS_COUNT; "
fi
if [[ -z "$T10_ERRORS" ]]; then
  _pass "T10: access.json checks unified through bridge_channel_access_file_present"
else
  _fail "T10" "$T10_ERRORS"
fi

# ---------------------------------------------------------------------------
# T11 — source guard: pre-#1214 early `[[ ! -e "$file" ]] -> missing`
# return at the top of `bridge_channel_env_file_readiness` must NOT
# reappear (would re-introduce the bug the fix closes).
# ---------------------------------------------------------------------------
T11_BODY_FILE="$SMOKE_DIR/t11-body.txt"
awk '
  /^bridge_channel_env_file_readiness\(\) \{$/ { capture=1 }
  capture { print }
  capture && /^\}$/ { exit }
' "$AGENTS_FILE" >"$T11_BODY_FILE"

# The first 15 lines of the function body must not contain the early
# `[[ ! -e ` test. (Later in the function the `-r` controller-read
# probe still appears legitimately.)
T11_HEAD_FILE="$SMOKE_DIR/t11-head.txt"
head -n 15 "$T11_BODY_FILE" >"$T11_HEAD_FILE"
if grep -E '^\s*if \[\[ ! -e "\$file" \]\]' "$T11_HEAD_FILE" >/dev/null; then
  _fail "T11" "early '[[ ! -e \"\$file\" ]] -> missing' return reintroduced — defeats #1214 fix"
else
  _pass "T11: source guard — early -e short-circuit not reintroduced"
fi

printf '[%s] %d/%d passed\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
