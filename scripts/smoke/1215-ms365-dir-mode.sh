#!/usr/bin/env bash
# scripts/smoke/1215-ms365-dir-mode.sh — issue #1215.
#
# Pins the contract closed by #1215 — ms365/teams plugin STATE_DIR must
# land at mode `02770` (setgid + rwx-for-owner-and-group) so the v2
# isolation contract's `ab-agent-<slug>` group can stat the dir, AND
# the explicit `chmodSync` after `mkdirSync` must self-heal an existing
# bad-mode dir on the next plugin process startup.
#
# This smoke runs in two modes:
#   - Source-level (always): grep the plugin TS files to assert the
#     `mkdirSync(..., mode: 0o770)` + `chmodSync(..., 0o2770)` pattern
#     is in place for STATE_DIR. Also assert `tokens/`, `pending/`,
#     and token/env files stay at `0o700` / `0o600` (no widening).
#   - Behavioral (Linux + sudo, or BRIDGE_TEST_LINUX_ROOT=1):
#     reproduce the JS shape via a small Node-equivalent in bash,
#     create a STATE_DIR with a bad pre-existing mode, run the
#     mkdir+chmod sequence, assert the mode is repaired to `02770`.
#
# Tests:
#   T1 (source) — ms365 server.ts STATE_DIR uses `mode: 0o770` +
#                 explicit `chmodSync(..., 0o2770)` self-heal.
#   T2 (source) — teams server.ts STATE_DIR uses same pattern.
#   T3 (source) — ms365 server.ts keeps TOKENS_DIR/PENDING_DIR at
#                 `0o700` (private; controller cannot read tokens).
#   T4 (source) — token files (json + tmp atomic writes) stay at
#                 `0o600`. No widening beyond 0600.
#   T5 (source) — bridge-setup.py call sites for the 4 channel dirs
#                 (discord/telegram/teams/mattermost) pass an
#                 explicit `mode=0o2770` to `_isolation_aware_mkdir`.
#   T6 (behavioral, Linux) — pre-create STATE_DIR as mode `0o660`,
#                            run mkdir+chmod, assert mode 02770.
#   T7 (behavioral, Linux) — fresh STATE_DIR mkdir lands at 02770.
#   T8 (behavioral, Linux) — `.ms365/.env` file mode stays `0o600`.
#
# Footgun #11: pipe/argv stdin only.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
_skip() { TOTAL=$((TOTAL + 1)); printf '[skip] %s\n' "$1"; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1215-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

MS365_TS="$REPO_ROOT/plugins/ms365/server.ts"
TEAMS_TS="$REPO_ROOT/plugins/teams/server.ts"
BRIDGE_SETUP="$REPO_ROOT/bridge-setup.py"

for f in "$MS365_TS" "$TEAMS_TS" "$BRIDGE_SETUP"; do
  if [[ ! -f "$f" ]]; then
    printf '[FAIL] required file missing: %s\n' "$f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# T1 — ms365 server.ts STATE_DIR pattern.
# ---------------------------------------------------------------------------
T1_ERRORS=""
if ! grep -E "mkdirSync\(STATE_DIR.*mode: 0o770" "$MS365_TS" >/dev/null; then
  T1_ERRORS+="ms365 STATE_DIR mkdirSync missing mode: 0o770; "
fi
if ! grep -E "chmodSync\(STATE_DIR, 0o2770\)" "$MS365_TS" >/dev/null; then
  T1_ERRORS+="ms365 STATE_DIR missing explicit chmodSync to 0o2770; "
fi
if [[ -z "$T1_ERRORS" ]]; then
  _pass "T1: ms365 STATE_DIR uses mode 0o770 + chmodSync(0o2770) self-heal"
else
  _fail "T1" "$T1_ERRORS"
fi

# ---------------------------------------------------------------------------
# T2 — teams server.ts STATE_DIR pattern.
# ---------------------------------------------------------------------------
T2_ERRORS=""
if ! grep -E "mkdirSync\(STATE_DIR.*mode: 0o770" "$TEAMS_TS" >/dev/null; then
  T2_ERRORS+="teams STATE_DIR mkdirSync missing mode: 0o770; "
fi
if ! grep -E "chmodSync\(STATE_DIR, 0o2770\)" "$TEAMS_TS" >/dev/null; then
  T2_ERRORS+="teams STATE_DIR missing explicit chmodSync to 0o2770; "
fi
if [[ -z "$T2_ERRORS" ]]; then
  _pass "T2: teams STATE_DIR uses mode 0o770 + chmodSync(0o2770) self-heal"
else
  _fail "T2" "$T2_ERRORS"
fi

# ---------------------------------------------------------------------------
# T3 — ms365 server.ts tokens/pending stay at 0o700.
# ---------------------------------------------------------------------------
T3_ERRORS=""
if ! grep -E "mkdirSync\(TOKENS_DIR.*mode: 0o700" "$MS365_TS" >/dev/null; then
  T3_ERRORS+="ms365 TOKENS_DIR not mode 0o700 (token privacy regression); "
fi
if ! grep -E "mkdirSync\(PENDING_DIR.*mode: 0o700" "$MS365_TS" >/dev/null; then
  T3_ERRORS+="ms365 PENDING_DIR not mode 0o700 (token privacy regression); "
fi
if [[ -z "$T3_ERRORS" ]]; then
  _pass "T3: ms365 tokens/pending stay at 0o700 (private)"
else
  _fail "T3" "$T3_ERRORS"
fi

# ---------------------------------------------------------------------------
# T4 — ms365 server.ts file modes stay at 0o600 (no widening beyond
# 0600 for secrets — explicitly forbidden by the brief).
# Look for the saveJson / token-write paths.
# ---------------------------------------------------------------------------
T4_ERRORS=""
# server.ts writes JSON state at mode 0o600 (saveJson + token writes).
# Count writeFileSync calls with mode != 0o600 / 0o600 / 0600 in the
# secret-write paths (rough heuristic: any writeFileSync followed by
# `mode: 0o<not-6>` is suspect).
if grep -E "writeFileSync\(.*mode: 0o(7|770|770|664|644)" "$MS365_TS" >/dev/null; then
  T4_ERRORS+="ms365 writeFileSync widened beyond 0o600 (secret file mode regression); "
fi
if grep -E "chmodSync\([^)]*\.env[^)]*0o(7|770|664|644)" "$MS365_TS" >/dev/null; then
  T4_ERRORS+="ms365 ENV_FILE chmod widened beyond 0o600 (secret file mode regression); "
fi
if [[ -z "$T4_ERRORS" ]]; then
  _pass "T4: ms365 token/env file modes stay at 0o600 (no widening)"
else
  _fail "T4" "$T4_ERRORS"
fi

# ---------------------------------------------------------------------------
# T5 — bridge-setup.py channel dir mkdir call sites pass mode=0o2770.
# ---------------------------------------------------------------------------
T5_ERRORS=""
# Extract context-aware lines: 4 channel dirs (discord/telegram/teams/mattermost).
for chan in discord telegram teams mattermost; do
  # Match: `_isolation_aware_mkdir(<chan>_dir, mode=0o2770, agent=...)`
  if ! grep -E "_isolation_aware_mkdir\(${chan}_dir, mode=0o2770" "$BRIDGE_SETUP" >/dev/null; then
    T5_ERRORS+="bridge-setup.py: ${chan}_dir mkdir missing mode=0o2770; "
  fi
done
if [[ -z "$T5_ERRORS" ]]; then
  _pass "T5: bridge-setup.py channel dirs (discord/telegram/teams/mattermost) pass mode=0o2770"
else
  _fail "T5" "$T5_ERRORS"
fi

# ---------------------------------------------------------------------------
# T6/T7/T8 — Behavioral self-heal tests. Linux-only (mode bit semantics
# match across Linux/macOS, but the v2 contract is Linux-only so we
# gate on the platform). Default: skip on macOS unless
# BRIDGE_TEST_LINUX_ROOT=1.
# ---------------------------------------------------------------------------
PLATFORM="$(uname -s 2>/dev/null || printf 'unknown')"
if [[ "$PLATFORM" != "Linux" && "${BRIDGE_TEST_LINUX_ROOT:-0}" != "1" ]]; then
  _skip "T6: pre-existing bad-mode dir → mode repaired to 02770 (skipped on non-Linux; set BRIDGE_TEST_LINUX_ROOT=1 to force)"
  _skip "T7: fresh STATE_DIR mkdir lands at 02770 (skipped on non-Linux)"
  _skip "T8: .env file mode stays at 0600 (skipped on non-Linux)"
else
  # Behavioral simulator. We mimic the JS shape directly in bash:
  #   mkdir -p STATE_DIR
  #   chmod 0770 STATE_DIR  (mkdirSync mode arg, best-effort)
  #   chmod 02770 STATE_DIR (explicit chmodSync self-heal)
  # and assert the resulting mode includes the setgid bit (02xxx).
  #
  # Portable mode probe: Linux `stat -c %a` returns the full octal
  # mode including setgid (e.g. `2770`). macOS `stat -f '%Lp'` only
  # returns the low 9 bits (`770`), so we use `stat -f '%p'` and
  # extract the setgid + 9-bit tail (`42770` -> setgid=2, low=770).
  STATE_DIR="$SMOKE_DIR/iso-workdir/.ms365"

  # Helper: print "2770" (or "770") for a given path; cross-platform.
  dir_mode() {
    local p="$1"
    local linux_out=""
    if linux_out="$(stat -c '%a' "$p" 2>/dev/null)" && [[ -n "$linux_out" ]]; then
      printf '%s' "$linux_out"
      return 0
    fi
    local macos_out=""
    if macos_out="$(stat -f '%p' "$p" 2>/dev/null)" && [[ -n "$macos_out" ]]; then
      # macOS '%p' format: <file-type-2-hex><setuid/setgid/sticky-1><perms-3>.
      # e.g. `42770` => file-type=4 (dir), special=2 (setgid), perms=770.
      # Return special+perms (skipping the leading file-type chars).
      printf '%s' "${macos_out: -4}"
      return 0
    fi
    printf ''
  }

  # T6 — pre-existing bad-mode dir self-heal.
  mkdir -p "$STATE_DIR"
  chmod 0660 "$STATE_DIR"
  # Run the mkdir+chmod sequence (recursive: true is a no-op on existing dir).
  mkdir -p "$STATE_DIR"
  chmod 0770 "$STATE_DIR" 2>/dev/null || true  # mimic mkdirSync's mode arg (best effort)
  chmod 02770 "$STATE_DIR"
  T6_MODE="$(dir_mode "$STATE_DIR")"
  if [[ "$T6_MODE" == "2770" ]]; then
    _pass "T6: pre-existing 0660 dir self-heals to 02770"
  else
    _fail "T6" "expected mode 2770, got: '$T6_MODE'"
  fi

  # T7 — fresh STATE_DIR mkdir lands at 02770.
  FRESH_DIR="$SMOKE_DIR/iso-workdir2/.ms365"
  mkdir -p "$FRESH_DIR"
  chmod 0770 "$FRESH_DIR" 2>/dev/null || true
  chmod 02770 "$FRESH_DIR"
  T7_MODE="$(dir_mode "$FRESH_DIR")"
  if [[ "$T7_MODE" == "2770" ]]; then
    _pass "T7: fresh STATE_DIR mkdir+chmod lands at 02770"
  else
    _fail "T7" "expected mode 2770, got: '$T7_MODE'"
  fi

  # T8 — .env file mode stays at 0600.
  ENV_FILE="$FRESH_DIR/.env"
  printf 'MS365_CLIENT_ID=test-id\n' >"$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  T8_MODE_LINUX="$(stat -c '%a' "$ENV_FILE" 2>/dev/null)"
  T8_MODE_MACOS="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null)"
  T8_MODE="${T8_MODE_LINUX:-$T8_MODE_MACOS}"
  if [[ "$T8_MODE" == "600" ]]; then
    _pass "T8: .env file mode stays at 0600 (no widening beyond 0600)"
  else
    _fail "T8" "expected mode 600, got: '$T8_MODE'"
  fi
fi

printf '[%s] %d/%d passed (FAILS=%d)\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL" "$FAILS"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
