#!/usr/bin/env bash
# scripts/smoke/1638-settings-cosmetic-conflict.sh — Issue #1638 smoke.
#
# On `agb upgrade --apply`, a settings.json that 3-way-classifies as
# `merge_required` used to text-merge-conflict on two purely-cosmetic axes —
# (1) hook-event group ORDER, (2) `python3` vs `/usr/bin/python3` interpreter
# prefix — writing a spurious `.upgrade-conflict` on every cm-prod iso v2
# upgrade even though the rendered hook SET was identical.
#
# This smoke drives the real `bridge-upgrade.py apply-live` path against a
# disposable git source repo + target root and asserts:
#   T1  Stop-group ORDER swapped (same SET)            → keep_live, NO conflict
#   T2  `python3` vs `/usr/bin/python3` only           → keep_live, NO conflict
#   T3  a genuine hook SET change (added/diverged)     → STILL conflict
#   T5  bare `python` → `python3` interpreter MIGRATION → NOT swallowed
#       (pre-check declines; real merge/conflict surfaces the change)
#   T6  relative/venv `.venv/bin/python3` interpreter-path change → NOT swallowed
#   T4  a NON-settings file with a real 3-way diff     → conflict path unchanged
#
# Footgun #11: every Python sub-invocation is file-as-argv via the sibling
# `*-helper.py`; no `<<EOF` / `<<'PY'` / here-string is piped to a subprocess.
# Uses BRIDGE_HOME / mktemp isolation; never touches operator live runtime.

set -euo pipefail

SMOKE_NAME="1638-settings-cosmetic-conflict"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/1638-settings-cosmetic-conflict-helper.py"
UPGRADE_PY="$SMOKE_REPO_ROOT/bridge-upgrade.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Build a fresh source git repo whose HEAD-1 is `base` content and HEAD is
# `upstream` content for $relpath, plus a target root holding the `live` file.
# Echoes the base_ref (HEAD-1 sha) so the caller can pass --base-ref.
#
# Args: <slot> <relpath> <base-emit> <upstream-emit> <live-emit>
# *-emit is either "settings:<variant>" (delegated to the helper) or
# "plain:<text>" (written verbatim).
setup_scenario() {
  local slot="$1" relpath="$2" base_emit="$3" upstream_emit="$4" live_emit="$5"
  local source_repo="$SMOKE_TMP_ROOT/$slot-source"
  local target_root="$SMOKE_TMP_ROOT/$slot-target"
  mkdir -p "$source_repo" "$(dirname "$source_repo/$relpath")" "$(dirname "$target_root/$relpath")"

  git -C "$source_repo" init -q
  git -C "$source_repo" config user.email "smoke@local.invalid"
  git -C "$source_repo" config user.name "Smoke"

  emit_to "$base_emit" "$source_repo/$relpath"
  git -C "$source_repo" add "$relpath"
  git -C "$source_repo" commit -q -m base
  local base_ref
  base_ref="$(git -C "$source_repo" rev-parse HEAD)"

  emit_to "$upstream_emit" "$source_repo/$relpath"
  git -C "$source_repo" add "$relpath"
  git -C "$source_repo" commit -q -m upstream

  emit_to "$live_emit" "$target_root/$relpath"

  printf '%s\t%s\t%s\n' "$source_repo" "$target_root" "$base_ref"
}

emit_to() {
  local spec="$1" out="$2"
  case "$spec" in
    settings:*) python3 "$HELPER" emit-settings "${spec#settings:}" "$out" ;;
    plain:*)    printf '%s\n' "${spec#plain:}" >"$out" ;;
    *)          smoke_fail "unknown emit spec: $spec" ;;
  esac
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

# Footgun #11 (H3): no here-string. Split a TAB-separated "src<TAB>tgt<TAB>ref"
# row into the caller's src/tgt/ref via parameter expansion. The callers declare
# `local src tgt ref`; bash dynamic scope lets this helper assign those locals.
# shellcheck disable=SC2034  # src/tgt/ref are consumed by the callers, not here.
split_row_tab3() {
  local _rest="$1"
  src="${_rest%%$'\t'*}"
  _rest="${_rest#*$'\t'}"
  tgt="${_rest%%$'\t'*}"
  ref="${_rest#*$'\t'}"
}

assert_t1_order_swapped() {
  local row src tgt ref json
  row="$(setup_scenario t1 ".claude/settings.json" \
    settings:base settings:upstream-order settings:live-order-swapped)"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "0" "$(count_field "$json" counts.files_merged_conflict)" \
    "T1 hook-order swap produces no merge conflict"
  smoke_assert_eq "1" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "T1 counted as settings_cosmetic_noconflict"
  smoke_assert_eq "1" "$(count_field "$json" counts.files_preserved_live)" \
    "T1 preserved live file"
  [[ ! -e "$tgt/.claude/settings.json.upgrade-conflict" ]] \
    || smoke_fail "T1 wrote a spurious .upgrade-conflict"
}

