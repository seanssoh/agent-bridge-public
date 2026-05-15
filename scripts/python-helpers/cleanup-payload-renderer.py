#!/usr/bin/env python3
"""Renderer body for bridge_cleanup_render_summary (lib/bridge-cleanup.sh).

Lives as a tracked file under scripts/python-helpers/ so the shell caller can
invoke it via `python3 <path>` instead of feeding the body through a
`cat > tmp <<'PY' ... PY` heredoc. The heredoc form is footgun #11
(see lib/bridge-init-default-crons.sh, #800, HANDOFF_2026-05-08) — even when
the heredoc target is a tempfile rather than python3's stdin directly, every
new heredoc in mitigation code creates a fresh failure surface. PR #886 r1
codex review flagged that the original #872 fix wrote the python body via
`cat > "$script_tmp" <<'PY'` inside the very function that was supposed to
mitigate the footgun — self-contradictory. This file is the r2 fix:
fixture-file delivery, no heredoc.

Contract:
  stdin  — JSON cleanup payload from bridge_cleanup_daily_backup_residue
           (empty / unparseable / valid all supported).
  stdout — markdown summary block suitable for the upgrade stdout output
           and the [upgrade-complete] task body.
  exit   — always 0; the renderer never breaks the upgrade tail.
"""

import json
import sys


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        print(
            "## Backup residue cleanup\n\n"
            "_Cleanup helper returned empty payload (no work performed)._"
        )
        return 0

    try:
        data = json.loads(raw)
    except Exception:
        print(
            "## Backup residue cleanup\n\n"
            "_Cleanup payload could not be parsed; see daemon logs for details._"
        )
        return 0

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
    lines.append(
        f"- Disk free before → after: **{before_human} → {after_human}** "
        f"(freed: **{freed_human}**)"
    )
    lines.append(f"- Stale `*.tgz.tmp.*` reaped: **{len(stale)}**")
    lines.append(f"- Daily archives pruned (retain=7d default): **{len(daily)}**")
    lines.append(f"- SQL snapshots pruned: **{len(snaps)}**")
    if upg.get("skipped_no_backup_mode"):
        lines.append("- Upgrade-* backups: **skipped** (--no-backup mode)")
    else:
        lines.append(
            f"- Upgrade-* backups pruned: **{len(upg_pruned)}** "
            f"(preserved {len(upg_preserved)} including current)"
        )

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
    return 0


if __name__ == "__main__":
    sys.exit(main())
