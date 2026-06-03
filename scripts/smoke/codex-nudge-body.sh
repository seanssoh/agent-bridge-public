#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/codex-nudge-body.sh — Issue #8945 Track A.
#
# Pins the engine-aware urgent-nudge body contract in bridge-send.sh:
#
#   T1: a Codex target gets the explicit multi-step body — it names every
#       step (inbox → claim → show → work → done) and ends with the
#       `agb done ... --note` close step so a literal reading still runs the
#       whole Task Processing Protocol (the #8945 patch-dev wedge: Codex read
#       the one-line `agb inbox` body literally, printed the inbox, and went
#       idle without claiming/processing/closing).
#   T2: a Claude target keeps the concise one-line `agb inbox <id>` body (the
#       agent-bridge Claude skill auto-expands it).
#   T3: an unknown / unresolved engine falls back to the one-line body
#       (fail-safe — a roster gap must never break the nudge).
#   T4 (teeth): the engine branch is actually present in bridge-send.sh —
#       reverting it (so codex and claude bodies become identical) fails the
#       assertion.
#
# The smoke extracts the pure `urgent_nudge_body` function from bridge-send.sh
# and evaluates it directly (bridge-send.sh is not source-safe — it runs an
# arg-parse main at the bottom). Footgun #11: driver emitted via printf-to-
# file, no heredoc-stdin.

set -uo pipefail

SMOKE_NAME="codex-nudge-body"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
SEND_SCRIPT="$REPO_ROOT/bridge-send.sh"

smoke_assert_file_exists "$SEND_SCRIPT" "bridge-send.sh must exist in the repo root"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# Structural gate: bridge-send.sh must define urgent_nudge_body and branch on
# the "codex" engine. If a future refactor inlines or removes the helper, the
# extraction below fails and this gate surfaces the reason precisely.
if ! grep -q 'urgent_nudge_body()' "$SEND_SCRIPT"; then
  smoke_fail "bridge-send.sh no longer defines urgent_nudge_body() — #8945 Track A regression"
fi
if ! grep -qF 'engine" == "codex"' "$SEND_SCRIPT"; then
  smoke_fail "bridge-send.sh urgent_nudge_body lost its codex engine branch — #8945 Track A regression (teeth)"
fi

DRIVER_DIR="$SMOKE_TMP_ROOT/driver"
mkdir -p "$DRIVER_DIR"
DRIVER="$DRIVER_DIR/driver.sh"

write_driver() {
  local out="$1"
  : >"$out"
  local line
  for line in \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    '# Extract just the pure urgent_nudge_body function from bridge-send.sh' \
    '# (the script itself is not source-safe — it has an arg-parse main).' \
    'FN_SRC="$(awk "/^urgent_nudge_body\\(\\) \\{/{f=1} f{print} f&&/^}/{exit}" "$SEND_SCRIPT")"' \
    'if [[ -z "$FN_SRC" ]]; then echo "DRIVER_FAIL: could not extract urgent_nudge_body"; exit 90; fi' \
    'eval "$FN_SRC"' \
    'declare -F urgent_nudge_body >/dev/null 2>&1 || { echo "DRIVER_FAIL: urgent_nudge_body not defined after eval"; exit 91; }' \
    'CODEX_BODY="$(urgent_nudge_body probe-codex codex)"' \
    'CLAUDE_BODY="$(urgent_nudge_body probe-claude claude)"' \
    'UNKNOWN_BODY="$(urgent_nudge_body probe-mystery unknown)"' \
    'EMPTY_BODY="$(urgent_nudge_body probe-empty "")"' \
    '# T1: codex body is explicit + multi-step.' \
    'case "$CODEX_BODY" in *"agb done"*"--note"*) echo "T1_CODEX_HAS_DONE_NOTE: yes" ;; *) echo "T1_CODEX_HAS_DONE_NOTE: no" ;; esac' \
    'case "$CODEX_BODY" in *"(5)"*) echo "T1_CODEX_HAS_STEP5: yes" ;; *) echo "T1_CODEX_HAS_STEP5: no" ;; esac' \
    'case "$CODEX_BODY" in *"do not stop after step 1"*) echo "T1_CODEX_HAS_NO_STOP: yes" ;; *) echo "T1_CODEX_HAS_NO_STOP: no" ;; esac' \
    'case "$CODEX_BODY" in *probe-codex*) echo "T1_CODEX_HAS_TARGET: yes" ;; *) echo "T1_CODEX_HAS_TARGET: no" ;; esac' \
    '# T2: claude body stays the one-liner.' \
    'if [[ "$CLAUDE_BODY" == "agb inbox probe-claude" ]]; then echo "T2_CLAUDE_ONELINER: yes"; else echo "T2_CLAUDE_ONELINER: no"; fi' \
    '# T3: unknown / empty engine falls back to the one-liner (fail-safe).' \
    'if [[ "$UNKNOWN_BODY" == "agb inbox probe-mystery" ]]; then echo "T3_UNKNOWN_FALLBACK: yes"; else echo "T3_UNKNOWN_FALLBACK: no"; fi' \
    'if [[ "$EMPTY_BODY" == "agb inbox probe-empty" ]]; then echo "T3_EMPTY_FALLBACK: yes"; else echo "T3_EMPTY_FALLBACK: no"; fi' \
    '# T4 (teeth): codex and claude bodies MUST differ.' \
    'if [[ "$CODEX_BODY" != "$CLAUDE_BODY" ]]; then echo "T4_BODIES_DIFFER: yes"; else echo "T4_BODIES_DIFFER: no"; fi'
  do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

extract_line() {
  local out="$1"
  local key="$2"
  printf '%s\n' "$out" | sed -n "s/^$key: //p" | head -n 1
}

write_driver "$DRIVER"

smoke_log "T1-T4: engine-aware urgent_nudge_body (#8945 Track A)"

OUT="$(
  SEND_SCRIPT="$SEND_SCRIPT" \
  "$BRIDGE_BASH" "$DRIVER" 2>&1
)"
RC=$?

if [[ $RC -ne 0 ]]; then
  smoke_fail "driver exited rc=$RC. output:
$OUT"
fi

# T1: Codex multi-step body.
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_CODEX_HAS_DONE_NOTE")" \
  "T1: codex nudge body ends with the 'agb done ... --note' close step"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_CODEX_HAS_STEP5")" \
  "T1: codex nudge body enumerates the multi-step protocol (has step (5))"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_CODEX_HAS_NO_STOP")" \
  "T1: codex nudge body tells the agent not to stop after listing the inbox"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_CODEX_HAS_TARGET")" \
  "T1: codex nudge body substitutes the target agent id"

# T2: Claude one-liner unchanged.
smoke_assert_eq "yes" "$(extract_line "$OUT" "T2_CLAUDE_ONELINER")" \
  "T2: claude nudge body stays the concise 'agb inbox <id>' one-liner (skill auto-expands)"

# T3: fail-safe fallback.
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_UNKNOWN_FALLBACK")" \
  "T3: unknown engine falls back to the one-line body (fail-safe)"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_EMPTY_FALLBACK")" \
  "T3: empty engine falls back to the one-line body (fail-safe)"

# T4: teeth — the two engines produce distinct bodies.
smoke_assert_eq "yes" "$(extract_line "$OUT" "T4_BODIES_DIFFER")" \
  "T4 (teeth): codex and claude nudge bodies differ (engine branch is live)"

smoke_log "all tests PASS — #8945 Track A: engine-aware urgent nudge body"
