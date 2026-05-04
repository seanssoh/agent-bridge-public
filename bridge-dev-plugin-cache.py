#!/usr/bin/env python3
"""Prepare Claude dev-loaded plugin cache/source links for live marketplace sources."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent


def marketplace_path(root: Path) -> Path:
    return root / ".claude-plugin" / "marketplace.json"


def cache_root() -> Path:
    explicit = os.environ.get("BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return Path.home() / ".claude" / "plugins" / "cache"


def claude_plugins_root() -> Path:
    explicit = os.environ.get("BRIDGE_CLAUDE_PLUGINS_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    root = cache_root()
    if root.name == "cache":
        return root.parent
    return Path.home() / ".claude" / "plugins"


def known_marketplaces_path() -> Path:
    return claude_plugins_root() / "known_marketplaces.json"


def normalize_channels(raw: str) -> list[str]:
    items: list[str] = []
    seen: set[str] = set()
    for chunk in raw.split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        items.append(item)
    return items


def load_marketplace(root: Path) -> tuple[str, dict[str, dict[str, str]]]:
    payload = json.loads(marketplace_path(root).read_text(encoding="utf-8"))
    marketplace_name = str(payload.get("name") or "").strip()
    default_version = str((payload.get("metadata") or {}).get("version") or "").strip()
    plugins = {}
    for item in payload.get("plugins") or []:
        name = str(item.get("name") or "").strip()
        if not name:
            continue
        plugins[name] = {
            "source": str(item.get("source") or "").strip(),
            "version": str(item.get("version") or default_version or "0.1.0").strip(),
        }
    if not marketplace_name:
        raise SystemExit("marketplace name missing")
    return marketplace_name, plugins


def marketplace_repo_slug(repo: str) -> str:
    repo = repo.strip().strip("/")
    if not repo or "/" not in repo:
        return ""
    return repo.replace("/", "-")


def load_known_marketplaces() -> dict[str, object]:
    path = known_marketplaces_path()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}


def channel_marketplace(channel: str) -> str:
    if not channel.startswith("plugin:") or "@" not in channel:
        return ""
    return channel[len("plugin:") :].split("@", 1)[1].strip()


def root_marketplace_name(root: Path) -> str:
    try:
        name, _plugins = load_marketplace(root)
    except (OSError, ValueError, SystemExit):
        return ""
    return name


def is_marketplace_manifest_readable(root: Path) -> bool:
    try:
        return marketplace_path(root).is_file()
    except OSError:
        return False


def resolve_marketplace_root(default_root: Path, channel: str) -> Path:
    marketplace = channel_marketplace(channel)
    if not marketplace:
        return default_root
    if root_marketplace_name(default_root) == marketplace:
        return default_root

    markets = load_known_marketplaces()
    entry = markets.get(marketplace)
    if not isinstance(entry, dict):
        return default_root

    plugins_root = claude_plugins_root()
    candidates: list[Path] = []
    install_location = str(entry.get("installLocation") or "").strip()
    if install_location:
        candidates.append(Path(install_location).expanduser())

    source = entry.get("source")
    if isinstance(source, dict):
        source_path = str(source.get("path") or "").strip()
        if source_path:
            candidates.append(Path(source_path).expanduser())
        repo_slug = marketplace_repo_slug(str(source.get("repo") or ""))
        if repo_slug:
            candidates.append(plugins_root / "marketplaces" / repo_slug)

    candidates.append(plugins_root / "marketplaces" / marketplace)
    for candidate in candidates:
        if is_marketplace_manifest_readable(candidate):
            return candidate.resolve()
    return default_root


def remove_tree(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
        return
    if path.exists():
        shutil.rmtree(path)


NODE_MODULES_NAME = "node_modules"
MCP_CONFIG_NAME = ".mcp.json"
SENSITIVE_KEY_PARTS = (
    "authorization",
    "api_key",
    "apikey",
    "app_password",
    "client_secret",
    "password",
    "secret",
    "token",
)


def is_sensitive_key(key: str) -> bool:
    lowered = key.lower().replace("-", "_")
    return any(part in lowered for part in SENSITIVE_KEY_PARTS)


def is_placeholder_secret(value: str) -> bool:
    stripped = value.strip()
    upper = stripped.upper()
    return (
        "PLACEHOLDER" in upper
        or upper in {"REDACTED", "<REDACTED>"}
        or stripped.startswith("__")
        and stripped.endswith("__")
    )


def merge_secret_placeholders(source: object, current: object, sensitive: bool = False) -> tuple[object, bool]:
    if isinstance(source, dict) and isinstance(current, dict):
        changed = False
        merged: dict[str, object] = {}
        for key, value in source.items():
            next_sensitive = sensitive or is_sensitive_key(str(key))
            if key in current:
                merged_value, item_changed = merge_secret_placeholders(value, current[key], next_sensitive)
                merged[key] = merged_value
                changed = changed or item_changed
            else:
                merged[key] = value
        return merged, changed

    if isinstance(source, list) and isinstance(current, list):
        changed = False
        merged = []
        for idx, value in enumerate(source):
            if idx < len(current):
                merged_value, item_changed = merge_secret_placeholders(value, current[idx], sensitive)
                merged.append(merged_value)
                changed = changed or item_changed
            else:
                merged.append(value)
        return merged, changed

    if (
        sensitive
        and isinstance(source, str)
        and isinstance(current, str)
        and is_placeholder_secret(source)
        and current.strip()
        and not is_placeholder_secret(current)
    ):
        return current, True

    return source, False


def maybe_render_mcp_with_preserved_secrets(src: Path, dst: Path) -> bytes | None:
    if src.name != MCP_CONFIG_NAME or not dst.is_file() or dst.is_symlink():
        return None
    try:
        source_payload = json.loads(src.read_text(encoding="utf-8"))
        current_payload = json.loads(dst.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    merged, changed = merge_secret_placeholders(source_payload, current_payload)
    if not changed:
        return None
    return (json.dumps(merged, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _copy_file_if_changed(src: Path, dst: Path) -> bool:
    """Copy file from src to dst when missing or content differs. Returns True if written."""
    try:
        rendered = maybe_render_mcp_with_preserved_secrets(src, dst)
        if rendered is not None:
            if dst.read_bytes() == rendered:
                return False
            dst.write_bytes(rendered)
            return True
        if dst.is_symlink() or dst.is_file():
            if dst.is_file() and not dst.is_symlink():
                if dst.stat().st_size == src.stat().st_size and dst.read_bytes() == src.read_bytes():
                    return False
            dst.unlink(missing_ok=True)
        elif dst.exists():
            remove_tree(dst)
    except OSError:
        remove_tree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return True


def _overlay_dir(src: Path, dst: Path) -> bool:
    """Recursively overlay src onto dst. Returns True if anything was written."""
    changed = False
    if dst.exists() and not dst.is_dir():
        remove_tree(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for entry in src.iterdir():
        target = dst / entry.name
        if entry.is_symlink() or entry.is_file():
            if _copy_file_if_changed(entry, target):
                changed = True
        elif entry.is_dir():
            if _overlay_dir(entry, target):
                changed = True
    return changed


def overlay_source_to_cache(source_path: Path, cache_version_path: Path) -> bool:
    """Mirror source files (except node_modules) onto cache. Returns True if changed."""
    changed = False
    for entry in source_path.iterdir():
        if entry.name == NODE_MODULES_NAME:
            continue
        target = cache_version_path / entry.name
        if entry.is_symlink() or entry.is_file():
            if _copy_file_if_changed(entry, target):
                changed = True
        elif entry.is_dir():
            if _overlay_dir(entry, target):
                changed = True
    return changed


def link_source_node_modules(source_path: Path, cache_version_path: Path) -> tuple[str, str]:
    source_node_modules = source_path / "node_modules"
    cache_node_modules = cache_version_path / "node_modules"

    if cache_version_path.is_symlink() and cache_version_path.resolve() == source_path:
        return "cache-is-source", ""
    if not cache_node_modules.exists():
        return "missing", ""
    if not cache_node_modules.is_dir():
        return "not-directory", str(cache_node_modules)

    if source_node_modules.is_symlink():
        if source_node_modules.resolve() == cache_node_modules.resolve():
            return "unchanged", str(cache_node_modules)
        source_node_modules.unlink()
        source_node_modules.symlink_to(cache_node_modules, target_is_directory=True)
        return "updated", str(cache_node_modules)

    if source_node_modules.exists():
        return "present", str(source_node_modules)

    source_node_modules.symlink_to(cache_node_modules, target_is_directory=True)
    return "linked", str(cache_node_modules)


def sync_plugin_cache(root: Path, channel: str) -> dict[str, str]:
    marketplace_name, plugins = load_marketplace(root)

    if not channel.startswith("plugin:") or "@" not in channel:
        return {"channel": channel, "status": "ignored", "reason": "not-a-plugin-channel"}

    plugin_spec = channel[len("plugin:") :]
    plugin_name, plugin_marketplace = plugin_spec.split("@", 1)
    if plugin_marketplace != marketplace_name:
        return {
            "channel": channel,
            "plugin": plugin_name,
            "status": "ignored",
            "reason": f"marketplace-mismatch:{plugin_marketplace}",
        }

    metadata = plugins.get(plugin_name)
    if metadata is None:
        return {"channel": channel, "plugin": plugin_name, "status": "missing", "reason": "not-in-marketplace"}

    source_rel = metadata.get("source") or ""
    version = metadata.get("version") or "0.1.0"
    source_path = (root / source_rel).resolve()
    if not source_path.exists():
        return {
            "channel": channel,
            "plugin": plugin_name,
            "status": "missing",
            "reason": f"source-missing:{source_path}",
        }

    plugin_cache_root = cache_root() / marketplace_name / plugin_name
    cache_version_path = plugin_cache_root / version
    orphan_removed = 0
    cache_type = "missing"

    if cache_version_path.is_symlink():
        current_target = cache_version_path.resolve()
        if current_target == source_path:
            status = "unchanged"
        else:
            cache_version_path.unlink(missing_ok=True)
            cache_version_path.symlink_to(source_path, target_is_directory=True)
            status = "updated"
        cache_type = "symlink"
    else:
        if cache_version_path.is_dir():
            # Real cache directories carry installed dependencies. Overlay source
            # files (everything except node_modules) so operator edits reach the
            # cache, while preserving the cache's installed node_modules dir. The
            # source root's node_modules is then linked back to the cache below.
            changed = overlay_source_to_cache(source_path, cache_version_path)
            status = "updated" if changed else "unchanged"
            cache_type = "directory"
        elif cache_version_path.exists():
            remove_tree(cache_version_path)
            status = "updated"
            cache_type = "symlink"
            plugin_cache_root.mkdir(parents=True, exist_ok=True)
            cache_version_path.symlink_to(source_path, target_is_directory=True)
        else:
            status = "linked"
            cache_type = "symlink"
            plugin_cache_root.mkdir(parents=True, exist_ok=True)
            cache_version_path.symlink_to(source_path, target_is_directory=True)

    if plugin_cache_root.exists():
        for marker in plugin_cache_root.rglob(".orphaned_at"):
            marker.unlink(missing_ok=True)
            orphan_removed += 1

    node_modules_status, node_modules_target = link_source_node_modules(source_path, cache_version_path)

    return {
        "channel": channel,
        "plugin": plugin_name,
        "marketplace": marketplace_name,
        "version": version,
        "source": str(source_path),
        "cache": str(cache_version_path),
        "cache_type": cache_type,
        "status": status,
        "node_modules_status": node_modules_status,
        "node_modules_target": node_modules_target,
        "orphan_removed": str(orphan_removed),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    sync_parser = sub.add_parser("sync")
    sync_parser.add_argument("--channels", required=True)
    sync_parser.add_argument("--root", default=str(repo_root()))
    sync_parser.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    if args.command != "sync":
        return 1

    root = Path(args.root).expanduser().resolve()
    results = [
        sync_plugin_cache(resolve_marketplace_root(root, item), item)
        for item in normalize_channels(args.channels)
    ]
    if args.json:
        json.dump({"results": results}, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    for item in results:
        status = item.get("status", "unknown")
        plugin = item.get("plugin") or item.get("channel") or "-"
        if status in {"linked", "updated", "unchanged"}:
            print(
                f"{plugin}: {status} cache={item.get('cache','-')} source={item.get('source','-')} "
                f"node_modules={item.get('node_modules_status','-')} "
                f"node_modules_target={item.get('node_modules_target','-') or '-'} "
                f"orphan_removed={item.get('orphan_removed','0')}"
            )
        else:
            print(f"{plugin}: {status} ({item.get('reason','-')})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
