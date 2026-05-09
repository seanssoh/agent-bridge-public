#!/usr/bin/env python3
"""Prepare Claude dev-loaded plugin cache/source links for live marketplace sources."""

from __future__ import annotations

import argparse
import json
import os
import re
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


# Mirrored in lib/bridge-agents.sh (`bridge_known_marketplace_info` and
# `bridge_write_isolated_known_marketplaces_catalog`). Any change to the
# accepted forms or the produced slug must be applied to both, otherwise
# the bash side and the Python side will disagree on the alias for the
# same source and Claude will fail to resolve the marketplace.
_GITHUB_URL_PREFIXES = (
    "https://github.com/",
    "http://github.com/",
    "git://github.com/",
)
_GITHUB_SSH_PREFIX = "git@github.com:"


def _github_repo_slug(source: str) -> str:
    """Return an `<org>-<repo>` alias when source names a GitHub repo.

    Accepted forms:
        https://github.com/<org>/<repo>          → <org>-<repo>
        https://github.com/<org>/<repo>.git      → <org>-<repo>
        git@github.com:<org>/<repo>.git          → <org>-<repo>
        <org>/<repo>                             → <org>-<repo>
        <org>/<repo>.git                         → <org>-<repo>

    Non-GitHub URLs (`https://gitlab.com/...`, `git@example.com:...`,
    archive URLs, paths) return "" so the caller can fall back to the
    simple slugify or skip aliasing entirely.
    """
    s = (source or "").strip()
    if not s:
        return ""
    lowered = s.lower()
    matched_prefix = ""
    for prefix in _GITHUB_URL_PREFIXES:
        if lowered.startswith(prefix):
            matched_prefix = prefix
            break
    if matched_prefix:
        s = s[len(matched_prefix):]
    elif lowered.startswith(_GITHUB_SSH_PREFIX):
        s = s[len(_GITHUB_SSH_PREFIX):]
    elif "://" in s or "@" in s.split("/", 1)[0]:
        # Looks like a URL or SSH spec but not GitHub — refuse rather
        # than producing a slug like `https:-gitlab.com`.
        return ""
    elif s.startswith("/"):
        # Looks like a filesystem path (`/local/path/...`) — refuse so
        # the simple-slugify fallback handles the path-style input
        # rather than producing a misleading `<root>-<dir>` alias.
        return ""
    s = s.strip().strip("/")
    if s.endswith(".git"):
        s = s[: -len(".git")]
    parts = [p for p in s.split("/") if p]
    if len(parts) < 2:
        return ""
    org, repo = parts[0], parts[1]
    if not org or not repo:
        return ""
    return f"{org}-{repo}"


def marketplace_repo_slug(repo: str) -> str:
    """Back-compat shim: prefer GitHub-aware parsing, then bare org/repo."""
    slug = _github_repo_slug(repo)
    if slug:
        return slug
    repo = (repo or "").strip().strip("/")
    if not repo or "/" not in repo:
        return ""
    return repo.replace("/", "-")


# Mirrored in lib/bridge-agents.sh. Aliases land under
# `<plugins_root>/marketplaces/<alias>` as root-owned symlinks, so any
# alias that escapes the marketplaces/ namespace is a privilege-escalation
# surface. Reject loudly rather than silently sanitising — a rejected
# input means an upstream catalog/config bug we want surfaced.
#
# Use `re.fullmatch` (not `re.match(... + "$")`): in Python's default
# (non-MULTILINE) mode, `$` matches at the end-of-string AND just before
# a trailing newline. That means `re.match(r"^[A-Za-z0-9._-]+$", "foo\n")`
# returns a match — letting an alias with a trailing newline slip past
# the safety regex. `fullmatch` requires the pattern to consume the
# entire string (no implicit trailing-`\n` allowance), which is the
# semantic the privilege-escalation gate needs.
_SAFE_ALIAS_RE = re.compile(r"[A-Za-z0-9._-]+")
_ALIAS_RESERVED_NAMES = {".", ".."}
_ALIAS_WINDOWS_RESERVED = (
    {"CON", "PRN", "AUX", "NUL"}
    | {f"COM{i}" for i in range(1, 10)}
    | {f"LPT{i}" for i in range(1, 10)}
)


