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
# Pattern detected (4 wrapper shapes — all reproduce the v0.13.7-v0.13.9
# deadlock chain when the subprocess is slow to drain):
#   1. command-start:    bash -s … <<EOF                / python3 - … <<PY
#   2. if-wrapped:       if [!] bash -s … <<EOF         / if [!] python3 - … <<PY
#   3. `$()`-wrapped:    var=$(bash -s … <<EOF)         / var=$(python3 - … <<PY)
#                        var="$(bash -s … <<EOF)"       / var="$(python3 - … <<PY)"
#   4. piped + `$()`:    var="$(printf … | bash -s … <<EOF)"  etc.
#
# Comment-only lines (first non-whitespace char is `#`) do NOT match —
# doc strings and audit-trail references to heredoc shapes do not trip
# the lint.
#
# This script is NOT a substitute for the migration work in S10-late;
# it's the regression guard during S2-S9 so the bridge-upgrade.sh heredoc
# carry-over doesn't grow while the rest of the stabilization is in
# progress.
#
# Usage:
#   scripts/lint-heredoc-ban.sh              # check, exit 1 if over ceiling
#   scripts/lint-heredoc-ban.sh --list       # list all detected sites
#   scripts/lint-heredoc-ban.sh --self-test  # verify pattern against fixtures
#   BRIDGE_UPGRADE_HEREDOC_CEILING=10 ...    # override ceiling for testing

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_file="$repo_root/bridge-upgrade.sh"
ceiling="${BRIDGE_UPGRADE_HEREDOC_CEILING:-18}"

# Pattern: heredoc-stdin invocation of bash -s / python3 - in any of the 4
# wrapper shapes (see header comment). The optional leading-context
# alternation captures:
#   - `if [!] ` prefix (alternative #1)
#   - any non-comment text containing `$(` optionally followed by
#     non-paren text (alternative #2 — handles assignment with `$()`,
#     piped command-substitution, etc.)
# Comment lines fail the leading-context alternation because `[^#]*` cannot
# consume `#`, and the bare command-start anchor `[[:space:]]*` requires
# the next char to be `b` or `p` (start of `bash`/`python3`).
pattern='^[[:space:]]*((if[[:space:]]+!?[[:space:]]*)|([^#]*\$\([^()]*))?(bash[[:space:]]+-s|python3[[:space:]]+-)[[:space:]].*<<-?["'"'"']?(EOF|PY)["'"'"']?'

run_self_test() {
  local fixture
  fixture="$(mktemp)"
  trap 'rm -f "$fixture"' RETURN

  cat >"$fixture" <<'FIXTURE'
# Comment line that mentions python3 - <<'PY' should NOT match.
  # Indented comment with bash -s -- <<'EOF' should NOT match.
echo "doc string with python3 - <<PY embedded" >/dev/null
bash -s -- "$arg" <<'EOF'
python3 - "$payload" <<'PY'
  bash -s -- "$arg" <<EOF
  python3 - <<-PY
if bash -s -- "$arg" <<'EOF'; then
if ! python3 - "$payload" <<'PY'; then
  if bash -s -- "$arg" <<EOF; then
  if ! python3 - <<PY; then
out="$(python3 - "$payload" <<'PY')"
out=$(python3 - "$payload" <<'PY')
out="$(bash -s -- "$arg" <<'EOF')"
out=$(bash -s -- "$arg" <<EOF)
local out="$(python3 - "$payload" <<'PY')"
result="$(printf '%s' "$json" | python3 - "$arg" <<'PY')"
result="$(printf '%s' "$json" | bash -s -- "$arg" <<'EOF')"
echo done
true
FIXTURE

  # Expected: 15 positive matches (every line that starts a real invocation).
  # Negative cases: 5 (two comments + echo doc-string + 2 trailing no-op lines).
  local expected=15
  local got
  got="$(grep -cE "$pattern" "$fixture" || true)"

  if [[ "$got" != "$expected" ]]; then
    echo "[lint-heredoc-ban] SELF-TEST FAIL: expected $expected matches, got $got" >&2
    echo "[lint-heredoc-ban] matches:" >&2
    grep -nE "$pattern" "$fixture" | sed 's/^/[lint-heredoc-ban]   /' >&2 || true
    return 1
  fi

  # Negative checks: comment-only lines and doc strings must NOT match.
  local negatives
  negatives="$(grep -nE "$pattern" "$fixture" | grep -E '^[0-9]+:[[:space:]]*#|echo "doc string' || true)"
  if [[ -n "$negatives" ]]; then
    echo "[lint-heredoc-ban] SELF-TEST FAIL: comment/doc-string lines matched:" >&2
    printf '%s\n' "$negatives" | sed 's/^/[lint-heredoc-ban]   /' >&2
    return 1
  fi

  echo "[lint-heredoc-ban] SELF-TEST PASS: pattern catches $got synthetic invocations across all 4 shapes."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

if [[ ! -f "$target_file" ]]; then
  echo "[lint-heredoc-ban] target file missing: $target_file" >&2
  exit 2
fi

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
