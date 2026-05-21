#!/usr/bin/env bash
# scripts/smoke/common-instructions-local-override.sh — regression for the
# COMMON-INSTRUCTIONS.local.md machine-local override path in bridge-docs.py.
#
# `agb upgrade` regenerates the shared docs wholesale, so a host has no
# upgrade-safe place for durable per-install rules unless the renderer reads
# a sibling override file. This smoke pins that
# render_shared_common_instructions_md() appends COMMON-INSTRUCTIONS.local.md
# when present and degrades to a byte-identical no-op when it is absent,
# empty, or unreadable.
#
# The assertions live in the paired .py (standalone, not heredoc-stdin to
# python3) so the smoke is immune to footgun #11.

set -euo pipefail

SMOKE_NAME="common-instructions-local-override"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "[smoke:${SMOKE_NAME}] starting"
"$PYTHON_BIN" "$SCRIPT_DIR/common-instructions-local-override.py"
