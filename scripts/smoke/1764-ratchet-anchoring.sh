#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1764-ratchet-anchoring.sh — Issue #1764.
#
# Self-test for the iso-helper-ratchet detection regex's word-boundary
# anchoring. The original codex-r1 pattern substring-matched, so `\.env`
# fired inside `os.environ` and `settings\.effective\.json` fired on
# fixture paths — 3 false-positive CI reds in a single day (#1749 /
# #1757 / #1761, 2026-06-10), each costing a diagnose+noqa+push round.
#
# This smoke pins the anchoring so it cannot regress:
#   - It extracts the LIVE `PATTERN=` line from scripts/iso-helper-ratchet.sh
#     (single source of truth — the test can never drift from the gate).
#   - It runs that pattern (with the ratchet's own noqa filter) against a
#     fixture file containing the three real false-positive shapes from the
#     issue evidence plus extra negatives, and asserts ZERO matches.
#   - It asserts a set of genuine boundary-shaped lines (positives) STILL
#     match, so the ratchet stays fail-closed for real callsites.
#   - It runs the real ratchet in check mode and asserts exit 0, proving the
#     shipped baseline is consistent with the anchored pattern.
#   - It injects a synthetic new boundary site into a throwaway baseline/
#     fixture overlay and asserts the ratchet flags it (regression caught).
#
# Footgun #11 (heredoc-stdin deadlock class): no heredoc-stdin / here-string
# is piped to a subprocess; the fixture file is written with `printf` and the
# ratchet is invoked with file-as-argv only.
#
# Exits 0 on full pass, non-zero on any failed assertion.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# This smoke lives at scripts/smoke/; the repo root is two levels up.
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
RATCHET="$REPO_ROOT/scripts/iso-helper-ratchet.sh"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

if ! command -v rg >/dev/null 2>&1; then
  printf '[SKIP] ripgrep (rg) not found; iso-helper-ratchet anchoring smoke needs rg\n' >&2
  exit 0
fi

[[ -f "$RATCHET" ]] || { printf '[FAIL] ratchet not found at %s\n' "$RATCHET" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agb-1764-ratchet.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT INT TERM

# ---- Extract the live pattern + noqa marker from the ratchet ----------------
# Pull the single-quoted RHS of `PATTERN=` and `NOQA_MARKER=` verbatim so the
# test exercises exactly what CI enforces.
PATTERN="$(sed -n "s/^PATTERN='\\(.*\\)'\$/\\1/p" "$RATCHET" | head -1)"
NOQA_MARKER="$(sed -n "s/^NOQA_MARKER='\\(.*\\)'\$/\\1/p" "$RATCHET" | head -1)"

if [[ -n "$PATTERN" ]]; then
  _pass "extracted live PATTERN from ratchet"
else
  _fail "extracted live PATTERN from ratchet" "PATTERN= line not found/parsed"
  printf '\n[summary] %d/%d passed\n' $((TOTAL - FAILS)) "$TOTAL" >&2
  exit 1
fi
[[ -n "$NOQA_MARKER" ]] || NOQA_MARKER='# noqa: iso-helper-boundary'

# ---- Fixture: NEGATIVES (must NOT match) ------------------------------------
# The three real false-positive shapes from the issue evidence + extras.
NEG="$WORK/negatives.txt"
{
  printf '%s\n' 'val = os.environ.get("BRIDGE_HOME", "")'
  printf '%s\n' 'data = dict(os.environ)'
  printf '%s\n' 'home = environ["HOME"]'
  printf '%s\n' 'def setup_environment(self): pass'
  printf '%s\n' 'x = prevent_default()'
  printf '%s\n' 'cfg = some.environment.value'
} >"$NEG"

# ---- Fixture: POSITIVES (must match) ----------------------------------------
# Genuine path-ish boundary references across the whole token family.
POS="$WORK/positives.txt"
{
  printf '%s\n' 'dotenv = agent_home + "/.telegram/.env"'
  printf '%s\n' 'shutil.copy(src, "/x/.env")'
  printf '%s\n' 'backup = home + "/.env.bak"'
  printf '%s\n' 'write(d + "/installed_plugins.json")'
  printf '%s\n' 'mk = root / "known_marketplaces.json"'
  printf '%s\n' 'acc = base + "/.access.json"'
  printf '%s\n' 'port_file = "webhook-port"'
  printf '%s\n' 'eff = home / ".claude/settings.effective.json"'
  printf '%s\n' 'env_sh = scaffold + "/agent-env.sh"'
} >"$POS"

# The ratchet's count_file pipeline is: rg <pattern> | grep -vF noqa.
# Replicate that here for the anchoring assertion.
neg_hits="$(rg --no-heading -e "$PATTERN" "$NEG" 2>/dev/null | grep -vF -- "$NOQA_MARKER" | wc -l | tr -d ' ')"
pos_hits="$(rg --no-heading -e "$PATTERN" "$POS" 2>/dev/null | grep -vF -- "$NOQA_MARKER" | wc -l | tr -d ' ')"

if [[ "$neg_hits" -eq 0 ]]; then
  _pass "negatives (os.environ / environ / environment) produce ZERO matches"
else
  _fail "negatives produce ZERO matches" "got $neg_hits match(es):
$(rg --no-heading --line-number -e "$PATTERN" "$NEG" 2>/dev/null)"
fi

pos_total="$(wc -l <"$POS" | tr -d ' ')"
if [[ "$pos_hits" -eq "$pos_total" ]]; then
  _pass "all $pos_total genuine boundary positives still match (fail-closed)"
else
  _fail "all genuine boundary positives still match" "expected $pos_total, got $pos_hits"
fi

# A noqa'd boundary line must be excluded by the filter (existing-site contract).
NOQ="$WORK/noqa.txt"
printf '%s  %s - controller-only\n' 'token = home + "/.env"' "$NOQA_MARKER" >"$NOQ"
noq_hits="$(rg --no-heading -e "$PATTERN" "$NOQ" 2>/dev/null | grep -vF -- "$NOQA_MARKER" | wc -l | tr -d ' ')"
if [[ "$noq_hits" -eq 0 ]]; then
  _pass "noqa'd boundary line stays non-flagged"
else
  _fail "noqa'd boundary line stays non-flagged" "got $noq_hits match(es)"
fi

# ---- End-to-end ratchet invocations (Bash 4+ only) --------------------------
# The ratchet uses an associative array (`declare -A`), so it only runs under
# Bash 4+. CI (Linux) and operator dev hosts with Homebrew Bash satisfy this;
# the stock macOS /bin/bash (3.2) does not. Invoke via the same `bash` the
# smoke runner uses (PATH, not the script's `env bash` shebang) and gate the
# end-to-end assertions on the interpreter version so a 3.2-only host degrades
# to a SKIP instead of a false pass/fail. The pattern-level anchoring
# assertions above are the interpreter-independent core guard.
ratchet_capable=0
if bash -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]' 2>/dev/null; then
  ratchet_capable=1
