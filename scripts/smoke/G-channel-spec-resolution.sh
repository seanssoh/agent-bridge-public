#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/G-channel-spec-resolution.sh — Issue #1221, v0.15.0-beta1 Lane G.
#
# Re-exec under bash 4+ so we can `source bridge-lib.sh` directly to exercise
# `bridge_qualify_channel_item` / `bridge_normalize_channels_csv` at the
# function level (matches scripts/smoke/1015-resume-claude-config-dir.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:G-channel-spec-resolution][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Pins the canonical built-in plugin → marketplace mapping that
# `bridge_qualify_channel_item` is required to apply to every un-suffixed
# `plugin:<name>` channel-spec token.
#
# Root cause (issue #1221): on `agent create --channels "plugin:teams,
# plugin:ms365"`, `bridge_qualify_channel_item` only auto-suffixed
# `teams|discord|telegram`. `ms365` (and, latent, `mattermost`) stayed
# unsuffixed in BRIDGE_AGENT_CHANNELS and the rendered launch_cmd, so
# downstream `setup ms365` and `agent start` failed the bridge-owned
# plugin-manifest gate. The fix lifts the per-plugin case into a small
# canonical table (`bridge_builtin_plugin_marketplace`) consulted by the
# qualifier, so the full built-in set (telegram → @claude-plugins-official;
# discord/teams/ms365/mattermost → @agent-bridge) gets the
# same resolution, and every caller of `bridge_qualify_channel_item` (the
# central normalizer, explicit roster channels, dev-channel filtering, the
# launch diagnostics in `bridge_agent_launch_cmd*`) sees the canonical form.
#
# Explicit suffixes remain verbatim — `plugin:teams@cosmax-marketplace` is
# never rewritten by the qualifier.
#
# Test plan — function-level (qualifier + normalizer):
#
#   T1.  `bridge_qualify_channel_item plugin:teams`     → plugin:teams@agent-bridge
#   T2.  `bridge_qualify_channel_item plugin:ms365`     → plugin:ms365@agent-bridge
#   T3.  `bridge_qualify_channel_item plugin:mattermost`→ plugin:mattermost@agent-bridge
#   T4.  `bridge_qualify_channel_item plugin:discord`   → plugin:discord@agent-bridge
#         (Task #12033: discord vendored to the agent-bridge marketplace)
#   T5.  `bridge_qualify_channel_item plugin:telegram`  → plugin:telegram@claude-plugins-official
#   T6.  `bridge_qualify_channel_item plugin:teams@cosmax-marketplace`
#         → plugin:teams@cosmax-marketplace (explicit suffix preserved)
#   T7.  `bridge_qualify_channel_item plugin:custom-dev@agent-bridge`
#         → plugin:custom-dev@agent-bridge (third-party explicit suffix preserved)
#   T8.  `bridge_qualify_channel_item plugin:unknown-builtin`
#         → plugin:unknown-builtin (no canonical home, returned verbatim)
#   T9.  `bridge_normalize_channels_csv "plugin:teams,plugin:ms365"`
#         → plugin:teams@agent-bridge,plugin:ms365@agent-bridge
#         (Issue #1221 reproducer — the spec that regressed in beta27).
#   T10. `bridge_normalize_channels_csv "plugin:teams@agent-bridge,plugin:teams"`
#         → plugin:teams@agent-bridge (no double-add — the second token
#         normalises to the same canonical form and the dedupe in
#         `bridge_append_csv_unique` collapses them).
#
# Test plan — table helper (canonical mapping in isolation):
#
#   T11. `bridge_builtin_plugin_marketplace teams`      → agent-bridge
#   T12. `bridge_builtin_plugin_marketplace ms365`      → agent-bridge
#   T13. `bridge_builtin_plugin_marketplace mattermost` → agent-bridge
#   T14. `bridge_builtin_plugin_marketplace discord`    → agent-bridge
#   T15. `bridge_builtin_plugin_marketplace telegram`   → claude-plugins-official
#   T16. `bridge_builtin_plugin_marketplace unknown`    → "" (no mapping)
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout). The
# smoke only sources bridge-lib.sh and calls pure functions — no roster
# persistence, no shell-out to bridge-setup.sh, no operator-side state read.

set -euo pipefail

SMOKE_NAME="G-channel-spec-resolution"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "G-channel-spec-resolution"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

