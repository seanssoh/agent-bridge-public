#!/usr/bin/env python3
"""v0.7.x telegram-relay residue cleanup.

Idempotent best-effort cleanup of any leftover state from the v0.6.37+
relay daemon (#475 phases 2/3, removed in v0.7.0 #501). Designed to run
once during ``agent-bridge upgrade --apply`` so operators do not have to
hand-paste the cleanup steps from
``docs/proposals/v0.7.0-install-cleanup-verification-prompt.md``.

Touched surface:

- ``state/channels/telegram/{tokens.list, *.sock, <token-hash>/}``
- ``agents/<agent>/.telegram/relay-token`` (per-agent token files)
- ``agent-roster.local.sh``:
  - ``BRIDGE_AGENT_CHANNELS["X"]`` containing ``plugin:telegram-relay@*``
    is rewritten to drop the relay item and ensure
    ``plugin:telegram@claude-plugins-official`` is present
  - ``BRIDGE_AGENT_LAUNCH_CMD["X"]`` containing the development-channel
    relay loader (``--dangerously-load-development-channels
    plugin:telegram-relay@<spec>`` in either whitespace or ``=`` form,
    plus dangling bare ``plugin:telegram-relay@<spec>`` tokens) is
    rewritten to drop the relay loader. Quote style and unrelated args
    (other dev channels, env assignments, flags) are preserved.
  - ``BRIDGE_TELEGRAM_RELAY_ENABLED`` and ``BRIDGE_TELEGRAM_USE_RELAY``
    scalar lines are deleted (matches both bare and ``export`` form)
- Source-deleted relay files left over from v0.6.37+ installs upgraded
  to v0.7.0+ (live-runtime is additive-only, so the upgrader cannot
  delete them as a side effect of the source diff). Versioned manifest:
  ``lib/telegram-relay.py``, ``bridge-telegram-relay.sh``,
  ``plugins/telegram-relay/``. Symlinks at any of these paths are
  refused (logged as ``prune_skipped``) — the operator likely retargeted
  them deliberately.
- Stale relay processes whose ``argv`` is rooted under the configured
  ``--target-root`` (``<target_root>/lib/telegram-relay.py`` or
  ``<target_root>/plugins/telegram-relay/...``). SIGTERM, then SIGKILL
  on the holdouts after ``--term-timeout`` seconds. The path-prefix
  anchor is required so a different install on the same host is not
  affected.

Preserved:

- Per-agent ``.telegram/.env`` and ``.telegram/access.json`` — the
  official ``plugin:telegram@claude-plugins-official`` still reads them.
- Anything else under ``state/channels/telegram/`` that does not match
  the deletion patterns (none should exist post-PR3, but defensive).

Stdlib only (``psutil`` is used opportunistically for stale-process
discovery; the tool falls back to parsing ``ps -eo pid,args`` when
``psutil`` is not importable). Returns JSON summary on stdout when
``--json`` is set.

Exit code:
  0 — success or no-op
  1 — hard error (filesystem permission, malformed roster file)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

ENV_KEYS_TO_REMOVE = (
    "BRIDGE_TELEGRAM_RELAY_ENABLED",
    "BRIDGE_TELEGRAM_USE_RELAY",
)

CHANNEL_LINE_RE = re.compile(
    r'^([ \t]*BRIDGE_AGENT_CHANNELS\["([^"]+)"\]=)"([^"]*)"(.*)$'
)

# v0.7.0 (#501) deleted these from source. Live-runtime upgrade is
# additive-only, so a versioned removal manifest is the safe path —
# generic mtime/size diffs would also nuke node_modules and other
# legitimately-present runtime trees.
TELEGRAM_RELAY_LIVE_FILES = (
    "lib/telegram-relay.py",
    "bridge-telegram-relay.sh",
)
TELEGRAM_RELAY_LIVE_DIRS = (
    "plugins/telegram-relay",
)

# Launch-cmd assignment forms. Two patterns instead of a single backref
# group because Bash treats the two quote styles as distinct tokens at
# parse time and the operator's existing quote choice must round-trip.
LAUNCH_CMD_LINE_DOUBLE_RE = re.compile(
    r'^(?P<prefix>[ \t]*BRIDGE_AGENT_LAUNCH_CMD\["(?P<agent>[^"]+)"\]=)'
    r'"(?P<value>[^"]*)"(?P<suffix>.*)$'
)
LAUNCH_CMD_LINE_SINGLE_RE = re.compile(
    r"^(?P<prefix>[ \t]*BRIDGE_AGENT_LAUNCH_CMD\[\"(?P<agent>[^\"]+)\"\]=)"
    r"'(?P<value>[^']*)'(?P<suffix>.*)$"
)
# Anything that starts with the assignment but neither close-quote form
# matched (escapes, multi-line continuations, eval-style values). The
# operator gets a heads-up via ``unparsed_launch_cmd_lines`` rather than
# a silent partial rewrite.
LAUNCH_CMD_LINE_ANY_PREFIX_RE = re.compile(
    r'^[ \t]*BRIDGE_AGENT_LAUNCH_CMD\[(?:"(?P<agent>[^"]+)"|\S+)\]='
)

# Removes the ``--dangerously-load-development-channels`` option in
# either whitespace-separated or ``=``-separated form when paired with
# a ``plugin:telegram-relay@<spec>`` argument.
RELAY_DEV_CHANNEL_RE = re.compile(
    r"--dangerously-load-development-channels[= ]plugin:telegram-relay@\S+"
)
# Dangling bare token left over after the option was stripped, or after
# operator hand-edits removed only the option half of the pair.
RELAY_BARE_TOKEN_RE = re.compile(r"\bplugin:telegram-relay@\S+")


def _load_text(path: Path) -> str | None:
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8")


def _atomic_write(path: Path, text: str) -> None:
    """Atomic, mode-preserving write.

    Captures the existing file's permission bits + group ownership before
    writing, then re-applies them to the new file before AND after the
    rename so the result matches the operator's pre-write expectations
    (e.g. a `0600` ``agent-roster.local.sh`` stays `0600` even when the
    process inherits a default `0022` umask). Uses a randomized tmp name
    in the parent directory to avoid both predictable-path squatting and
    symlink-follow attacks against a stale ``.cleanup-tmp`` left from an
    interrupted prior run.
    """
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)

    original_mode: int | None = None
    original_gid: int | None = None
    try:
        st = path.stat()
        original_mode = stat.S_IMODE(st.st_mode)
        original_gid = st.st_gid
    except (FileNotFoundError, OSError):
        original_mode = 0o600  # private default if file is fresh
        original_gid = None

    fd, tmp_str = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".cleanup-tmp",
        dir=str(parent),
    )
    tmp_path = Path(tmp_str)
    try:
        try:
            os.fchmod(fd, original_mode)
        except OSError:
            pass
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        # Re-apply mode in case fchmod was clobbered by an ACL/umask layer
        # between mkstemp and fdopen close.
        try:
            os.chmod(tmp_path, original_mode)
        except OSError:
            pass
        os.replace(tmp_path, path)
        # Belt-and-suspenders: re-apply mode after replace in case a
        # filesystem (or copy-on-write layer) re-derives mode from the
        # parent ACL on rename. Some FUSE backends do this.
        try:
            os.chmod(path, original_mode)
        except OSError:
            pass
        if original_gid is not None:
            try:
                os.chown(path, -1, original_gid)
            except (PermissionError, OSError):
                # gid preservation is best-effort; non-root cleanup
                # cannot reassign group when the operator is not in
                # the target group, and that is acceptable.
                pass
    except Exception:
        try:
            tmp_path.unlink()
        except OSError:
            pass
        raise


def remove_env_lines(roster_path: Path, *, dry_run: bool) -> list[str]:
    """Delete ``BRIDGE_TELEGRAM_RELAY_*`` and ``BRIDGE_TELEGRAM_USE_RELAY``.

    Matches both bare assignment (``KEY=value``) and ``export`` form
    (``export KEY=value``). De-duplicates the returned key list when a key
    appears more than once. Returns ``[]`` if no-op.
    """
    text = _load_text(roster_path)
    if text is None:
        return []
    pattern = re.compile(
        r"^[ \t]*(?:export[ \t]+)?("
        + "|".join(re.escape(k) for k in ENV_KEYS_TO_REMOVE)
        + r")="
    )
    keep: list[str] = []
    removed: list[str] = []
    for line in text.splitlines(keepends=True):
        m = pattern.match(line)
        if m:
            removed.append(m.group(1))
            continue
        keep.append(line)
    if not removed:
        return []
    if not dry_run:
        _atomic_write(roster_path, "".join(keep))
    deduped: list[str] = []
    seen: set[str] = set()
    for k in removed:
        if k not in seen:
            seen.add(k)
            deduped.append(k)
    return deduped


def _is_relay_item(item: str) -> bool:
    item = item.strip()
    return item == "plugin:telegram-relay" or item.startswith("plugin:telegram-relay@")


def rewrite_channels(roster_path: Path, *, dry_run: bool) -> list[str]:
    """Rewrite ``BRIDGE_AGENT_CHANNELS`` lines that contain a relay variant.

    For each affected line: drop every ``plugin:telegram-relay*`` item
    from the comma-separated list, ensure
    ``plugin:telegram@claude-plugins-official`` is present (added if not
    already in the kept list). Returns the agent names whose lines were
    rewritten (in roster order, with duplicates if the same agent is
    declared more than once — the helper preserves whatever shape the
    operator wrote).
    """
    text = _load_text(roster_path)
    if text is None:
        return []
    new_lines: list[str] = []
    affected: list[str] = []
    for line in text.splitlines(keepends=True):
        m = CHANNEL_LINE_RE.match(line.rstrip("\n"))
        if not m:
            new_lines.append(line)
            continue
        prefix, agent, csv, suffix = m.group(1), m.group(2), m.group(3), m.group(4)
        items = [s.strip() for s in csv.split(",") if s.strip()]
        if not any(_is_relay_item(it) for it in items):
            new_lines.append(line)
            continue
        kept: list[str] = []
        seen_official = False
        for it in items:
            if _is_relay_item(it):
                continue
            if it == "plugin:telegram@claude-plugins-official":
                seen_official = True
            kept.append(it)
        if not seen_official:
            kept.append("plugin:telegram@claude-plugins-official")
        rewritten = f'{prefix}"{",".join(kept)}"{suffix}'
        if not rewritten.endswith("\n"):
            rewritten += "\n"
        new_lines.append(rewritten)
        affected.append(agent)
    if not affected:
        return []
    if not dry_run:
        _atomic_write(roster_path, "".join(new_lines))
    return affected


def remove_state_files(state_root: Path, *, dry_run: bool) -> list[str]:
    """Remove orphaned relay state under ``state/channels/telegram/``.

    Targets: ``tokens.list``, ``*.sock``, and any subdirectory (the
    ``<token-hash>/`` daemon state dirs). Returns paths removed in
    deterministic (sorted) order.
    """
    if not state_root.is_dir():
        return []
    removed: list[str] = []
    tokens = state_root / "tokens.list"
    if tokens.is_file():
        if not dry_run:
            tokens.unlink()
        removed.append(str(tokens))
    for sock in sorted(state_root.glob("*.sock")):
        if not dry_run:
            try:
                sock.unlink()
            except FileNotFoundError:
                continue
        removed.append(str(sock))
    for sub in sorted(state_root.iterdir()):
        if sub.is_dir() and not sub.is_symlink():
            if not dry_run:
                _rmtree_safe(sub)
            removed.append(str(sub) + "/")
    return removed


def _rmtree_safe(path: Path) -> None:
    """Recursively delete; never follows symlinks, never crosses bind mounts."""
    if path.is_symlink() or not path.is_dir():
        try:
            path.unlink()
        except (FileNotFoundError, IsADirectoryError):
            pass
        return
    for child in path.iterdir():
        _rmtree_safe(child)
    path.rmdir()


def remove_per_agent_relay_tokens(agents_root: Path, *, dry_run: bool) -> list[str]:
    """Remove ``<agent>/.telegram/relay-token`` files. Returns paths removed."""
    if not agents_root.is_dir():
        return []
    removed: list[str] = []
    for agent_dir in sorted(agents_root.iterdir()):
        if not agent_dir.is_dir() or agent_dir.is_symlink():
            continue
        relay_token = agent_dir / ".telegram" / "relay-token"
        if relay_token.is_file():
            if not dry_run:
                relay_token.unlink()
            removed.append(str(relay_token))
    return removed


def _strip_relay_tokens(value: str) -> str:
    """Remove relay dev-channel option + dangling bare tokens from a launch cmd."""
    cleaned = RELAY_DEV_CHANNEL_RE.sub("", value)
    cleaned = RELAY_BARE_TOKEN_RE.sub("", cleaned)
    # Collapse runs of whitespace inside the captured value only — the
    # surrounding line (prefix/suffix) is preserved verbatim, so leading
    # indentation and trailing comments survive intact.
    cleaned = re.sub(r"[ \t]{2,}", " ", cleaned)
    return cleaned.strip()


def rewrite_launch_cmds(
    roster_path: Path, *, dry_run: bool
) -> tuple[list[str], list[str]]:
    """Rewrite ``BRIDGE_AGENT_LAUNCH_CMD["X"]=...`` lines that load the relay.

    Returns ``(rewritten_agents, unparsed_lines)``. Lines whose quoting
    matches neither the double- nor single-quoted form (escapes,
    multi-line continuations, ``eval``-style expansions) are recorded
    in ``unparsed_lines`` and left untouched — the operator should
    inspect them by hand. The agent name comes from the assignment
    bracket if parseable, else the (1-indexed) line number.

    Quote style is preserved on rewrite. Other dev channels (e.g.
    ``plugin:teams@agent-bridge``), env assignments before ``claude``,
    and unrelated flags are not touched.
    """
    text = _load_text(roster_path)
    if text is None:
        return [], []
    new_lines: list[str] = []
    rewritten_agents: list[str] = []
    unparsed: list[str] = []
    any_change = False
    for idx, line in enumerate(text.splitlines(keepends=True), start=1):
        stripped = line.rstrip("\n")
        m_double = LAUNCH_CMD_LINE_DOUBLE_RE.match(stripped)
        m_single = LAUNCH_CMD_LINE_SINGLE_RE.match(stripped)
        if m_double is not None:
            quote = '"'
            m = m_double
        elif m_single is not None:
            quote = "'"
            m = m_single
        else:
            prefix_only = LAUNCH_CMD_LINE_ANY_PREFIX_RE.match(stripped)
            if prefix_only is not None:
                agent = prefix_only.group("agent") or f"line-{idx}"
                if RELAY_DEV_CHANNEL_RE.search(stripped) or RELAY_BARE_TOKEN_RE.search(
                    stripped
                ):
                    unparsed.append(agent)
            new_lines.append(line)
            continue
        agent = m.group("agent")
        value = m.group("value")
        suffix = m.group("suffix")
        # If the relay tokens live *outside* the captured value (i.e.
        # in the suffix after the matched closing quote), the value is
        # almost certainly an escaped-quote / multi-token expansion the
        # regex closed prematurely. Touching it would corrupt the
        # operator's intent — surface as unparsed instead.
        if RELAY_DEV_CHANNEL_RE.search(suffix) or RELAY_BARE_TOKEN_RE.search(suffix):
            unparsed.append(agent)
            new_lines.append(line)
            continue
        if not (
            RELAY_DEV_CHANNEL_RE.search(value) or RELAY_BARE_TOKEN_RE.search(value)
        ):
            new_lines.append(line)
            continue
        new_value = _strip_relay_tokens(value)
        if new_value == value:
            new_lines.append(line)
            continue
        rewritten = (
            f"{m.group('prefix')}{quote}{new_value}{quote}{m.group('suffix')}"
        )
        if line.endswith("\n") and not rewritten.endswith("\n"):
            rewritten += "\n"
        new_lines.append(rewritten)
        rewritten_agents.append(agent)
        any_change = True
    if any_change and not dry_run:
        _atomic_write(roster_path, "".join(new_lines))
    return rewritten_agents, unparsed


def _iter_processes_psutil():
    try:
        import psutil  # type: ignore[import-not-found]
    except ImportError:
        return None
    items: list[tuple[int, list[str]]] = []
    for proc in psutil.process_iter(["pid", "cmdline"]):
        try:
            cmdline = proc.info.get("cmdline") or []
            pid = int(proc.info["pid"])
        except (KeyError, TypeError, ValueError):
            continue
        if not cmdline:
            continue
        items.append((pid, list(cmdline)))
    return items


def _iter_processes_ps() -> list[tuple[int, list[str]]]:
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid=,args="], text=True, stderr=subprocess.DEVNULL
        )
    except (FileNotFoundError, subprocess.CalledProcessError, OSError):
        return []
    items: list[tuple[int, list[str]]] = []
    for raw_line in out.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        head, _, rest = line.partition(" ")
        try:
            pid = int(head)
        except ValueError:
            continue
        # ps -o args= already coalesces argv into a single space-joined
        # string. Split on whitespace for prefix-anchor matching; this is
        # lossy but the matcher only needs argv[0..1] for the path check.
        argv = rest.strip().split()
        if not argv:
            continue
        items.append((pid, argv))
    return items


def _stale_relay_match(argv: list[str], target_root: Path) -> str | None:
    """Return the matched absolute path if argv runs telegram-relay under target_root.

    Two argv shapes are accepted:
      1. ``<target_root>/lib/telegram-relay.py ...``
         (when the script is invoked directly via shebang).
      2. ``python3 <target_root>/lib/telegram-relay.py ...``
         (or any python interpreter; checks argv[1] when argv[0] is a
         python binary).

    A path under ``<target_root>/plugins/telegram-relay/...`` is also
    matched (Node child processes spawned out of the relay plugin tree).

    Substring/glob matches against the bare name ``lib/telegram-relay.py``
    are intentionally rejected — a different install on the same host
    must not be affected.
    """
    if not argv:
        return None
    target_str = str(target_root)
    rel_file = str(target_root / "lib" / "telegram-relay.py")
    rel_plugin_prefix = str(target_root / "plugins" / "telegram-relay") + os.sep
    rel_plugin_exact = str(target_root / "plugins" / "telegram-relay")

    # The interpreter case: argv[0] looks like python (case-insensitive
    # matches the macOS Python.framework `Python` binary too), argv[1]
    # is the path.
    candidates: list[str] = []
    head = argv[0]
    head_base = os.path.basename(head).lower()
    if head_base.startswith("python") and len(argv) >= 2:
        candidates.append(argv[1])
    candidates.append(head)

    for cand in candidates:
        if not cand:
            continue
        if cand == rel_file:
            return cand
        if cand == rel_plugin_exact or cand.startswith(rel_plugin_prefix):
            return cand
        # Defensive: reject anything that does not literally start with
        # the absolute target_root path. This is the path-prefix anchor
        # the issue body calls out.
        if not cand.startswith(target_str + os.sep):
            continue
    return None


def stop_stale_relay_processes(
    target_root: Path, *, dry_run: bool, term_timeout: float = 8.0
) -> list[str]:
    """SIGTERM (then SIGKILL) relay processes rooted under ``target_root``.

    Returns a list of redacted descriptors ``"<pid>:<matched-path>"`` —
    intentionally **does not** include raw argv because the relay's argv
    can carry ``--token-file`` paths under credential directories. Each
    matched-path is one we already constructed from ``target_root``, so
    it is known-safe to log.
    """
    procs = _iter_processes_psutil()
    if procs is None:
        procs = _iter_processes_ps()
    matches: list[tuple[int, str]] = []
    self_pid = os.getpid()
    for pid, argv in procs:
        if pid == self_pid:
            continue
        matched = _stale_relay_match(argv, target_root)
        if matched is not None:
            matches.append((pid, matched))
    redacted = [f"{pid}:{path}" for pid, path in matches]
    if dry_run or not matches:
        return redacted

    # SIGTERM phase.
    for pid, _ in matches:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            continue

    deadline = time.monotonic() + max(0.5, term_timeout)
    survivors = list(matches)
    while survivors and time.monotonic() < deadline:
        time.sleep(0.25)
        still_alive: list[tuple[int, str]] = []
        for pid, path in survivors:
            try:
                # Signal 0 = "still there?" probe.
                os.kill(pid, 0)
                still_alive.append((pid, path))
            except (ProcessLookupError, OSError):
                continue
        survivors = still_alive

    # SIGKILL holdouts.
    for pid, _ in survivors:
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            continue
    return redacted


def prune_live_files(
    target_root: Path, *, dry_run: bool
) -> tuple[list[str], list[str]]:
    """Delete v0.7.0-deleted relay files left in the live runtime.

    Returns ``(pruned_relpaths, skipped_relpaths)``. ``skipped`` covers
    paths that exist but are symlinks (refused on safety grounds — the
    operator likely retargeted them deliberately, and following could
    delete an unrelated tree). Missing paths are silently ignored.
    """
    pruned: list[str] = []
    skipped: list[str] = []
    for relpath in TELEGRAM_RELAY_LIVE_FILES:
        path = target_root / relpath
        if path.is_symlink():
            skipped.append(relpath)
            continue
        if not path.exists():
            continue
        if not dry_run:
            try:
                path.unlink()
            except FileNotFoundError:
                continue
        pruned.append(relpath)
    for relpath in TELEGRAM_RELAY_LIVE_DIRS:
        path = target_root / relpath
        if path.is_symlink():
            skipped.append(relpath)
            continue
        if not path.exists():
            continue
        if not dry_run:
            _rmtree_safe(path)
        pruned.append(relpath)
    return pruned, skipped


def _backup_live_paths(
    target_root: Path,
    relpaths: list[str],
    *,
    backup_root: Path,
) -> None:
    """Copy each relpath under ``backup_root/live/`` before prune.

    Used when the cleanup runs **outside** ``agent-bridge upgrade --apply``
    (no upgrader-managed backup to extend). Mirrors the layout that
    ``bridge-upgrade.py backup-extend-live`` produces so an operator who
    needs to recover can re-use the same restore tooling. Symlinks are
    not followed (matches ``_rmtree_safe`` semantics).
    """
    backup_live = backup_root / "live"
    for relpath in relpaths:
        src = target_root / relpath
        dst = backup_live / relpath
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_symlink():
            # Should not happen — prune_live_files refuses symlinks —
            # but defensive in case the caller passes a list it did
            # not derive from prune_live_files.
            continue
        if src.is_dir():
            shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
        elif src.is_file():
            shutil.copy2(src, dst, follow_symlinks=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--target-root",
        required=True,
        help="BRIDGE_HOME equivalent (the live runtime root).",
    )
    parser.add_argument(
        "--roster-file",
        help="Override roster path; default <target-root>/agent-roster.local.sh",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Detect only; do not modify any file.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON summary on stdout (default: human key: value lines).",
    )
    parser.add_argument(
        "--term-timeout",
        type=float,
        default=8.0,
        help="Seconds to wait between SIGTERM and SIGKILL for stale relay procs.",
    )
    parser.add_argument(
        "--backup-root",
        help=(
            "Override the standalone-run backup directory. Default: "
            "<target-root>/backups/relay-cleanup-<UTC-stamp>/. "
            "Ignored when run from `agent-bridge upgrade --apply` (the "
            "upgrader provides its own backup via `backup-extend-live`)."
        ),
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help=(
            "Skip the standalone-run backup before pruning live files. "
            "Use only when the upgrader is calling this tool (it has "
            "already extended the upgrade backup manifest)."
        ),
    )
    args = parser.parse_args()

    target_root = Path(args.target_root).expanduser()
    roster_file = Path(args.roster_file or (target_root / "agent-roster.local.sh"))
    state_root = target_root / "state" / "channels" / "telegram"
    agents_root = target_root / "agents"

    backup_root: Path | None = None

    try:
        # 1. Rewrite launch commands first. Future sessions stop loading
        #    the relay plugin tree; live processes are not yet affected.
        launch_cmds_rewritten, unparsed_launch_cmd_lines = rewrite_launch_cmds(
            roster_file, dry_run=args.dry_run
        )
        # 2. Existing channel rewrite (also touches agent-roster.local.sh).
        agents_migrated = rewrite_channels(roster_file, dry_run=args.dry_run)
        # 3. Stop stale relay processes — must happen *before* live-file
        #    prune (mmap'd binaries on Linux can hold the inode open).
        stale_processes_terminated = stop_stale_relay_processes(
            target_root,
            dry_run=args.dry_run,
            term_timeout=max(0.0, float(args.term_timeout)),
        )
        # 4. Live-file prune (Gap B). Compute first so we can backup
        #    pre-deletion when running standalone.
        if args.dry_run:
            live_files_pruned, prune_skipped = prune_live_files(
                target_root, dry_run=True
            )
        else:
            # Plan first (still on disk), backup, then apply.
            planned, prune_skipped = prune_live_files(target_root, dry_run=True)
            if planned and not args.no_backup:
                stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                backup_root = (
                    Path(args.backup_root).expanduser()
                    if args.backup_root
                    else target_root / "backups" / f"relay-cleanup-{stamp}"
                )
                backup_root.mkdir(parents=True, exist_ok=True)
                _backup_live_paths(target_root, planned, backup_root=backup_root)
            live_files_pruned, _ = prune_live_files(target_root, dry_run=False)
        # 5. Existing state cleanup — must run *after* the live-file
        #    prune. If a surviving relay process recreated state between
        #    step 3 and now, this is the catch-up sweep.
        env_keys_removed = remove_env_lines(roster_file, dry_run=args.dry_run)
        state_files_removed = remove_state_files(state_root, dry_run=args.dry_run)
        agent_tokens_removed = remove_per_agent_relay_tokens(
            agents_root, dry_run=args.dry_run
        )
    except OSError as exc:
        print(f"relay-cleanup: filesystem error: {exc}", file=sys.stderr)
        return 1

    summary = {
        "dry_run": args.dry_run,
        "agents_migrated": agents_migrated,
        "env_keys_removed": env_keys_removed,
        "state_files_removed": state_files_removed,
        "agent_tokens_removed": agent_tokens_removed,
        "launch_cmds_rewritten": launch_cmds_rewritten,
        "unparsed_launch_cmd_lines": unparsed_launch_cmd_lines,
        "live_files_pruned": live_files_pruned,
        "prune_skipped": prune_skipped,
        "stale_processes_terminated": stale_processes_terminated,
        "agent_restart_required": list(launch_cmds_rewritten),
        "backup_root": str(backup_root) if backup_root else "",
    }
    summary["any_changes"] = any(
        bool(summary[key])
        for key in (
            "agents_migrated",
            "env_keys_removed",
            "state_files_removed",
            "agent_tokens_removed",
            "launch_cmds_rewritten",
            "live_files_pruned",
            "stale_processes_terminated",
        )
    )

    # Consolidated `changed_paths` for `bridge-upgrade.py backup-extend-live`
    # consumption. The `removed:` prefix matches the convention of the
    # existing backup-extend-live API (paths that will be deleted are
    # recorded so rollback can restore them, identical handling to
    # files that will be modified-in-place). Live-file prunes are
    # emitted as absolute paths so the upgrader's relpath-vs-target-root
    # check resolves correctly.
    changed: list[str] = []
    if agents_migrated or env_keys_removed or launch_cmds_rewritten:
        changed.append(str(roster_file))
    for path_str in state_files_removed:
        changed.append(f"removed:{path_str}")
    for path_str in agent_tokens_removed:
        changed.append(f"removed:{path_str}")
    for relpath in live_files_pruned:
        changed.append(f"removed:{target_root / relpath}")
    summary["changed_paths"] = changed

    if args.json:
        print(json.dumps(summary, sort_keys=True))
    else:
        for key, value in summary.items():
            print(f"{key}: {value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
