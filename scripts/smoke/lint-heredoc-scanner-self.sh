#!/usr/bin/env bash
# scripts/smoke/lint-heredoc-scanner-self.sh — taxonomic self-tests for
# scripts/audit-footgun-11.sh and scripts/lint-heredoc-ban.sh --baseline-check.
#
# Covers the full footgun #11 taxonomy described in audit-footgun-11.sh:
#   C1, C2, C3, C4, H3, SAFE — plus comment-line negatives and the
#   reformatting-invariance of snippet_hash.
#
# The fixture is a synthetic shell file we generate into a tempdir, then
# we run the audit script against it and assert per-line classifications.
# We DO NOT scan the real tree here — that's the job of scripts/oss-preflight.sh
# (legacy ceiling) and the lint-heredoc-ban CI job (baseline ratchet).
#
# This smoke is in the modular smoke matrix so that any regression in
# scanner logic is caught before it can wedge the production baseline.
#
# Run:
#   bash scripts/smoke/lint-heredoc-scanner-self.sh
#
# CI: included in scripts/ci-select-smoke.sh once audit/lint code changes.

set -euo pipefail

SMOKE_NAME="lint-heredoc-scanner-self"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
AUDIT="$REPO_ROOT/scripts/audit-footgun-11.sh"
LINT="$REPO_ROOT/scripts/lint-heredoc-ban.sh"

# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

[[ -x "$AUDIT" ]] || smoke_fail "audit script missing or non-executable: $AUDIT"
[[ -x "$LINT"  ]] || smoke_fail "lint script missing or non-executable: $LINT"

# ---------------------------------------------------------------------------
# Fixture files. Each non-comment line is labelled in a trailing comment for
# the human reader; the assertions below compare against expected category
# at each line number.
#
# The fixtures are CHECKED IN under scripts/smoke/lint-heredoc-fixtures/ and
# copied into the temp tree here (NOT generated via heredoc). Generating
# them via `cat <<'FIXTURE'` would wedge on Bash 5.3.9 — the exact footgun
# this test is guarding against — because the fixture body contains every
# C1/C2/C3/C4/H3 shape we want to classify (r2 fix for codex PR #954 r1
# finding P1 #2). The audit script skips scripts/smoke/lint-heredoc-fixtures/
# explicitly so the checked-in fixtures do not pollute the real baseline.
#
# fixture.sh is STATIC TEXT — never executed. The r5 P2 shape near the
# bottom (heredoc inside `$(case ... in arm) ... ;; esac)`) is not
# parseable by Bash 3.2 (`bash -n` errors on macOS stock bash) but
# parses cleanly under Bash 4+, which the audit requires. Do not "fix"
# this for Bash 3.2 — the parser shape IS the regression the fixture
# exercises.
# ---------------------------------------------------------------------------

FIXTURES_SRC="$REPO_ROOT/scripts/smoke/lint-heredoc-fixtures"
[[ -d "$FIXTURES_SRC" ]] || smoke_fail "fixture source dir missing: $FIXTURES_SRC"
[[ -f "$FIXTURES_SRC/fixture.sh" ]] || smoke_fail "fixture.sh missing"
[[ -f "$FIXTURES_SRC/fixture-reformat-a.sh" ]] || smoke_fail "fixture-reformat-a.sh missing"
[[ -f "$FIXTURES_SRC/fixture-reformat-b.sh" ]] || smoke_fail "fixture-reformat-b.sh missing"

fixture_dir="$SMOKE_TMP_ROOT/fixture-repo"
mkdir -p "$fixture_dir/scripts"
cd "$fixture_dir"
git init -q .
git config user.email "smoke@example.test"
git config user.name "smoke"

cp "$FIXTURES_SRC/fixture.sh" scripts/fixture.sh
git add -A
git commit -qm "fixture"

# Sanity: the fixture's line numbers must match the assertions below.
fixture_audit_root="$fixture_dir"

