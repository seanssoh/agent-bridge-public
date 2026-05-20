#!/usr/bin/env python3
"""antigravity-settings-preseed.py — atomic preseed of agy settings.json.

Track C1 of the Antigravity (`agy`) engine wave. Invoked by
`bridge_antigravity_settings_preseed` in lib/bridge-antigravity.sh with
file-as-argv (NOT heredoc-stdin — footgun #11 / KNOWN_ISSUES.md §26).

Read-modify-write of `~/.gemini/antigravity-cli/settings.json`:
  - add <workdir> to `trustedWorkspaces` (array of trusted dirs) so the
    agy trust selector ("Do you trust the contents of this project?") is
    pre-empted before launch;
  - add `command(<agb>)` and `command(<agent-bridge>)` to
    `permissions.allow` so the bridge CLIs run without per-call prompts;
  - set `altScreenMode` to `always` so the agy render mode is deterministic
    for `tmux capture-pane` idle detection. (The wave plan first specified
    `inline`, but agy v1.0.0 rejects that value with a blocking "Settings
    Error" selector — verified live at Phase-5b QA. `always` is accepted and
    `tmux capture-pane` reads the alternate screen fine.)

ALL pre-existing keys are preserved. Idempotent: a second run adds nothing
duplicate. The write is atomic (temp file in the same directory + rename).

argv:
  1  settings_file   path to settings.json (created if absent)
  2  workdir         absolute path to add to trustedWorkspaces
  3  agb_path        absolute path to the `agb` CLI
  4  agent_bridge    absolute path to the `agent-bridge` CLI

Exit non-zero on any failure; prints a one-line reason to stderr.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile


def _load(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"antigravity-settings-preseed: cannot read {path}: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(
            f"antigravity-settings-preseed: {path} is not a JSON object"
        )
    return data


def _ensure_list(container: dict, key: str) -> list:
    value = container.get(key)
    if not isinstance(value, list):
        value = []
        container[key] = value
    return value


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        sys.stderr.write(
            "antigravity-settings-preseed: expected 4 args "
            "(settings_file workdir agb_path agent_bridge_path)\n"
        )
        return 2

    settings_file, workdir, agb_path, agent_bridge_path = argv[1:5]

    data = _load(settings_file)

    # trustedWorkspaces — pre-empt the agy trust selector.
    trusted = _ensure_list(data, "trustedWorkspaces")
    if workdir not in trusted:
        trusted.append(workdir)

    # permissions.allow — auto-allow the bridge CLIs.
    permissions = data.get("permissions")
    if not isinstance(permissions, dict):
        permissions = {}
        data["permissions"] = permissions
    allow = _ensure_list(permissions, "allow")
    for cli in (agb_path, agent_bridge_path):
        entry = f"command({cli})"
        if entry not in allow:
            allow.append(entry)

    # altScreenMode — pin a deterministic render mode for tmux capture-pane
    # idle detection. agy v1.0.0 rejects "inline" (blocking Settings Error);
    # "always" is accepted and capture-pane reads the alternate screen fine.
    data["altScreenMode"] = "always"

    target_dir = os.path.dirname(os.path.abspath(settings_file)) or "."
    try:
        os.makedirs(target_dir, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(prefix=".settings-preseed-", dir=target_dir)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(data, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            os.replace(tmp_path, settings_file)
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except OSError as exc:
        sys.stderr.write(
            f"antigravity-settings-preseed: cannot write {settings_file}: {exc}\n"
        )
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
