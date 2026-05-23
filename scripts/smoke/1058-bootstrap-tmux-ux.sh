#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1058-bootstrap-tmux-ux.sh — Issue #1058.
#
# Pins the contract that `lib/bridge-tmux-ux.sh`'s managed-block writer is
# idempotent and degrades gracefully.
#
# Background (#1058): Agent Bridge launches Claude/Codex inside tmux. A fresh
# server's stock tmux defaults (`default-terminal screen`, `mouse off`,
# `escape-time 500`) degrade the TUI. `bridge_setup_tmux_ux` (sourced by
# bridge-bootstrap.sh) writes an idempotent `# BEGIN/# END AGENT BRIDGE
# TMUX UX` managed block to ~/.tmux.conf.
#
# Test plan (in-process bash — no live tmux server is required; the helper's
# `tmux info` probe simply finds no server and skips re-sourcing):
#
#   T1. First write into a conf that already has an unrelated user line —
#       the managed block is appended, the user line survives.
#   T2. Second write (idempotent) — rc=1 "no change", exactly one BEGIN and
#       one END marker, the user line still survives.
#   T3. A user line added AFTER the block survives an in-place replacement
#       when the block body changes.
#   T4. Malformed block (BEGIN without END) — writer returns rc=2 and does
#       NOT rewrite the file.
#   T5. Version gate — `terminal-features` is included for tmux >= 3.2 and
#       omitted for older tmux.
#   T6. --dry-run — the conf is never created.
#
# Footgun #11 (heredoc_write deadlock class): this smoke and the helper it
# exercises build every block with `printf` — no heredoc-to-subprocess, no
# `<<<` here-strings, no process-substitution-into-reader.

set -uo pipefail

SMOKE_NAME="1058-bootstrap-tmux-ux"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
HELPER="$REPO_ROOT/lib/bridge-tmux-ux.sh"
smoke_assert_file_exists "$HELPER" "lib/bridge-tmux-ux.sh exists"

# shellcheck source=lib/bridge-tmux-ux.sh
source "$HELPER"

# --- T1: first write appends the block, unrelated user line survives ---------
smoke_log "T1: first write appends the managed block and preserves an unrelated user line"

CONF="$SMOKE_TMP_ROOT/t1.tmux.conf"
printf '%s\n' 'set -g status-bg blue' >"$CONF"

T1_BODY="$(bridge_tmux_ux_render_block "tmux-256color" 1)"
T1_RC=0
bridge_tmux_ux_write_conf "$CONF" "$T1_BODY" || T1_RC=$?
smoke_assert_eq "0" "$T1_RC" "T1: first write returns rc=0 (written)"
smoke_assert_eq "1" "$(grep -c '^# BEGIN AGENT BRIDGE TMUX UX$' "$CONF")" \
  "T1: exactly one BEGIN marker after first write"
smoke_assert_eq "1" "$(grep -c '^# END AGENT BRIDGE TMUX UX$' "$CONF")" \
  "T1: exactly one END marker after first write"
smoke_assert_eq "1" "$(grep -c '^set -g status-bg blue$' "$CONF")" \
  "T1: the pre-existing unrelated user line survives the write"
smoke_assert_eq "1" "$(grep -c '^set -g mouse on$' "$CONF")" \
  "T1: the managed block contains the mouse-on line"
smoke_assert_eq "1" "$(grep -c '^set -s escape-time 10$' "$CONF")" \
  "T1: the managed block uses the conservative escape-time 10"
# The END marker must be on its own line, never fused to the last body line.
[[ "$(tail -n1 "$CONF")" == "# END AGENT BRIDGE TMUX UX" ]] \
  || smoke_fail "T1: END marker is not on its own final line"
smoke_log "T1 PASS"

# --- T2: second write is idempotent (no change, no duplicate) ----------------
smoke_log "T2: a second write reports no change and never duplicates the block"

T2_RC=0
bridge_tmux_ux_write_conf "$CONF" "$T1_BODY" || T2_RC=$?
smoke_assert_eq "1" "$T2_RC" "T2: re-write returns rc=1 (already up to date)"
smoke_assert_eq "1" "$(grep -c '^# BEGIN AGENT BRIDGE TMUX UX$' "$CONF")" \
  "T2: still exactly one BEGIN marker after re-write"
