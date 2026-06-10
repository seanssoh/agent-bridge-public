#!/usr/bin/env python3
"""Seed-if-absent the operator's per-plugin display config into an agent home.

Issue #1753: ``claude-hud`` (and similar display-only Claude Code plugins) ship
several HUD rows OFF by default. Every bridge agent runs in an isolated config
dir (agent-home ``.claude/``), so a freshly scaffolded Claude agent has **no**
``plugins/<plugin>/config.json`` and renders the abbreviated HUD — even when the
operator's own ``~/.claude/plugins/<plugin>/config.json`` enables the full view.
The previous workaround was a manual per-agent copy that any new (or wiped)
agent home regressed past.

This helper copies, for each allowlisted plugin:

    src = <operator_home>/.claude/plugins/<plugin>/config.json
    dst = <config_dir>/plugins/<plugin>/config.json

only when ``src`` exists AND ``dst`` is absent. It NEVER overwrites an existing
agent-local ``config.json`` (design note 2: agents may legitimately diverge).

Allowlist (design note 1): an explicit allowlist is the gate, not generic
seeding of arbitrary plugin config — a generic copy risks carrying
secret-bearing plugin config across agent boundaries. The allowlist is passed
as the third argv (comma-separated); the caller defaults it to ``claude-hud``
and lets the operator extend it via a roster knob. An empty/whitespace token
list is a no-op.

Plugin ids are validated as a single safe path segment (``^[A-Za-z0-9._-]+$``,
with ``.`` and ``..`` rejected outright) BEFORE they are used as a path
component, and the resolved ``src`` / ``dst`` are asserted to stay under their
intended roots. This blocks an allowlist token like ``../../secret-root`` from
escaping the operator plugin root or the agent config dir (defense in depth:
both the id pattern and the containment check must pass).

Atomicity (design note 2 / no-clobber): the copy uses an exclusive create
(``open(dst, "xb")``) rather than a check-then-``copyfile``. ``copyfile`` opens
the destination for truncating write and would clobber an agent-local config
that appeared between the existence check and the copy. With ``"xb"`` the open
fails closed (``FileExistsError`` → skip) if the dst exists at write time, so a
diverged agent-local config is never truncated even under a concurrent agent
write on the create/start double-call.

This helper covers the SHARED-mode (non-isolated) path only: a plain controller
copy. The engine gate (Claude-only, design note 4), the operator-home
resolution (design note 5), and the iso v2 controller->iso publish boundary
(design note 3) are all handled by the shell caller
(``bridge_seed_operator_plugin_config`` in ``lib/bridge-agents.sh``). On
linux-user-isolated hosts the shell caller does NOT invoke this helper — the
controller reads its own operator home and publishes each config into the iso
agent home via ``bridge_iso_run --op publish-root-file`` (root-owned, ``chgrp
ab-agent-<a>``, mode 0660), because an iso UID cannot read the controller HOME.

Args:
    sys.argv[1] — operator_home (the operator's HOME; ``.claude/plugins`` source).
    sys.argv[2] — config_dir (the agent's per-agent ``.claude`` config dir).
    sys.argv[3] — allowlist (comma-separated plugin ids; e.g. ``claude-hud``).

Output: prints one ``seeded=<plugin>`` line per copied plugin to stdout.

Exit codes:
    0 — completed (zero or more plugins seeded; absent src / present dst are
        expected no-ops, not failures).
    1 — argument parsing error.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# A plugin id must be a single safe path segment: it becomes a directory name
# under `.claude/plugins/`. No `/`, no `..`, no leading-dot traversal. This is
# the first of two containment layers (the second is the resolved-path
# is_relative_to assertion at copy time).
_SAFE_PLUGIN_ID = re.compile(r"^[A-Za-z0-9._-]+$")


def _is_safe_plugin_id(plugin: str) -> bool:
    if plugin in (".", ".."):
        return False
    return bool(_SAFE_PLUGIN_ID.match(plugin))


def _split_allowlist(raw: str) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for token in raw.replace(",", " ").split():
        token = token.strip()
        if not token or token in seen:
            continue
        # Accept a stray `plugin:` prefix for symmetry with the roster
        # plugin-id convention (bridge_agent_plugins_csv).
        if token.startswith("plugin:"):
            token = token[len("plugin:") :]
        if not token or token in seen:
            continue
        seen.add(token)
        # Reject anything that is not a safe single path segment — a token
        # like `../../secret-root` would otherwise escape the plugin root.
        if not _is_safe_plugin_id(token):
            print(f"[warn] skip unsafe plugin id: {token!r}", file=sys.stderr)
            continue
        out.append(token)
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "usage: seed-operator-plugin-config.py "
            "<operator_home> <config_dir> <allowlist-csv>",
            file=sys.stderr,
        )
        return 1

    operator_home = Path(argv[1]).expanduser()
    config_dir = Path(argv[2]).expanduser()
    plugins = _split_allowlist(argv[3])

    if not plugins:
        return 0

    src_root = (operator_home / ".claude" / "plugins").resolve()
    dst_root = (config_dir / "plugins").resolve()

    for plugin in plugins:
        # _split_allowlist already enforced the safe-segment pattern; the
        # resolved-path containment check below is the second defense layer.
        src = (src_root / plugin / "config.json").resolve()
        dst = (dst_root / plugin / "config.json").resolve()

        # Containment (defense in depth): a copy must never read or write
        # outside the intended roots, even if the id pattern were ever
        # loosened. is_relative_to also rejects a symlinked plugin dir that
        # resolves outside its root.
        if not src.is_relative_to(src_root) or not dst.is_relative_to(dst_root):
            print(f"[warn] skip out-of-root plugin: {plugin!r}", file=sys.stderr)
            continue

        # Seed-if-absent: copy only when the operator has a config for this
        # plugin. (The agent-side absence is enforced atomically by the
        # exclusive open below, not a pre-check, so a concurrent agent write
        # cannot be clobbered.)
        if not src.is_file():
            continue

        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            # Read the operator source, then write the dst with an EXCLUSIVE
            # create ("xb"). If an agent-local config appeared between the
            # plugin selection and this write, the open fails closed with
            # FileExistsError and we skip — never truncating a diverged
            # agent config (the seed-if-absent / no-clobber contract).
            data = src.read_bytes()
            with open(dst, "xb") as fh:
                fh.write(data)
        except FileExistsError:
            # Dst already present (or won the race) — never overwrite.
            continue
        except OSError as exc:
            # Best-effort defense-in-depth: a single plugin's copy failure
            # (e.g. a transient permission edge) must not abort the create /
            # start path or block the remaining plugins.
            print(f"[warn] seed {plugin}: {exc}", file=sys.stderr)
            continue
        print(f"seeded={plugin}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
