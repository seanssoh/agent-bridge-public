#!/usr/bin/env bash
# scripts/smoke/1675-1694-settings-homebrew-abspath-conflict.sh
#   — Issues #1675 + #1694 smoke (same root as #1638's cosmetic short-circuit).
#
# On `agb upgrade --apply`, a settings.json that 3-way-classifies as
# `merge_required` used to text-merge-conflict on TWO render-owned cosmetic
# axes that #1638's pre-check did NOT yet cover:
#   #1675  the live interpreter is Homebrew's `/opt/homebrew/bin/python3`
#          (rendered on Homebrew-python macOS hosts), which was absent from the
#          cosmetic interpreter allowlist → fell through to a spurious conflict.
#   #1694  the render expands the template `~/.agent-bridge/hooks/<x>` path arg
#          to an absolute `<BRIDGE_HOME>/hooks/<x>` form, which #1638 normalized
#          only on the interpreter TOKEN, not the path ARGUMENT → fell through.
# Both are reconciled authoritatively by `shared_settings_rerender` right after
# the merge, so the conflict was always spurious + recurring fleet-wide toil on
# the security-relevant hooks file (every macOS/Homebrew hook-region upgrade).
#
# This smoke drives the real `bridge-upgrade.py apply-live` path against a
# disposable git source repo + target root and asserts:
#   H1  Homebrew python3 + ~-expanded abs hook paths (#1675 + #1694)
#         → keep_live, NO conflict
#   H2  /usr/bin/python3 (already allowlisted) + ~-expanded abs hook paths only
#         (#1694 isolated)                              → keep_live, NO conflict
#   H3  a render-owned cosmetic diff that ALSO replaces a hook BASENAME (a real
#         operator edit) STILL conflicts                → conflict path unchanged
#
# Footgun #11: every Python sub-invocation is file-as-argv via the shared
# `1638-settings-cosmetic-conflict-helper.py`; no `<<EOF` / `<<'PY'` /
# here-string is piped to a subprocess. Uses BRIDGE_HOME / mktemp isolation;
# never touches operator live runtime.

set -euo pipefail

SMOKE_NAME="1675-1694-settings-homebrew-abspath-conflict"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Reuse the #1638 fixture/field helper (same cosmetic short-circuit surface).
HELPER="$SCRIPT_DIR/1638-settings-cosmetic-conflict-helper.py"
UPGRADE_PY="$SMOKE_REPO_ROOT/bridge-upgrade.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Build a fresh source git repo whose HEAD-1 is `base` content and HEAD is
# `upstream` content for $relpath, plus a target root holding the `live` file.
# Echoes "src<TAB>tgt<TAB>base_ref".
#
# Args: <slot> <relpath> <base-variant> <upstream-variant> <live-variant>
setup_scenario() {
  local slot="$1" relpath="$2" base_v="$3" upstream_v="$4" live_v="$5"
  local source_repo="$SMOKE_TMP_ROOT/$slot-source"
  local target_root="$SMOKE_TMP_ROOT/$slot-target"
  mkdir -p "$source_repo" "$(dirname "$source_repo/$relpath")" "$(dirname "$target_root/$relpath")"

  git -C "$source_repo" init -q
  git -C "$source_repo" config user.email "smoke@local.invalid"
  git -C "$source_repo" config user.name "Smoke"

  python3 "$HELPER" emit-settings "$base_v" "$source_repo/$relpath"
  git -C "$source_repo" add "$relpath"
  git -C "$source_repo" commit -q -m base
  local base_ref
  base_ref="$(git -C "$source_repo" rev-parse HEAD)"

  python3 "$HELPER" emit-settings "$upstream_v" "$source_repo/$relpath"
  git -C "$source_repo" add "$relpath"
  git -C "$source_repo" commit -q -m upstream

  python3 "$HELPER" emit-settings "$live_v" "$target_root/$relpath"

  printf '%s\t%s\t%s\n' "$source_repo" "$target_root" "$base_ref"
}

run_apply() {
  local source_repo="$1" target_root="$2" base_ref="$3"
  python3 "$UPGRADE_PY" apply-live \
    --source-root "$source_repo" \
    --target-root "$target_root" \
    --base-ref "$base_ref"
}

count_field() {
  python3 "$HELPER" field "$1" "$2"
}

# Footgun #11 (H3): no here-string. Split a TAB-separated row into src/tgt/ref
# via the caller's dynamic-scope locals (same idiom as the #1638 smoke).
# shellcheck disable=SC2034  # src/tgt/ref are consumed by the callers, not here.
split_row_tab3() {
  local _rest="$1"
  src="${_rest%%$'\t'*}"
  _rest="${_rest#*$'\t'}"
  tgt="${_rest%%$'\t'*}"
  ref="${_rest#*$'\t'}"
}

assert_h1_homebrew_abspath() {
  local row src tgt ref json
  row="$(setup_scenario h1 ".claude/settings.json" \
    base upstream-pypath live-homebrew-abspath)"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "0" "$(count_field "$json" counts.files_merged_conflict)" \
    "H1 Homebrew python + abs hook paths produces no merge conflict (#1675+#1694)"
  smoke_assert_eq "1" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "H1 counted as settings_cosmetic_noconflict"
  smoke_assert_eq "1" "$(count_field "$json" counts.files_preserved_live)" \
    "H1 preserved live file"
  [[ ! -e "$tgt/.claude/settings.json.upgrade-conflict" ]] \
    || smoke_fail "H1 wrote a spurious .upgrade-conflict"
}

assert_h2_abspath_only() {
  local row src tgt ref json
  row="$(setup_scenario h2 ".claude/settings.json" \
    base upstream-pypath live-abspath-usrbin)"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "0" "$(count_field "$json" counts.files_merged_conflict)" \
    "H2 ~-expanded abs hook paths alone produces no merge conflict (#1694)"
  smoke_assert_eq "1" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "H2 counted as settings_cosmetic_noconflict"
  [[ ! -e "$tgt/.claude/settings.json.upgrade-conflict" ]] \
    || smoke_fail "H2 wrote a spurious .upgrade-conflict"
}

assert_h3_genuine_edit_still_conflicts() {
  # SAFETY: a replaced hook BASENAME riding ALONGSIDE the cosmetic
  # Homebrew/abs-path axes is a real operator edit. The pre-check must DECLINE
  # (different hook SET after canonicalization) so the change still surfaces as
  # a conflict — the render must not silently swallow an operator's real edit.
  local row src tgt ref json
  row="$(setup_scenario h3 ".claude/settings.json" \
    base upstream-session-stop-edited live-genuine-edit-abspath)"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "0" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "H3 replaced hook basename is NOT treated as cosmetic"
  smoke_assert_eq "1" "$(count_field "$json" counts.files_merged_conflict)" \
    "H3 genuine operator hook edit STILL conflicts"
  smoke_assert_file_exists "$tgt/.claude/settings.json.upgrade-conflict" \
    "H3 wrote the expected .upgrade-conflict"
}

main() {
  smoke_require_cmd git
  smoke_require_cmd python3
  smoke_setup_bridge_home "1675-1694-settings-homebrew-abspath-conflict"
  smoke_run "H1 Homebrew python + abs hook paths → keep_live" assert_h1_homebrew_abspath
  smoke_run "H2 abs hook path only → keep_live" assert_h2_abspath_only
  smoke_run "H3 genuine hook edit + cosmetic axes → still conflict" assert_h3_genuine_edit_still_conflicts
  smoke_log "passed"
}

main "$@"
