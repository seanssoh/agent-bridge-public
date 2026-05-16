#!/usr/bin/env bash
# Regression smoke — BSD mktemp template portability.
#
# Patch task #4648 (2026-05-16): bridge-agent.sh:1959 used
# `mktemp ".XXXXXX.py"` which on macOS BSD `mktemp` returns the
# LITERAL `XXXXXX.py` path (only trailing `X` sequences are expanded).
# A literal path is created the first time; subsequent calls fail
# with `mkstemp failed: File exists` and block every shared-settings
# rerender on macOS.
#
# This smoke is a regression guard against re-introducing the same
# template shape (`.XXXXXX.<suffix>` in a positional mktemp call) in
# any tracked shell file.
#
# Coverage:
#   M1 — direct BSD mktemp behavior probe: `.XXXXXX.py` returns the
#         literal path (proves the bug class exists on the host).
#   M2 — bridge-agent.sh's mktemp template is suffix-less (fixed).
#   M3 — bridge-review.sh's mktemp template is suffix-less (fixed
#         via mv-rename so the cosmetic `.md` is preserved).
#   M4 — grep-based lint: no NEW positional mktemp call with the
#         `.X{4,}.<ext>` pattern in tracked shell files.

set -uo pipefail

SMOKE_NAME="bsd-mktemp-portability"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# M1 — Probe BSD behavior to confirm the bug class exists on this host.
# On Linux GNU coreutils this probe is informational: GNU `mktemp`
# expands X anywhere in the template, so the literal-path bug does
# NOT manifest. The smoke proceeds either way; M2/M3/M4 are the
# real regression checks.
smoke_log "M1: probe BSD mktemp behavior with .XXXXXX.py template"
M1_PROBE="$SMOKE_TMP_ROOT/probe.XXXXXX.py"
M1_OUT="$(mktemp "$M1_PROBE")"
if [[ "$M1_OUT" == "$M1_PROBE" ]]; then
  smoke_log "M1 result: BSD-style literal expansion (no X substitution) — bug class active on this host"
else
  smoke_log "M1 result: GNU-style X expansion produced '$M1_OUT' — bug class NOT active on this host"
fi
rm -f "$M1_OUT"

# M2 — bridge-agent.sh template is BSD-safe (suffix-less)
smoke_log "M2: bridge-agent.sh mktemp template is suffix-less"
if grep -qE 'mktemp\s+"?[^"]*bridge-rerender-plan\.XXXXXX\.py' "$REPO_ROOT/bridge-agent.sh"; then
  smoke_fail "M2: bridge-agent.sh still has the .XXXXXX.py template (task #4648 regression)"
fi
if ! grep -qE 'mktemp\s+"[^"]*bridge-rerender-plan\.XXXXXX"' "$REPO_ROOT/bridge-agent.sh"; then
  smoke_fail "M2: bridge-agent.sh missing the expected suffix-less mktemp template"
fi
smoke_log "M2 PASS"

# M3 — bridge-review.sh templates are BSD-safe (suffix-less + mv-rename).
# Two sites: review-request (line ~300) and review-complete (line ~402).
smoke_log "M3: bridge-review.sh mktemp templates are suffix-less (2 sites)"
for tag in "review-request" "review-complete"; do
  if grep -qE "mktemp\s+\"?[^\"]*${tag}\.XXXXXX\.md" "$REPO_ROOT/bridge-review.sh"; then
    smoke_fail "M3: bridge-review.sh still has the ${tag}.XXXXXX.md template"
  fi
  if ! grep -qE "mktemp\s+\"[^\"]*${tag}\.XXXXXX\"" "$REPO_ROOT/bridge-review.sh"; then
    smoke_fail "M3: bridge-review.sh missing the expected ${tag} suffix-less mktemp template"
  fi
done
smoke_log "M3 PASS"

# M4 — grep-based lint: catch NEW occurrences across tracked shell files.
# Pattern: `mktemp "<path>.XXXXXX.<ext>"` (positional mktemp call with a
# 4+ char X sequence followed by `.<extension>` then closing quote).
# Excludes the `-t` flag form (BSD `-t` always appends a unique suffix,
# so it doesn't trigger File-exists race even if the X chunk is in the
# middle).
smoke_log "M4: grep lint against new mktemp suffix violations"
M4_HITS="$(cd "$REPO_ROOT" && grep -rnE 'mktemp\s+"[^"]*\.X{4,}\.[A-Za-z0-9]+"' bridge-*.sh lib/*.sh 2>/dev/null || true)"
if [[ -n "$M4_HITS" ]]; then
  smoke_log "M4: detected violations:"
  printf '%s\n' "$M4_HITS" | sed 's/^/[smoke:bsd-mktemp-portability]   /'
  smoke_fail "M4: NEW positional mktemp .XXXXXX.<ext> template introduced (task #4648 regression class)"
fi
smoke_log "M4 PASS"

smoke_log "PASS — BSD mktemp portability intact (4 cases)"
exit 0
