#!/usr/bin/env bash
# scripts/lint-heredoc-ban.sh — ratchet lint preventing NEW heredoc-stdin
# subprocess sites in footgun-#11-prone files (currently bridge-upgrade.sh,
# bridge-agent.sh, bridge-daemon.sh, and lib/bridge-cron.sh).
#
# Context: footgun #11 (Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock
# chain — fixed in v0.13.7 through v0.13.9 for the upgrader and refs #4773
# for the agent CLI). Six leap-path upgrader sites were extracted to
# standalone helpers under lib/upgrade-helpers/; 18 off-leap sites remain
# in bridge-upgrade.sh deferred to the S10-late stabilization wave. For
# bridge-agent.sh, the three nested-$() heredoc-stdin sites in
# run_list/run_registry/run_show were migrated to file-as-argv (operator
# host hangs of 7-17 hours triaged in queue task #4773); 9 single-level
# heredoc-stdin sites remain. Queue task #4807 then extracted every
# heredoc-stdin site in bridge-daemon.sh (7 sites → lib/daemon-helpers/)
# and lib/bridge-cron.sh (13 sites → lib/cron-helpers/) after the
# operator host accumulated 7 zombie daemon processes plus two
# cron-workers hung 13h on the same task id. This lint ratchets each
# count downward — it fails CI if anyone introduces a NEW heredoc-stdin
# subprocess line in any tracked file without first migrating an
# existing one out.
#
# Ratchet semantics:
# - BRIDGE_UPGRADE_HEREDOC_CEILING (default 18) — bridge-upgrade.sh.
# - BRIDGE_AGENT_HEREDOC_CEILING   (default  9) — bridge-agent.sh.
# - BRIDGE_DAEMON_HEREDOC_CEILING  (default  0) — bridge-daemon.sh.
# - BRIDGE_CRON_HEREDOC_CEILING    (default  0) — lib/bridge-cron.sh.
# - When stabilization migrates more sites, the ceilings drop to the new
#   counts via PR that updates this script's defaults.
# - PRs that add new heredoc-stdin without removing one push count over
#   the ceiling and fail this lint.
#
# Contract — broad-match:
#   A "site" is any non-comment line in a target file that contains a
#   heredoc-fed `bash -s ...` or `python3 - ...` subprocess on the same
#   line — i.e., the sub-pattern
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
#   scripts/lint-heredoc-ban.sh                  # legacy per-file ceiling check (default)
#   scripts/lint-heredoc-ban.sh --list           # list all detected sites in every target
#   scripts/lint-heredoc-ban.sh --self-test      # verify pattern against fixtures
#   BRIDGE_UPGRADE_HEREDOC_CEILING=10 ...        # override bridge-upgrade.sh ceiling
#   BRIDGE_AGENT_HEREDOC_CEILING=8 ...           # override bridge-agent.sh ceiling
#   BRIDGE_DAEMON_HEREDOC_CEILING=1 ...          # override bridge-daemon.sh ceiling
#   BRIDGE_CRON_HEREDOC_CEILING=1 ...            # override lib/bridge-cron.sh ceiling
#
# Phase 1 baseline ratchet (footgun #11):
#   scripts/lint-heredoc-ban.sh --baseline-check  # category-aware ratchet against
#                                                   .lint-heredoc-baseline.tsv. Fails
#                                                   on any C1/C2/C3/C4/H3 site whose
#                                                   snippet hash is not in the
#                                                   baseline, or on a site whose
#                                                   category changed since the
#                                                   baseline (e.g. a previously C3
#                                                   site that got wrapped in $()).
#   scripts/lint-heredoc-ban.sh --baseline-update # regenerate baseline TSV from
#                                                   current tree (drops removed
#                                                   sites, keeps reason/owner/phase
#                                                   columns for matched hashes).
#                                                   Hand-review the diff and fill
#                                                   metadata for new rows before
#                                                   committing — silent acceptance
#                                                   is prohibited.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Target files + their per-file ceiling env var name + default. Adding a
# new target is a 1-line append. Each target is checked independently.
declare -a TARGETS=(
  "bridge-upgrade.sh:BRIDGE_UPGRADE_HEREDOC_CEILING:18"
  "bridge-agent.sh:BRIDGE_AGENT_HEREDOC_CEILING:9"
  "bridge-daemon.sh:BRIDGE_DAEMON_HEREDOC_CEILING:0"
  "lib/bridge-cron.sh:BRIDGE_CRON_HEREDOC_CEILING:0"
)

