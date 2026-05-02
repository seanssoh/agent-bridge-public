#!/usr/bin/env python3
"""v0.7.x telegram-relay residue cleanup.

Idempotent best-effort cleanup of any leftover state from the v0.6.37+
relay daemon (#475 phases 2/3, removed in v0.7.0 #501). Designed to run
once during ``agent-bridge upgrade --apply`` so operators do not have to
hand-paste the cleanup steps from
``docs/proposals/v0.7.0-install-cleanup-verification-prompt.md``.

Touched surface:

- ``state/channels/telegram/{tokens.list, *.sock, <token-hash>/}``
- ``agents/<agent>/.telegram/relay-token`` (per-agent token files)
- ``agent-roster.local.sh``:
  - ``BRIDGE_AGENT_CHANNELS["X"]`` containing ``plugin:telegram-relay@*``
    is rewritten to drop the relay item and ensure
    ``plugin:telegram@claude-plugins-official`` is present
  - ``BRIDGE_TELEGRAM_RELAY_ENABLED`` and ``BRIDGE_TELEGRAM_USE_RELAY``
    scalar lines are deleted (matches both bare and ``export`` form)

Preserved:

- Per-agent ``.telegram/.env`` and ``.telegram/access.json`` — the
  official ``plugin:telegram@claude-plugins-official`` still reads them.
- Anything else under ``state/channels/telegram/`` that does not match
  the deletion patterns (none should exist post-PR3, but defensive).

Stdlib only. Returns JSON summary on stdout when ``--json`` is set.

Exit code:
  0 — success or no-op
  1 — hard error (filesystem permission, malformed roster file)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ENV_KEYS_TO_REMOVE = (
    "BRIDGE_TELEGRAM_RELAY_ENABLED",
    "BRIDGE_TELEGRAM_USE_RELAY",
)

CHANNEL_LINE_RE = re.compile(
    r'^([ \t]*BRIDGE_AGENT_CHANNELS\["([^"]+)"\]=)"([^"]*)"(.*)$'
)


def _load_text(path: Path) -> str | None:
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8")


def _atomic_write(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".cleanup-tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def remove_env_lines(roster_path: Path, *, dry_run: bool) -> list[str]:
    """Delete ``BRIDGE_TELEGRAM_RELAY_*`` and ``BRIDGE_TELEGRAM_USE_RELAY``.

    Matches both bare assignment (``KEY=value``) and ``export`` form
    (``export KEY=value``). De-duplicates the returned key list when a key
    appears more than once. Returns ``[]`` if no-op.
    """
    text = _load_text(roster_path)
    if text is None:
        return []
    pattern = re.compile(
        r"^[ \t]*(?:export[ \t]+)?("
        + "|".join(re.escape(k) for k in ENV_KEYS_TO_REMOVE)
        + r")="
    )
    keep: list[str] = []
    removed: list[str] = []
    for line in text.splitlines(keepends=True):
        m = pattern.match(line)
        if m:
            removed.append(m.group(1))
            continue
        keep.append(line)
    if not removed:
        return []
    if not dry_run:
        _atomic_write(roster_path, "".join(keep))
    deduped: list[str] = []
    seen: set[str] = set()
    for k in removed:
        if k not in seen:
            seen.add(k)
            deduped.append(k)
    return deduped


def _is_relay_item(item: str) -> bool:
    item = item.strip()
    return item == "plugin:telegram-relay" or item.startswith("plugin:telegram-relay@")


def rewrite_channels(roster_path: Path, *, dry_run: bool) -> list[str]:
    """Rewrite ``BRIDGE_AGENT_CHANNELS`` lines that contain a relay variant.

    For each affected line: drop every ``plugin:telegram-relay*`` item
    from the comma-separated list, ensure
    ``plugin:telegram@claude-plugins-official`` is present (added if not
    already in the kept list). Returns the agent names whose lines were
    rewritten (in roster order, with duplicates if the same agent is
    declared more than once — the helper preserves whatever shape the
    operator wrote).
    """
    text = _load_text(roster_path)
    if text is None:
        return []
    new_lines: list[str] = []
    affected: list[str] = []
    for line in text.splitlines(keepends=True):
        m = CHANNEL_LINE_RE.match(line.rstrip("\n"))
        if not m:
            new_lines.append(line)
            continue
        prefix, agent, csv, suffix = m.group(1), m.group(2), m.group(3), m.group(4)
        items = [s.strip() for s in csv.split(",") if s.strip()]
        if not any(_is_relay_item(it) for it in items):
            new_lines.append(line)
            continue
        kept: list[str] = []
        seen_official = False
        for it in items:
            if _is_relay_item(it):
                continue
            if it == "plugin:telegram@claude-plugins-official":
                seen_official = True
            kept.append(it)
        if not seen_official:
            kept.append("plugin:telegram@claude-plugins-official")
        rewritten = f'{prefix}"{",".join(kept)}"{suffix}'
        if not rewritten.endswith("\n"):
            rewritten += "\n"
        new_lines.append(rewritten)
        affected.append(agent)
    if not affected:
        return []
    if not dry_run:
        _atomic_write(roster_path, "".join(new_lines))
    return affected


def remove_state_files(state_root: Path, *, dry_run: bool) -> list[str]:
    """Remove orphaned relay state under ``state/channels/telegram/``.

    Targets: ``tokens.list``, ``*.sock``, and any subdirectory (the
    ``<token-hash>/`` daemon state dirs). Returns paths removed in
    deterministic (sorted) order.
    """
    if not state_root.is_dir():
        return []
    removed: list[str] = []
    tokens = state_root / "tokens.list"
    if tokens.is_file():
        if not dry_run:
            tokens.unlink()
        removed.append(str(tokens))
    for sock in sorted(state_root.glob("*.sock")):
        if not dry_run:
            try:
                sock.unlink()
            except FileNotFoundError:
                continue
        removed.append(str(sock))
    for sub in sorted(state_root.iterdir()):
        if sub.is_dir() and not sub.is_symlink():
            if not dry_run:
                _rmtree_safe(sub)
            removed.append(str(sub) + "/")
    return removed


def _rmtree_safe(path: Path) -> None:
    """Recursively delete; never follows symlinks, never crosses bind mounts."""
    if path.is_symlink() or not path.is_dir():
        try:
            path.unlink()
        except (FileNotFoundError, IsADirectoryError):
            pass
        return
    for child in path.iterdir():
        _rmtree_safe(child)
    path.rmdir()


def remove_per_agent_relay_tokens(agents_root: Path, *, dry_run: bool) -> list[str]:
    """Remove ``<agent>/.telegram/relay-token`` files. Returns paths removed."""
    if not agents_root.is_dir():
        return []
    removed: list[str] = []
    for agent_dir in sorted(agents_root.iterdir()):
        if not agent_dir.is_dir() or agent_dir.is_symlink():
            continue
        relay_token = agent_dir / ".telegram" / "relay-token"
        if relay_token.is_file():
            if not dry_run:
                relay_token.unlink()
            removed.append(str(relay_token))
    return removed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target-root",
        required=True,
        help="BRIDGE_HOME equivalent (the live runtime root).",
    )
    parser.add_argument(
        "--roster-file",
        help="Override roster path; default <target-root>/agent-roster.local.sh",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Detect only; do not modify any file.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON summary on stdout (default: human key: value lines).",
    )
    args = parser.parse_args()

    target_root = Path(args.target_root).expanduser()
    roster_file = Path(args.roster_file or (target_root / "agent-roster.local.sh"))
    state_root = target_root / "state" / "channels" / "telegram"
    agents_root = target_root / "agents"

    try:
        agents_migrated = rewrite_channels(roster_file, dry_run=args.dry_run)
        env_keys_removed = remove_env_lines(roster_file, dry_run=args.dry_run)
        state_files_removed = remove_state_files(state_root, dry_run=args.dry_run)
        agent_tokens_removed = remove_per_agent_relay_tokens(
            agents_root, dry_run=args.dry_run
        )
    except OSError as exc:
        print(f"relay-cleanup: filesystem error: {exc}", file=sys.stderr)
        return 1

    summary = {
        "dry_run": args.dry_run,
        "agents_migrated": agents_migrated,
        "env_keys_removed": env_keys_removed,
        "state_files_removed": state_files_removed,
        "agent_tokens_removed": agent_tokens_removed,
    }
    summary["any_changes"] = any(
        bool(summary[key])
        for key in (
            "agents_migrated",
            "env_keys_removed",
            "state_files_removed",
            "agent_tokens_removed",
        )
    )

    if args.json:
        print(json.dumps(summary, sort_keys=True))
    else:
        for key, value in summary.items():
            print(f"{key}: {value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
