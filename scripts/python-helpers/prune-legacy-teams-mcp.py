#!/usr/bin/env python3
"""Remove legacy project MCP Teams servers that shadow the Teams plugin.

Agent Bridge now launches Teams through Claude's development plugin loader.
Older setup paths wrote a bare ``mcpServers.teams`` entry into the agent root
or workdir ``.mcp.json``. When that stale entry is still present, Claude binds
``server:teams`` to the bare MCP server instead of the plugin namespace
(``plugin:teams:teams``), and channel notifications can be silently skipped.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


def entry_looks_bridge_managed_teams(entry: Any, agent: str) -> bool:
    if not isinstance(entry, dict):
        return False

    env = entry.get("env")
    env = env if isinstance(env, dict) else {}
    args = entry.get("args")
    args = args if isinstance(args, list) else []
    arg_text = " ".join(str(item) for item in args)
    command = str(entry.get("command") or "")

    if str(env.get("BRIDGE_AGENT_ID") or "") == agent and (
        "TEAMS_STATE_DIR" in env or "plugins/teams" in arg_text
    ):
        return True

    if (
        command.endswith("bun")
        and "server.ts" in arg_text
        and (
            "/agent-bridge/plugins/teams" in arg_text
            or "/.claude/plugins/cache/agent-bridge/teams/" in arg_text
        )
    ):
        return True

    return False


def write_json_in_place(path: Path, payload: dict[str, Any]) -> None:
    data = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    try:
        tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
        tmp.write_text(data, encoding="utf-8")
        os.chmod(tmp, path.stat().st_mode & 0o777)
        os.replace(tmp, path)
    except OSError:
        try:
            tmp.unlink()  # type: ignore[name-defined]
        except Exception:
            pass
        # Isolated agent roots can be non-writable even when the agent owns
        # the .mcp.json file. Truncate in place in that case.
        path.write_text(data, encoding="utf-8")


def prune_file(path: Path, agent: str) -> str:
    if not path.is_file():
        return f"absent path={path}"

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return f"skipped path={path} reason=read-failed:{exc}"

    if not isinstance(payload, dict):
        return f"skipped path={path} reason=root-not-object"

    servers = payload.get("mcpServers")
    if not isinstance(servers, dict):
        return f"unchanged path={path} reason=no-mcpServers"

    entry = servers.get("teams")
    if not entry_looks_bridge_managed_teams(entry, agent):
        return f"unchanged path={path} reason=no-legacy-teams-entry"

    del servers["teams"]
    payload["mcpServers"] = servers
    try:
        write_json_in_place(path, payload)
    except OSError as exc:
        return f"failed path={path} reason=write-failed:{exc}"

    return f"pruned path={path}"


def unique_paths(paths: list[Path]) -> list[Path]:
    result: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        result.append(path)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", required=True)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--agent-root", required=True)
    args = parser.parse_args()

    workdir = Path(args.workdir).expanduser().resolve()
    agent_root = Path(args.agent_root).expanduser().resolve()
    paths = unique_paths([workdir / ".mcp.json", agent_root / ".mcp.json"])

    failed = False
    for path in paths:
        line = prune_file(path, args.agent)
        print(line)
        if line.startswith("failed "):
            failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