declare -F bridge_qualify_channel_item >/dev/null \
  || smoke_fail "bridge_qualify_channel_item not defined after sourcing bridge-lib.sh"
declare -F bridge_builtin_plugin_marketplace >/dev/null \
  || smoke_fail "bridge_builtin_plugin_marketplace not defined (issue #1221 canonical-table helper)"
declare -F bridge_normalize_channels_csv >/dev/null \
  || smoke_fail "bridge_normalize_channels_csv not defined"

# --- T1..T8: qualifier per-input contract ---------------------------------

test_qualify_teams() {
  local out
  out="$(bridge_qualify_channel_item "plugin:teams")"
  smoke_assert_eq "plugin:teams@agent-bridge" "$out" \
    "T1 plugin:teams resolves to @agent-bridge"
}

test_qualify_ms365() {
  local out
  out="$(bridge_qualify_channel_item "plugin:ms365")"
  smoke_assert_eq "plugin:ms365@agent-bridge" "$out" \
    "T2 plugin:ms365 resolves to @agent-bridge (issue #1221 primary vector)"
}

test_qualify_mattermost() {
  local out
  out="$(bridge_qualify_channel_item "plugin:mattermost")"
  smoke_assert_eq "plugin:mattermost@agent-bridge" "$out" \
    "T3 plugin:mattermost resolves to @agent-bridge"
}

test_qualify_discord() {
  local out
  out="$(bridge_qualify_channel_item "plugin:discord")"
  # Task #12033: discord is now a vendored bridge-official plugin resolving to
  # the local agent-bridge marketplace (mirrors teams/ms365/mattermost).
  smoke_assert_eq "plugin:discord@agent-bridge" "$out" \
    "T4 plugin:discord resolves to @agent-bridge"
}

test_qualify_telegram() {
  local out
  out="$(bridge_qualify_channel_item "plugin:telegram")"
  smoke_assert_eq "plugin:telegram@claude-plugins-official" "$out" \
    "T5 plugin:telegram resolves to @claude-plugins-official"
}

test_qualify_explicit_third_party_marketplace() {
  local out
  out="$(bridge_qualify_channel_item "plugin:teams@cosmax-marketplace")"
  smoke_assert_eq "plugin:teams@cosmax-marketplace" "$out" \
    "T6 explicit @cosmax-marketplace suffix never rewritten"
}

test_qualify_explicit_agent_bridge_suffix_preserved() {
  local out
  out="$(bridge_qualify_channel_item "plugin:custom-dev@agent-bridge")"
  smoke_assert_eq "plugin:custom-dev@agent-bridge" "$out" \
    "T7 explicit @agent-bridge suffix on a non-builtin name preserved verbatim"
}

test_qualify_unknown_plugin_passthrough() {
  local out
  out="$(bridge_qualify_channel_item "plugin:unknown-builtin")"
  smoke_assert_eq "plugin:unknown-builtin" "$out" \
    "T8 un-suffixed non-builtin name returned verbatim (no canonical home)"
}

# --- T9..T10: normalizer end-to-end on the issue #1221 spec shape ---------

test_normalize_issue_1221_reproducer() {
  # The exact spec that regressed in beta27: `agent create --channels
  # "plugin:teams,plugin:ms365"`. Both tokens MUST land canonicalised in the
  # normalised CSV; the order MUST be input order (the normalizer dedupes
  # via `bridge_append_csv_unique` but preserves first-seen order).
  local out
  out="$(bridge_normalize_channels_csv "plugin:teams,plugin:ms365")"
  smoke_assert_eq "plugin:teams@agent-bridge,plugin:ms365@agent-bridge" "$out" \
    "T9 normalize teams,ms365 → both resolve canonical (#1221 reproducer)"
}

test_normalize_no_double_add() {
  # Re-rendering an already-canonical channel CSV merged with the same
  # un-suffixed plugin name must NOT produce two distinct entries. The
  # qualifier converts the un-suffixed token to the same canonical form,
  # and `bridge_append_csv_unique` collapses the duplicate.
  local out
  out="$(bridge_normalize_channels_csv "plugin:teams@agent-bridge,plugin:teams")"
  smoke_assert_eq "plugin:teams@agent-bridge" "$out" \
    "T10 re-normalize canonical + un-suffixed does not double-add"
}

# --- T11..T16: canonical-table helper in isolation ------------------------

