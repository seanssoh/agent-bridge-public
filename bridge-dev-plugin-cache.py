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


def _marketplace_entry_matches_root(entry: object, root: Path) -> bool:
    if not isinstance(entry, dict):
        return False
    root_s = str(root)
    if str(entry.get("installLocation") or "").strip() != root_s:
        return False
    source = entry.get("source")
    if not isinstance(source, dict):
        return False
    return (
        str(source.get("source") or "").strip() == "directory"
        and str(source.get("path") or "").strip() == root_s
    )


def ensure_known_marketplace_for_root(root: Path, marketplace_name: str) -> tuple[bool, str]:
    """Ensure Claude can resolve plugin:<name>@<marketplace> to this root.

    The cache linker can install plugin files without touching
    known_marketplaces.json, but Claude's development-channel loader also
    consults that catalog when it expands a marketplace-scoped plugin into
    its .mcp.json servers. Shared agents that only had installed_plugins.json
    could therefore see `plugin:teams@agent-bridge` but still report
    `server:teams · no MCP server configured with that name`.
    """
    if not marketplace_name:
        return True, "no-marketplace"
    try:
        _require_safe_path_component(
            marketplace_name,
            role="marketplace name",
            context="known marketplace catalog update",
        )
    except ValueError as exc:
        return False, str(exc)

    path = known_marketplaces_path()
    root = root.resolve()
    # L1-D Part C (beta22, codex r1 race-safety, 2026-05-25):
    # `merge_installed_plugins` already protects installed_plugins.json with
    # a sidecar `installed_plugins.json.lock` flock; this writer (and the
    # D2 seed-side `lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py`)
    # both touch the SAME per-UID `known_marketplaces.json` but had no
    # shared lock. Concurrent runs (start hook + cron-driven seed +
    # operator `agb plugins seed`) could lose updates — a read-modify-
    # write race where the later writer overwrites the earlier writer's
    # entry. Use a sidecar `known_marketplaces.json.lock` flock with the
    # exact same convention (LOCK_EX on a same-dir lockfile, dropped on
    # function exit). Identical writers in the seed-merge helper share
    # the same lock path so they serialize against each other too.
    import errno  # noqa: F401  (kept for parity with merge_installed_plugins)
    import fcntl

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        return False, f"mkdir-failed: {exc}"

    lock_path = path.with_name(f"{path.name}.lock")
    try:
        lock_fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as exc:
        return False, f"lock-open-failed: {exc}"

    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
        except OSError as exc:
            return False, f"flock-failed: {exc}"

        # Re-read under the lock to avoid losing a concurrent update that
        # landed between our pre-lock load and the LOCK_EX acquire.
        payload = load_known_marketplaces()
        existing = payload.get(marketplace_name)
        if _marketplace_entry_matches_root(existing, root):
            return True, "already-correct"

        payload[marketplace_name] = {
            "source": {"source": "directory", "path": str(root)},
            "installLocation": str(root),
            "lastUpdated": _now_iso_utc(),
        }
        existing_mode = 0o600
        if path.exists():
            try:
                existing_mode = path.stat().st_mode & 0o777
            except OSError:
                existing_mode = 0o600
        tmp_path = path.with_name(f"{path.name}.tmp.{os.getpid()}")
        try:
            tmp_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            os.chmod(tmp_path, existing_mode)
            os.replace(tmp_path, path)
        finally:
            try:
                if tmp_path.exists():
                    tmp_path.unlink()
            except OSError:
                pass
        return True, "updated"
    except OSError as exc:
        return False, f"write-failed: {exc}"
    finally:
        try:
            os.close(lock_fd)
        except OSError:
            pass


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

# Issue #1663 — upgrade/VCS sidecars that must NEVER be copied into a
# plugin cache. `bridge-upgrade.py`'s `conflict_backup_path` writes
# `<file>.upgrade-conflict` preserving the original file's mode/owner; on
# an iso-v2 host a 0600 owner-only `server.ts.upgrade-conflict` left
# inside a plugin source dir is unreadable by the isolated UID. The old
# overlay used an exact-name skip set only, so it tried to `copy2` the
# sidecar → PermissionError → the entire plugin cache build aborted →
# every iso agent on that plugin cascade-failed to launch. These are not
# plugin content, so skipping them is correct and non-fatal (skip+WARN).
#
# Deliberately NARROW: we do NOT skip `*.bak`, `*.tmp`, or arbitrary
# dotfiles — those can be legitimate plugin content. Only known
# upgrade/merge/VCS sidecars are pattern-skipped.
_SIDECAR_SKIP_SUFFIXES = (
    ".upgrade-conflict",
    ".orig",
    ".rej",
)
# git/hg merge-tool sidecars carry the marker as an INFIX, e.g.
# `server.ts.BACKUP.12345`, `config.json.LOCAL.678`.
_SIDECAR_MERGE_INFIXES = (
    ".BACKUP.",
    ".BASE.",
    ".LOCAL.",
    ".REMOTE.",
)
# Exact VCS metadata names if they somehow appear under a plugin source.
_VCS_METADATA_NAMES = frozenset({".git", ".hg", ".svn"})

