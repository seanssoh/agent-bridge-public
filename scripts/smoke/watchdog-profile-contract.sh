#!/usr/bin/env bash
# scripts/smoke/watchdog-profile-contract.sh — regression for the
# bridge-watchdog.py home-profile-contract check. The watchdog's
# required-files / managed-CLAUDE.md-block / onboarding-staleness signals
# only apply to Claude static agents. Issues #905 / #907 each special-
# cased one slice (codex, then dynamic), but the antigravity engine
# (v0.14.5) fell through to the Claude default and surfaced as a false
# status=error on every scan. This smoke pins has_home_profile_contract()
# as the single gate and guards that a Claude static agent with missing
# profile files still classifies as error.
#
# The actual assertions live in scripts/smoke/watchdog-profile-
# contract.py — kept as a standalone .py file (not heredoc-stdin to
# python3) so the smoke is immune to footgun #11 even if a future caller
# wraps this driver in `$()` capture.

set -euo pipefail

SMOKE_NAME="watchdog-profile-contract"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "[smoke:${SMOKE_NAME}] starting"
"$PYTHON_BIN" "$SCRIPT_DIR/watchdog-profile-contract.py"
