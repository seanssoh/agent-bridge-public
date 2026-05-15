#!/usr/bin/env bash
# scripts/lint-heredoc-ban.sh — ratchet lint preventing NEW heredoc-stdin
# subprocess sites in bridge-upgrade.sh.
#
# Context: footgun #11 (Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock
# chain — fixed in v0.13.7 through v0.13.9). Six leap-path sites were
# extracted to standalone helpers under lib/upgrade-helpers/; 18 off-leap
# sites remain in bridge-upgrade.sh deferred to the S10-late stabilization
# wave. This lint ratchets the count downward — it fails CI if anyone
# introduces a NEW heredoc-stdin subprocess line in bridge-upgrade.sh
# without first migrating an existing one out.
#
# Ratchet semantics:
# - BRIDGE_UPGRADE_HEREDOC_CEILING (default 18) is the current allowed count.
# - When S10-late migrates sites, the ceiling drops to the new count via
#   PR that updates this script's default.
# - PRs that add new heredoc-stdin without removing one push count over
#   the ceiling and fail this lint.
#
# Pattern detected:
#   <bash -s ...|python3 - ...> ... <<EOF | <<'EOF' | <<"EOF" | <<PY | <<'PY' | <<"PY" | <<-...
# at the start of a non-comment line (so doc strings and comment mentions
# don't trip the lint).
#
# This script is NOT a substitute for the migration work in S10-late;
# it's the regression guard during S2-S9 so the bridge-upgrade.sh heredoc
# carry-over doesn't grow while the rest of the stabilization is in
# progress.
#
# Usage:
#   scripts/lint-heredoc-ban.sh              # check, exit 1 if over ceiling
#   scripts/lint-heredoc-ban.sh --list       # list all detected sites
#   BRIDGE_UPGRADE_HEREDOC_CEILING=10 ...    # override ceiling for testing

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_file="$repo_root/bridge-upgrade.sh"
ceiling="${BRIDGE_UPGRADE_HEREDOC_CEILING:-18}"

if [[ ! -f "$target_file" ]]; then
  echo "[lint-heredoc-ban] target file missing: $target_file" >&2
  exit 2
fi

# Pattern: command-line invocation of bash -s / python3 - with a heredoc
# end-marker on the same line, optionally wrapped in `if [!] ...`.
pattern='^[[:space:]]*(if[[:space:]]+!?[[:space:]]*)?(bash[[:space:]]+-s|python3[[:space:]]+-)[[:space:]].*<<-?["'"'"']?(EOF|PY)["'"'"']?'

if [[ "${1:-}" == "--list" ]]; then
  grep -nE "$pattern" "$target_file" || true
  echo
  echo "(ceiling: $ceiling)"
  exit 0
fi

count="$(grep -cE "$pattern" "$target_file" || true)"

if [[ "$count" -gt "$ceiling" ]]; then
  echo "[lint-heredoc-ban] FAIL: bridge-upgrade.sh has $count heredoc-stdin subprocess sites, exceeding the ceiling ($ceiling)." >&2
  echo "[lint-heredoc-ban] This lint ratchets footgun #11 carry-over. New heredoc-stdin sites must be" >&2
  echo "[lint-heredoc-ban] extracted to lib/upgrade-helpers/ (see existing examples)." >&2
  echo "[lint-heredoc-ban]" >&2
  echo "[lint-heredoc-ban] Detected sites:" >&2
  grep -nE "$pattern" "$target_file" | sed 's/^/[lint-heredoc-ban]   /' >&2 || true
  exit 1
fi

if [[ "$count" -lt "$ceiling" ]]; then
  echo "[lint-heredoc-ban] note: count=$count is below ceiling=$ceiling. Consider lowering the ceiling in scripts/lint-heredoc-ban.sh to ratchet."
fi

echo "[lint-heredoc-ban] PASS: count=$count, ceiling=$ceiling"
exit 0
