#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
#
# Bug #507 — backup residue cleanup helpers, invoked from `agb upgrade --apply`
# (and standalone via the operator-facing snippets in OPERATOR_ACTIONS_PENDING).
#
# Functions are idempotent and never abort the upgrade. They emit a structured
# summary on stdout so the caller (bridge-upgrade.sh) can fold it into the
# upgrade JSON output and the [upgrade-complete] task body.

# Run cleanup-residue subcommand and print its JSON payload to stdout. Returns
# 0 on success; non-zero only if the python3 invocation itself failed (e.g.
# python missing). Cleanup-internal failures are reported via the
# `cleanup_failures` array in the JSON, not via exit code.
#
# Required env:
#   BRIDGE_CLEANUP_TARGET_ROOT     — BRIDGE_HOME of the install being upgraded
#   BRIDGE_CLEANUP_SOURCE_ROOT     — source checkout containing bridge-upgrade.py
# Optional env:
#   BRIDGE_CLEANUP_BACKUP_DIR              (default <target>/backups/daily)
#   BRIDGE_CLEANUP_UPGRADE_BACKUPS_DIR     (default <target>/backups)
#   BRIDGE_CLEANUP_CURRENT_BACKUP_ROOT     (current upgrade backup; preserved)
#   BRIDGE_CLEANUP_NO_BACKUP_MODE          (1 → skip upgrade-* prune)
#   BRIDGE_CLEANUP_DAILY_RETAIN_DAYS       (default 7)
#   BRIDGE_CLEANUP_UPGRADE_RETAIN_COUNT    (default 5)
#   BRIDGE_CLEANUP_UPGRADE_RETAIN_DAYS     (default 14)
#   BRIDGE_CLEANUP_CLAUDE_CONFIG_PATH      (default ~/.claude.json)
bridge_cleanup_daily_backup_residue() {
  local target_root="${BRIDGE_CLEANUP_TARGET_ROOT:-}"
  local source_root="${BRIDGE_CLEANUP_SOURCE_ROOT:-}"
  local backup_dir="${BRIDGE_CLEANUP_BACKUP_DIR:-}"
  local upgrade_backups_dir="${BRIDGE_CLEANUP_UPGRADE_BACKUPS_DIR:-}"
  local current_backup_root="${BRIDGE_CLEANUP_CURRENT_BACKUP_ROOT:-}"
  local no_backup_mode="${BRIDGE_CLEANUP_NO_BACKUP_MODE:-0}"
  local daily_retain_days="${BRIDGE_CLEANUP_DAILY_RETAIN_DAYS:-7}"
  local upgrade_retain_count="${BRIDGE_CLEANUP_UPGRADE_RETAIN_COUNT:-5}"
  local upgrade_retain_days="${BRIDGE_CLEANUP_UPGRADE_RETAIN_DAYS:-14}"
  local claude_config_path="${BRIDGE_CLEANUP_CLAUDE_CONFIG_PATH:-}"

  if [[ -z "$target_root" || -z "$source_root" ]]; then
    printf '{"cleanup_failures":[{"step":"setup","error":"target_root or source_root unset"}]}\n'
    return 1
  fi
  [[ -n "$backup_dir" ]] || backup_dir="$target_root/backups/daily"
  [[ -n "$upgrade_backups_dir" ]] || upgrade_backups_dir="$target_root/backups"

  local args=(cleanup-residue
    --target-root "$target_root"
    --backup-dir "$backup_dir"
    --upgrade-backups-dir "$upgrade_backups_dir"
    --daily-retain-days "$daily_retain_days"
    --upgrade-retain-count "$upgrade_retain_count"
    --upgrade-retain-days "$upgrade_retain_days"
  )
  [[ -n "$current_backup_root" ]] && args+=(--current-backup-root "$current_backup_root")
  [[ "$no_backup_mode" == "1" ]] && args+=(--no-backup-mode)
  [[ -n "$claude_config_path" ]] && args+=(--claude-config-path "$claude_config_path")

  python3 "$source_root/bridge-upgrade.py" "${args[@]}"
}