# Issue #1663 — required plugin contract material. Silently shipping a
# plugin cache that is missing one of these is worse than failing: the
# plugin would load broken. So if one of these is unreadable / fails to
# copy, we must fail-loud (install-failed) instead of skip+WARN. Matched
# by basename, so `.claude-plugin/plugin.json` is covered by `plugin.json`.
_REQUIRED_CONTRACT_NAMES = frozenset(
    {
        "plugin.json",
        "package.json",
        "server.ts",
        "server.js",
        "mcp.json",
        MCP_CONFIG_NAME,  # ".mcp.json"
    }
)


class RequiredContractUnreadable(OSError):
    """Raised when a REQUIRED plugin-contract entry cannot be copied.

    Issue #1663 — the per-entry overlay guard skips+WARNs an *unknown*
    unreadable entry so one bad sidecar can never cascade-fail the whole
    cache build. But a required-contract file (plugin.json, package.json,
    server.ts/js, mcp.json/.mcp.json) silently missing from the cache is
    worse than failing. This subclasses OSError so it still flows into
    `sync_plugin_cache`'s existing `except OSError` → `install-failed`
    branch (fail-loud), while the per-entry guard re-raises it instead of
    swallowing it.
    """


def _sidecar_skip_reason(name: str) -> str | None:
    """Return a human reason if ``name`` is a known upgrade/VCS sidecar.

    Returns None when the entry is legitimate plugin content. Issue #1663.
    """
    if name in _VCS_METADATA_NAMES:
        return f"vcs-metadata:{name}"
    for suffix in _SIDECAR_SKIP_SUFFIXES:
        if name.endswith(suffix):
            return f"upgrade-sidecar:{name}"
    for infix in _SIDECAR_MERGE_INFIXES:
        if infix in name:
            return f"merge-sidecar:{name}"
    return None


def _is_required_contract_name(name: str) -> bool:
    """True when ``name`` is required plugin-contract material. Issue #1663."""
    return name in _REQUIRED_CONTRACT_NAMES


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


def _is_symlink_outside_source_root(entry: Path, source_root: Path) -> bool:
    """True when ``entry`` is a symlink whose resolved target is outside ``source_root``.

    v0.9.8 #786 Finding 1 — operator hosts that migrated from v0.7→v0.8
    isolation often carry leftover ``source/node_modules`` symlinks that
    point at the controller's plugin cache (e.g.
    ``/home/<controller>/.claude/plugins/cache/...``). When the linker
    runs as the isolated UID, the controller path is unreadable and a
    blind ``iterdir()`` through the symlink raises ``PermissionError``,
    failing the whole sync. Detect symlinks-to-outside-source up front
    so the linker can skip them with a WARN instead of crashing.

    ``source_root`` must already be resolved by the caller; ``entry``
    is resolved here. ``Path.resolve()`` only follows the readlink
    chain and does not require read access on the final target, so the
    symlink target being permission-denied to the running UID does not
    block the check.
    """
    if not entry.is_symlink():
        return False
    try:
        resolved = entry.resolve()
    except OSError:
        # Loop or other resolution failure — treat as outside so we
        # skip+warn rather than crash on iterdir().
        return True
    try:
        # Python 3.9+: Path.is_relative_to. Available everywhere this
        # repo's `python3` runs (CI + macOS Homebrew + Amazon Linux 2023).
        return not resolved.is_relative_to(source_root)
    except AttributeError:
        # Defensive fallback for unexpectedly old interpreters.
        try:
            resolved.relative_to(source_root)
            return False
        except ValueError:
            return True


