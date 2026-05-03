#!/usr/bin/env bash

# Issue #523: telegram-relay residue survives v0.7 cleanup via launch
# cmd and stale live files. Locks the contract for both Gap A
# (BRIDGE_AGENT_LAUNCH_CMD rewrite) and Gap B (versioned live-file
# prune) plus the cleanup execution order, idempotency, symlink
# safety, and absolute-path-anchored stale-process matching.

set -euo pipefail

SMOKE_NAME="telegram-relay-residue-cleanup"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  # Belt-and-suspenders: any sleeper process the smoke spawned should
  # be cleaned up even if an assertion failed mid-run. The trap fires
  # before smoke_cleanup_temp_root removes BRIDGE_HOME.
  if [[ -n "${SMOKE_RELAY_INTREE_PID:-}" ]]; then
    kill -KILL "$SMOKE_RELAY_INTREE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${SMOKE_RELAY_FOREIGN_PID:-}" ]]; then
    kill -KILL "$SMOKE_RELAY_FOREIGN_PID" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

CLEANUP_PY="$SMOKE_REPO_ROOT/bridge-relay-cleanup.py"

# json_field follows the established `scripts/smoke/upgrade-*.sh`
# pattern: a Python one-liner reads JSON from stdin, then prints the
# result of the expression argument. The expression is smoke-author
# code (not user input), so the inline `eval` mirrors the existing
# convention here. New smokes outside this file should keep using it
# for consistency.
json_field() {
  local json="$1"
  local expr="$2"
  printf '%s' "$json" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
print(eval(sys.argv[1], {"payload": payload}))
' "$expr"
}

write_fixture_roster() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<'EOF'
# Smoke fixture: agent X carries the relay residue (Gap A target).
BRIDGE_AGENT_CHANNELS["X"]="plugin:telegram@claude-plugins-official"
BRIDGE_AGENT_LAUNCH_CMD["X"]="claude --dangerously-load-development-channels plugin:telegram-relay@agent-bridge --dangerously-load-development-channels plugin:teams@agent-bridge --some-flag"
# Agent Y is clean; cleanup must not touch it.
BRIDGE_AGENT_CHANNELS["Y"]="plugin:telegram@claude-plugins-official"
BRIDGE_AGENT_LAUNCH_CMD["Y"]='claude --dangerously-load-development-channels plugin:teams@agent-bridge'
# Agent Z has a deliberately malformed (escaped-quote) value that the
# regex-based rewriter cannot safely touch — must surface in
# unparsed_launch_cmd_lines and be left untouched.
BRIDGE_AGENT_LAUNCH_CMD["Z"]="claude --foo \"plugin:telegram-relay@agent-bridge\""
EOF
}

write_fixture_live_files() {
  mkdir -p "$BRIDGE_HOME/lib" "$BRIDGE_HOME/plugins/telegram-relay"
  printf 'fixture: lib/telegram-relay.py\n' >"$BRIDGE_HOME/lib/telegram-relay.py"
  printf 'fixture: bridge-telegram-relay.sh\n' >"$BRIDGE_HOME/bridge-telegram-relay.sh"
  printf 'fixture: plugins/telegram-relay/server.ts\n' >"$BRIDGE_HOME/plugins/telegram-relay/server.ts"
}

assert_dry_run_reports_residue() {
  local json rewritten pruned migrated launch_x

  json="$(python3 "$CLEANUP_PY" --target-root "$BRIDGE_HOME" --dry-run --json)"
  rewritten="$(json_field "$json" 'payload["launch_cmds_rewritten"]')"
  pruned="$(json_field "$json" 'payload["live_files_pruned"]')"
  migrated="$(json_field "$json" 'payload["agents_migrated"]')"
  smoke_assert_eq "['X']" "$rewritten" "dry-run reports launch-cmd rewrite for agent X"
  smoke_assert_contains "$pruned" "lib/telegram-relay.py" "dry-run plans lib prune"
  smoke_assert_contains "$pruned" "bridge-telegram-relay.sh" "dry-run plans bridge-telegram-relay.sh prune"
  smoke_assert_contains "$pruned" "plugins/telegram-relay" "dry-run plans plugin tree prune"
  smoke_assert_eq "[]" "$migrated" "channel rewrite is no-op for already-clean fixture"

  # Dry-run must not mutate the roster.
  launch_x="$(grep '^BRIDGE_AGENT_LAUNCH_CMD\["X"\]=' "$BRIDGE_ROSTER_LOCAL_FILE")"
  smoke_assert_contains "$launch_x" "telegram-relay" "dry-run leaves roster untouched"

  # Dry-run must not delete fixture files.
  smoke_assert_file_exists "$BRIDGE_HOME/lib/telegram-relay.py" "dry-run preserves lib fixture"
  smoke_assert_file_exists "$BRIDGE_HOME/bridge-telegram-relay.sh" "dry-run preserves bridge-telegram-relay.sh fixture"
  smoke_assert_file_exists "$BRIDGE_HOME/plugins/telegram-relay/server.ts" "dry-run preserves plugin tree fixture"
}