# Render a human-readable cleanup summary block from the JSON cleanup payload.
# Output is plain markdown suitable for embedding in:
#   - the upgrade stdout output
#   - the [upgrade-complete] task body
# Stdin: JSON cleanup payload from bridge_cleanup_daily_backup_residue.
# Stdout: markdown block.
bridge_cleanup_render_summary() {
  # Issue #872 / PR #886:
  #
  # Round 1 history: the original surface used `python3 - <<'PY' ... PY`,
  # which makes the heredoc body itself python3's stdin (because `-` reads
  # the script from stdin). The caller's `printf '%s' "$CLEANUP_JSON" |
  # bridge_cleanup_render_summary` pipe was therefore inaccessible to the
  # renderer — sys.stdin always returned empty and json.load surfaced
  # JSONDecodeError verbatim into the [upgrade-complete] task body.
  #
  # Round 1 fix (PR #886 r1) replaced the heredoc-stdin form with a
  # `cat >"$script_tmp" <<'PY' ... PY` tempfile-script form. r1 codex
  # review correctly flagged this as self-contradictory: the original
  # bug class is "heredoc-as-content-delivery is fragile under the
  # post-#800 heredoc/here-string toolchain" (see HANDOFF_2026-05-08).
  # Mitigating a footgun #11 trip with another heredoc still leaves the
  # heredoc-content boundary in the source — every new heredoc is a
  # fresh failure surface and a regression magnet (#840 docstring-literal
  # trip is the most recent recurrence).
  #
  # Round 2 fix (this commit): the renderer body lives as a tracked
  # python file under scripts/python-helpers/cleanup-payload-renderer.py
  # and we invoke it as `python3 <path>`. fd 0 still points at the
  # caller's pipe so sys.stdin.read() sees the JSON payload as intended.
  # No heredoc, no tempfile script write — the script is content the
  # repo ships, not content this function emits.
  #
  # We self-resolve the script path from BASH_SOURCE so the helper works
  # both inside the full upgrader (BRIDGE_SCRIPT_DIR set by bridge-lib.sh)
  # and under the smoke runner (only lib/bridge-cleanup.sh sourced).
  local _self_dir
  _self_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  local renderer="$_self_dir/scripts/python-helpers/cleanup-payload-renderer.py"
  if [[ ! -f "$renderer" ]]; then
    printf '## Backup residue cleanup\n\n_Renderer payload missing at %s._\n' \
      "$renderer"
    return 0
  fi
  python3 "$renderer"
}

# Render the agent-safe verification block embedded in the [upgrade-complete]
# task body. Caller passes BRIDGE_HOME so the snippet uses absolute paths
# (avoids ambiguity when an admin pastes from an unrelated shell).
bridge_cleanup_render_verification_block() {
  local target_root="${1:-$HOME/.agent-bridge}"
  cat <<EOF
## Daily-backup health check

Run these commands from any shell with python3 available. All are read-only.

\`\`\`bash
TARGET_ROOT="$target_root"

# 1. Backup directory hygiene
du -sh "\$TARGET_ROOT/backups/daily" "\$TARGET_ROOT/backups"/upgrade-* 2>/dev/null
ls "\$TARGET_ROOT/backups/daily"/*.tgz.tmp.* 2>/dev/null \\
  && echo "STALE TMP STILL PRESENT — re-run agb upgrade or manually rm them" \\
  || echo "tmp clean"

# 2. Daemon + agent bridge status
agent-bridge status 2>/dev/null | head -20

# 3. Daily-backup state (cooldown / last success / last failure)
cat "\$TARGET_ROOT/state/daily-backup/state.env" 2>/dev/null || echo "(no state yet)"

# 4. tasks.db integrity (read-only, agent-safe)
python3 "\$TARGET_ROOT/bridge-upgrade.py" verify-tasks-db --target-root "\$TARGET_ROOT"

# 5. ~/.claude.json validity
python3 -c "import json,os; json.load(open(os.path.expanduser('~/.claude.json'))); print('.claude.json OK')" \\
  || echo ".claude.json CORRUPTED — restore from ~/.claude/backups/<latest>/.claude.json"

# 6. Latest SQL snapshot restore self-test (writes to a temp DB, not live)
LATEST=\$(ls -1t "\$TARGET_ROOT/state/backup-snapshots"/tasks-*.sql.gz 2>/dev/null | head -1)
if [[ -n "\$LATEST" ]]; then
  TMPDB=\$(mktemp "\${TMPDIR:-/tmp}/agb-restore-check.sqlite.XXXXXX")
  if gunzip -c "\$LATEST" | sqlite3 "\$TMPDB" >/dev/null 2>&1; then
    echo "snapshot restorable: \$LATEST"
  else
    echo "snapshot BROKEN: \$LATEST"
  fi
  rm -f "\$TMPDB"
else
  echo "(no SQL snapshot yet — first daily backup hasn't run)"
fi
\`\`\`

If any step prints CORRUPTED / BROKEN / STALE TMP, see
\`OPERATOR_ACTIONS_PENDING.md\` § "v0.7.1 → v0.7.2 — daily-backup residue cleanup"
for the manual recovery commands.
EOF
}