def _overlay_entry(
    entry: Path,
    target: Path,
    source_root: Path,
    skip_names: set[str],
    agent: str = "",
) -> bool:
    """Overlay a single source entry into the cache. Returns True if written.

    Shared by both `_overlay_dir()` (recursive) and
    `overlay_source_to_cache()` (top level) so the skip/guard policy is
    applied uniformly at every depth (Issue #1663 — the bug was that
    only the top level pattern-skipped, while the recursion did not, or
    vice versa; centralizing removes that drift).

    Policy, in order:
      0. REQUIRED-CONTRACT classification wins over EVERY skip path
         (Issue #1663 P1 / r2 codex catch). A required-contract entry
         (plugin.json, .claude-plugin/plugin.json, package.json,
         server.ts/js, mcp.json/.mcp.json — basename match) that cannot be
         materialized into the cache for ANY reason — symlink resolving
         outside the marketplace root, PermissionError, generic OSError —
         is promoted to a fail-loud `RequiredContractUnreadable`
         (→ install-failed). It must NEVER be silently skipped: shipping a
         "verified" cache that is missing its contract file is worse than
         failing. (Required-contract basenames are never sidecar patterns,
         so step 0 and the sidecar-skip never conflict.)
      1. Exact-name `skip_names` (node_modules etc.) → silent skip.
      2. Known upgrade/VCS/merge sidecar (`*.upgrade-conflict`, `*.orig`,
         `*.rej`, `*.BACKUP.*`/`*.BASE.*`/`*.LOCAL.*`/`*.REMOTE.*`, `.git`/
         `.hg`/`.svn`) → skip + WARN, NON-FATAL. These are explicitly not
         plugin content, so they must not abort the build or mark the
         cache incomplete.
      3. Symlink resolving outside the marketplace source root → skip +
         WARN (pre-existing v1-isolation-leftover guard). NON-required
         entries only — a required-contract symlink-outside is fail-loud
         per step 0.
      4. Directory → recurse (is_dir() FIRST so symlinks-to-directory are
         materialized as a real copy — r4 codex catch).
      5. File / symlink → copy.

    Defense-in-depth (Issue #1663): steps 2-5 run under a per-entry guard
    so a single unreadable NON-required entry (e.g. a 0600 owner-only file
    an iso UID cannot read) is skipped + WARN'd instead of aborting the
    WHOLE cache build (which cascade-failed every iso agent on the plugin).
    """
    name = entry.name
    if name in skip_names:
        return False

    # Step 0 — required-contract classification takes precedence over all
    # skip paths. `_overlay_required_contract_entry` raises
    # RequiredContractUnreadable if a required-contract entry cannot be
    # materialized (symlink-outside / unreadable / OSError); otherwise it
    # copies it and returns the changed flag. Non-required entries skip
    # this branch and fall through to the normal skip/copy policy below.
    if _is_required_contract_name(name):
        return _overlay_required_contract_entry(entry, target, source_root, agent=agent)

    sidecar_reason = _sidecar_skip_reason(name)
    if sidecar_reason is not None:
        sys.stderr.write(
            f"[bridge-dev-plugin-cache] WARNING: skipping non-plugin sidecar "
            f"{entry} ({sidecar_reason}; not copied into cache) "
            f"agent={agent or '-'}\n"
        )
        return False

    try:
        if _is_symlink_outside_source_root(entry, source_root):
            sys.stderr.write(
                f"[bridge-dev-plugin-cache] WARNING: skipping symlink {entry} -> "
                f"{entry.resolve()} (outside source root {source_root}; "
                f"likely v1-isolation leftover, run cleanup helper)\n"
            )
            return False
        if entry.is_dir():  # includes symlinks-to-directory (resolved-stat)
            return _overlay_dir(entry, target, source_root, skip_names=skip_names, agent=agent)
        if entry.is_file() or entry.is_symlink():
            return _copy_file_if_changed(entry, target)
        return False
    except RequiredContractUnreadable:
        # Already classified as fail-loud deeper in the recursion (a
        # required-contract entry nested under this directory) — let it
        # propagate up to sync_plugin_cache's `except OSError` (install-failed).
        raise
    except OSError as exc:
        # Unknown unreadable NON-required entry — skip + WARN, never abort
        # the build. This is what stops one 0600 sidecar (or any unreadable
        # file) from cascade-failing every iso agent on the plugin (#1663).
        sys.stderr.write(
            f"[bridge-dev-plugin-cache] WARNING: skipping unreadable entry "
            f"{entry} ({exc}; omitted from cache) agent={agent or '-'}\n"
        )
        return False


