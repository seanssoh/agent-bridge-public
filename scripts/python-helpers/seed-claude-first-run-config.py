#!/usr/bin/env python3
"""Seed a per-agent ``CLAUDE_CONFIG_DIR`` so Claude Code skips first-run prompts.

Issue #1073: a fresh non-admin Claude channel agent launched with its own
``CLAUDE_CONFIG_DIR`` hits the Claude CLI's theme picker on first run. The
tmux session sits at the picker; ``bridge-run.sh``'s foreground detection
times out, kills the session, and relaunches — producing an infinite restart
loop. Admin agents reuse the controller's already-onboarded ``~/.claude`` so
this was first surfaced when the first per-agent-config Claude agent (a
Teams channel agent) was created. The Bypass Permissions warning is handled
separately via ``skipDangerousModePermissionPrompt`` in settings.json
(`bridge-hooks.py::managed_claude_settings_defaults`); this helper covers
the ``.claude.json``-driven onboarding prompts.

Writes the bootstrap payload (``hasCompletedOnboarding``, ``firstStartTime``,
``opusProMigrationComplete``, ``sonnet1m45MigrationComplete``,
``migrationVersion``, ``userID``, project ``hasTrustDialogAccepted`` /
``hasCompletedProjectOnboarding``) into ``<config_dir>/.claude.json`` —
the file Claude Code reads when ``CLAUDE_CONFIG_DIR`` is set. The shape
mirrors ``bridge-auth.py::claude_config_bootstrap_payload`` byte-for-byte
(the function ``auth claude-token sync`` already uses), so this helper
reuses ``bridge-auth.py`` directly rather than duplicating the payload.

Idempotent: existing keys in ``.claude.json`` are preserved (``setdefault``).
Re-running this on a config dir that already has ``hasCompletedOnboarding``
set is a no-op for that key but still rewrites the file atomically.

Args:
    sys.argv[1] — config_dir (path to the per-agent ``.claude`` dir).
    sys.argv[2] — workdir (the agent's workspace cwd; recorded as a
                  trusted project so Claude does not prompt for the trust
                  dialog on first launch in that workspace).

Output: prints ``seed_ok=<config_path>`` on success to stdout.

Exit codes:
    0 — seeded successfully (or no-op when keys already present).
    1 — failed (path validation, write, or argument parsing).

Why a standalone helper rather than a new ``bridge-auth.py`` subcommand:
    ``bridge-auth.py``'s top-level parser requires ``--registry``, which
    is irrelevant to first-run seeding (no token involved). A small
    standalone wrapper keeps the call site in ``bridge-agent.sh`` /
    ``bridge-start.sh`` clean (no fake registry path) and matches the
    pattern of the rest of ``scripts/python-helpers/``.
"""

from __future__ import annotations

import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: seed-claude-first-run-config.py <config_dir> <workdir>",
            file=sys.stderr,
        )
        return 1

    config_dir = Path(argv[1]).expanduser()
    workdir = argv[2].strip()

    # Reuse the helpers from bridge-auth.py. Both functions are pure and
    # do not require the registry argv plumbing; importing them directly
    # avoids duplicating the bootstrap payload shape (which already lives
    # in claude_config_bootstrap_payload and is consumed by the proven
    # auth claude-token sync path).
    script_dir = Path(__file__).resolve().parent.parent.parent
    sys.path.insert(0, str(script_dir))
    try:
        # `bridge-auth` (hyphen) is not a valid Python module name; import
        # via importlib so the existing file layout does not need to be
        # restructured.
        import importlib.util

        auth_path = script_dir / "bridge-auth.py"
        spec = importlib.util.spec_from_file_location(
            "bridge_auth_helpers", auth_path
        )
        if spec is None or spec.loader is None:
            print(
                f"[error] cannot load bridge-auth helpers: {auth_path}",
                file=sys.stderr,
            )
            return 1
        auth_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(auth_module)
    except Exception as exc:  # noqa: BLE001 — surface any load failure
        print(f"[error] bridge-auth import failed: {exc}", file=sys.stderr)
        return 1

    trusted_workdirs = [workdir] if workdir else None
    try:
        config_path = auth_module.ensure_claude_config_file(
            config_dir,
            trusted_workdirs,
            owner_uid=None,
            owner_gid=None,
            allowed_root=None,
        )
    except Exception as exc:  # noqa: BLE001 — surface any write failure
        print(f"[error] ensure_claude_config_file failed: {exc}", file=sys.stderr)
        return 1

    print(f"seed_ok={config_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