run_audit_against_fixture() {
  # Trick: audit script roots itself at the parent of its own dirname.
  # We can't move it, so we run it with an env override that asks it to
  # scan a tmp git tree. The current audit script uses `git ls-files`
  # inside its own repo_root, so for the smoke we copy it INTO the
  # fixture repo and run from there.
  cp "$AUDIT" "$fixture_dir/scripts/audit-footgun-11.sh"
  chmod +x "$fixture_dir/scripts/audit-footgun-11.sh"
  # Add to fixture's git so git ls-files sees it; but the audit script
  # skips its own path, so we won't get its own self-reference in output.
  ( cd "$fixture_dir" && git add scripts/audit-footgun-11.sh && git commit -qm "audit" )
  "$fixture_dir/scripts/audit-footgun-11.sh" --tsv
}

audit_tsv="$SMOKE_TMP_ROOT/audit.tsv"
run_audit_against_fixture > "$audit_tsv"

smoke_log "fixture audit produced $(wc -l < "$audit_tsv") row(s) (incl header)"

# Helper: assert classification at line N matches expected category.
expect_at() {
  local lineno="$1" expected_cat="$2" label="$3"
  local got
  got="$(awk -F'\t' -v ln="$lineno" '$1=="scripts/fixture.sh" && $2==ln {print $3; exit}' "$audit_tsv")"
  [[ -n "$got" ]] || smoke_fail "$label: no audit row at scripts/fixture.sh line $lineno"
  smoke_assert_eq "$expected_cat" "$got" "$label (line $lineno)"
}

# Helper: assert no audit row at line N (negative case for comments etc).
expect_none_at() {
  local lineno="$1" label="$2"
  local got
  got="$(awk -F'\t' -v ln="$lineno" '$1=="scripts/fixture.sh" && $2==ln {print $3}' "$audit_tsv")"
  [[ -z "$got" ]] || smoke_fail "$label: expected no audit row at line $lineno, got '$got'"
}

# Comment-only lines (2, 3) — negative.
expect_none_at  2  "comment with bash -s heredoc-literal must NOT match"
expect_none_at  3  "comment with python3 nested-\$ heredoc-literal must NOT match"

# C3 — single-quoted PY.
expect_at  6  C3  "C3 single-quoted PY"

# C3 — tab-strip <<-PY.
expect_at 11  C3  "C3 tab-strip <<-PY"

# C3 — arbitrary delimiter MARKER.
expect_at 16  C3  "C3 arbitrary delimiter"

# C4 — bash -s heredoc.
expect_at 21  C4  "C4 bash -s heredoc"

# C1 — nested \$() with python3.
expect_at 26  C1  "C1 nested \$() with python3"

# C1 — env-prefixed inside \$().
expect_at 32  C1  "C1 env-prefixed inside \$()"

# C1 — pipe-then-capture.
expect_at 38  C1  "C1 pipe-then-capture"

# C1 — backtick wrapper.
expect_at 44  C1  "C1 backtick wrapper"

# C2 — cat heredoc inside \$().
expect_at 49  C2  "C2 cat heredoc inside \$()"

# SAFE — cat > path heredoc.
expect_at 55  SAFE "SAFE cat > path heredoc"
# SAFE — top-level cat heredoc.
expect_at 60  SAFE "SAFE top-level cat heredoc"
# SAFE — redirect to stderr.
expect_at 65  SAFE "SAFE cat > /dev/stderr heredoc"

# H3 — here-string into read.
expect_at 70  H3   "H3 here-string into read"
# H3 — here-string into python3 (interpreter consumer flag).
expect_at 73  H3   "H3 here-string into interpreter"
# H3 — process substitution.
expect_at 76  H3   "H3 process substitution"

# C3 — heredoc operator with whitespace before delimiter (`<<  'PY'`).
# r3 P2 #2: bash accepts whitespace; the audit must match it.
expect_at 81  C3   "C3 whitespace before delimiter"

# C1 — cross-line capture (`\$(` opens, continuation lines, heredoc inside).
# r3 P1: classifier must carry capture state across lines so the heredoc
# on a continuation line is recognized as in-capture.
expect_at 92  C1   "C1 cross-line \$() capture"

# C1 — cross-line backtick wrapper variant.
expect_at 99  C1   "C1 cross-line backtick capture"

