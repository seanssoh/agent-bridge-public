#!/usr/bin/env python3
"""bridge-migrate.py — canonical overhead migration for Track 1 redesign.

Subcommands:
  overhead pre-migrate --output <file>
      Snapshot each agent's current CLAUDE.md size, line count, and managed
      block byte count. JSON report written to --output.

  overhead dry-run [--agent <name>|--all]
      Render what the new managed block would look like (with session_type
      filter) and compare to the current one. Emits a per-agent byte diff
      summary and lists detected legacy inline blocks that will be replaced
      by pointers.
      Writes nothing to disk.

  overhead apply [--agent <name>|--all] [--yes]
      Run normalize_claude() for each selected agent. Records a JSONL log
      under <bridge-home>/state/doc-migration/apply-<YYYYMMDD-HHMMSS>-<pid>.jsonl
      and backups under a matching `backups-<stamp>` directory. If the old
      managed block contains legacy inline sections, also writes a sidecar
      CLAUDE.md.bak-<YYYYMMDD>-managed-block backup next to CLAUDE.md for
      operator inspection. Rollback uses the state backup. The PID suffix
      prevents collisions when two runs start in the same second.

  overhead rollback --stamp <YYYYMMDD-HHMMSS-<pid>>
      Replays the apply JSONL and restores each backup file.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path


LEGACY_INLINE_BLOCKS = (
    ("external_push_policy", "## Agent Bridge external push policy"),
    ("autonomy_anti_stall", "## Autonomy & Anti-Stall"),
    ("upstream_issue_policy", "## Upstream Issue Policy"),
    ("admin_first_run_onboarding", "## Admin First-Run Onboarding Defaults"),
    ("admin_self_cleanup", "## Admin Self-Cleanup of Own Queue"),
    ("admin_static_dynamic_boundary", "## Admin Static vs Dynamic Agent Boundary"),
    ("admin_upgrade_protocol", "## Admin Upgrade Protocol"),
    ("channel_setup_protocol", "## Channel Setup Protocol"),
)


def _script_dir() -> Path:
    """Directory containing this script — source tree for sibling modules."""
    return Path(__file__).resolve().parent


def _bridge_home() -> Path:
    """Runtime BRIDGE_HOME (where agents/, state/, shared/, logs/ live).

    Falls back to this script's directory only for backwards compatibility
    with invocations that don't export BRIDGE_HOME and where the source
    checkout happens to coincide with the runtime root. New code should
    prefer explicit --bridge-home on the CLI.
    """
    env = os.environ.get("BRIDGE_HOME")
    if env:
        return Path(env)
    return _script_dir()


def _load_bridge_docs():
    """Import bridge-docs.py as module `_bridge_docs` (hyphen workaround).

    Always load the bridge-docs.py that lives alongside this script, never
    the one under BRIDGE_HOME — an installed BRIDGE_HOME may hold an older
    runtime copy that lacks symbols (e.g. read_session_type) this script
    needs. See codex review of v0.3.8 -> v0.4.0 diff: the old behaviour
    crashed `AttributeError: module '_bridge_docs' has no attribute
    'read_session_type'` whenever an operator ran a new source checkout
    against their existing BRIDGE_HOME.
    """
    script = _script_dir() / "bridge-docs.py"
    spec = importlib.util.spec_from_file_location("_bridge_docs", str(script))
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load bridge-docs.py from {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["_bridge_docs"] = module
    spec.loader.exec_module(module)
    return module


def _agents_root(bridge_home: Path) -> Path:
    return bridge_home / "agents"


def _list_agents(bridge_home: Path) -> list[str]:
    root = _agents_root(bridge_home)
    if not root.exists():
        return []
    out = []
    for entry in sorted(root.iterdir()):
        if not entry.is_dir():
            continue
        if entry.name.startswith("_") or entry.name.startswith("."):
            continue
        # Skip agents without CLAUDE.md; nothing to migrate.
        if not (entry / "CLAUDE.md").exists():
            continue
        out.append(entry.name)
    return out


def _managed_block_text(text: str, bd) -> str:
    match = re.search(
        rf"{re.escape(bd.MANAGED_START)}.*?{re.escape(bd.MANAGED_END)}",
        text,
        flags=re.S,
    )
    return match.group(0) if match else ""


def _measure(agent_dir: Path) -> dict:
    """Return a size/shape fingerprint for agent's CLAUDE.md + managed block."""
    claude = agent_dir / "CLAUDE.md"
    if not claude.exists():
        return {
            "agent": agent_dir.name,
            "exists": False,
        }
    try:
        text = claude.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return {"agent": agent_dir.name, "exists": True, "readable": False}
    bd = sys.modules.get("_bridge_docs") or _load_bridge_docs()
    managed_block = _managed_block_text(text, bd)
    managed_bytes = 0
    legacy_inline_blocks: list[str] = []
    if managed_block:
        managed_bytes = len(managed_block.encode("utf-8"))
        legacy_inline_blocks = _detect_legacy_inline_blocks(managed_block)
    return {
        "agent": agent_dir.name,
        "exists": True,
        "readable": True,
        "session_type": bd.read_session_type(agent_dir),
        "total_bytes": len(text.encode("utf-8")),
        "total_lines": text.count("\n") + (0 if text.endswith("\n") else 1),
        "managed_bytes": managed_bytes,
        "has_managed_block": bool(managed_block),
        "legacy_inline_blocks": legacy_inline_blocks,
    }