def _overlay_required_contract_entry(
    entry: Path,
    target: Path,
    source_root: Path,
    agent: str = "",
) -> bool:
    """Materialize a REQUIRED plugin-contract entry into the cache, fail-loud.

    Issue #1663 (P1 / r2 codex catch) — a required-contract file
    (plugin.json, .claude-plugin/plugin.json, package.json, server.ts/js,
    mcp.json/.mcp.json) must end up in the cache or the whole install
    fails. It is NEVER eligible for any skip path:

      * symlink resolving outside the marketplace source root → fail-loud
        (a v1-isolation-leftover symlink at a contract path would otherwise
        be silently dropped and the cache reported `linked-verified` with
        the contract missing — exactly the P1 bug).
      * PermissionError / generic OSError on stat/copy → fail-loud.

    Always raises `RequiredContractUnreadable` on any failure; otherwise
    returns the `_copy_file_if_changed` changed flag. The caller has
    already confirmed `_is_required_contract_name(entry.name)`.
    """
    try:
        if _is_symlink_outside_source_root(entry, source_root):
            raise RequiredContractUnreadable(
                f"required-contract-symlink-outside-source:{entry}:"
                f"resolves outside source root {source_root}"
            )
        # A required-contract name is expected to be a regular file (a dir
        # at that path is malformed plugin material). Treat is_file /
        # symlink-to-file as the copy case; anything else is fail-loud.
        if entry.is_file() or entry.is_symlink():
            return _copy_file_if_changed(entry, target)
        raise RequiredContractUnreadable(
            f"required-contract-unreadable:{entry}:not-a-regular-file"
        )
    except RequiredContractUnreadable:
        raise
    except OSError as exc:
        raise RequiredContractUnreadable(
            f"required-contract-unreadable:{entry}:{exc}"
        ) from exc


