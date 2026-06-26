#!/usr/bin/env python3
"""Launch hardening shared by bridge-spawned disposable `claude -p` children.

Problem (#17957 path B). A disposable / non-interactive `claude -p` that runs
in — or inherits — an agent's *real* config-dir also inherits that config's
``enabledPlugins["telegram@claude-plugins-official"]=true``. Claude Code then
auto-loads the telegram plugin inside the child, which SIGTERMs the admin's
live `getUpdates` poller and grabs `bot.pid`; ~27s later the disposable child
exits and orphans the stolen poller, leaving the admin's interactive Telegram
permanently dead. Discord's gateway websocket has the same one-holder-per-token
shape.

Fix. Launch every such child with a per-invocation ``--settings`` overlay that
sets ONLY the singleton channel plugins to ``false``, leaving every other
plugin and every MCP server the child legitimately needs intact. The `claude`
CLI's ``--settings`` accepts a path OR an inline JSON string and applies it as a
MERGE layer scoped to the single invocation — it never mutates the agent's
interactive ``.claude/settings.json``. Because the overlay touches only the two
``enabledPlugins`` keys (and no ``mcpServers`` key at all), a per-key settings
merge disables just the singleton channels and preserves the rest. This is the
same overlay mechanism ``scripts/apply-channel-policy.sh`` uses via
``settings.local.json``, narrowed to one disposable launch.

Do NOT use ``--strict-mcp-config`` here: that would over-broadly drop the
functional MCP servers the knowledge / memory helpers need. ``--strict-mcp-config``
is correct only for spawns that need no MCP at all (the cron runner's
``run_claude``). Spawns that fully isolate their config-dir (``probe_claude_token``
in bridge-auth.py) inherit nothing and need no overlay; this helper is for the
disposable ``-p`` spawns that DO need their inherited plugins/MCP minus the
singleton channels.

Push is unaffected. A disposable child that must deliver to Telegram/Discord
uses the non-plugin sendMessage path (`bridge-notify.py` / `bridge-channels.py`
/ `bridge-cron-runner.py` ``telegram_send``), which talks to the HTTP API
directly and never touches the poller — so suppressing the plugin costs the
child nothing on the push side.
"""

from __future__ import annotations

import json

# Plugins that enforce one-connection-per-bot-token upstream (telegram's
# `getUpdates` poller; discord's gateway websocket). KEEP IN SYNC with the
# `SINGLETON_PLUGINS` array in `scripts/apply-channel-policy.sh` — listing a
# plugin here is a declaration that concurrent instances are broken by the
# *service*, not the plugin, so every disposable child must suppress it too.
# Plugins that talk to stateless HTTP APIs (teams, ms365) do NOT belong here.
SINGLETON_CHANNEL_PLUGINS = (
    "telegram@claude-plugins-official",
    "discord@claude-plugins-official",
)


def singleton_channel_suppression_overlay() -> str:
    """Return a ``--settings`` JSON overlay disabling ONLY the singleton channel
    plugins.

    The overlay carries a single top-level ``enabledPlugins`` object with one
    ``false`` entry per singleton channel and nothing else, so a per-key merge
    over the agent's resolved settings cannot disable any other plugin or any
    MCP server.
    """
    overlay = {
        "enabledPlugins": {plugin: False for plugin in SINGLETON_CHANNEL_PLUGINS}
    }
    return json.dumps(overlay, ensure_ascii=True)


def singleton_channel_suppression_argv() -> list[str]:
    """Return the ``claude -p`` argv fragment that suppresses the singleton
    channel plugins for a disposable / non-interactive child.

    Splice the returned list into the command right after ``-p``; flag order is
    irrelevant to the CLI and the prompt stays the trailing positional.
    """
    return ["--settings", singleton_channel_suppression_overlay()]
