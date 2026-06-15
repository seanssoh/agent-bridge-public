#!/usr/bin/env bash

# Issue #1817: the upgrader must keep the live-root CLAUDE.md a thin operator
# stub rather than ancestor-injecting the ~24 KB contributor contract into
# every agent session. This smoke exercises bridge-upgrade.py apply-live for
# the cases the substitution has to get right:
#   1. fresh install (no live CLAUDE.md)                 -> seed the operator stub
#   2. existing install carrying the managed contract    -> substitute to the stub
#   3. operator-customized live CLAUDE.md                 -> preserve verbatim
#   4. contract bytes + operator edits appended           -> preserve verbatim
#   5. re-run upgrade over the stub                       -> no-op (idempotent)
# Cases 3 and 4 are the #1 invariant: never clobber an operator file. Detection
# is EXACT content-hash match against bridge-shipped contracts, so case 4 (an
# old contract that the operator edited) is preserved even though it still
# contains every contract heading.

set -euo pipefail

SMOKE_NAME="1817-live-root-claude-stub"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

STUB_MARKER="<!-- agent-bridge: live-root operator stub (#1817) -->"

# A source repo whose tracked root CLAUDE.md is THE contract this upgrade ships.
# apply-live recognizes the unmodified copy of this exact file by content hash
# (the current-source hash is folded into the managed-contract set), so it does
# not depend on the static historical allowlist staying in sync with the smoke.
make_contract_source_repo() {
  local source_repo="$1"
  mkdir -p "$source_repo"
  git -C "$source_repo" init >/dev/null
  git -C "$source_repo" config user.email "smoke@local.invalid"
  git -C "$source_repo" config user.name "Smoke"
  cat >"$source_repo/CLAUDE.md" <<'CONTRACT'
# CLAUDE.md

**Audience**: a code contributor. This file is the **repo contributor contract**.

## Source Checkout vs Live Runtime (critical)

Never confuse these two trees.

## High-Risk Areas (edit with care)

1. Queue / daemon / status.
CONTRACT
  printf 'tracked\n' >"$source_repo/keep.txt"
  git -C "$source_repo" add CLAUDE.md keep.txt
  git -C "$source_repo" commit -m base >/dev/null
}

apply_live() {
  local source_repo="$1" target_root="$2"
  python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" apply-live \
    --source-root "$source_repo" --target-root "$target_root" >/dev/null
}

sha_of() {
  shasum "$1" | awk '{print $1}'
}

fresh_install_seeds_stub() {
  local source_repo target_root
  source_repo="$SMOKE_TMP_ROOT/fresh-source"
  target_root="$SMOKE_TMP_ROOT/fresh-target"
  make_contract_source_repo "$source_repo"
  mkdir -p "$target_root"
  # No live CLAUDE.md exists yet.
  apply_live "$source_repo" "$target_root"

  smoke_assert_file_exists "$target_root/CLAUDE.md" "fresh install seeds a live-root CLAUDE.md"
  local body
  body="$(cat "$target_root/CLAUDE.md")"
  smoke_assert_contains "$body" "$STUB_MARKER" "fresh-install live-root CLAUDE.md is the operator stub"
  smoke_assert_not_contains "$body" "repo contributor contract" "fresh-install live-root CLAUDE.md is NOT the contributor contract"
  # The contract was still skipped by the classifier, not deployed verbatim.
  smoke_assert_eq "tracked" "$(cat "$target_root/keep.txt")" "fresh install still deploys other tracked files"
}

existing_contract_substituted() {
  local source_repo target_root
  source_repo="$SMOKE_TMP_ROOT/existing-source"
  target_root="$SMOKE_TMP_ROOT/existing-target"
  make_contract_source_repo "$source_repo"
  mkdir -p "$target_root"
  # Pre-state: the live root already carries the unmodified bridge-managed
  # contract (an existing install upgraded from before #1817).
  cp "$source_repo/CLAUDE.md" "$target_root/CLAUDE.md"
  apply_live "$source_repo" "$target_root"

  local body
  body="$(cat "$target_root/CLAUDE.md")"
  smoke_assert_contains "$body" "$STUB_MARKER" "existing-contract live-root CLAUDE.md substituted to the stub"
  smoke_assert_not_contains "$body" "repo contributor contract" "existing-contract live-root CLAUDE.md no longer the contract"
}