smoke_assert_eq "1" "$(grep -c '^# END AGENT BRIDGE TMUX UX$' "$CONF")" \
  "T2: still exactly one END marker after re-write"
smoke_assert_eq "1" "$(grep -c '^set -g status-bg blue$' "$CONF")" \
  "T2: the unrelated user line still survives the re-write"
smoke_log "T2 PASS"

# --- T3: in-place replace preserves a user line that follows the block -------
smoke_log "T3: a user line after the block survives an in-place block replacement"

printf '%s\n' 'set -g history-limit 50000' >>"$CONF"
# Render a DIFFERENT body (screen-256color fallback) so the block content
# genuinely changes and the writer must replace in place.
T3_BODY="$(bridge_tmux_ux_render_block "screen-256color" 0)"
T3_RC=0
bridge_tmux_ux_write_conf "$CONF" "$T3_BODY" || T3_RC=$?
smoke_assert_eq "0" "$T3_RC" "T3: in-place replacement returns rc=0 (updated)"
smoke_assert_eq "1" "$(grep -c '^# BEGIN AGENT BRIDGE TMUX UX$' "$CONF")" \
  "T3: still exactly one BEGIN marker after in-place replacement"
smoke_assert_eq "1" "$(grep -c '^set -g status-bg blue$' "$CONF")" \
  "T3: the user line BEFORE the block survives the replacement"
smoke_assert_eq "1" "$(grep -c '^set -g history-limit 50000$' "$CONF")" \
  "T3: the user line AFTER the block survives the replacement"
smoke_assert_eq "1" "$(grep -c '^set -g default-terminal "screen-256color"$' "$CONF")" \
  "T3: the replaced block carries the new default-terminal value"
smoke_assert_eq "0" "$(grep -c '^set -ag terminal-features' "$CONF")" \
  "T3: the version-gated terminal-features line is absent when omitted"
smoke_log "T3 PASS"

# --- T4: malformed block (BEGIN without END) is refused, file untouched ------
smoke_log "T4: a malformed block (BEGIN without END) returns rc=2 and does not rewrite the file"

MAL_CONF="$SMOKE_TMP_ROOT/t4.tmux.conf"
printf '%s\n' 'set -g status-bg green' '# BEGIN AGENT BRIDGE TMUX UX' 'set -g mouse on' >"$MAL_CONF"
MAL_BEFORE="$(cat "$MAL_CONF")"
T4_RC=0
bridge_tmux_ux_write_conf "$MAL_CONF" "$T1_BODY" || T4_RC=$?
smoke_assert_eq "2" "$T4_RC" "T4: malformed block returns rc=2"
smoke_assert_eq "$MAL_BEFORE" "$(cat "$MAL_CONF")" \
  "T4: the file is left untouched when the existing block is malformed"
smoke_log "T4 PASS"

# --- T5: version gate for the terminal-features line -------------------------
smoke_log "T5: terminal-features is gated on tmux >= 3.2"

for ok_version in "tmux 3.2" "tmux 3.6a" "tmux 4.0" "tmux next-3.4"; do
  bridge_tmux_ux_version_supports_terminal_features "$ok_version" \
    || smoke_fail "T5: expected '$ok_version' to support terminal-features"
done
for old_version in "tmux 3.1c" "tmux 2.9a" "tmux 1.8" "garbage"; do
  if bridge_tmux_ux_version_supports_terminal_features "$old_version"; then
    smoke_fail "T5: expected '$old_version' to NOT support terminal-features"
  fi
done
smoke_log "T5 PASS"

# --- T6: --dry-run never creates the conf ------------------------------------
smoke_log "T6: bridge_setup_tmux_ux --dry-run never mutates ~/.tmux.conf"

DRY_CONF="$SMOKE_TMP_ROOT/t6-dry.tmux.conf"
BRIDGE_TMUX_UX_CONF="$DRY_CONF" bridge_setup_tmux_ux --dry-run >/dev/null 2>&1
[[ ! -e "$DRY_CONF" ]] \
  || smoke_fail "T6: --dry-run created the conf file; it must never mutate ~/.tmux.conf"
smoke_log "T6 PASS"

smoke_log "all tests PASS — bridge_setup_tmux_ux managed-block writer is idempotent and degrades gracefully (#1058)"
exit 0
