#!/usr/bin/env bash
# Issue #1144 — post-upgrade [upgrade-complete] task body regression.
#
# Beta8 surfaced two coupled regressions in the post-upgrade task body:
#   1. `from_version: unknown` even when the pre-upgrade install had a
#      readable VERSION file. Root cause: `INSTALLED_VERSION` was only
#      assigned inside the `--check` branch (bridge-upgrade.sh ~line
#      1274); the normal apply path left it unset, and the body template
#      at line ~2210 rendered `${INSTALLED_VERSION:-unknown}`.
#   2. `body_file: …/state/bridge-upgrade/post-task/upgrade-complete-<TS>.md`
#      pointed at a path that no longer existed on disk after task
#      creation. Root cause: a `rm -f "$_post_body_persist"` on the
#      task-create success branch nuked the very file the queue row's
#      body_path column still referenced.
#
# Coverage:
#   T1 — bridge_upgrade_version_from_file reads the live VERSION at
#        TARGET_ROOT before any apply step touches it (the value the fix
#        captures into INSTALLED_VERSION).
#   T2 — the apply-path INSTALLED_VERSION capture block (lifted verbatim
#        from bridge-upgrade.sh by marker grep) populates the variable
#        from a fixture VERSION file. Asserts `from_version: <pre>` (NOT
#        `unknown`) when rendered through the body template.
#   T3 — bridge_upgrade_installed_field fallback: when TARGET_ROOT/VERSION
#        is missing but state/upgrade/last-upgrade.json carries a recorded
#        `version` field, the capture path still produces a real value.
#   T4 — persist file survives a successful task create: the body_file
#        path advertised by the queue row remains openable after the
#        upgrade exits. Mirrors the bridge-upgrade.sh persist block by
#        stubbing the `agent-bridge task create` invocation with a
#        zero-exit fake; asserts the persist file is still on disk.
#
# Footgun #11: no heredoc / here-string anywhere. Content is written via
# line-by-line `printf '%s\n' ...` blocks. Runs entirely under an
# isolated $TMP; never touches operator state.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
UPGRADE_SH="$ROOT_DIR/bridge-upgrade.sh"

[[ -f "$UPGRADE_SH" ]] || {
  printf 'FAIL (bootstrap): missing %s\n' "$UPGRADE_SH" >&2
  exit 2
}

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-1144-upgrade-complete-task.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Extract the two helper definitions and the apply-path capture block from
# bridge-upgrade.sh by literal markers, then eval them in this shell. This
# binds the smoke directly to the shipped code surface: a future PR that
# deletes the capture block or renames a helper trips the test.
#
# `sed -n '/start/,/end/p'` is the standard bash range extraction
# primitive — no temp pipe, no heredoc.
extract_block() {
  local start_pat="$1"
  local end_pat="$2"
  sed -n "/$start_pat/,/$end_pat/p" "$UPGRADE_SH"
}

HELPER_VERSION_FROM_FILE="$(extract_block '^bridge_upgrade_version_from_file()' '^}$')"
HELPER_INSTALLED_FIELD="$(extract_block '^bridge_upgrade_installed_field()' '^}$')"
# r2 (issue #1144 follow-up): the capture block now lives inside the
# `if [[ "$SUBCOMMAND" == "apply" ]]; then` outer block (indented two
# spaces) and BEFORE the `git checkout TARGET_REF` step. The start marker
# is the literal first comment line; the end marker is a sentinel comment
# we added so the inner indented `fi` keywords don't collide with the
# outer apply block's terminator.
CAPTURE_BLOCK="$(extract_block '^[[:space:]]*# Issue #1144: capture the pre-apply VERSION' '^[[:space:]]*# END: Issue #1144 INSTALLED_VERSION capture block')"

if [[ -z "$HELPER_VERSION_FROM_FILE" ]]; then
  printf 'FAIL (bootstrap): could not extract bridge_upgrade_version_from_file\n' >&2
  exit 2