# r5 P2 — case-arm `pattern)` INSIDE an already-open `$()` capture.
# This is the configuration that actually requires maybe_strip_case_arm
# to run: without the strip, the case-arm `)` pops the 'C' frame the
# outer `$(` pushed, the heredoc's entry_capture becomes 0, and the
# heredoc mis-classifies as C3 — bypassing the CI ratchet (codex PR
# #954 r3 P1 BLOCKING). r4's earlier shape put the case-arm BEFORE
# `out=$(` opened, so the heredoc's entry_capture was set by the
# inner `$(` regardless and the regression wasn't actually exercised
# (codex PR #954 r4 P2 finding #5). r5 restructures: outer `$(` opens
# first, then `case`, then `active)`, then the heredoc inside.
expect_at 120 C1   "C1 case-arm inside open \$() (r5 P2)"

# r5 P2 verification hook: rerun the audit with the debug counter env
# var set, and assert the case-arm stripper actually fired on the
# fixture. The expect_at above is the live classification witness; this
# is the orthogonal "the strip ran in real code" assertion the brief
# called out, so a future regression that silently no-ops the stripper
# (e.g. a future commit gates it more aggressively) would fail this
# even before the classification regression surfaces.
fires_stderr="$SMOKE_TMP_ROOT/audit-fires.stderr"
BRIDGE_AUDIT_DEBUG_CASE_ARM=1 "$fixture_dir/scripts/audit-footgun-11.sh" --summary \
  >/dev/null 2>"$fires_stderr"
fires_count="$(grep -oE 'STRIP_CASE_ARM_FIRES=[0-9]+' "$fires_stderr" | cut -d= -f2 | head -1)"
[[ -n "$fires_count" ]] \
  || smoke_fail "STRIP_CASE_ARM_FIRES not emitted by audit --summary under BRIDGE_AUDIT_DEBUG_CASE_ARM=1"
(( fires_count > 0 )) \
  || smoke_fail "STRIP_CASE_ARM_FIRES=0 — maybe_strip_case_arm did NOT fire on the fixture scan, the strip is silently no-op'd"
smoke_log "STRIP_CASE_ARM_FIRES=$fires_count on fixture scan (case-arm strip ran)"

# ---------------------------------------------------------------------------
# Snippet-hash stability under reformatting. Reformatted_pair() generates
# two snippets that should be semantically equal (only whitespace differs)
# and asserts identical SHA-256 in the audit output.
# ---------------------------------------------------------------------------

cp "$FIXTURES_SRC/fixture-reformat-a.sh" scripts/fixture-reformat-a.sh
cp "$FIXTURES_SRC/fixture-reformat-b.sh" scripts/fixture-reformat-b.sh

( cd "$fixture_dir" && git add -A && git commit -qm "reformat fixtures" )

audit_tsv2="$SMOKE_TMP_ROOT/audit2.tsv"
"$fixture_dir/scripts/audit-footgun-11.sh" --tsv > "$audit_tsv2"

hash_a="$(awk -F'\t' '$1=="scripts/fixture-reformat-a.sh" && $3=="C1" {print $4; exit}' "$audit_tsv2")"
hash_b="$(awk -F'\t' '$1=="scripts/fixture-reformat-b.sh" && $3=="C1" {print $4; exit}' "$audit_tsv2")"
smoke_assert_eq "$hash_a" "$hash_b" "snippet_hash stable across whitespace reformatting"

# ---------------------------------------------------------------------------
# JSON mode emits valid JSON-per-line and the same hash anchor.
# ---------------------------------------------------------------------------

audit_json="$SMOKE_TMP_ROOT/audit.jsonl"
"$fixture_dir/scripts/audit-footgun-11.sh" --json > "$audit_json"
# Call validator file-as-argv (NOT heredoc-stdin) — see lib/lint-helpers/validate-jsonl.py.
# Keeps this smoke immune to the very bug it is guarding against (footgun #11).
python3 "$REPO_ROOT/lib/lint-helpers/validate-jsonl.py" "$audit_json" \
  path line category snippet_hash reason snippet

# ---------------------------------------------------------------------------
# Summary mode prints all 6 category counters.
# ---------------------------------------------------------------------------

summary_out="$("$fixture_dir/scripts/audit-footgun-11.sh" --summary)"
for cat in C1 C2 C3 C4 H3 SAFE TOTAL; do
  smoke_assert_contains "$summary_out" "$cat" "summary contains $cat row"
done