def _detect_legacy_inline_blocks(text: str) -> list[str]:
    """Return legacy managed-block sections that should now be pointers."""
    found: list[str] = []
    for key, heading in LEGACY_INLINE_BLOCKS:
        if heading in text:
            found.append(key)
    return found


def _legacy_sidecar_backup_path(claude_path: Path, stamp: str) -> Path:
    date_part = stamp.split("-", 1)[0]
    base = claude_path.with_name(f"{claude_path.name}.bak-{date_part}-managed-block")
    if not base.exists():
        return base
    for index in range(2, 100):
        candidate = claude_path.with_name(f"{claude_path.name}.bak-{date_part}-managed-block-{index}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"could not allocate sidecar backup path for {claude_path}")


def cmd_pre_migrate(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home)
    rows = [_measure(_agents_root(bridge_home) / name) for name in _list_agents(bridge_home)]
    payload = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "bridge_home": str(bridge_home),
        "agent_count": len(rows),
        "rows": rows,
    }
    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.json or not args.output:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def _select_agents(args: argparse.Namespace, bridge_home: Path) -> list[str]:
    if args.agent:
        return [args.agent]
    if args.all:
        return _list_agents(bridge_home)
    return _list_agents(bridge_home)  # default: all


def cmd_dry_run(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home)
    bd = _load_bridge_docs()
    diffs: list[dict] = []
    for name in _select_agents(args, bridge_home):
        agent_dir = _agents_root(bridge_home) / name
        before = _measure(agent_dir)
        if not before.get("has_managed_block"):
            diffs.append({**before, "status": "no-managed-block"})
            continue
        # Render what the new block would look like.
        new_block = bd.render_agent_bridge_block(agent_dir)
        new_block_bytes = len(new_block.encode("utf-8"))
        diffs.append({
            "agent": name,
            "session_type": before.get("session_type"),
            "managed_bytes_before": before.get("managed_bytes"),
            "managed_bytes_after": new_block_bytes,
            "delta_bytes": new_block_bytes - before.get("managed_bytes", 0),
            "legacy_inline_blocks": before.get("legacy_inline_blocks", []),
        })
    payload = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "bridge_home": str(bridge_home),
        "diffs": diffs,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        for d in diffs:
            if d.get("status"):
                print(f"- {d['agent']}: {d['status']}")
                continue
            print(f"- {d['agent']} ({d['session_type']}): {d['managed_bytes_before']} → {d['managed_bytes_after']} bytes ({d['delta_bytes']:+d})")
            if d.get("legacy_inline_blocks"):
                print(f"  legacy inline blocks: {', '.join(d['legacy_inline_blocks'])}")
    return 0


def _apply_log_path(bridge_home: Path, stamp: str) -> Path:
    return bridge_home / "state" / "doc-migration" / f"apply-{stamp}.jsonl"