operator_customized_preserved() {
  local source_repo target_root before_sha
  source_repo="$SMOKE_TMP_ROOT/custom-source"
  target_root="$SMOKE_TMP_ROOT/custom-target"
  make_contract_source_repo "$source_repo"
  mkdir -p "$target_root"
  # Pre-state: operator hand-wrote their own live-root CLAUDE.md. Its bytes
  # never match a shipped contract, so it must be left untouched.
  printf '# CLAUDE.md\n\nThis install is operated by the comms team.\nOur own house rules live here.\n' \
    >"$target_root/CLAUDE.md"
  before_sha="$(sha_of "$target_root/CLAUDE.md")"
  apply_live "$source_repo" "$target_root"

  smoke_assert_eq "$before_sha" "$(sha_of "$target_root/CLAUDE.md")" \
    "operator-customized live-root CLAUDE.md preserved byte-for-byte"
  smoke_assert_not_contains "$(cat "$target_root/CLAUDE.md")" "$STUB_MARKER" "operator-customized CLAUDE.md not overwritten with the stub"
}

contract_plus_operator_edits_preserved() {
  local source_repo target_root before_sha
  source_repo="$SMOKE_TMP_ROOT/edited-source"
  target_root="$SMOKE_TMP_ROOT/edited-target"
  make_contract_source_repo "$source_repo"
  mkdir -p "$target_root"
  # Pre-state: operator took the deployed contract and appended their own
  # section. The file still contains EVERY contract heading/marker, but the
  # bytes differ from any shipped contract, so the substitution must preserve
  # it. This is the case a marker/heading-only detector would wrongly clobber.
  cp "$source_repo/CLAUDE.md" "$target_root/CLAUDE.md"
  printf '\n## Operator notes (do not delete)\n\nLocal team conventions live below.\n' \
    >>"$target_root/CLAUDE.md"
  before_sha="$(sha_of "$target_root/CLAUDE.md")"
  apply_live "$source_repo" "$target_root"

  smoke_assert_eq "$before_sha" "$(sha_of "$target_root/CLAUDE.md")" \
    "contract+operator-edits live-root CLAUDE.md preserved byte-for-byte"
  smoke_assert_not_contains "$(cat "$target_root/CLAUDE.md")" "$STUB_MARKER" "contract+operator-edits file not overwritten with the stub"
  smoke_assert_contains "$(cat "$target_root/CLAUDE.md")" "Operator notes (do not delete)" "operator-appended section survives the upgrade"
}

stub_is_idempotent() {
  local source_repo target_root first
  source_repo="$SMOKE_TMP_ROOT/idem-source"
  target_root="$SMOKE_TMP_ROOT/idem-target"
  make_contract_source_repo "$source_repo"
  mkdir -p "$target_root"
  apply_live "$source_repo" "$target_root"
  first="$(cat "$target_root/CLAUDE.md")"
  # A second upgrade pass must leave the already-stubbed file unchanged (the
  # stub marker / hash-mismatch excludes it from re-substitution).
  apply_live "$source_repo" "$target_root"
  smoke_assert_eq "$first" "$(cat "$target_root/CLAUDE.md")" "re-running upgrade leaves the operator stub unchanged"
}

main() {
  smoke_require_cmd git
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  smoke_run "fresh install seeds operator stub" fresh_install_seeds_stub
  smoke_run "existing contract substituted to stub" existing_contract_substituted
  smoke_run "operator-customized CLAUDE.md preserved" operator_customized_preserved
  smoke_run "contract + operator edits preserved" contract_plus_operator_edits_preserved
  smoke_run "stub substitution is idempotent" stub_is_idempotent
  smoke_log "passed"
}

main "$@"