assert_t2_python_path() {
  local row src tgt ref json
  row="$(setup_scenario t2 ".claude/settings.json" \
    settings:base settings:upstream-pypath settings:live-abs-pypath)"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "0" "$(count_field "$json" counts.files_merged_conflict)" \
    "T2 python-path-only diff produces no merge conflict"
  smoke_assert_eq "1" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "T2 counted as settings_cosmetic_noconflict"
  [[ ! -e "$tgt/.claude/settings.json.upgrade-conflict" ]] \
    || smoke_fail "T2 wrote a spurious .upgrade-conflict"
}

assert_t3_genuine_hook_change() {
  local row src tgt ref json
  row="$(setup_scenario t3 ".claude/settings.json" \
    settings:base settings:upstream-hook-different settings:live-hook-added)"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "1" "$(count_field "$json" counts.files_merged_conflict)" \
    "T3 genuine hook SET change STILL conflicts"
  smoke_assert_eq "0" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "T3 not swallowed by the cosmetic pre-check"
  smoke_assert_file_exists "$tgt/.claude/settings.json.upgrade-conflict" \
    "T3 wrote the expected .upgrade-conflict"
}

assert_t5_python_migration_not_swallowed() {
  # codex #1638 review: a bare `python` → `python3` interpreter MIGRATION is a
  # real change (live `python` may be Python 2 / missing), NOT cosmetic. The
  # cosmetic pre-check must NOT fire and must NOT preserve the live file, so
  # upstream's interpreter fix is surfaced (merged/conflicted) rather than
  # silently kept. Here upstream's `python3` and live's `python` edit different
  # lines than the shared `autoDreamEnabled` add, so the genuine fall-through is
  # a CLEAN merge — the point is that keep_live did NOT swallow the migration.
  local row src tgt ref json
  row="$(setup_scenario t5 ".claude/settings.json" \
    settings:base settings:upstream-pypath settings:live-bare-python)"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "0" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "T5 bare python is not treated as cosmetic"
  smoke_assert_eq "0" "$(count_field "$json" counts.files_preserved_live)" \
    "T5 did not keep_live (upstream interpreter change not swallowed)"
  smoke_assert_eq "1" "$(count_field "$json" counts.files_merged_clean)" \
    "T5 fell through to the real merge path (clean merge surfaces the change)"
  [[ ! -e "$tgt/.claude/settings.json.upgrade-conflict" ]] \
    || smoke_fail "T5 clean-merge fall-through should not write .upgrade-conflict"
}

assert_t6_venv_python_not_swallowed() {
  # codex #1638 round 2: a RELATIVE/virtualenv interpreter path
  # (`.venv/bin/python3` vs upstream bare `python3`) is a real interpreter-PATH
  # change, NOT cosmetic. The pre-check must decline and must NOT keep_live so
  # the change is surfaced (here a clean merge, since the venv edit and the
  # shared `autoDreamEnabled` add touch different lines).
  local row src tgt ref json
  row="$(setup_scenario t6 ".claude/settings.json" \
    settings:base settings:upstream-pypath settings:live-venv-python)"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "0" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "T6 venv-relative python3 is not treated as cosmetic"
  smoke_assert_eq "0" "$(count_field "$json" counts.files_preserved_live)" \
    "T6 did not keep_live (venv interpreter-path change not swallowed)"
  [[ ! -e "$tgt/.claude/settings.json.upgrade-conflict" ]] \
    || smoke_fail "T6 clean-merge fall-through should not write .upgrade-conflict"
}

assert_t4_non_settings_unchanged() {
  local row src tgt ref json
  row="$(setup_scenario t4 "lib/sample.sh" \
    "plain:base line" "plain:upstream line" "plain:live line")"
  split_row_tab3 "$row"
  json="$(run_apply "$src" "$tgt" "$ref")"

  smoke_assert_eq "1" "$(count_field "$json" counts.files_merged_conflict)" \
    "T4 non-settings real diff still conflicts"
  smoke_assert_eq "0" "$(count_field "$json" counts.settings_cosmetic_noconflict)" \
    "T4 cosmetic pre-check never fires for non-settings files"
  smoke_assert_file_exists "$tgt/lib/sample.sh.upgrade-conflict" \
    "T4 wrote the expected .upgrade-conflict"
}

main() {
  smoke_require_cmd git
  smoke_require_cmd python3
  smoke_setup_bridge_home "1638-settings-cosmetic-conflict"
  smoke_run "T1 hook-event order swap → keep_live" assert_t1_order_swapped
  smoke_run "T2 python3 vs /usr/bin/python3 → keep_live" assert_t2_python_path
  smoke_run "T3 genuine hook change → still conflict" assert_t3_genuine_hook_change
  smoke_run "T5 python→python3 migration → not swallowed by pre-check" assert_t5_python_migration_not_swallowed
  smoke_run "T6 venv-relative python3 → not swallowed by pre-check" assert_t6_venv_python_not_swallowed
  smoke_run "T4 non-settings real diff → conflict unchanged" assert_t4_non_settings_unchanged
  smoke_log "passed"
}

main "$@"