# ---------------------------------------------------------------------------
# baseline-check.py occurrence-count ratchet (r3 P2 #1).
#
# If a file has ONE baselined `python3 - <<'PY'` site and someone copies
# the same opener to add a SECOND identical line, the (path, hash) presence
# check alone would treat the copy as already accepted. The fix tracks
# OCCURRENCE COUNTS per (path, hash, category) and reports overflow as a
# new site that needs review.
#
# Test fixtures are written via printf — NOT heredoc — to keep this smoke
# immune to Bash 5.3.9 footgun #11 (the very class the lint guards).
# ---------------------------------------------------------------------------

baseline_helper="$REPO_ROOT/lib/lint-helpers/baseline-check.py"
overflow_tsv_baseline="$SMOKE_TMP_ROOT/overflow-baseline.tsv"
overflow_tsv_current_ok="$SMOKE_TMP_ROOT/overflow-current-ok.tsv"
overflow_tsv_current_dup="$SMOKE_TMP_ROOT/overflow-current-dup.tsv"

printf 'path\tline\tcategory\tsnippet_hash\treason\towner\texpires_or_phase\n' \
  >"$overflow_tsv_baseline"
printf 'fake.sh\t10\tC3\tabc123\tsmoke\ttest\ttest\n' \
  >>"$overflow_tsv_baseline"

printf 'path\tline\tcategory\tsnippet_hash\treason\tsnippet\n' \
  >"$overflow_tsv_current_ok"
printf "fake.sh\t10\tC3\tabc123\tsmoke\tpython3 - <<'PY'\n" \
  >>"$overflow_tsv_current_ok"

printf 'path\tline\tcategory\tsnippet_hash\treason\tsnippet\n' \
  >"$overflow_tsv_current_dup"
printf "fake.sh\t10\tC3\tabc123\tsmoke\tpython3 - <<'PY'\n" \
  >>"$overflow_tsv_current_dup"
printf "fake.sh\t20\tC3\tabc123\tsmoke\tpython3 - <<'PY'\n" \
  >>"$overflow_tsv_current_dup"

set +e
python3 "$baseline_helper" "$overflow_tsv_current_ok" "$overflow_tsv_baseline" >/dev/null 2>&1
overflow_ok_rc=$?
python3 "$baseline_helper" "$overflow_tsv_current_dup" "$overflow_tsv_baseline" >/dev/null 2>&1
overflow_dup_rc=$?
set -e

smoke_assert_eq 0 "$overflow_ok_rc" "baseline-check: 1 baseline + 1 current = PASS"
smoke_assert_eq 1 "$overflow_dup_rc" "baseline-check: 1 baseline + 2 copies = FAIL (copy-paste overflow caught)"

# ---------------------------------------------------------------------------
# r4 P2 #2: deletion drift detection. If baseline accounts for MORE
# occurrences than current scan finds, the stale capacity could silently
# absorb a newly added copy of the same opener in a later PR. Force the
# contributor to run --baseline-update so the TSV always matches reality.
# ---------------------------------------------------------------------------

deletion_tsv_baseline="$SMOKE_TMP_ROOT/deletion-baseline.tsv"
deletion_tsv_current="$SMOKE_TMP_ROOT/deletion-current.tsv"

# Baseline records 2 occurrences of (fake.sh, hash=abc123, C3).
printf 'path\tline\tcategory\tsnippet_hash\treason\towner\texpires_or_phase\n' \
  >"$deletion_tsv_baseline"
printf 'fake.sh\t10\tC3\tabc123\tsmoke\ttest\ttest\n' \
  >>"$deletion_tsv_baseline"
printf 'fake.sh\t20\tC3\tabc123\tsmoke\ttest\ttest\n' \
  >>"$deletion_tsv_baseline"

# Current scan only finds 1 occurrence — site was deleted but baseline
# still has capacity for 2.
printf 'path\tline\tcategory\tsnippet_hash\treason\tsnippet\n' \
  >"$deletion_tsv_current"
printf "fake.sh\t10\tC3\tabc123\tsmoke\tpython3 - <<'PY'\n" \
  >>"$deletion_tsv_current"

set +e
python3 "$baseline_helper" "$deletion_tsv_current" "$deletion_tsv_baseline" >/dev/null 2>&1
deletion_rc=$?
set -e

smoke_assert_eq 1 "$deletion_rc" "baseline-check: 2 baseline + 1 current = FAIL (stale capacity caught — r4 P2 #2)"

smoke_log "ALL TESTS PASSED"