assert_apply_rewrites_and_prunes() {
  local json launch_x launch_y launch_z restart_required backup_root pruned

  json="$(python3 "$CLEANUP_PY" --target-root "$BRIDGE_HOME" --json)"
  pruned="$(json_field "$json" 'payload["live_files_pruned"]')"
  smoke_assert_contains "$pruned" "lib/telegram-relay.py" "apply prunes lib"
  restart_required="$(json_field "$json" 'payload["agent_restart_required"]')"
  smoke_assert_eq "['X']" "$restart_required" "apply emits restart hint for X"

  launch_x="$(grep '^BRIDGE_AGENT_LAUNCH_CMD\["X"\]=' "$BRIDGE_ROSTER_LOCAL_FILE")"
  smoke_assert_not_contains "$launch_x" "telegram-relay" "agent X relay loader removed"
  smoke_assert_contains "$launch_x" "plugin:teams@agent-bridge" "agent X teams dev channel preserved"
  smoke_assert_contains "$launch_x" "--some-flag" "agent X --some-flag preserved"
  # Quote style must be preserved (X started double-quoted).
  smoke_assert_match "$launch_x" '^BRIDGE_AGENT_LAUNCH_CMD\["X"\]="' "agent X double-quote style preserved"

  launch_y="$(grep '^BRIDGE_AGENT_LAUNCH_CMD\["Y"\]=' "$BRIDGE_ROSTER_LOCAL_FILE")"
  smoke_assert_match "$launch_y" "^BRIDGE_AGENT_LAUNCH_CMD\\[\"Y\"\\]='" "agent Y single-quote style preserved (no rewrite)"
  smoke_assert_contains "$launch_y" "plugin:teams@agent-bridge" "agent Y line untouched"

  launch_z="$(grep '^BRIDGE_AGENT_LAUNCH_CMD\["Z"\]=' "$BRIDGE_ROSTER_LOCAL_FILE")"
  smoke_assert_contains "$launch_z" "telegram-relay" "agent Z malformed line left untouched"

  [[ ! -e "$BRIDGE_HOME/lib/telegram-relay.py" ]] || smoke_fail "apply did not delete lib/telegram-relay.py"
  [[ ! -e "$BRIDGE_HOME/bridge-telegram-relay.sh" ]] || smoke_fail "apply did not delete bridge-telegram-relay.sh"
  [[ ! -e "$BRIDGE_HOME/plugins/telegram-relay" ]] || smoke_fail "apply did not delete plugin tree"

  backup_root="$(json_field "$json" 'payload["backup_root"]')"
  [[ -n "$backup_root" && -d "$backup_root" ]] || smoke_fail "apply must create backup root, got: $backup_root"
  smoke_assert_file_exists "$backup_root/live/lib/telegram-relay.py" "backup captures lib"
  smoke_assert_file_exists "$backup_root/live/bridge-telegram-relay.sh" "backup captures bridge-telegram-relay.sh"
  smoke_assert_file_exists "$backup_root/live/plugins/telegram-relay/server.ts" "backup captures plugin tree"
}

assert_unparsed_reported() {
  local json unparsed
  # `assert_apply_rewrites_and_prunes` already mutated the roster. Z's
  # malformed line is the only relay-token line left after that pass —
  # re-run dry-run to capture it explicitly.
  json="$(python3 "$CLEANUP_PY" --target-root "$BRIDGE_HOME" --dry-run --json)"
  unparsed="$(json_field "$json" 'payload["unparsed_launch_cmd_lines"]')"
  smoke_assert_eq "['Z']" "$unparsed" "agent Z surfaces in unparsed_launch_cmd_lines"
}

assert_idempotent() {
  local json any_changes rewritten pruned

  # Drop agent Z so the second run is genuinely clean.
  python3 - "$BRIDGE_ROSTER_LOCAL_FILE" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
keep = [line for line in text.splitlines(keepends=True) if 'BRIDGE_AGENT_LAUNCH_CMD["Z"]' not in line]
path.write_text("".join(keep), encoding="utf-8")
PY

  json="$(python3 "$CLEANUP_PY" --target-root "$BRIDGE_HOME" --json)"
  any_changes="$(json_field "$json" 'payload["any_changes"]')"
  rewritten="$(json_field "$json" 'payload["launch_cmds_rewritten"]')"
  pruned="$(json_field "$json" 'payload["live_files_pruned"]')"
  smoke_assert_eq "False" "$any_changes" "second run is no-op"
  smoke_assert_eq "[]" "$rewritten" "second run does not re-rewrite"
  smoke_assert_eq "[]" "$pruned" "second run does not re-prune"
}

