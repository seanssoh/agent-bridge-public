#!/usr/bin/env python3
"""Helper for scripts/smoke/8807-mcp-reaper-patterns.sh (incident #8807 P0b).

Extracted from the smoke's inline `python3 - <<'PY'` heredocs so the smoke
carries no heredoc-stdin sites (lint-heredoc-ban C3 ban; see KNOWN_ISSUES.md
§26). Invoked file-as-argv per the lib/upgrade-helpers pattern:

    python3 8807-mcp-reaper-patterns-helper.py pattern-matrix <reaper.py>
    python3 8807-mcp-reaper-patterns-helper.py pid-reuse     <reaper.py>
    python3 8807-mcp-reaper-patterns-helper.py spawn <argv0> <pid_file>

Each subcommand exits non-zero (with a message on stderr) on failure so the
calling smoke can `|| smoke_fail`.
"""

from __future__ import annotations

import ast
import importlib.util
import re
import subprocess
import sys
import time
from pathlib import Path


def _load_default_patterns(reaper_path: str) -> list[re.Pattern[str]]:
    """Extract DEFAULT_PATTERNS from the reaper source via AST (no import — the
    module's dataclass introspection is fragile under a non-standard module
    name on some Python builds)."""
    src = Path(reaper_path).read_text(encoding="utf-8")
    tree = ast.parse(src)
    patterns: list[str] | None = None
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "DEFAULT_PATTERNS":
                    patterns = [ast.literal_eval(elt) for elt in node.value.elts]
    if not patterns:
        print("could not extract DEFAULT_PATTERNS", file=sys.stderr)
        sys.exit(1)
    return [re.compile(p) for p in patterns]


def _load_module(reaper_path: str):
    spec = importlib.util.spec_from_file_location("bridge_mcp_cleanup", reaper_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def cmd_pattern_matrix(reaper_path: str) -> int:
    pats = _load_default_patterns(reaper_path)

    def hit(cmd: str) -> bool:
        return any(p.search(cmd) for p in pats)

    positive = [
        "npm exec @upstash/context7-mcp",
        "npm exec @playwright/mcp@latest",
        "npm exec @shopify/dev-mcp@latest",
        # Shopify bare-basename resolved entrypoint (anchored on node_modules/).
        "node /Users/x/.npm/_npx/abc/node_modules/.bin/shopify-dev-mcp",
        "node /Users/x/.npm/_npx/abc/node_modules/@shopify/dev-mcp/dist/index.js",
        # cosmax-crm proxy under the bridge plugin-cache.
        "node /Users/x/.claude/plugins/cache/cosmax-marketplace/cosmax-crm/0.19.3-3/scripts/crm-mcp-proxy.mjs",
        "node /home/u/.npm/_npx/abc/node_modules/.bin/context7-mcp",
        "bun /home/u/.agent-bridge/plugins/teams/server.ts",
        "bun run --cwd /home/u/.agent-bridge/plugins/telegram --silent start",
        "bun run --cwd /home/u/.bun/install/claude-plugins-official/telegram/0.0.6 start",
    ]
    negative = [
        # Lethal collateral on the live host — none are Agent Bridge MCP servers.
        "/Applications/Pencil.app/Contents/Resources/mcp-server-darwin-arm64 --stdio",
        "/usr/local/bin/mcp-server --port 9000",
        "/Applications/Telegram.app/Contents/MacOS/Telegram",
        "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams",
        "/Applications/Figma.app/Contents/MacOS/Figma",
        # Bare interpreters / unrelated same-uid projects.
        "node /Users/x/code/myapp/index.js",
        "/home/u/.bun/bin/bun server.ts",
        "bun /Users/x/Projects/mywebapp/src/server.ts",
        "bun run --cwd /home/user/myproject build",
        # codex r2: crm/shopify matchers must be bridge-scoped — an unrelated
        # same-uid node running a like-named script must NOT match.
        "node /tmp/unrelated/crm-mcp-proxy.mjs",
        "node /Users/x/Projects/myproj/scripts/crm-mcp-proxy.mjs",
        # #1480 r2 (codex): a project-local .claude/plugins/LOCAL tree is NOT
        # the bridge plugin-cache and must NOT match the cache-anchored pattern.
        "node /Users/alice/project/.claude/plugins/local/scripts/crm-mcp-proxy.mjs",
        "node /tmp/foo/shopify-dev-mcp",
        "node /Users/x/code/app/bin/shopify-dev-mcp",
        # codex orphans are NOT reaped by the MCP cleaner.
        "codex resume 9f3a2b1c --cwd /home/agent",
        "codex exec --ephemeral --skip-git-repo-check -C crm-dev",
    ]

    bad: list[tuple[str, str]] = []
    for cmd in positive:
        if not hit(cmd):
            bad.append(("MISS positive", cmd))
    for cmd in negative:
        if hit(cmd):
            bad.append(("LETHAL negative", cmd))
    if bad:
        for kind, cmd in bad:
            print(f"{kind}: {cmd}", file=sys.stderr)
        return 1
    print(f"[ok] {len(positive)} positive + {len(negative)} negative controls correct")
    return 0


def cmd_pid_reuse(reaper_path: str) -> int:
    mod = _load_module(reaper_path)
    child = subprocess.Popen(["/bin/sleep", "30"])
    try:
        for _ in range(50):
            if mod.read_proc_identity(child.pid) is not None:
                break
            time.sleep(0.05)
        ident = mod.read_proc_identity(child.pid)
        assert ident is not None, "could not read live child identity"
        cmd, ppid, age = ident
        sp = re.compile(r"sleep")
        assert mod.still_killable(child.pid, cmd, sp, ppid, 0), "exact identity must be killable"
        assert not mod.still_killable(child.pid, cmd, re.compile("nomatch"), ppid, 0), "pattern-mismatch must refuse"
        assert not mod.still_killable(child.pid, "different", sp, ppid, 0), "command-change must refuse"
        assert not mod.still_killable(child.pid, cmd, sp, ppid + 99999, 0), "ppid-change must refuse"
        assert not mod.still_killable(child.pid, cmd, sp, ppid, age + 100000), "younger-than-snapshot must refuse"
        child.terminate()
        child.wait()
        ok, status = mod.kill_pid(child.pid, 0.2, cmd, sp, ppid, 0)
        assert ok and status == "skipped-pid-reuse", f"vanished pid must skip, got ({ok},{status})"
        print("[ok] PID-reuse revalidation enforced")
        return 0
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()


def cmd_spawn(argv0: str, pid_file: str) -> int:
    """Spawn a /bin/sleep with a crafted argv[0] so ps shows <argv0> 600.

    argv[0] is the only displayed token; "600" is the sleep duration. Detached
    (start_new_session) so it reparents to init/launchd (PPID=1) as an orphan.
    """
    proc = subprocess.Popen(
        [argv0, "600"],
        executable="/bin/sleep",
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    Path(pid_file).write_text(str(proc.pid), encoding="utf-8")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: 8807-mcp-reaper-patterns-helper.py <pattern-matrix|pid-reuse|spawn> ...", file=sys.stderr)
        return 2
    command = argv[1]
    if command == "pattern-matrix":
        return cmd_pattern_matrix(argv[2])
    if command == "pid-reuse":
        return cmd_pid_reuse(argv[2])
    if command == "spawn":
        return cmd_spawn(argv[2], argv[3])
    print(f"unknown subcommand: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