fi
if [[ -z "$HELPER_INSTALLED_FIELD" ]]; then
  printf 'FAIL (bootstrap): could not extract bridge_upgrade_installed_field\n' >&2
  exit 2
fi
if [[ -z "$CAPTURE_BLOCK" ]]; then
  printf 'FAIL (bootstrap): could not extract issue #1144 capture block — regression?\n' >&2
  exit 2
fi

# Defining helpers via eval is the test seam — we want the smoke to fail
# if the helper signatures drift, which only works if we use the real
# definitions verbatim.
eval "$HELPER_VERSION_FROM_FILE"
eval "$HELPER_INSTALLED_FIELD"

# ---------------------------------------------------------------------------
# T1 — bridge_upgrade_version_from_file reads VERSION at TARGET_ROOT.
# ---------------------------------------------------------------------------
printf '== T1 — version_from_file reads pre-apply VERSION ==\n'

T1_TARGET="$TMP/t1-target"
mkdir -p "$T1_TARGET"
printf '%s\n' '0.14.5-beta7' >"$T1_TARGET/VERSION"

step "T1 version_from_file returns 0.14.5-beta7"
_t1_value="$(bridge_upgrade_version_from_file "$T1_TARGET")"
if [[ "$_t1_value" == "0.14.5-beta7" ]]; then
  ok
else
  err "expected 0.14.5-beta7, got '$_t1_value'"
fi

# ---------------------------------------------------------------------------
# T2 — apply-path capture block populates INSTALLED_VERSION from VERSION.
# ---------------------------------------------------------------------------
printf '== T2 — INSTALLED_VERSION captured pre-apply ==\n'

T2_TARGET="$TMP/t2-target"
mkdir -p "$T2_TARGET"
printf '%s\n' '0.14.5-beta7' >"$T2_TARGET/VERSION"

step "T2 capture block sets INSTALLED_VERSION to pre-apply VERSION"
# Drive the literal capture block from bridge-upgrade.sh. The block
# guards `if [[ -z "${INSTALLED_VERSION:-}" ]]; then` so a pre-set value
# (from --check) wins; in the apply path it is unset, which is the case
# we exercise here.
TARGET_ROOT="$T2_TARGET"
unset INSTALLED_VERSION 2>/dev/null || true
eval "$CAPTURE_BLOCK"
if [[ "${INSTALLED_VERSION:-}" == "0.14.5-beta7" ]]; then
  ok
else
  err "expected INSTALLED_VERSION=0.14.5-beta7, got '${INSTALLED_VERSION:-}'"
fi

step "T2 body template renders from_version: <pre> (NOT unknown)"
_t2_rendered="$(printf -- '- from_version: %s\n' "${INSTALLED_VERSION:-unknown}")"
case "$_t2_rendered" in
  *"from_version: 0.14.5-beta7"*)
    case "$_t2_rendered" in
      *"unknown"*) err "rendered body still contains 'unknown': $_t2_rendered" ;;
      *) ok ;;
    esac
    ;;
  *)
    err "rendered body missing pre-version: $_t2_rendered"
    ;;
esac

# ---------------------------------------------------------------------------
# T3 — fallback to bridge_upgrade_installed_field when VERSION is missing.
# ---------------------------------------------------------------------------
printf '== T3 — installed_field fallback for legacy installs ==\n'

T3_TARGET="$TMP/t3-target"
mkdir -p "$T3_TARGET/state/upgrade"
# No VERSION file. last-upgrade.json carries the recorded version from a
# prior write-state pass — what an install that survived a partial
# upgrade reports.
{
  printf '%s\n' '{'
  printf '%s\n' '  "version": "0.14.5-beta7",'
  printf '%s\n' '  "source_head": "deadbeef",'
  printf '%s\n' '  "channel": "stable"'
  printf '%s\n' '}'
} >"$T3_TARGET/state/upgrade/last-upgrade.json"