# Core danger pattern. Anchored to "command name + space + heredoc op + tag",
# but NOT anchored to start-of-line — so wrapper shape is irrelevant.
#
# r4 (codex integration review #5818): extended to catch bare
# `bash <<TAG` (no `-s` flag) which slipped past the scanner in
# scripts/smoke/1121-agent-delete-os-purge.sh. The two sub-patterns:
#   - `bash -s ... <<EOF|<<PY` — original wave-pinned shape
#   - `python3 - ... <<EOF|<<PY` — original
#   - `bash[[:space:]]*<<TAG` — bare bash heredoc-stdin (catches `bash <<PROBE`).
#     Tag must be uppercase identifier so `bash << EOF` and quoted variants
#     all match, but `cat > file <<TAG` (write-to-file, safe) does NOT match.
danger_pattern='(bash[[:space:]]+-s|python3[[:space:]]+-)[[:space:]].*<<-?["'"'"']?(EOF|PY)["'"'"']?|bash[[:space:]]+<<-?[[:space:]]*["'"'"']?[A-Z_][A-Z0-9_]+["'"'"']?'

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
# r2 (codex integration review #5818): bare `bash <<TAG` positives —
# new sub-pattern catches the heredoc-stdin-to-bash shape that earlier
# slipped past the `bash -s` requirement.
bash <<PROBE
bash <<'PROBE'
out=$(bash <<PROBE)
bash << PROBE
bash << "PROBE"
echo done
true
FIXTURE

  # 23 positives: every non-comment line containing the danger pattern.
  # Includes broad-match positives — nested $(), backtick wrapper, the
  # doc-string literal, three bare `bash <<TAG` positives (r2 #5818),
  # AND two `bash << TAG` (whitespace between op + tag) positives
  # (r3 #5825).
  local expected=23
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

# ---------------------------------------------------------------------------
# Phase 1 baseline ratchet (footgun #11). Category-aware, snippet-hash
# anchored. Identity column is snippet_hash (normalized SHA-256), so the
# baseline survives line-number drift and indentation reformatting.
#
# Baseline file: .lint-heredoc-baseline.tsv
# Schema:
#   path<TAB>line<TAB>category<TAB>snippet_hash<TAB>reason<TAB>owner<TAB>expires_or_phase
#
# The Python helpers are invoked file-as-argv (lib/lint-helpers/*.py) — never
# via heredoc-stdin — so this lint can never trip the very bug it is
# guarding against.
# ---------------------------------------------------------------------------

baseline_file_default="$repo_root/.lint-heredoc-baseline.tsv"
audit_script="$repo_root/scripts/audit-footgun-11.sh"
baseline_check_py="$repo_root/lib/lint-helpers/baseline-check.py"
baseline_update_py="$repo_root/lib/lint-helpers/baseline-update.py"

run_baseline_check() {
  local baseline_file="${BRIDGE_LINT_BASELINE_FILE:-$baseline_file_default}"

  if [[ ! -x "$audit_script" ]]; then
    echo "[lint-heredoc-ban] FAIL: audit script missing or non-executable: $audit_script" >&2
    return 2
  fi
  if [[ ! -f "$baseline_check_py" ]]; then
    echo "[lint-heredoc-ban] FAIL: helper missing: $baseline_check_py" >&2
    return 2
  fi
  if [[ ! -f "$baseline_file" ]]; then
    echo "[lint-heredoc-ban] FAIL: baseline file missing: $baseline_file" >&2
    echo "[lint-heredoc-ban] Run: scripts/lint-heredoc-ban.sh --baseline-update" >&2
    return 2
  fi

  local current_tsv
  current_tsv="$(mktemp)"
  # shellcheck disable=SC2064  # path captured at trap-set time on purpose
  trap "rm -f '$current_tsv'" RETURN

  if ! "$audit_script" --tsv > "$current_tsv"; then
    echo "[lint-heredoc-ban] FAIL: audit script returned non-zero" >&2
    return 2
  fi

  python3 "$baseline_check_py" "$current_tsv" "$baseline_file"
}