def cmd_apply(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home)
    if not args.yes and not args.dry_run:
        print("refusing to apply without --yes (or pass --dry-run).", file=sys.stderr)
        return 2
    bd = _load_bridge_docs()
    # Stamp includes the PID so two runs starting in the same second get
    # distinct log + backup locations. Rollback takes the same stamp back.
    stamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}"
    log_path = _apply_log_path(bridge_home, stamp)
    backup_root = bridge_home / "state" / "doc-migration" / f"backups-{stamp}"
    results: list[dict] = []
    ok = 0
    failed = 0
    agents = _select_agents(args, bridge_home)
    for name in agents:
        agent_dir = _agents_root(bridge_home) / name
        claude_path = agent_dir / "CLAUDE.md"
        if not claude_path.exists():
            results.append({"agent": name, "status": "skip-no-claude"})
            continue
        try:
            original_text = claude_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            results.append({"agent": name, "status": "unreadable", "error": str(exc)})
            failed += 1
            continue
        legacy_inline_blocks = _detect_legacy_inline_blocks(_managed_block_text(original_text, bd))
        # Record backup (actual file copy; the normalize_claude internal
        # backup_root is not used here to keep control of the stamped layout).
        sidecar_backup = ""
        if not args.dry_run:
            backup_root.mkdir(parents=True, exist_ok=True)
            backup_file = backup_root / f"{name}.CLAUDE.md.bak"
            backup_file.write_text(original_text, encoding="utf-8")
            if legacy_inline_blocks:
                sidecar_path = _legacy_sidecar_backup_path(claude_path, stamp)
                shutil.copy2(claude_path, sidecar_path)
                sidecar_backup = str(sidecar_path)
        # Invoke normalize_claude through bridge-docs.
        try:
            changed = bd.normalize_claude(agent_dir, args.dry_run, backup_root)
        except Exception as exc:  # broad — we do not want one agent to poison the batch
            results.append({
                "agent": name,
                "status": "error",
                "error": f"{type(exc).__name__}: {exc}",
            })
            failed += 1
            continue
        results.append({
            "agent": name,
            "status": "changed" if changed else "unchanged",
            "session_type": bd.read_session_type(agent_dir),
            "backup": str((backup_root / f"{name}.CLAUDE.md.bak") if not args.dry_run else ""),
            "legacy_sidecar_backup": sidecar_backup,
            "legacy_inline_blocks": legacy_inline_blocks,
            "claude_path": str(claude_path),
        })
        if changed:
            ok += 1
    if not args.dry_run:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as fh:
            for row in results:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    payload = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "bridge_home": str(bridge_home),
        "stamp": stamp,
        "apply_log": str(log_path) if not args.dry_run else "",
        "backup_root": str(backup_root) if not args.dry_run else "",
        "ok": ok,
        "failed": failed,
        "results": results,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"{ok} ok, {failed} failed (stamp={stamp})")
    return 0 if failed == 0 else 1


def cmd_rollback(args: argparse.Namespace) -> int:
    bridge_home = Path(args.bridge_home)
    if not args.stamp:
        print("--stamp <YYYYMMDD-HHMMSS-<pid>> required", file=sys.stderr)
        return 2
    log_path = _apply_log_path(bridge_home, args.stamp)
    if not log_path.exists():
        print(f"apply log not found: {log_path}", file=sys.stderr)
        return 2
    restored = 0
    failed = 0
    for line in log_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("status") != "changed":
            continue
        backup = row.get("backup") or ""
        claude = row.get("claude_path") or ""
        if not backup or not claude or not Path(backup).exists():
            failed += 1
            continue
        try:
            shutil.copyfile(backup, claude)
            restored += 1
        except OSError:
            failed += 1
    payload = {
        "stamp": args.stamp,
        "log_path": str(log_path),
        "restored": restored,
        "failed": failed,
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"restored: {restored}, failed: {failed}")
    return 0 if failed == 0 else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    # `overhead` subcommand group
    overhead = sub.add_parser("overhead")
    oh = overhead.add_subparsers(dest="action", required=True)

    common_kwargs = dict()

    pre = oh.add_parser("pre-migrate")
    pre.add_argument("--bridge-home", default=str(_bridge_home()))
    pre.add_argument("--output")
    pre.add_argument("--json", action="store_true")
    pre.set_defaults(func=cmd_pre_migrate)

    dry = oh.add_parser("dry-run")
    dry.add_argument("--bridge-home", default=str(_bridge_home()))
    group = dry.add_mutually_exclusive_group()
    group.add_argument("--agent")
    group.add_argument("--all", action="store_true")
    dry.add_argument("--json", action="store_true")
    dry.set_defaults(func=cmd_dry_run)

    apl = oh.add_parser("apply")
    apl.add_argument("--bridge-home", default=str(_bridge_home()))
    group2 = apl.add_mutually_exclusive_group()
    group2.add_argument("--agent")
    group2.add_argument("--all", action="store_true")
    apl.add_argument("--yes", action="store_true")
    apl.add_argument("--dry-run", action="store_true")
    apl.add_argument("--json", action="store_true")
    apl.set_defaults(func=cmd_apply)

    rb = oh.add_parser("rollback")
    rb.add_argument("--bridge-home", default=str(_bridge_home()))
    rb.add_argument("--stamp", required=True)
    rb.add_argument("--json", action="store_true")
    rb.set_defaults(func=cmd_rollback)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
