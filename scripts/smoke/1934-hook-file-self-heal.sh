#!/usr/bin/env bash
# scripts/smoke/1934-hook-file-self-heal.sh — Issue #1934 facet 2 smoke.
#
# Facet 2 self-heal: a live Claude agent whose rendered hook COMMAND points at a
# script FILE that no longer exists (the OS reaped a transient /tmp hooks dir)
# must be detected and recovered without a human. Claude fail-CLOSES on a missing
# hook script (UserPromptSubmit → silent deafness; PreToolUse `*` → tool
# deadlock), so the bridge must (1) DETECT the stale/absent reference and (2)
# force a canonical re-render.
#
# This smoke pins the two mechanical halves the daemon reconcile tick
# (`bridge_daemon_reheal_missing_hook_files`, bridge-daemon.sh) composes:
#
#   DETECT — `lib/daemon-helpers/hook-file-missing-scan.py` reports `missing`
#   when a settings file references a hook script that does not exist, and `ok`
#   once the script is present. (Fail-SAFE: an unreadable settings file or a
#   foreign hook command that does not match the bridge hook-script shape stays
#   `ok`, so the daemon never fires a spurious re-render.)
#
#   RECOVER — re-rendering a settings file whose hooks point at a transient
#   (reaped) dir rewrites the command paths to the canonical install hooks dir
#   (facet 1 `_stable_hooks_dir`), flipping the scan from `missing` back to `ok`.
#
# The daemon tick wiring itself (roster iteration + live-session gating) is not
# exercised here — that path needs a live tmux fleet; this smoke covers the
# detect + recover primitives it is built from.

set -euo pipefail

SMOKE_NAME="1934-hook-file-self-heal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

SCAN="$SMOKE_REPO_ROOT/lib/daemon-helpers/hook-file-missing-scan.py"

assert_scan_detects_missing_and_present() {
  smoke_make_temp_root "$SMOKE_NAME"
  local s="$SMOKE_TMP_ROOT/settings.json"
  local hooks_dir="$SMOKE_TMP_ROOT/install/hooks"
  mkdir -p "$hooks_dir"

  # A settings file whose PreToolUse hook references a script that does NOT yet
  # exist (the reaped-hook shape).
  cat >"$s" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/usr/bin/python3 $hooks_dir/tool-policy.py", "timeout": 5 }
        ]
      }
    ]
  }
}
EOF

  local out status
  out="$(python3 "$SCAN" "$s")"
  status="${out%%$'\t'*}"
  smoke_assert_eq "missing" "$status" \
    "scan reports MISSING when a referenced hook script is absent (#1934)"

  # Now deploy the script — the scan must flip to ok (the recover half).
  : >"$hooks_dir/tool-policy.py"
  out="$(python3 "$SCAN" "$s")"
  smoke_assert_eq "ok" "$out" \
    "scan reports OK once the hook script exists (#1934)"
  smoke_cleanup_temp_root
}

assert_scan_failsafe_on_foreign_and_unreadable() {
  smoke_make_temp_root "$SMOKE_NAME"
  local s="$SMOKE_TMP_ROOT/foreign.json"
  # A foreign / non-bridge hook command (does not match the hooks/<name>.{py,sh}
  # absolute-path shape) must never report missing — no spurious re-render.
  cat >"$s" <<'EOF'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo hello" } ] } ] } }
EOF
  smoke_assert_eq "ok" "$(python3 "$SCAN" "$s")" \
    "scan is fail-safe on a foreign hook command (#1934)"

  # An unreadable / absent settings file is fail-safe ok too.
  smoke_assert_eq "ok" "$(python3 "$SCAN" "$SMOKE_TMP_ROOT/does-not-exist.json")" \
    "scan is fail-safe on an unreadable settings file (#1934)"
  smoke_cleanup_temp_root
}

assert_render_recovers_transient_pointer() {
  smoke_make_temp_root "$SMOKE_NAME"
  # Simulate a pre-facet-1 bricked settings file: the bridge_home is transient
  # and its hooks dir does NOT exist (the reaped shape). Re-rendering through the
  # shared renderer must rewrite the hook command paths to the canonical install
  # hooks dir (a SURVIVING dir), flipping the scan from missing to ok. HOME is
  # pointed at a controlled temp home that DOES contain the canonical install, so
  # the test is deterministic and host-independent.
  local bh="$SMOKE_TMP_ROOT/agb-iso-test-token"
  mkdir -p "$bh/agents/.claude"
  cp "$SMOKE_REPO_ROOT/agents/.claude/settings.json" \
    "$bh/agents/.claude/settings.json"
  printf '{}\n' >"$bh/agents/.claude/settings.local.json"
  [[ -d "$bh/hooks" ]] && smoke_fail "fixture invalid: transient hooks dir should be absent"

  # A controlled canonical install (HOME-relative) the fence resolves to, with
  # the referenced scripts present so the post-render scan reports ok.
  local home="$SMOKE_TMP_ROOT/canon-home"
  local canon="$home/.agent-bridge/hooks"
  mkdir -p "$canon"
  for f in tool-policy.py prompt-guard.py prompt_timestamp.py session-start.py \
           session-stop.py surface-reply-enforce.py pre-compact.py \
           inbox-auto-drain.py askuserquestion-ban.py mark-idle.sh clear-idle.sh; do
    : >"$canon/$f"
  done

  local eff="$bh/agents/.claude/settings.effective.json"
  HOME="$home" python3 "$SMOKE_REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$bh/agents/.claude/settings.json" \
    --overlay-settings-file "$bh/agents/.claude/settings.local.json" \
    --effective-settings-file "$eff" \
    --operator-global-settings-file "" \
    --launch-cmd "" >/dev/null

  smoke_assert_eq "ok" "$(python3 "$SCAN" "$eff")" \
    "re-render rewrites a transient hook pointer to a surviving (canonical) dir (#1934)"
  smoke_cleanup_temp_root
}

main() {
  smoke_run "scan detects a missing hook script and clears once present" \
    assert_scan_detects_missing_and_present
  smoke_run "scan is fail-safe on foreign / unreadable input" \
    assert_scan_failsafe_on_foreign_and_unreadable
  smoke_run "re-render recovers a transient (reaped) hook pointer" \
    assert_render_recovers_transient_pointer

  smoke_log "PASS"
}

main "$@"
