#!/usr/bin/env bash
# scripts/smoke/1789-rotation-limited-until.sh — PR #1790 (#1789 D1/D2).
#
# Thin CI registration wrapper (PR #1790 r3 P1: the canonical rotation suite
# lived dangling under tests/ with no ci-select-smoke.sh mapping, so changes
# to the rotation surface never re-ran it in CI).
#
# The suite itself is tests/claude-token-rotation/smoke.sh — an isolated
# BRIDGE_HOME fixture covering the keychain-free auth path end-to-end plus
# the #1789 limit-window block: rotate --limited-until stamps the
# rotating-away token, ring selection skips future-limited candidates,
# all_tokens_limited refusal carries soonest_reset (sentinel-encoded TSV,
# r3 BLOCKING 1), an expired stamp re-admits the token, and explicit
# activate clears a pending stamp (r2 finding).
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

exec bash "$REPO_ROOT/tests/claude-token-rotation/smoke.sh"
