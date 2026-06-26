#!/usr/bin/env python3
"""Plugin version-sync guard (internal incident #18177).

Why this exists
---------------
Bots reseed a plugin's cache only when its *version* bumps (per-agent
version-gated cache). If a plugin's SKILL/content changes but its version is
NOT bumped, the reseed is skipped and stale content ships dark. On the day
#18177 was filed this happened three times in one day — a sales-critical
feature stayed dark because `marketplace.json` said teams=0.1.1 while the
plugin manifest was already at 0.1.8.

What gates the reseed
---------------------
The load-bearing version is the pair

    .claude-plugin/marketplace.json  (the per-plugin `version` entry)
    plugins/<name>/.claude-plugin/plugin.json  (`version`)

Claude loads a plugin via its `plugin.json`; the bridge cache gates a reseed on
the *marketplace entry* version (see `bridge-dev-plugin-cache.py`
`load_marketplace`). A drift between those two is exactly the slip that escaped
review three times. This guard makes that drift a HARD FAIL.

Part 1 (HARD FAIL) — marketplace entry.version == plugin.json.version, for every
plugin declared in the repo-root marketplace that ships a tracked plugin.json.

`package.json` is ALSO compared, but a mismatch there is a WARNING, not a hard
fail. `package.json` is the npm package version — a separate publish namespace
that legitimately diverges (e.g. the vendored discord MCP server ships
`claude-channel-discord@0.0.1` while the Claude plugin is at `0.1.0`). Promoting
it to a hard fail would red the current tree without touching the reseed gate.

Part 2 (ADVISORY WARN) — when a plugin's tracked files changed vs the base ref
(origin/main by default) but its plugin.json `version` did NOT bump, warn
"content changed without a version bump." Best-effort: skipped quietly when the
base ref is unavailable (shallow checkout, detached CI fetch). It never blocks —
a robust content-hash baseline across reseeds is impractical and not every
content change warrants a version bump (a comment fix, a test-only edit), so a
fragile heuristic must not gate merges.

Usage:
    scripts/lint-plugin-version-sync.py            # Part 1 hard check + Part 2 warn
    scripts/lint-plugin-version-sync.py --no-content-warn   # Part 1 only
    scripts/lint-plugin-version-sync.py --base <ref>        # override Part 2 base
    scripts/lint-plugin-version-sync.py --self-test         # logic self-check (no repo state)

Exit codes: 0 = pass (warnings allowed), 1 = a hard version mismatch, 2 = a
structural error (unparseable marketplace, a path the marketplace points at is
missing).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

TAG = "[plugin-version-sync]"


class StructuralError(Exception):
    """A malformed marketplace / missing source path the lint can't reason about."""


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _load_json(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        # A valid-but-non-object JSON (list/str/number/null) would otherwise
        # AttributeError on the `.get(...)` calls below. Fail cleanly instead.
        raise StructuralError(
            f"{path}: expected a JSON object, got {type(data).__name__}"
        )
    return data


def _rel(root: Path, path: Path) -> str:
    try:
        return str(path.resolve().relative_to(root))
    except ValueError:
        return str(path)


def _plugin_dir(root: Path, entry: dict) -> Path:
    """Resolve a marketplace plugin entry to its source directory.

    Honors the declared `source` (default `./plugins/<name>`) rather than
    assuming the layout, so a future relocation can't silently bypass the gate.
    """
    source = str(entry.get("source") or "").strip()
    if source:
        rel = source[2:] if source.startswith("./") else source
        return (root / rel).resolve()
    return (root / "plugins" / str(entry.get("name") or "")).resolve()


def check_versions(root: Path) -> tuple[list[str], list[str], list[str]]:
    """Part 1 (+ package.json warn).

    Returns (hard_fail_lines, warn_lines, info_lines).
    Raises StructuralError on an unusable marketplace / missing source path.
    """
    marketplace_path = root / ".claude-plugin" / "marketplace.json"
    try:
        marketplace = _load_json(marketplace_path)
    except FileNotFoundError as exc:
        raise StructuralError(f"missing {_rel(root, marketplace_path)}") from exc
    except json.JSONDecodeError as exc:
        raise StructuralError(f"cannot parse {_rel(root, marketplace_path)}: {exc}") from exc

    plugins = marketplace.get("plugins")
    if not isinstance(plugins, list):
        raise StructuralError(f"{_rel(root, marketplace_path)} has no 'plugins' array")

    fails: list[str] = []
    warns: list[str] = []
    infos: list[str] = []

    for entry in plugins:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "").strip()
        if not name:
            raise StructuralError("a marketplace plugin entry is missing 'name'")
        mkt_version = str(entry.get("version") or "").strip()
        if not mkt_version:
            raise StructuralError(f"plugin '{name}' has no 'version' in the marketplace entry")

        pdir = _plugin_dir(root, entry)
        if not pdir.is_dir():
            raise StructuralError(f"plugin '{name}' source dir not found: {_rel(root, pdir)}")

        # --- Part 1: marketplace entry vs plugin.json (HARD) ---
        plugin_json = pdir / ".claude-plugin" / "plugin.json"
        if plugin_json.is_file():
            try:
                pj_version = str(_load_json(plugin_json).get("version") or "").strip()
            except json.JSONDecodeError as exc:
                raise StructuralError(f"cannot parse {_rel(root, plugin_json)}: {exc}") from exc
            if pj_version != mkt_version:
                fails.append(
                    f"plugin '{name}' version mismatch\n"
                    f"{TAG}   marketplace .claude-plugin/marketplace.json : {mkt_version}\n"
                    f"{TAG}   manifest    {_rel(root, plugin_json)} : {pj_version}\n"
                    f"{TAG}   -> bump BOTH to the same version. A drift here makes the "
                    f"per-agent version-gated reseed skip changed content (#18177)."
                )
        else:
            infos.append(
                f"plugin '{name}' ships no plugin.json ({_rel(root, plugin_json)}) "
                f"— version-sync check skipped for it"
            )

        # --- package.json: npm namespace (WARN only) ---
        package_json = pdir / "package.json"
        if package_json.is_file():
            try:
                pkg_version = str(_load_json(package_json).get("version") or "").strip()
            except json.JSONDecodeError as exc:
                warns.append(f"cannot parse {_rel(root, package_json)}: {exc}")
                pkg_version = ""
            if pkg_version and pkg_version != mkt_version:
                warns.append(
                    f"plugin '{name}' package.json version "
                    f"({_rel(root, package_json)}: {pkg_version}) differs from the "
                    f"plugin version ({mkt_version}). package.json is the npm "
                    f"namespace; bump it too if this is a real release."
                )

    return (fails, warns, infos)