def _alias_rejection_reason(alias: object) -> str:
    """Return an empty string when alias is safe, else a human-readable reason."""
    if not isinstance(alias, str):
        return f"not a string ({type(alias).__name__})"
    if alias == "":
        return "empty"
    if len(alias) > 200:
        return f"length {len(alias)} exceeds 200"
    if not _SAFE_ALIAS_RE.fullmatch(alias):
        return "contains characters outside [A-Za-z0-9._-]"
    if ".." in alias:
        return "contains '..'"
    if alias in _ALIAS_RESERVED_NAMES:
        return f"reserved name '{alias}'"
    if alias.upper() in _ALIAS_WINDOWS_RESERVED:
        return f"reserved Windows name '{alias}'"
    if alias.startswith(".") and alias != ".git":
        return f"leading dot disallowed ('{alias}')"
    return ""


def _is_safe_alias(alias: object) -> bool:
    return _alias_rejection_reason(alias) == ""


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


def _require_safe_path_component(value: str, *, role: str, context: str) -> None:
    """Fail loud when a value about to become a path component is unsafe.

    Mirrors the contract of `bridge_isolation_alias_rejection_reason` in
    lib/bridge-agents.sh: any path component that escapes the documented
    safe-alias namespace can plant a symlink/dir outside the
    intended root, so we refuse rather than silently sanitising.
    Raises ValueError with a concrete reason — callers higher up surface
    this through `bridge_die`-equivalent logging or let it propagate to
    the operator.
    """
    reason = _alias_rejection_reason(value)
    if reason:
        raise ValueError(
            f"[bridge-dev-plugin-cache] refusing unsafe {role} {value!r} "
            f"(context: {context}): {reason}"
        )