assert_symlink_safety() {
  local json skipped target_passwd

  # Reseed only the lib path as a symlink to a sensitive system file.
  rm -f "$BRIDGE_HOME/lib/telegram-relay.py"
  ln -s /etc/passwd "$BRIDGE_HOME/lib/telegram-relay.py"
  # Snapshot inode so we can prove /etc/passwd was not deleted/replaced.
  target_passwd="$(stat -f '%i' /etc/passwd 2>/dev/null || stat -c '%i' /etc/passwd)"

  json="$(python3 "$CLEANUP_PY" --target-root "$BRIDGE_HOME" --json)"
  skipped="$(json_field "$json" 'payload["prune_skipped"]')"
  smoke_assert_contains "$skipped" "lib/telegram-relay.py" "symlink prune is refused"

  [[ -L "$BRIDGE_HOME/lib/telegram-relay.py" ]] || smoke_fail "symlink must still exist (refused, not deleted)"
  [[ -r /etc/passwd ]] || smoke_fail "/etc/passwd must remain readable"
  local now_inode
  now_inode="$(stat -f '%i' /etc/passwd 2>/dev/null || stat -c '%i' /etc/passwd)"
  smoke_assert_eq "$target_passwd" "$now_inode" "/etc/passwd inode unchanged"

  # Cleanup the symlink so subsequent assertions start from a known shape.
  rm -f "$BRIDGE_HOME/lib/telegram-relay.py"
}

assert_stale_process_path_anchor() {
  local foreign_root sleeper_py json terminated intree_pid foreign_pid

  if ! command -v python3 >/dev/null 2>&1; then
    smoke_log "skipping stale-process assertion: python3 missing"
    return 0
  fi

  # Build an in-tree relay sleeper so the path-prefix matcher fires.
  mkdir -p "$BRIDGE_HOME/lib"
  sleeper_py="$BRIDGE_HOME/lib/telegram-relay.py"
  cat >"$sleeper_py" <<'PY'
import sys, time
# Distinct argv tail makes manual triage easier if the smoke ever
# leaks a sleeper into the operator's process table.
sys.argv = sys.argv + ["--smoke-fixture-tag=residue-cleanup"]
time.sleep(120)
PY

  # Foreign sleeper (different root → must not be killed).
  foreign_root="$SMOKE_TMP_ROOT/foreign-bridge"
  mkdir -p "$foreign_root/lib"
  cp "$sleeper_py" "$foreign_root/lib/telegram-relay.py"

  python3 "$sleeper_py" >/dev/null 2>&1 &
  intree_pid=$!
  SMOKE_RELAY_INTREE_PID="$intree_pid"
  python3 "$foreign_root/lib/telegram-relay.py" >/dev/null 2>&1 &
  foreign_pid=$!
  SMOKE_RELAY_FOREIGN_PID="$foreign_pid"

  # Give both sleepers a moment to enter ps.
  sleep 1

  json="$(python3 "$CLEANUP_PY" --target-root "$BRIDGE_HOME" --term-timeout 4 --json)"
  terminated="$(json_field "$json" 'payload["stale_processes_terminated"]')"
  smoke_assert_contains "$terminated" "$intree_pid:" "in-tree relay PID matched and reported"
  smoke_assert_not_contains "$terminated" "$foreign_pid:" "foreign-install relay PID NOT matched"

  # Foreign sleeper must still be alive.
  if ! kill -0 "$foreign_pid" 2>/dev/null; then
    smoke_fail "foreign-install relay process was killed (path-prefix anchor leak)"
  fi
  # In-tree sleeper should be gone.
  if kill -0 "$intree_pid" 2>/dev/null; then
    smoke_fail "in-tree relay process survived SIGTERM/SIGKILL"
  fi
  SMOKE_RELAY_INTREE_PID=""
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "telegram-relay-residue"
  write_fixture_roster
  write_fixture_live_files
  smoke_run "dry-run reports residue without mutating" assert_dry_run_reports_residue
  smoke_run "apply rewrites launch cmd, prunes live tree, backs up" assert_apply_rewrites_and_prunes
  smoke_run "malformed launch-cmd line surfaces as unparsed" assert_unparsed_reported
  smoke_run "idempotent on a clean install" assert_idempotent
  smoke_run "symlink at residue path refused" assert_symlink_safety
  smoke_run "stale-process matcher anchored to absolute target_root" assert_stale_process_path_anchor
  smoke_log "passed"
}

main "$@"