run_baseline_update() {
  local baseline_file="${BRIDGE_LINT_BASELINE_FILE:-$baseline_file_default}"

  if [[ ! -x "$audit_script" ]]; then
    echo "[lint-heredoc-ban] FAIL: audit script missing or non-executable: $audit_script" >&2
    return 2
  fi
  if [[ ! -f "$baseline_update_py" ]]; then
    echo "[lint-heredoc-ban] FAIL: helper missing: $baseline_update_py" >&2
    return 2
  fi

  local current_tsv
  current_tsv="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$current_tsv'" RETURN

  if ! "$audit_script" --tsv > "$current_tsv"; then
    echo "[lint-heredoc-ban] FAIL: audit script returned non-zero" >&2
    return 2
  fi

  if ! python3 "$baseline_update_py" "$current_tsv" "$baseline_file"; then
    echo "[lint-heredoc-ban] FAIL: baseline-update helper returned non-zero" >&2
    return 2
  fi

  echo "[lint-heredoc-ban] baseline updated: $baseline_file"
  echo "[lint-heredoc-ban] Review the diff and fill owner / expires_or_phase columns for new rows."
}

case "${1:-}" in
  --baseline-check)
    run_baseline_check
    exit $?
    ;;
  --baseline-update)
    run_baseline_update
    exit $?
    ;;
esac

mode="check"
if [[ "${1:-}" == "--list" ]]; then
  mode="list"
fi

overall_rc=0
for spec in "${TARGETS[@]}"; do
  rel_path="${spec%%:*}"
  rest="${spec#*:}"
  env_var="${rest%%:*}"
  default_ceiling="${rest#*:}"
  target_file="$repo_root/$rel_path"

  # Resolve the ceiling via indirect expansion so we honor per-file env
  # overrides without listing every var name here.
  ceiling="${!env_var:-$default_ceiling}"

  if [[ ! -f "$target_file" ]]; then
    echo "[lint-heredoc-ban] target file missing: $target_file" >&2
    overall_rc=2
    continue
  fi

  if [[ "$mode" == "list" ]]; then
    echo "== $rel_path (ceiling: $ceiling, env: $env_var) =="
    list_sites "$target_file"
    echo
    continue
  fi

  count="$(count_sites "$target_file")"

  if [[ "$count" -gt "$ceiling" ]]; then
    echo "[lint-heredoc-ban] FAIL: $rel_path has $count heredoc-stdin subprocess sites, exceeding the ceiling ($ceiling)." >&2
    echo "[lint-heredoc-ban] This lint ratchets footgun #11 carry-over. New heredoc-stdin sites must be" >&2
    echo "[lint-heredoc-ban] extracted to lib/upgrade-helpers/ (see existing examples) or spooled to a tempfile" >&2
    echo "[lint-heredoc-ban] (file-as-argv, see PR #937 status-print pattern)." >&2
    echo "[lint-heredoc-ban]" >&2
    echo "[lint-heredoc-ban] Detected sites in $rel_path:" >&2
    list_sites "$target_file" | sed 's/^/[lint-heredoc-ban]   /' >&2
    overall_rc=1
    continue
  fi

  if [[ "$count" -lt "$ceiling" ]]; then
    echo "[lint-heredoc-ban] note: $rel_path count=$count is below ceiling=$ceiling. Consider lowering the $env_var default in scripts/lint-heredoc-ban.sh to ratchet."
  fi

  echo "[lint-heredoc-ban] PASS: $rel_path count=$count, ceiling=$ceiling"
done

exit "$overall_rc"