def _git(root: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
    )
    return (proc.returncode, proc.stdout.strip())


def _resolve_base(root: Path, explicit: str | None) -> str | None:
    candidates: list[str] = []
    if explicit:
        candidates.append(explicit)
    if os.environ.get("BASE_SHA"):
        candidates.append(os.environ["BASE_SHA"])
    candidates += ["origin/main", "main"]
    for ref in candidates:
        rc, _ = _git(root, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
        if rc == 0:
            return ref
    return None


def check_content_drift(root: Path, base: str | None) -> list[str]:
    """Part 2 (advisory). Returns warn lines; never raises, never fails."""
    ref = _resolve_base(root, base)
    if ref is None:
        return [f"{TAG} info: no base ref (origin/main) resolvable — content-drift check skipped"]

    marketplace_path = root / ".claude-plugin" / "marketplace.json"
    try:
        plugins = _load_json(marketplace_path).get("plugins", [])
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    if not isinstance(plugins, list):
        return []

    warns: list[str] = []
    for entry in plugins:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "").strip()
        if not name:
            continue
        pdir = _plugin_dir(root, entry)
        rel_dir = _rel(root, pdir)

        rc, out = _git(root, "diff", "--name-only", f"{ref}...HEAD", "--", rel_dir)
        if rc != 0:
            continue
        changed = [line for line in out.splitlines() if line.strip()]
        if not changed:
            continue

        plugin_json_rel = f"{rel_dir}/.claude-plugin/plugin.json"
        cur_version = ""
        pj = pdir / ".claude-plugin" / "plugin.json"
        if pj.is_file():
            try:
                cur_version = str(_load_json(pj).get("version") or "").strip()
            except (json.JSONDecodeError, StructuralError):
                # Advisory path never raises — a non-object/unparseable current
                # manifest just yields no comparable version.
                cur_version = ""
        rc_base, base_blob = _git(root, "show", f"{ref}:{plugin_json_rel}")
        if rc_base != 0:
            # New plugin (no base manifest) — nothing to compare against.
            continue
        try:
            base_data = json.loads(base_blob)
        except json.JSONDecodeError:
            continue
        if not isinstance(base_data, dict):
            # Advisory path: a valid-but-non-object base manifest can't be
            # version-compared — skip cleanly, never traceback.
            continue
        base_version = str(base_data.get("version") or "").strip()

        if cur_version and base_version and cur_version == base_version:
            shown = ", ".join(changed[:5])
            if len(changed) > 5:
                shown += f", … (+{len(changed) - 5} more)"
            warns.append(
                f"plugin '{name}' changed tracked content vs {ref} but plugin.json "
                f"version did NOT bump (still {cur_version}). Bump {plugin_json_rel} "
                f".version so bots reseed. Changed: {shown}"
            )
    return warns