def _overlay_dir(
    src: Path,
    dst: Path,
    source_root: Path,
    skip_names: set[str] | None = None,
    agent: str = "",
) -> bool:
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

    v0.9.8 #786 Finding 1 — guard against v1-isolation leftover
    symlinks-to-outside-source BEFORE the is_dir() recursion, otherwise
    iterdir() would walk into a controller path the isolated UID
    cannot read.

    Issue #1663 — per-entry skip/guard policy (sidecar pattern-skip +
    unreadable-entry tolerance + required-contract fail-loud) lives in
    `_overlay_entry()` so it applies at EVERY recursion depth, not just
    the top level.
    """
    changed = False
    if dst.exists() and not dst.is_dir():
        remove_tree(dst)
    dst.mkdir(parents=True, exist_ok=True)
    skip_names = skip_names or set()
    for entry in src.iterdir():
        target = dst / entry.name
        if _overlay_entry(entry, target, source_root, skip_names, agent=agent):
            changed = True
    return changed


def overlay_source_to_cache(
    source_path: Path,
    cache_version_path: Path,
    source_root: Path | None = None,
    skip_names: set[str] | None = None,
    agent: str = "",
) -> bool:
    """Mirror source into cache.

    First-time installs and migrations mirror everything, including
    node_modules. Existing cache refreshes may pass ``skip_names`` to
    preserve expensive subtrees in place while still picking up source
    edits to plugin code and metadata.

    r3 codex catch — earlier overlay skipped node_modules and
    link_source_node_modules then symlinked source/node_modules → cache,
    which (a) modified the SOURCE tree (unsafe, source-of-truth must
    stay clean) and (b) made every agent's sync race over the same
    source/node_modules pointer (cross-agent collision). The fix is to
    treat the cache as a fully self-contained per-agent snapshot:
    copy node_modules into the cache too. Disk overhead is bounded by
    the plugin's installed dependency tree per agent (operator
    acknowledged 100-300 MB / agent in design v2).

    v0.9.8 #786 Finding 1 r1 — used the plugin's own source path as
    the boundary for symlink-outside-source detection. r2 catch:
    that boundary was too narrow — a plugin that legitimately uses
    ``node_modules -> ../dist`` (a sibling dir inside the same
    marketplace) was wrongly skipped because ``../dist`` is outside
    the plugin path even though it is inside the marketplace.

    r2 fix: caller passes the MARKETPLACE root via ``source_root``.
    Symlinks resolving inside the marketplace are recursed (intra-
    marketplace deps OK); symlinks resolving outside (e.g. v1-isolation
    leftover ``node_modules -> /<controller>/.claude/plugins/cache/...``)
    are skipped with a WARN log instead of triggering a
    ``PermissionError`` on iterdir() under the isolated UID.

    Back-compat: when ``source_root`` is omitted (legacy callers),
    fall back to ``source_path`` as before.

    Issue #1663 — per-entry skip/guard policy (upgrade/VCS sidecar
    pattern-skip + unreadable-entry tolerance + required-contract
    fail-loud) is centralized in `_overlay_entry()`, applied identically
    here and inside the recursive `_overlay_dir()`.
    """
    if source_root is None:
        source_root = source_path.resolve()
    else:
        source_root = source_root.resolve()
    changed = False
    skip_names = skip_names or set()
    for entry in source_path.iterdir():
        target = cache_version_path / entry.name
        if _overlay_entry(entry, target, source_root, skip_names, agent=agent):
            changed = True
    return changed


# Issue #1282 (Surface B) — conservative heuristic that mirrors the one
# in `lib/upgrade-helpers/plugins-seed-parse-sync-output.py`. Used to
# distinguish `node_modules=missing` from `node_modules=not-required`
# so `.mjs` proxy plugins that ship without a `package.json` (e.g.
# `cosmax-ep-approval`'s `ep-mcp-proxy.mjs` — inline-deps) do not paint
# the seed output with cosmetic noise. Returns True when the plugin's
# source ANY of:
#   * declares non-empty `dependencies` / `peerDependencies` in package.json
#   * ships a sibling lockfile (bun.lock, bun.lockb, package-lock.json,
#     yarn.lock)
# Any I/O error → False (steady-state benign — caller stays on the
# legacy `missing` label so a real install gap is still surfaced).
def _plugin_source_declares_deps(source_path: Path) -> bool:
    try:
        if not source_path.is_dir():
            return False
    except OSError:
        return False
    for lock in ("bun.lock", "bun.lockb", "package-lock.json", "yarn.lock"):
        try:
            if (source_path / lock).is_file():
                return True
        except OSError:
            continue
    pkg = source_path / "package.json"
    try:
        if not pkg.is_file():
            return False
    except OSError:
        return False
    try:
        with pkg.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        return False
    if not isinstance(data, dict):
        return False
    for key in ("dependencies", "peerDependencies"):
        deps = data.get(key)
        if isinstance(deps, dict) and deps:
            return True
    return False


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


def _find_missing_required_contract(
    cache_version_path: Path, source_path: Path
) -> str | None:
    """Return a reason if a required-contract file in source is absent in cache.

    Issue #1663 (P1 defense-in-depth / r2 codex catch) — the fail-loud
    path in `_overlay_required_contract_entry` already prevents a required
    file from being silently skipped, but verify must independently assert
    the invariant so NO future skip path can ship a `linked-verified`
    cache that is missing its contract material.

    Invariant: every required-contract file that EXISTS in the source tree
    (matched by basename, at any depth) must be present at the same
    relative path in the cache. We only require what the source has — a
    `.mjs` proxy plugin that legitimately ships without `package.json` /
    `server.ts` is not penalized (we never assert a file the source lacks).

    Any I/O error walking the source is reported as a verify failure (a
    source we cannot enumerate is not a cache we can certify).
    """
    try:
        source_entries = list(os.walk(source_path, followlinks=False))
    except OSError as exc:
        return f"required-contract-source-walk-failed:{exc}"
    for dirpath, _dirnames, filenames in source_entries:
        for fname in filenames:
            if not _is_required_contract_name(fname):
                continue
            src_file = Path(dirpath) / fname
            try:
                rel = src_file.relative_to(source_path)
            except ValueError:
                continue
            cache_file = cache_version_path / rel
            try:
                present = cache_file.is_file()
            except OSError as exc:
                return f"required-contract-cache-stat-failed:{rel}:{exc}"
            if not present:
                return f"required-contract-missing-in-cache:{rel}"
    return None


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

    Issue #1663 (P1 defense-in-depth): additionally assert that every
    required-contract file present in source landed in the cache, so a
    missing contract file can never be reported `*-verified`.
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

    # Issue #1663 (P1 defense-in-depth) — a usable cache dir is not enough;
    # the required-contract material must actually be in it. Fail verify if
    # any required-contract file present in source is missing from cache.
    missing = _find_missing_required_contract(resolved, source_path)
    if missing is not None:
        return False, missing

    return True, ""


def sync_plugin_cache(root: Path, channel: str, agent: str = "") -> dict[str, str]:
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

    catalog_ok, catalog_reason = ensure_known_marketplace_for_root(root, marketplace_name)
    if not catalog_ok:
        return {
            "channel": channel,
            "plugin": plugin_name,
            "marketplace": marketplace_name,
            "status": "catalog-write-failed",
            "reason": catalog_reason,
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
            overlay_source_to_cache(
                source_path, cache_version_path, source_root=root, agent=agent
            )
            status = "updated"
            cache_type = "directory"
        elif cache_version_path.is_dir():
            # Already a real per-agent directory. Overlay source files
            # except node_modules so operator edits to source reach the
            # cache while the expensive dependency tree is preserved in
            # place. Re-walking node_modules on every agent start can
            # block launch behind filesystem/AV scans on live installs.
            skip_names = set()
            if (cache_version_path / NODE_MODULES_NAME).is_dir():
                skip_names.add(NODE_MODULES_NAME)
            changed = overlay_source_to_cache(
                source_path,
                cache_version_path,
                source_root=root,
                skip_names=skip_names,
                agent=agent,
            )
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
            overlay_source_to_cache(
                source_path, cache_version_path, source_root=root, agent=agent
            )
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
            overlay_source_to_cache(
                source_path, cache_version_path, source_root=root, agent=agent
            )
            status = "linked"
            cache_type = "directory"
    except RequiredContractUnreadable as exc:
        # Issue #1663 — a REQUIRED plugin-contract entry (plugin.json,
        # package.json, server.ts/js, mcp.json/.mcp.json) could not be
        # copied into the cache. Silently shipping a cache missing its
        # contract file is worse than failing, so fail loud here. Unknown
        # sidecars/unreadable entries do NOT reach this branch — they are
        # skipped + WARN'd inside `_overlay_entry()`.
        return {
            "channel": channel,
            "plugin": plugin_name,
            "marketplace": marketplace_name,
            "version": version,
            "source": str(source_path),
            "cache": str(cache_version_path),
            "cache_type": cache_type,
            "status": "install-failed",
            # exc message already carries the `required-contract-unreadable:`
            # tag (set at the raise site in `_overlay_entry`).
            "reason": str(exc),
        }
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
    elif not _plugin_source_declares_deps(source_path):
        # Issue #1282 (Surface B) — `.mjs` proxy plugins (e.g.
        # `cosmax-ep-approval`'s `ep-mcp-proxy.mjs`) use Node.js inline
        # deps and ship without a `package.json`/lockfile. The seed
        # used to emit `node_modules=missing` for these, which painted
        # the operator dashboard with cosmetic false-positive noise.
        # Mark the field honestly: this plugin's source does not
        # declare deps, so no `node_modules` directory is expected.
        node_modules_status = "not-required"
        node_modules_target = ""
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
        "known_marketplace": catalog_reason,
        "node_modules_status": node_modules_status,
        "node_modules_target": node_modules_target,
        "orphan_removed": str(orphan_removed),
    }


_VERIFIED_STATUSES = frozenset(
    {"linked-verified", "updated-verified", "unchanged-verified"}
)
_BENIGN_STATUSES = frozenset({"ignored"})


def _is_required_channel(channel: str, required: set[str], optional: set[str]) -> bool:
    """Return True when this channel should block on failure (Q4 split).

    Decision tree:
      1. channel ∈ required (operator listed in BRIDGE_AGENT_CHANNELS) → required.
      2. channel ∈ optional (BRIDGE_AGENT_PLUGINS only) → NOT required.
      3. Both sets EMPTY (legacy caller without splits) → required (back-compat
         with pre-v0.9.7 bridge-run sync helper).
      4. Operator declared splits but this channel is in neither (e.g. orphan
         from --channels but absent from both --required and --optional) →
         NOT required (conservative; don't block on unlisted plugins).

    r6 codex catch — earlier signature only took `required` and returned
    True when `not required`, but with the r5 classification reorder
    that empty-required fallback fired EVEN when --optional-channels
    was non-empty, demoting genuinely optional plugins to channel-required.
    """
    if channel in required:
        return True
    if channel in optional:
        return False
    if not required and not optional:
        return True
    return False


def _now_iso_utc() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{datetime.now(timezone.utc).microsecond // 1000:03d}Z"


def _manifest_entry_already_correct(payload: dict, entry: dict[str, str]) -> bool:
    """Return True if the manifest already has a correct entry for this plugin.

    Used by the read-only pre-check so an isolated agent whose plugins dir is
    root-owned but already-correct does not have to acquire a writable lock.
    "Correct" means: an entry exists for `<plugin>@<marketplace>`, its first
    element is a dict, and both `installPath` and `version` already match the
    verified-cache values we would otherwise write. `installedAt` and
    `lastUpdated` are deliberately ignored — they drift across launches and
    are not a correctness signal.
    """
    plugin_name = entry.get("plugin", "")
    marketplace = entry.get("marketplace", "")
    version = entry.get("version", "")
    install_path = entry.get("cache", "")
    if not plugin_name or not marketplace or not install_path:
        return False
    key = f"{plugin_name}@{marketplace}"
    existing_list = (payload.get("plugins") or {}).get(key)
    if not isinstance(existing_list, list) or not existing_list:
        return False
    first = existing_list[0]
    if not isinstance(first, dict):
        return False
    if first.get("installPath") != install_path:
        return False
    if first.get("version") != version:
        return False
    return True


def _read_manifest_payload(target: Path) -> tuple[dict, str | None]:
    """Read the manifest as JSON. Returns (payload, error_reason).

    Empty / missing → default `{"version": 2, "plugins": {}}` with no error.
    Read or parse failure → `({}, reason)`.
    """
    if not target.is_file():
        return {"version": 2, "plugins": {}}, None
    try:
        return json.loads(target.read_text(encoding="utf-8")), None
    except (OSError, json.JSONDecodeError) as exc:
        return {}, f"read-failed: {exc}"


def _update_installed_plugins_manifest(
    plugins_root: Path,
    verified_entries: list[dict[str, str]],
) -> tuple[bool, str]:
    """Merge verified plugin entries into <plugins_root>/installed_plugins.json.

    Returns (ok, reason). The contract is now stricter than the first draft:

      - If every verified entry is already correctly represented in the
        manifest (matching `installPath` + `version`), return
        `(True, "already-correct")` WITHOUT taking the writable lock. This is
        the path isolated-UID agents fall through when their root-owned
        manifest was populated by a separate share-catalog process.
      - If a write is required and the lock cannot be acquired, return
        `(False, "lock-open-failed: ...")` etc. The caller must treat this as
        a required-failure for channel-required plugins (silent-success
        elimination per r1 review feedback).
      - Atomic write via tempfile + os.replace under a sidecar
        `installed_plugins.json.lock` flock — we replace the target inode, so
        locking the target file itself races with the swap.

    Per-entry policy when writing: preserve `installedAt` if the same plugin
    entry exists; always refresh `installPath`, `version`, `lastUpdated`.
    Other plugin entries are preserved verbatim.
    """
    import errno
    import fcntl
    import tempfile

    if not verified_entries:
        return True, "no-op"

    target = plugins_root / "installed_plugins.json"
    lock_path = plugins_root / "installed_plugins.json.lock"

    # Read-only pre-check: when the manifest already has correct entries for
    # every verified plugin, no write is needed. This is what lets isolated
    # agents (root-owned plugins dir) skip the writable lock when the
    # share-catalog path already populated their manifest correctly.
    pre_payload, pre_err = _read_manifest_payload(target)
    if pre_err is None:
        all_correct = all(
            _manifest_entry_already_correct(pre_payload, entry)
            for entry in verified_entries
        )
        if all_correct:
            return True, "already-correct"

    try:
        plugins_root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        return False, f"mkdir-failed: {exc}"

    try:
        lock_fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as exc:
        return False, f"lock-open-failed: {exc}"

    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
        except OSError as exc:
            return False, f"flock-failed: {exc}"

        existing_mode = 0o600
        if target.is_file():
            try:
                existing_mode = target.stat().st_mode & 0o777
            except OSError:
                pass
            try:
                payload = json.loads(target.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                return False, f"read-failed: {exc}"
        else:
            payload = {"version": 2, "plugins": {}}

        plugins = payload.setdefault("plugins", {})
        now = _now_iso_utc()
        changed = False

        for entry in verified_entries:
            plugin_name = entry.get("plugin", "")
            marketplace = entry.get("marketplace", "")
            version = entry.get("version", "")
            install_path = entry.get("cache", "")
            if not plugin_name or not marketplace or not install_path:
                continue
            key = f"{plugin_name}@{marketplace}"
            existing_list = plugins.get(key) or []
            installed_at = now
            if isinstance(existing_list, list) and existing_list:
                first = existing_list[0]
                if isinstance(first, dict) and "installedAt" in first:
                    installed_at = first["installedAt"]
            new_entry = {
                "scope": "user",
                "installPath": install_path,
                "version": version,
                "installedAt": installed_at,
                "lastUpdated": now,
            }
            if isinstance(existing_list, list) and existing_list:
                existing_first = existing_list[0] if isinstance(existing_list[0], dict) else {}
                merged = dict(existing_first)
                merged.update(new_entry)
                if merged == existing_first:
                    continue
                existing_list[0] = merged
                plugins[key] = existing_list
            else:
                plugins[key] = [new_entry]
            changed = True

        if not changed:
            return True, "no-change"

        try:
            tmp_fd, tmp_name = tempfile.mkstemp(
                prefix="installed_plugins.", suffix=".json.tmp", dir=str(plugins_root)
            )
        except OSError as exc:
            return False, f"tempfile-failed: {exc}"
        try:
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as fp:
                json.dump(payload, fp, ensure_ascii=False, indent=2)
                fp.write("\n")
            os.chmod(tmp_name, existing_mode)
            os.replace(tmp_name, str(target))
        except OSError as exc:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            if exc.errno == errno.EACCES:
                return False, f"eacces (root-owned manifest, fail-soft): {exc}"
            return False, f"write-failed: {exc}"

        return True, "updated"
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            os.close(lock_fd)
        except OSError:
            pass


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
    # r5 codex catch (BLOCKING) — channel-required wins over optional
    # when a plugin appears in BOTH lists. The earlier ordering had
    # optional winning, which violated the original PR 2 spec
    # ("channel-required = block, optional = warn+continue; both lists
    # = channel-required is critical path"). Channel membership
    # (BRIDGE_AGENT_CHANNELS=plugin:teams) means messages flow through
    # that plugin — silently launching without it kills inbound
    # delivery. Subtract required from optional so that any overlap
    # is treated as channel-required.
    optional_set -= required_set
    agent_label = args.agent or "-"

    results = [
        sync_plugin_cache(resolve_marketplace_root(root, item), item, agent=args.agent)
        for item in normalize_channels(args.channels)
    ]

    # Tag each result with criticality so the downstream reporter and
    # exit-code logic can apply the Q4 split uniformly.
    required_failures: list[dict[str, str]] = []
    optional_failures: list[dict[str, str]] = []
    for item in results:
        channel = item.get("channel", "")
        status = item.get("status", "unknown")
        # r5/r6 — pass BOTH sets so the helper can distinguish:
        #   in required → channel-required (block)
        #   in optional → optional (warn)
        #   neither + both empty → channel-required (legacy back-compat)
        #   neither + at least one set populated → optional (conservative)
        if _is_required_channel(channel, required_set, optional_set):
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

    # After per-plugin verification, register the verified entries in the
    # agent's installed_plugins.json so Claude's plugin loader treats them as
    # installed (not just cached). Without this, non-isolated agents that
    # use --dangerously-load-development-channels still report
    # `plugin: <X>@<marketplace> · plugin not installed` in the Claude pane.
    # Sales_sean (isolated) avoids this because its catalog share path
    # already populates the manifest; the helper's read-only pre-check
    # returns `already-correct` and skips the writable lock there.
    verified_for_manifest = [
        item for item in results if item.get("status") in _VERIFIED_STATUSES
    ]
    manifest_status, manifest_reason = _update_installed_plugins_manifest(
        claude_plugins_root(),
        verified_for_manifest,
    )
    manifest_summary = {
        "ok": manifest_status,
        "reason": manifest_reason,
        "verified_count": len(verified_for_manifest),
        "plugins_root": str(claude_plugins_root()),
    }

    # Manifest write failure is fatal for channel-required plugins UNLESS the
    # read-only pre-check already certified the entries as `already-correct`
    # (which counts as ok=True, never reaches this branch). Per r1 review:
    # silent success when cache verifies but manifest is missing/stale is the
    # bug class the dev-cache linker was already trying to eliminate; the
    # manifest write completes that contract for non-isolated agents.
    if not manifest_status:
        for item in verified_for_manifest:
            channel = item.get("channel", "")
            if not _is_required_channel(channel, required_set, optional_set):
                continue
            item_copy = dict(item)
            item_copy["status"] = "manifest-write-failed"
            item_copy["reason"] = manifest_reason
            required_failures.append(item_copy)

    if args.json:
        json.dump(
            {
                "results": results,
                "agent": args.agent,
                "required_failure_count": len(required_failures),
                "optional_failure_count": len(optional_failures),
                "manifest": manifest_summary,
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

    if not manifest_status:
        # Fail-soft: log the reason but don't block launch. Isolated UID
        # agents typically have a root-owned manifest that the share-catalog
        # path maintains; the dev-cache sync running as the isolated UID
        # cannot rewrite it, but that is benign as long as the entry is
        # already present (which the catalog path ensures separately).
        print(
            f"WARNING: installed_plugins.json merge skipped — {manifest_reason} "
            f"(plugins_root={claude_plugins_root()}, agent={agent_label})"
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
