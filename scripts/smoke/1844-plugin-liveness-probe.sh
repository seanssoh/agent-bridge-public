#!/usr/bin/env bash
# scripts/smoke/1844-plugin-liveness-probe.sh — regression for issue
# #1844, where bridge-status.py's Plugin Liveness section rendered
# "<channel>=unknown" for every agent on every host because the probe
# was never wired (plugins_for_agent hardcoded "status": "unknown") and
# the section hard-truncated with "+N more" hiding actionable rows.
#
# The actual assertions live in
# scripts/smoke/1844-plugin-liveness-probe.py — kept as a standalone
# .py file (not heredoc-stdin to python3) so the smoke is immune to
# footgun #11 even if a future caller wraps this driver in `$()` capture.

set -euo pipefail

SMOKE_NAME="1844-plugin-liveness-probe"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "[smoke:${SMOKE_NAME}] starting"
"$PYTHON_BIN" "$SCRIPT_DIR/1844-plugin-liveness-probe.py"
