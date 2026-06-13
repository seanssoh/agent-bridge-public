#!/usr/bin/env bash
# scripts/smoke/1872-watchdog-unsupported-engine-info.sh — regression for
# bridge-watchdog.py #1872: ``unsupported_engine_contract`` is informational/
# advisory, not an operator-actionable problem.
#
# Before #1872 a HEALTHY antigravity (engine has no implemented contract) static
# agent classified as ``unsupported_engine_contract`` and that status counted as
# a problem, so the daemon regenerated a HIGH ``[watchdog] agent profile drift``
# task on every scan (patch-agy noise the fleet closed as a stale alarm). #1872
# excludes the status from the problem count + HIGH drift-task gate while keeping
# the row visible in the report.
#
# POSITIVE: healthy unsupported-engine agent → row visible, problem tally 0.
# NEGATIVE CONTROL: SAME engine with broken_links > 0 → warn (engine-agnostic
# drift) → NOT advisory → STILL pages. This proves the reclassify is scoped to
# the engine-contract status only, not a blanket suppression.
#
# The assertions live in scripts/smoke/1872-watchdog-unsupported-engine-info.py
# — kept as a standalone .py file (not heredoc-stdin to python3) so the smoke is
# immune to footgun #11 even if a future caller wraps this driver in `$()`
# capture.

set -euo pipefail

SMOKE_NAME="1872-watchdog-unsupported-engine-info"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "[smoke:${SMOKE_NAME}] starting"
"$PYTHON_BIN" "$SCRIPT_DIR/1872-watchdog-unsupported-engine-info.py"
