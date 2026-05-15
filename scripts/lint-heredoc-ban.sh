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
# Contract — broad-match:
#   A "site" is any non-comment line in bridge-upgrade.sh that contains
#   a heredoc-fed `bash -s ...` or `python3 - ...` subprocess on the
#   same line — i.e., the sub-pattern
#       <bash -s | python3 -> ... <<EOF | <<'EOF' | <<"EOF" | <<PY | <<'PY' | <<"PY" | <<-...
#   appears anywhere on the line.
#
#   Wrapper shape does NOT matter: command-start, `if [!] ` wrapped,
#   `var=$(...)` / `var="$(...)"` command-substitution, piped + `$()`,
#   nested `$(...)` deeper than one level, backtick command-sub, or even
#   the pattern embedded inside a double-quoted string — all count.
#
#   The only false-positive surface is a literal mention of the
#   sub-pattern inside a string on a NON-comment line. In practice
#   bridge-upgrade.sh has zero such strings, and the right place to
#   document the danger pattern in code is a comment line (those are
#   excluded — see below).
#
# Comment-line skip:
#   Lines whose first non-whitespace char is `#` are excluded from the
#   count. Audit-trail references, doc strings inside comments, and
#   intent-explaining notes do not trip the lint.
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

# Core danger pattern. Anchored to "command name + space + heredoc op + tag",
# but NOT anchored to start-of-line — so wrapper shape is irrelevant.
danger_pattern='(bash[[:space:]]+-s|python3[[:space:]]+-)[[:space:]].*<<-?["'"'"']?(EOF|PY)["'"'"']?'

# Comment-prefix on `grep -nE` output (format: LINENO:CONTENT). Lines whose
# CONTENT (after optional whitespace) begins with `#` are comment-only.
comment_prefix='^[0-9]+:[[:space:]]*#'

count_sites() {
  local file="$1"
  local n
  # 1st pass: every line containing the danger pattern (with line numbers).
  # 2nd pass: drop comment-only lines.
  # `grep -vc` outputs "0" with exit 1 when the input stream is empty —
  # accept that via `|| true` so set -o pipefail doesn't trip.
  n="$(grep -nE "$danger_pattern" "$file" 2>/dev/null \
        | grep -vcE "$comment_prefix" 2>/dev/null || true)"
  [[ -z "$n" ]] && n=0
  printf '%s\n' "$n"
}

list_sites() {
  local file="$1"
  grep -nE "$danger_pattern" "$file" 2>/dev/null \
    | grep -vE "$comment_prefix" || true
}

run_self_test() {
  local fixture
  fixture="$(mktemp)"
  trap 'rm -f "$fixture"' RETURN

  cat >"$fixture" <<'FIXTURE'
# Comment line that mentions python3 - <<'PY' should NOT match.
  # Indented comment with bash -s -- <<'EOF' should NOT match.
# Comment with nested $(python3 - <<PY) should NOT match either.
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
nested="$(other "$(bar)" | python3 - "$payload" <<'PY')"
backtick=`python3 - "$payload" <<'PY'`
echo "doc string with python3 - <<PY embedded" >/dev/null
echo done
true
FIXTURE

  # 18 positives: every non-comment line containing the danger pattern.
  # Includes broad-match positives — nested $(), backtick wrapper, and the
  # doc-string literal — to make the broad-match contract explicit.
  # 5 negatives: 3 comment lines + 2 trailing no-ops.
  local expected=18
  local got
  got="$(count_sites "$fixture")"

  if [[ "$got" != "$expected" ]]; then
    echo "[lint-heredoc-ban] SELF-TEST FAIL: expected $expected matches, got $got" >&2
    echo "[lint-heredoc-ban] matches:" >&2
    list_sites "$fixture" | sed 's/^/[lint-heredoc-ban]   /' >&2
    return 1
  fi

  local comment_hits
  comment_hits="$(list_sites "$fixture" | grep -cE "$comment_prefix" || true)"
  if [[ "${comment_hits:-0}" != "0" ]]; then
    echo "[lint-heredoc-ban] SELF-TEST FAIL: $comment_hits comment-prefixed line(s) matched (must be 0):" >&2
    list_sites "$fixture" | grep -E "$comment_prefix" | sed 's/^/[lint-heredoc-ban]   /' >&2
    return 1
  fi

  echo "[lint-heredoc-ban] SELF-TEST PASS: $got positives caught (broad-match across all wrapper shapes), 0 comment-line false positives."
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
  list_sites "$target_file"
  echo
  echo "(ceiling: $ceiling)"
  exit 0
fi

count="$(count_sites "$target_file")"

if [[ "$count" -gt "$ceiling" ]]; then
  echo "[lint-heredoc-ban] FAIL: bridge-upgrade.sh has $count heredoc-stdin subprocess sites, exceeding the ceiling ($ceiling)." >&2
  echo "[lint-heredoc-ban] This lint ratchets footgun #11 carry-over. New heredoc-stdin sites must be" >&2
  echo "[lint-heredoc-ban] extracted to lib/upgrade-helpers/ (see existing examples)." >&2
  echo "[lint-heredoc-ban]" >&2
  echo "[lint-heredoc-ban] Detected sites:" >&2
  list_sites "$target_file" | sed 's/^/[lint-heredoc-ban]   /' >&2
  exit 1
fi

if [[ "$count" -lt "$ceiling" ]]; then
  echo "[lint-heredoc-ban] note: count=$count is below ceiling=$ceiling. Consider lowering the ceiling in scripts/lint-heredoc-ban.sh to ratchet."
fi

echo "[lint-heredoc-ban] PASS: count=$count, ceiling=$ceiling"
exit 0