def resolve_marketplace_root(default_root: Path, channel: str) -> Path:
    marketplace = channel_marketplace(channel)
    if not marketplace:
        return default_root
    if root_marketplace_name(default_root) == marketplace:
        return default_root

    # Defense-in-depth: marketplace was extracted from the channel string
    # (`plugin:<name>@<marketplace>`) and is about to be joined into a
    # filesystem path under `<plugins_root>/marketplaces/<marketplace>`.
    # The bash side validates this before the catalog write, but the dev-
    # cache pipeline reaches here independently — keep the gate explicit.
    _require_safe_path_component(
        marketplace, role="marketplace id",
        context=f"resolve_marketplace_root channel={channel!r}",
    )

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
            # `repo_slug` derives from operator-controlled known_marketplaces.json
            # source.repo (org/name); validate before joining so a poisoned slug
            # cannot land us at `<plugins_root>/marketplaces/../foo`.
            _require_safe_path_component(
                repo_slug, role="repo slug",
                context=f"resolve_marketplace_root marketplace={marketplace!r}",
            )
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
    """Recursively overlay src onto dst. Returns True if anything was written.

    r4 codex catch — entries that are symlinks-to-directory (created
    accidentally by the r1/r2 link_source_node_modules path) were
    matched by the `entry.is_symlink() or entry.is_file()` arm and sent
    to shutil.copy2, producing a corrupt or absent cache. is_dir()
    returns True for symlinks-to-directory because pathlib stats the
    resolved target, so test for is_dir() FIRST and recurse through
    the symlink — this materializes the dependency tree into the
    cache as a real directory copy regardless of whether source's
    node_modules is a symlink (r1/r2 leftover) or a real dir.
    """
    changed = False
    if dst.exists() and not dst.is_dir():
        remove_tree(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for entry in src.iterdir():
        target = dst / entry.name
        if entry.is_dir():  # includes symlinks-to-directory (resolved-stat)
            if _overlay_dir(entry, target):
                changed = True
        elif entry.is_file() or entry.is_symlink():
            if _copy_file_if_changed(entry, target):
                changed = True
    return changed


def overlay_source_to_cache(source_path: Path, cache_version_path: Path) -> bool:
    """Mirror EVERYTHING from source onto cache, including node_modules.

    r3 codex catch — earlier overlay skipped node_modules and
    link_source_node_modules then symlinked source/node_modules → cache,
    which (a) modified the SOURCE tree (unsafe, source-of-truth must
    stay clean) and (b) made every agent's sync race over the same
    source/node_modules pointer (cross-agent collision). The fix is to
    treat the cache as a fully self-contained per-agent snapshot:
    copy node_modules into the cache too. Disk overhead is bounded by
    the plugin's installed dependency tree per agent (operator
    acknowledged 100-300 MB / agent in design v2).
    """
    changed = False
    for entry in source_path.iterdir():
        target = cache_version_path / entry.name
        # r4 codex catch — is_dir() FIRST so symlinks-to-directory are
        # materialized into the cache as a real directory copy. Old
        # ordering matched is_symlink first → shutil.copy2 → corrupt cache.
        if entry.is_dir():
            if _overlay_dir(entry, target):
                changed = True
        elif entry.is_file() or entry.is_symlink():
            if _copy_file_if_changed(entry, target):
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


def _verify_cache_version_path(
    cache_version_path: Path, source_path: Path
) -> tuple[bool, str]:
    """Post-link verification under the running UID.

    The Python process already runs as the isolated UID (bridge-start
    wraps the whole bridge-run.sh session under `sudo -n -u <os_user> -H`
    for linux-user-isolated agents — see bridge-start.sh:447). So an
    `os.access` probe here measures what the isolated agent will actually
    see when it tries to read the cache version directory.

    Returns (ok, reason). reason is empty when ok=True. v0.9.7 RC6:
    success labels (`linked-verified`, `updated-verified`,
    `unchanged-verified`) MUST NOT be emitted unless this returns True.
    The previous linker logged `linked-OK` based purely on the symlink
    existing, even when the dest dir was unreadable for the isolated UID
    or never created — that silent success is exactly the bug RC6 names.
    """
    try:
        if not source_path.exists():
            return False, f"source-missing:{source_path}"
    except OSError as exc:
        return False, f"source-stat-failed:{exc}"

    if not os.access(str(source_path), os.R_OK):
        return False, f"source-unreadable:{source_path}"

    try:
        resolved = cache_version_path.resolve()
    except OSError as exc:
        return False, f"cache-resolve-failed:{exc}"

    if not resolved.is_dir():
        return False, f"cache-version-dir-missing:{cache_version_path}"

    if not os.access(str(resolved), os.R_OK):
        return False, f"cache-version-dir-unreadable:{cache_version_path}"

    # Every parent dir must be traversable for the isolated UID, otherwise
    # the agent process can resolve the symlink but cannot enter the cache.
    parent = resolved.parent
    while True:
        try:
            if not os.access(str(parent), os.X_OK):
                return False, f"parent-not-traversable:{parent}"
        except OSError as exc:
            return False, f"parent-access-failed:{parent}:{exc}"
        if parent == parent.parent:
            break
        parent = parent.parent

    return True, ""


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
    # RC6 pre-link assertion: source path must exist AND be readable by
    # the running UID (which is the isolated agent UID under sudo wrap).
    # The previous linker only checked existence; an unreadable source
    # (group/ACL drift) would still log success.
    if not source_path.exists():
        return {
            "channel": channel,
            "plugin": plugin_name,
            "status": "missing",
            "reason": f"source-missing:{source_path}",
        }
    if not os.access(str(source_path), os.R_OK):
        return {
            "channel": channel,
            "plugin": plugin_name,
            "status": "install-failed",
            "reason": f"source-unreadable:{source_path}",
        }

    # Defense-in-depth: every component about to be joined into the
    # cache path is operator/marketplace-controlled (marketplace.json,
    # channel string). Validate before `cache_root() / mkt / plug / ver`
    # so an unsafe component (newline, `..`, slash) cannot escape the
    # cache root via path traversal — fail loud rather than silently
    # caching to a poisoned path.
    _require_safe_path_component(
        marketplace_name, role="marketplace name",
        context=f"sync_plugin_cache channel={channel!r}",
    )
    _require_safe_path_component(
        plugin_name, role="plugin name",
        context=f"sync_plugin_cache channel={channel!r}",
    )
    _require_safe_path_component(
        str(version), role="plugin version",
        context=f"sync_plugin_cache channel={channel!r}",
    )

    plugin_cache_root = cache_root() / marketplace_name / plugin_name
    cache_version_path = plugin_cache_root / version
    orphan_removed = 0
    cache_type = "missing"

    try:
        # r2 codex catch — operator's binding principle is per-agent
        # isolated cache. r1 implementation used symlink to source which
        # made each agent's distinct cache *path* resolve to the same
        # *target*: cross-agent interference on writes, modifications
        # to the source visible to every agent. Replace symlink with
        # real per-agent directory (overlay copy of source into the
        # isolated home). Disk overhead 100-300 MB per agent acknowledged
        # in design v2 §"Per-Agent Cache Tradeoffs".
        if cache_version_path.is_symlink():
            # Migrate any pre-existing symlink (from r1 or v0.9.6 install)
            # into a real directory. Unlink the symlink, then mkdir +
            # overlay source so the cache is genuinely per-agent.
            cache_version_path.unlink(missing_ok=True)
            # r4 codex Probe 7 — also chmod parent dirs to 0700 so a
            # default umask (0o022) does not leave the marketplace +
            # plugin level world-readable above the per-version cache.
            plugin_cache_root.mkdir(parents=True, exist_ok=True)
            plugin_cache_root.chmod(0o700)
            if plugin_cache_root.parent != cache_root() and plugin_cache_root.parent.exists():
                plugin_cache_root.parent.chmod(0o700)
            cache_version_path.mkdir(parents=False, exist_ok=False, mode=0o700)
            cache_version_path.chmod(0o700)  # explicit, defensive against umask
            overlay_source_to_cache(source_path, cache_version_path)
            status = "updated"
            cache_type = "directory"
        elif cache_version_path.is_dir():
            # Already a real per-agent directory. Overlay source files
            # (except node_modules) so operator edits to source reach
            # the cache, while preserving the cache's installed
            # node_modules dir. The source root's node_modules is then
            # linked back to the cache below.
            changed = overlay_source_to_cache(source_path, cache_version_path)
            status = "updated" if changed else "unchanged"
            cache_type = "directory"
        elif cache_version_path.exists():
            # Stray non-directory entry (file, special) — remove and
            # rebuild as real directory.
            remove_tree(cache_version_path)
            # r4 codex Probe 7 — also chmod parent dirs to 0700 so a
            # default umask (0o022) does not leave the marketplace +
            # plugin level world-readable above the per-version cache.
            plugin_cache_root.mkdir(parents=True, exist_ok=True)
            plugin_cache_root.chmod(0o700)
            if plugin_cache_root.parent != cache_root() and plugin_cache_root.parent.exists():
                plugin_cache_root.parent.chmod(0o700)
            cache_version_path.mkdir(parents=False, exist_ok=False, mode=0o700)
            cache_version_path.chmod(0o700)  # explicit, defensive against umask
            overlay_source_to_cache(source_path, cache_version_path)
            status = "updated"
            cache_type = "directory"
        else:
            # First-time install — create the per-agent directory and
            # overlay source files into it.
            # r4 codex Probe 7 — also chmod parent dirs to 0700 so a
            # default umask (0o022) does not leave the marketplace +
            # plugin level world-readable above the per-version cache.
            plugin_cache_root.mkdir(parents=True, exist_ok=True)
            plugin_cache_root.chmod(0o700)
            if plugin_cache_root.parent != cache_root() and plugin_cache_root.parent.exists():
                plugin_cache_root.parent.chmod(0o700)
            cache_version_path.mkdir(parents=False, exist_ok=False, mode=0o700)
            cache_version_path.chmod(0o700)  # explicit, defensive against umask
            overlay_source_to_cache(source_path, cache_version_path)
            status = "linked"
            cache_type = "directory"
    except OSError as exc:
        # Filesystem refused the install action — fail loud, do not
        # fall through to a verified label. RC6 root cause was the
        # opposite: actions silently failed and the linker still
        # printed success.
        return {
            "channel": channel,
            "plugin": plugin_name,
            "marketplace": marketplace_name,
            "version": version,
            "source": str(source_path),
            "cache": str(cache_version_path),
            "cache_type": cache_type,
            "status": "install-failed",
            "reason": f"install-error:{exc}",
        }

    if plugin_cache_root.exists():
        for marker in plugin_cache_root.rglob(".orphaned_at"):
            marker.unlink(missing_ok=True)
            orphan_removed += 1

    # r3 codex catch — link_source_node_modules MODIFIED the source's
    # node_modules entry, making every agent's sync race over the same
    # source pointer (cross-agent collision). The new overlay path
    # above includes node_modules in the cache itself, so the cache is
    # genuinely self-contained per-agent. We retain the status report
    # for backward compat (downstream readers parse the field) but
    # derive it from the cache's own node_modules now.
    cache_node_modules = cache_version_path / "node_modules"
    if cache_node_modules.is_dir():
        node_modules_status = "present"
        node_modules_target = str(cache_node_modules)
    elif cache_node_modules.exists():
        node_modules_status = "not-directory"
        node_modules_target = str(cache_node_modules)
    else:
        node_modules_status = "missing"
        node_modules_target = ""

    # RC6 post-link verification: a successful install action does not
    # imply a usable cache for the isolated agent. We must verify under
    # the running UID before promoting the status to a `*-verified`
    # label. Failure relabels to `linked-failed` with a structured
    # reason and the criticality split decides block vs warn.
    verified, verify_reason = _verify_cache_version_path(cache_version_path, source_path)
    if not verified:
        return {
            "channel": channel,
            "plugin": plugin_name,
            "marketplace": marketplace_name,
            "version": version,
            "source": str(source_path),
            "cache": str(cache_version_path),
            "cache_type": cache_type,
            "status": "linked-failed",
            "reason": verify_reason,
            "node_modules_status": node_modules_status,
            "node_modules_target": node_modules_target,
            "orphan_removed": str(orphan_removed),
        }

    # Success path: relabel `linked` → `linked-verified`,
    # `updated` → `updated-verified`, `unchanged` → `unchanged-verified`.
    # Operators (and the bridge-run audit tail) rely on the `-verified`
    # suffix to distinguish v0.9.7 RC6-fixed output from the older
    # `linked-OK` lying-success line.
    verified_status = f"{status}-verified"

    return {
        "channel": channel,
        "plugin": plugin_name,
        "marketplace": marketplace_name,
        "version": version,
        "source": str(source_path),
        "cache": str(cache_version_path),
        "cache_type": cache_type,
        "status": verified_status,
        "node_modules_status": node_modules_status,
        "node_modules_target": node_modules_target,
        "orphan_removed": str(orphan_removed),
    }


_VERIFIED_STATUSES = frozenset(
    {"linked-verified", "updated-verified", "unchanged-verified"}
)
_BENIGN_STATUSES = frozenset({"ignored"})


def _is_required_channel(channel: str, required: set[str]) -> bool:
    """Return True when this channel should block on failure (Q4 split).

    A channel is required when its full `plugin:<name>@<marketplace>`
    string was passed in `--required-channels`, OR (back-compat) when
    `--required-channels` is empty (legacy callers that don't yet pass
    the split treat every channel as required, matching pre-v0.9.7
    behavior of the bridge-run sync helper).
    """
    if not required:
        return True
    return channel in required


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    sync_parser = sub.add_parser("sync")
    sync_parser.add_argument("--channels", required=True)
    # v0.9.7 RC6 (Q4 decision): channel-required plugin failure must
    # block bridge-start; optional plugin failure must warn and continue.
    # The caller (bridge-run.sh) computes the two sets from
    # `bridge_agent_effective_dev_channels_csv` and `BRIDGE_AGENT_PLUGINS`
    # respectively and passes them as separate args. Defaulting both to
    # empty preserves the pre-RC6 caller contract: with no split the
    # linker treats every channel as required (block-on-fail), which
    # matches the legacy bridge-run behavior of `bridge_warn` + return.
    sync_parser.add_argument(
        "--required-channels",
        default="",
        help=(
            "CSV of channel-required plugin: entries (failure blocks "
            "bridge-start). Default empty = treat every --channels item "
            "as required (back-compat)."
        ),
    )
    sync_parser.add_argument(
        "--optional-channels",
        default="",
        help=(
            "CSV of optional plugin: entries (failure warns and "
            "continues). Items in this set are demoted to non-fatal "
            "even if also listed in --channels."
        ),
    )
    sync_parser.add_argument("--root", default=str(repo_root()))
    sync_parser.add_argument("--json", action="store_true")
    sync_parser.add_argument(
        "--agent",
        default="",
        help="Agent name for log lines (operator-visible context).",
    )

    args = parser.parse_args(argv)
    if args.command != "sync":
        return 1

    root = Path(args.root).expanduser().resolve()
    required_set = set(normalize_channels(args.required_channels))
    optional_set = set(normalize_channels(args.optional_channels))
    # Optional always wins over required when an entry appears in both
    # (operator listed the same plugin in BRIDGE_AGENT_CHANNELS and
    # BRIDGE_AGENT_PLUGINS — treat the more lenient declaration as the
    # binding one, since the operator explicitly opted into the
    # warn-and-continue mode for that plugin).
    required_set -= optional_set
    agent_label = args.agent or "-"

    results = [
        sync_plugin_cache(resolve_marketplace_root(root, item), item)
        for item in normalize_channels(args.channels)
    ]

    # Tag each result with criticality so the downstream reporter and
    # exit-code logic can apply the Q4 split uniformly.
    required_failures: list[dict[str, str]] = []
    optional_failures: list[dict[str, str]] = []
    for item in results:
        channel = item.get("channel", "")
        status = item.get("status", "unknown")
        if channel in optional_set:
            criticality = "optional"
        elif _is_required_channel(channel, required_set):
            criticality = "channel-required"
        else:
            criticality = "optional"
        item["criticality"] = criticality

        if status in _VERIFIED_STATUSES or status in _BENIGN_STATUSES:
            continue
        if criticality == "channel-required":
            required_failures.append(item)
        else:
            optional_failures.append(item)

    if args.json:
        json.dump(
            {
                "results": results,
                "agent": args.agent,
                "required_failure_count": len(required_failures),
                "optional_failure_count": len(optional_failures),
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
        # JSON callers still get the criticality-aware exit code so a
        # programmatic consumer (bridge-run.sh) can branch identically
        # whether or not it asked for human or JSON output.
        return 1 if required_failures else 0

    for item in results:
        status = item.get("status", "unknown")
        plugin = item.get("plugin") or item.get("channel") or "-"
        criticality = item.get("criticality", "channel-required")
        if status in _VERIFIED_STATUSES:
            print(
                f"{plugin}: {status} cache={item.get('cache','-')} source={item.get('source','-')} "
                f"node_modules={item.get('node_modules_status','-')} "
                f"node_modules_target={item.get('node_modules_target','-') or '-'} "
                f"orphan_removed={item.get('orphan_removed','0')} "
                f"criticality={criticality}"
            )
        elif status in _BENIGN_STATUSES:
            print(f"{plugin}: {status} ({item.get('reason','-')})")
        else:
            # Failure line — tag with criticality so the operator (and
            # bridge-run audit) can tell `WARNING (optional)` apart from
            # `ERROR (channel-required)` at a glance.
            tag = "ERROR" if criticality == "channel-required" else "WARNING"
            print(
                f"{tag} {plugin}: {status} ({item.get('reason','-')}) "
                f"criticality={criticality} agent={agent_label}"
            )

    if optional_failures and not required_failures:
        # Q4 decision: optional plugin failures warn and continue. Emit
        # one summary line per failed optional plugin so the operator
        # sees `launched without it` in the launch log even when no
        # ERROR line drew their attention to the per-plugin block above.
        for item in optional_failures:
            plugin = item.get("plugin") or item.get("channel") or "-"
            print(
                f"WARNING: plugin {plugin} missing for agent {agent_label}, "
                f"launched without it"
            )

    return 1 if required_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
