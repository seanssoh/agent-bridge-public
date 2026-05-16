#!/usr/bin/env bash
# scripts/smoke/classify-stale-dynamic-exemption.sh — regression for the
# bridge-status.py classify_stale upstream bug where dynamic-source
# agents (operator-driven containers like crm-dev, agb-dev-claude) were
# flagged as warn/crit purely on idle time. Idle is the normal state
# for dynamic agents — the operator parks them between interactive
# sessions — so the dashboard health counter on a healthy host
# constantly produced false positives (Sean, 2026-05-16).
#
# The actual assertions live in scripts/smoke/classify-stale-dynamic-
# exemption.py — kept as a standalone .py file (not heredoc-stdin to
# python3) so the smoke is immune to footgun #11 even if a future
# caller wraps this driver in `$()` capture.

set -euo pipefail

SMOKE_NAME="classify-stale-dynamic-exemption"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "[smoke:${SMOKE_NAME}] starting"
"$PYTHON_BIN" "$SCRIPT_DIR/classify-stale-dynamic-exemption.py"