test_table_teams() {
  local out
  out="$(bridge_builtin_plugin_marketplace "teams")"
  smoke_assert_eq "agent-bridge" "$out" "T11 table teams → agent-bridge"
}

test_table_ms365() {
  local out
  out="$(bridge_builtin_plugin_marketplace "ms365")"
  smoke_assert_eq "agent-bridge" "$out" "T12 table ms365 → agent-bridge"
}

test_table_mattermost() {
  local out
  out="$(bridge_builtin_plugin_marketplace "mattermost")"
  smoke_assert_eq "agent-bridge" "$out" "T13 table mattermost → agent-bridge"
}

test_table_discord() {
  local out
  out="$(bridge_builtin_plugin_marketplace "discord")"
  # Task #12033: discord vendored to the agent-bridge marketplace.
  smoke_assert_eq "agent-bridge" "$out" \
    "T14 table discord → agent-bridge"
}

test_table_telegram() {
  local out
  out="$(bridge_builtin_plugin_marketplace "telegram")"
  smoke_assert_eq "claude-plugins-official" "$out" \
    "T15 table telegram → claude-plugins-official"
}

test_table_unknown() {
  local out
  out="$(bridge_builtin_plugin_marketplace "unknown-builtin")"
  smoke_assert_eq "" "$out" "T16 table unknown → empty (no mapping)"
}

# Task #12033: stale-marketplace migration for vendored built-ins. An existing
# install carrying the explicit legacy `plugin:discord@claude-plugins-official`
# token must be REPLACED with `plugin:discord@agent-bridge` (not appended), so a
# re-provision cannot leave the agent double-registered.
test_migrate_discord_official_pin() {
  local out
  out="$(bridge_migrate_builtin_channel_marketplace "plugin:discord@claude-plugins-official")"
  smoke_assert_eq "plugin:discord@agent-bridge" "$out" \
    "T17 migrate plugin:discord@claude-plugins-official → @agent-bridge"
}

test_migrate_preserves_operator_fork() {
  local out
  out="$(bridge_migrate_builtin_channel_marketplace "plugin:discord@my-private-fork")"
  smoke_assert_eq "plugin:discord@my-private-fork" "$out" \
    "T18 migrate leaves operator-pinned marketplace untouched"
}

test_migrate_csv_collapses_double_register() {
  local out
  out="$(bridge_migrate_builtin_marketplaces_csv "plugin:discord@claude-plugins-official,plugin:discord@agent-bridge,plugin:ms365@agent-bridge")"
  smoke_assert_eq "plugin:discord@agent-bridge,plugin:ms365@agent-bridge" "$out" \
    "T19 migrate CSV collapses old+new discord to a single @agent-bridge token"
}

main() {
  smoke_run "T1 qualify plugin:teams"      test_qualify_teams
  smoke_run "T2 qualify plugin:ms365"      test_qualify_ms365
  smoke_run "T3 qualify plugin:mattermost" test_qualify_mattermost
  smoke_run "T4 qualify plugin:discord"    test_qualify_discord
  smoke_run "T5 qualify plugin:telegram"   test_qualify_telegram
  smoke_run "T6 qualify explicit @cosmax-marketplace" test_qualify_explicit_third_party_marketplace
  smoke_run "T7 qualify explicit @agent-bridge non-builtin" test_qualify_explicit_agent_bridge_suffix_preserved
  smoke_run "T8 qualify unknown-builtin passthrough" test_qualify_unknown_plugin_passthrough
  smoke_run "T9 normalize issue-1221 reproducer" test_normalize_issue_1221_reproducer
  smoke_run "T10 normalize no double-add"  test_normalize_no_double_add
  smoke_run "T11 table teams"              test_table_teams
  smoke_run "T12 table ms365"              test_table_ms365
  smoke_run "T13 table mattermost"         test_table_mattermost
  smoke_run "T14 table discord"            test_table_discord
  smoke_run "T15 table telegram"           test_table_telegram
  smoke_run "T16 table unknown"            test_table_unknown
  smoke_run "T17 migrate discord official pin → agent-bridge" test_migrate_discord_official_pin
  smoke_run "T18 migrate preserves operator fork"            test_migrate_preserves_operator_fork
  smoke_run "T19 migrate CSV collapses double-register"      test_migrate_csv_collapses_double_register
  smoke_log "passed"
}

main "$@"