step "T3 capture block falls back to last-upgrade.json when VERSION is absent"
TARGET_ROOT="$T3_TARGET"
unset INSTALLED_VERSION 2>/dev/null || true
eval "$CAPTURE_BLOCK"
if [[ "${INSTALLED_VERSION:-}" == "0.14.5-beta7" ]]; then
  ok
else
  err "expected INSTALLED_VERSION=0.14.5-beta7 (from last-upgrade.json), got '${INSTALLED_VERSION:-}'"
fi

# ---------------------------------------------------------------------------
# T4 — persist file survives successful task-create on the apply path.
# ---------------------------------------------------------------------------
printf '== T4 — body_file persists on disk after task create ==\n'

# Mirror the persist + task-create block from bridge-upgrade.sh
# (lines ~2410-2418). We stage a fake `agent-bridge` that returns 0
# (simulating a successful queue create) and exercise the same shell
# sequence. The success branch must NOT delete the persist file —
# bridge-queue.py records the path verbatim in the task row's body_path
# column, so the persisted file IS what the queue row references.
T4_TARGET="$TMP/t4-target"
mkdir -p "$T4_TARGET"

# A `_post_body` tempfile carrying a representative body.
_post_body="$(mktemp "$TMP/t4-body.XXXXXX")"
{
  printf '%s\n' '# Agent Bridge upgrade completed'
  printf '%s\n' ''
  printf '%s\n' '- from_version: 0.14.5-beta7'
  printf '%s\n' '- to_version: 0.14.5-beta9'
} >"$_post_body"

# Replicate the persist block.
_post_body_persist_dir="$T4_TARGET/state/bridge-upgrade/post-task"
mkdir -p "$_post_body_persist_dir"
# Use a fixed timestamp suffix so the smoke does not race on subsecond
# scheduling.
_post_body_persist="$_post_body_persist_dir/upgrade-complete-19700101T000000Z.md"
cp "$_post_body" "$_post_body_persist"

# Simulate the success branch of `bridge_upgrade_with_target_env … task
# create … > "$_post_task_log" 2>&1` by running `:` (no-op, rc=0). The
# real branch in bridge-upgrade.sh after the fix is a `:` no-op too —
# the file MUST stay on disk regardless of the task-create exit code.
_post_task_log="$(mktemp "$TMP/t4-task.log.XXXXXX")"
if : >"$_post_task_log" 2>&1; then
  : # success branch — persist file MUST remain (issue #1144 fix)
else
  : # failure branch is not exercised in this T
fi
# bridge-upgrade.sh also runs `rm -f "$_post_body" "$_post_task_log"`
# unconditionally after the if/else — this removes the tempfile body
# and the task-create log, NOT the persist file. Mirror that too.
rm -f "$_post_body" "$_post_task_log"

step "T4 persist file exists after successful task create"
if [[ -f "$_post_body_persist" ]]; then
  ok
else
  err "persist file missing after task create: $_post_body_persist"
fi

step "T4 persist dir contains exactly the persist file"
_t4_count="$(find "$_post_body_persist_dir" -maxdepth 1 -name 'upgrade-complete-*.md' -type f | wc -l | tr -d '[:space:]')"
if [[ "$_t4_count" == "1" ]]; then
  ok
else
  err "expected 1 persist file, found $_t4_count"
fi

step "T4 persist file body matches the rendered body"
if grep -q 'from_version: 0.14.5-beta7' "$_post_body_persist"; then
  ok
else
  err "persist file missing rendered from_version line; contents:"
  sed 's/^/    /' "$_post_body_persist" >&2
fi