fi

if [[ "$ratchet_capable" -eq 1 ]]; then
  check_out="$(bash "$RATCHET" 2>&1)"; check_rc=$?
  if [[ "$check_rc" -eq 0 ]]; then
    _pass "real ratchet check mode passes against shipped baseline (exit 0)"
  else
    _fail "real ratchet check mode passes against shipped baseline" "exit=$check_rc out=$check_out"
  fi
else
  printf '[skip] end-to-end ratchet invocation (PATH bash is < 4; pattern-level guards above still ran)\n'
fi

# ---- End-to-end fail-closed: a new boundary site beyond baseline flags ------
# Copy the shipped baseline and lower exactly ONE file's ceiling so only that
# file regresses. scripts/picker-sweep.sh has a known genuine boundary line
# (a `…/rate-limit-rotation.env` state path) recorded in the shipped baseline;
# zeroing its entry forces the ratchet to report a single regression. This
# proves the gate is still fail-closed for real boundary callsites under the
# anchored pattern.
if [[ "$ratchet_capable" -eq 1 ]]; then
  SHIPPED_BASELINE="$REPO_ROOT/scripts/baselines/iso-helper-baseline.txt"
  OVERLAY="$WORK/overlay-baseline.txt"
  # Lower exactly ONE nonzero entry to 0 so only that file regresses.
  fallback_entry="$(grep -E '=[1-9][0-9]*$' "$SHIPPED_BASELINE" 2>/dev/null | head -1)"
  fallback_file="${fallback_entry%%=*}"
  if [[ -n "$fallback_file" ]]; then
    # Escape regex/sed metacharacters in the relpath for a safe anchored sub.
    esc_file="$(printf '%s' "$fallback_file" | sed 's/[.[\*^$/]/\\&/g')"
    sed "s|^${esc_file}=.*|${fallback_file}=0|" "$SHIPPED_BASELINE" >"$OVERLAY"
    fc_out="$(BRIDGE_ISO_HELPER_BASELINE_FILE="$OVERLAY" bash "$RATCHET" 2>&1)"; fc_rc=$?
    if [[ "$fc_rc" -eq 1 ]] && printf '%s' "$fc_out" | grep -q "REGRESSION ${fallback_file}"; then
      _pass "ratchet flags a boundary site that exceeds baseline (fail-closed, exit 1)"
    else
      _fail "ratchet flags a boundary site that exceeds baseline" "exit=$fc_rc out=$fc_out"
    fi
  else
    _fail "ratchet flags a boundary site that exceeds baseline" "no nonzero baseline entry to test against"
  fi
else
  printf '[skip] end-to-end fail-closed assertion (PATH bash is < 4; pattern-level guards above still ran)\n'
fi

printf '\n[summary] %d/%d tests passed\n' $((TOTAL - FAILS)) "$TOTAL"
[[ "$FAILS" -eq 0 ]] || exit 1
exit 0
