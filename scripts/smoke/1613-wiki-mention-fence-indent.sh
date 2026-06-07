#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1613-wiki-mention-fence-indent.sh — issue #1613 part (b).
#
# scripts/wiki-mention-scan.py blanked ```` ``` ````/~~~ fenced regions and
# skipped inline codespans, but it did NOT handle CommonMark 4-space / tab
# INDENTED code blocks. Bash `[[ ... ]]` tests and POSIX `[:space:]` classes
# inside an indented block were therefore parsed as wikilinks, polluting the
# unresolved-wikilink section of the distribution report (live symptom:
# candidates `$dry_run -eq 0`, `:space:`).
#
# The #1613 fix adds a length-preserving `blank_indented_code` pre-processing
# pass (run after `blank_fenced_code`) plus a defensive POSIX-class reject in
# `iter_wikilinks`. This smoke pins:
#   - the verbatim issue-body repro now yields ONLY the real link
#     (`['people']`), not `['$dry_run -eq 0', ':space:', 'people']`;
#   - regression controls: legit column-0 links (plain / aliased / anchored)
#     still resolve, tab-indented blocks are also blanked, an indented line
#     that merely continues a paragraph keeps its link (CommonMark: indented
#     code cannot interrupt a paragraph), blank-separated indented list
#     paragraphs keep their links (the pass refuses to open a code block
#     inside a list) while genuine indented code AFTER the list closes is
#     still blanked, and match offsets stay aligned.
#
# The python body is carried in a file-as-argv helper — never heredoc-stdin
# (lint-heredoc-ban / footgun #11).

set -euo pipefail

SMOKE_NAME="1613-wiki-mention-fence-indent"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

SCAN_PY="$SMOKE_REPO_ROOT/scripts/wiki-mention-scan.py"
HELPER_PY="$SCRIPT_DIR/1613-wiki-mention-fence-indent-helper.py"

smoke_log "A: wiki-mention-scan.py compiles"
python3 -c "import py_compile; py_compile.compile('$SCAN_PY', doraise=True)" || \
  smoke_fail "wiki-mention-scan.py failed py_compile"

smoke_log "B: issue-body repro yields only the real [[people]] link"
python3 "$HELPER_PY" repro "$SCAN_PY" || \
  smoke_fail "indented-code-block false-positives leaked as wikilinks"

smoke_log "C: regression controls (legit links, tab block, paragraph continuation, offsets)"
python3 "$HELPER_PY" controls "$SCAN_PY" || \
  smoke_fail "a regression control failed"

smoke_log "D: wiki-mention-scan.py keeps the indented-code pre-processing symbol"
grep -q 'blank_indented_code' "$SCAN_PY" || \
  smoke_fail "wiki-mention-scan.py lost the blank_indented_code pass"

smoke_log "PASS: $SMOKE_NAME"