def run_self_test() -> int:
    """Deterministic logic check on a synthetic tree (no repo state)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / ".claude-plugin").mkdir(parents=True)
        (root / "plugins" / "good" / ".claude-plugin").mkdir(parents=True)
        (root / "plugins" / "bad" / ".claude-plugin").mkdir(parents=True)

        def write(p: Path, obj: dict) -> None:
            p.write_text(json.dumps(obj), encoding="utf-8")

        # 1. In-sync tree must pass.
        write(
            root / ".claude-plugin" / "marketplace.json",
            {"name": "t", "plugins": [{"name": "good", "source": "./plugins/good", "version": "0.2.0"}]},
        )
        write(root / "plugins" / "good" / ".claude-plugin" / "plugin.json", {"name": "good", "version": "0.2.0"})
        fails, _, _ = check_versions(root)
        if fails:
            print(f"{TAG} SELF-TEST FAIL: in-sync tree should pass, got {len(fails)} failure(s)", file=sys.stderr)
            return 1

        # 2. A version drift must hard-fail exactly once.
        write(
            root / ".claude-plugin" / "marketplace.json",
            {
                "name": "t",
                "plugins": [
                    {"name": "good", "source": "./plugins/good", "version": "0.2.0"},
                    {"name": "bad", "source": "./plugins/bad", "version": "0.2.0"},
                ],
            },
        )
        write(root / "plugins" / "bad" / ".claude-plugin" / "plugin.json", {"name": "bad", "version": "0.3.0"})
        fails, _, _ = check_versions(root)
        if len(fails) != 1:
            print(f"{TAG} SELF-TEST FAIL: one desync should hard-fail exactly once, got {len(fails)}", file=sys.stderr)
            return 1

        # 3. A package.json drift must WARN, not hard-fail.
        write(root / "plugins" / "bad" / ".claude-plugin" / "plugin.json", {"name": "bad", "version": "0.2.0"})
        write(root / "plugins" / "bad" / "package.json", {"name": "bad-npm", "version": "0.0.1"})
        fails, warns, _ = check_versions(root)
        if fails:
            print(f"{TAG} SELF-TEST FAIL: package.json drift must not hard-fail, got {len(fails)}", file=sys.stderr)
            return 1
        if not any("package.json" in w for w in warns):
            print(f"{TAG} SELF-TEST FAIL: package.json drift should emit a WARN", file=sys.stderr)
            return 1

    print(f"{TAG} SELF-TEST PASS: in-sync passes, version drift hard-fails, package.json drift warns.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Plugin version-sync guard (#18177)")
    parser.add_argument("--base", default=None, help="base ref for the Part 2 content-drift check (default: origin/main)")
    parser.add_argument("--no-content-warn", action="store_true", help="skip the Part 2 advisory content-drift check")
    parser.add_argument("--self-test", action="store_true", help="run the logic self-test on a synthetic tree")
    args = parser.parse_args(argv)

    if args.self_test:
        return run_self_test()

    root = repo_root()
    try:
        fails, warns, infos = check_versions(root)
    except StructuralError as exc:
        print(f"{TAG} FAIL: {exc}", file=sys.stderr)
        return 2

    if not args.no_content_warn:
        warns = warns + check_content_drift(root, args.base)

    for line in infos:
        print(f"{TAG} info: {line}")
    for line in warns:
        print(f"{TAG} WARN: {line}", file=sys.stderr)
    for line in fails:
        print(f"{TAG} FAIL: {line}", file=sys.stderr)

    if fails:
        print(
            f"{TAG} FAIL: {len(fails)} plugin version mismatch(es) — fix before merge.",
            file=sys.stderr,
        )
        return 1

    print(f"{TAG} PASS: all in-repo plugin versions are in sync.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