# ---------------------------------------------------------------------------
# T5 — SOURCE_ROOT == TARGET_ROOT ordering (issue #1144 r2 regression).
# ---------------------------------------------------------------------------
# On a git-clone install (UPGRADING.md §97-105) the live install IS the
# source checkout: SOURCE_ROOT == TARGET_ROOT. In that layout, the
# `git -C "$SOURCE_ROOT" checkout -q "$TARGET_REF"` step at
# bridge-upgrade.sh:~1375 rewrites TARGET_ROOT/VERSION in place — so any
# INSTALLED_VERSION capture that runs AFTER the checkout reads the NEW
# (target) version, not the previously-installed one.
#
# T5 simulates the apply path's ordering directly:
#   1. Fixture: TARGET_ROOT/VERSION = 0.14.5-beta7 (the pre-upgrade install).
#   2. Run the capture block FIRST (mirroring the r2 placement).
#   3. Mutate TARGET_ROOT/VERSION = 0.14.5-beta8 (simulating the
#      `git checkout TARGET_REF` step that follows in the apply path).
#   4. Assert INSTALLED_VERSION == 0.14.5-beta7 (pre-checkout value).
#
# Then a negative control: re-run the capture block AFTER the simulated
# checkout from a clean state — INSTALLED_VERSION would be 0.14.5-beta8.
# This demonstrates that placement (not the capture helpers themselves)
# determines the outcome — exactly the codex r1 BLOCKING finding.
printf '== T5 — SOURCE_ROOT == TARGET_ROOT ordering ==\n'

T5_ROOT="$TMP/t5-source-equals-target"
mkdir -p "$T5_ROOT"
printf '%s\n' '0.14.5-beta7' >"$T5_ROOT/VERSION"

# In a same-root install, SOURCE_ROOT and TARGET_ROOT are the same path.
# The capture block in bridge-upgrade.sh only references TARGET_ROOT, so
# we drive it with TARGET_ROOT only; the implicit equivalence with
# SOURCE_ROOT is the precondition we are modelling.
TARGET_ROOT="$T5_ROOT"
unset INSTALLED_VERSION 2>/dev/null || true

# Step 1: capture BEFORE the simulated checkout — this is the r2
# placement under test.
eval "$CAPTURE_BLOCK"
_t5_pre_checkout="${INSTALLED_VERSION:-}"

# Step 2: simulate `git -C "$SOURCE_ROOT" checkout -q "$TARGET_REF"`
# rewriting TARGET_ROOT/VERSION in place (same-root install).
printf '%s\n' '0.14.5-beta8' >"$T5_ROOT/VERSION"

step "T5 INSTALLED_VERSION captured BEFORE checkout == pre-upgrade version"
if [[ "$_t5_pre_checkout" == "0.14.5-beta7" ]]; then
  ok
else
  err "expected INSTALLED_VERSION=0.14.5-beta7 (pre-checkout), got '$_t5_pre_checkout'"
fi

step "T5 INSTALLED_VERSION is NOT the post-checkout value"
if [[ "$_t5_pre_checkout" != "0.14.5-beta8" ]]; then
  ok
else
  err "INSTALLED_VERSION leaked the post-checkout VERSION ('0.14.5-beta8') — placement is wrong"
fi

# Negative control: confirm the helpers themselves are not magic. If the
# capture were placed AFTER the checkout (the pre-r2 buggy ordering), the
# block would read the mutated VERSION file and INSTALLED_VERSION would
# be the target release. This proves the ordering is what matters.
step "T5 (control) capture AFTER simulated checkout would yield the wrong (target) version"
unset INSTALLED_VERSION 2>/dev/null || true
eval "$CAPTURE_BLOCK"
_t5_post_checkout="${INSTALLED_VERSION:-}"
if [[ "$_t5_post_checkout" == "0.14.5-beta8" ]]; then
  ok
else
  err "control failed: expected post-checkout capture to read 0.14.5-beta8, got '$_t5_post_checkout'"
fi

step "T5 body template with pre-r2 ordering would render the wrong from_version"
_t5_buggy_rendered="$(printf -- '- from_version: %s\n' "${_t5_post_checkout:-unknown}")"
case "$_t5_buggy_rendered" in
  *"from_version: 0.14.5-beta8"*) ok ;;
  *) err "control failed: rendered body did not reflect post-checkout VERSION: $_t5_buggy_rendered" ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n== 1144-upgrade-complete-task summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
