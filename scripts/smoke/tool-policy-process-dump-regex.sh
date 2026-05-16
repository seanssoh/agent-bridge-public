#!/usr/bin/env bash
# scripts/smoke/tool-policy-process-dump-regex.sh — regression for the
# hooks/tool-policy.py process-environment-dump regex tightening
# (2026-05-16, operator-flagged false positive on natural-language
# tokens such as `stale env override` inside task titles).
#
# The actual assertions live in
# scripts/smoke/tool-policy-process-dump-regex.py — kept as a
# standalone .py file (not heredoc-stdin to python3) so the smoke is
# immune to footgun #11 even if a future caller wraps this driver in
# `$()` capture.

set -euo pipefail

SMOKE_NAME="tool-policy-process-dump-regex"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "[smoke:${SMOKE_NAME}] starting"
"$PYTHON_BIN" "$SCRIPT_DIR/tool-policy-process-dump-regex.py"
