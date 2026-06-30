#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/20878-hud-tap-universality-ratchet.sh — auto-rotate backstop
# roadmap step 3 (codex design #20878 points 2/3; tracking issue #2217).
#
# Contract: every managed-Claude LIFECYCLE entrypoint must install the
# claude-hud stdin usage tap, and the tap's WRITE path must share the
# `.usage-cache.json` suffix the monitor's READ resolver consumes — otherwise a
# managed Claude agent produces no usage cache, the monitor sees no
# `used_percent`, and proactive token rotation goes BLIND for it (it hard-caps
# before anything rotates). codex #20878: "make hud-tap universal ... should be
# enforced with a ratchet/preflight for managed Claude agents."
#
# Complements (does NOT duplicate) existing coverage:
#   - scripts/smoke/17927-p2-statusline-usage-feed.sh E5 proves the READ
#     resolver (bridge_usage_resolve_claude_cache_path) matches the launch
#     CLAUDE_CONFIG_DIR cache path across the three agent modes. (read side)
#   - scripts/smoke/1961-statusline-compose.sh proves cmd_ensure_hud_usage_tap
#     COMPOSES the tap correctly + idempotently. (install logic)
#   - NEITHER proves the install is actually CALLED at the managed-Claude
#     launch paths — a new launch entrypoint, or a refactor that drops a call
#     site, would silently leave a managed agent untapped. This ratchet closes
#     that Case-6 gap.
#
# R1 — bridge_ensure_hud_usage_tap is INVOKED (a real call, not the definition
#      or a comment mention) at every managed-Claude lifecycle entrypoint:
#      start (bridge-start.sh), mid-session run (bridge-run.sh), and upgrade
#      propagation (bridge-upgrade.sh). REVERT TEETH: drop any call site → R1
#      fails loudly here instead of silently in the field.
# R2 — the tap WRITE-path suffix (scripts/hud-usage-tap.py) and the monitor
#      READ-path suffix (bridge_usage_resolve_claude_cache_path in
#      bridge-usage.sh) are the SAME literal `plugins/claude-hud/.usage-cache.json`
#      → a one-sided rename that desyncs write vs read (tap writes where the
#      monitor never reads) is caught.
#
# Footgun #11 (heredoc-stdin deadlock class): no heredoc-stdin / here-string is
# piped to a subprocess; grep runs over source files (file-as-argv) and the
# resolver-body match is a pure-bash glob, not a piped grep.
# Exits 0 on full pass, non-zero on any failed assertion.

set -uo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# This smoke lives at scripts/smoke/; the repo root is two levels up.
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

# ---------------------------------------------------------------------------
# R1 — tap install is CALLED at every managed-Claude lifecycle entrypoint.
# A real CALL is the function name followed by whitespace then a `"` or `$`
# first-argument token. This excludes both the definition
# (`bridge_ensure_hud_usage_tap() {` → `()` follows) and comment mentions
# (`# ... bridge_ensure_hud_usage_tap installs ...` → an alpha word follows).
# ---------------------------------------------------------------------------
_call_re='(^|[^[:alnum:]_])bridge_ensure_hud_usage_tap[[:space:]]+["$]'

for entry in bridge-start.sh bridge-run.sh bridge-upgrade.sh; do
  f="$REPO_ROOT/$entry"
  if [[ ! -f "$f" ]]; then
    _fail "R1 $entry" "file missing at $f"
    continue
  fi
  if grep -nEq "$_call_re" "$f"; then
    _pass "R1 $entry invokes bridge_ensure_hud_usage_tap (managed-Claude tap wired)"
  else
    _fail "R1 $entry" "no bridge_ensure_hud_usage_tap CALL — managed Claude agents launched/upgraded via $entry would be untapped → monitor sees no used_percent → proactive rotation blind"
  fi
done

# ---------------------------------------------------------------------------
# R2 — write-path / read-path cache suffix agreement.
# ---------------------------------------------------------------------------
SUFFIX='plugins/claude-hud/.usage-cache.json'
TAP="$REPO_ROOT/scripts/hud-usage-tap.py"
USAGE="$REPO_ROOT/bridge-usage.sh"

# WRITE side: hud-usage-tap.py composes Path(home)/"plugins"/"claude-hud" then
# /".usage-cache.json".
if [[ -f "$TAP" ]] \
  && grep -Eq '"plugins"[[:space:]]*/[[:space:]]*"claude-hud"' "$TAP" \
  && grep -q '\.usage-cache\.json' "$TAP"; then
  _pass "R2 write: hud-usage-tap.py writes under plugins/claude-hud/.usage-cache.json"
else
  _fail "R2 write" "hud-usage-tap.py no longer composes the plugins/claude-hud/.usage-cache.json suffix"
fi

# READ side: bridge_usage_resolve_claude_cache_path emits the same suffix on
# every branch. Extract the real shipped function body (single source of truth,
# same awk-extract pattern as 17927-p2 E5) and glob-match the suffix — no piped
# grep (footgun #11 class).
RESOLVER="$(awk '/^bridge_usage_resolve_claude_cache_path\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$USAGE")"
if [[ -n "$RESOLVER" && "$RESOLVER" == *"$SUFFIX"* ]]; then
  _pass "R2 read: bridge_usage_resolve_claude_cache_path resolves the same $SUFFIX suffix"
else
  _fail "R2 read" "resolver body absent or suffix drifted from $SUFFIX (write/read cache paths would diverge → tap writes where the monitor never reads)"
fi

# ---------------------------------------------------------------------------
if (( FAILS > 0 )); then
  printf '\n[20878-hud-tap-universality-ratchet] %d/%d checks FAILED\n' "$FAILS" "$TOTAL" >&2
  exit 1
fi
printf '\n[20878-hud-tap-universality-ratchet] all %d checks passed\n' "$TOTAL"
