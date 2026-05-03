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
  python3 - <<'PY'
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f"## Backup residue cleanup\n\nCould not parse cleanup payload: {exc}")
    raise SystemExit(0)

stale = data.get("stale_tmp_removed") or []
daily = data.get("daily_pruned") or []
snaps = data.get("snapshots_pruned") or []
upg = data.get("upgrade_backups") or {}
upg_pruned = upg.get("pruned") or []
upg_preserved = upg.get("preserved") or []
cfg = data.get("claude_config") or {}
fails = data.get("cleanup_failures") or []

freed_human = data.get("bytes_freed_human") or "0 B"
before_human = data.get("free_bytes_before_human") or "?"
after_human = data.get("free_bytes_after_human") or "?"

lines = ["## Backup residue cleanup", ""]
lines.append(f"- Disk free before → after: **{before_human} → {after_human}** "
             f"(freed: **{freed_human}**)")
lines.append(f"- Stale `*.tgz.tmp.*` reaped: **{len(stale)}**")
lines.append(f"- Daily archives pruned (retain=7d default): **{len(daily)}**")
lines.append(f"- SQL snapshots pruned: **{len(snaps)}**")
if upg.get("skipped_no_backup_mode"):
    lines.append("- Upgrade-* backups: **skipped** (--no-backup mode)")
else:
    lines.append(f"- Upgrade-* backups pruned: **{len(upg_pruned)}** "
                 f"(preserved {len(upg_preserved)} including current)")

cfg_status = cfg.get("status", "unknown")
status_blurb = {
    "ok": "valid JSON",
    "missing": "not present (no Claude Code installed for this user?)",
    "corrupted": "**CORRUPTED — recover from ~/.claude/backups/**",
    "unreadable": "unreadable (permissions?)",
}.get(cfg_status, cfg_status)
lines.append(f"- `~/.claude.json`: {status_blurb}")
if cfg_status == "corrupted" and cfg.get("recovery_candidate"):
    lines.append(f"  - Suggested recovery source: `{cfg['recovery_candidate']}`")

if fails:
    lines.append("")
    lines.append("### Cleanup failures (manual follow-up required)")
    for failure in fails:
        step = failure.get("step", "?")
        err = failure.get("error", "?")
        path = failure.get("path", "")
        suffix = f" (path={path})" if path else ""
        lines.append(f"- `{step}`: {err}{suffix}")

print("\n".join(lines))
PY
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
  TMPDB=\$(mktemp -t agb-restore-check.XXXXXX.sqlite)
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
